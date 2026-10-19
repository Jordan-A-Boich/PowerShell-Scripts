<#
.SYNOPSIS
    Interactive CDC job health check and repair for SQL Server, focused on
    Availability Groups.

.DESCRIPTION
    Prompt-driven - no parameters to memorize. Point it at a server (any
    replica works; it finds the primary) and it reports a rolled-up view of
    the current CDC topology, then flags the common ways CDC drifts out of
    shape in an AG:

      - missing capture or cleanup jobs on the primary
      - capture job missing the 'Start Every 5 Minutes' restart schedule
      - capture/cleanup jobs missing (or carrying an outdated/wrong-AG)
        'Check To See If Primary' first step
      - secondary replicas missing msdb.dbo.cdc_jobs / cdc_jobs_view
      - secondary replicas whose job definitions or cdc_jobs settings
        (maxtrans, maxscans, retention, ...) do not match the primary

    Note on job_id: the settings values in msdb.dbo.cdc_jobs sync from the
    primary, but job_id is per-replica. Each replica's own msdb.dbo.sysjobs
    is the source of truth for it, so both the drift check and the fix map
    cdc_jobs.job_id to the LOCAL job on that replica - the primary's job_id
    values are never copied to a secondary.

    You then choose to fix everything or just specific findings by number.
    Databases published for transactional replication are handled: the Log
    Reader Agent performs capture there, so a missing capture job is expected
    and not reported.

    Optional environment variables (skip the matching prompt when set):
      DBA_SERVERS   - server name
      DBA_USERNAME  - SQL login (omit for Windows authentication)
      DBA_PASSWORD  - SQL password
#>

$ErrorActionPreference = 'Stop'

# --- Script-scoped connection state -------------------------------------------
$script:SqlUser = ''
$script:SqlPassword = ''

# --- Output helpers ------------------------------------------------------------
function Write-Ok   { param([string]$M) Write-Host "  [OK]   $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "  [..]   $M" }
function Write-Warn { param([string]$M) Write-Host "  [WARN] $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [FAIL] $M" -ForegroundColor Red }

# --- SQL helpers ----------------------------------------------------------------
function New-CdcConnectionString {
    param([string]$Server, [string]$Database = 'master')
    if ($script:SqlUser) {
        return "Server=$Server;Database=$Database;User ID=$($script:SqlUser);Password=$($script:SqlPassword);TrustServerCertificate=True;Connection Timeout=15"
    }
    return "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Connection Timeout=15"
}

function Invoke-CdcSql {
    <# Runs a query and returns the rows of the first result set as an array. #>
    param(
        [Parameter(Mandatory)] [string]$Server,
        [string]$Database = 'master',
        [Parameter(Mandatory)] [string]$Query,
        [hashtable]$Parameters,
        [switch]$NonQuery
    )
    $conn = New-Object System.Data.SqlClient.SqlConnection (New-CdcConnectionString $Server $Database)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 120
        if ($Parameters) {
            foreach ($k in $Parameters.Keys) {
                $v = $Parameters[$k]
                if ($null -eq $v) { $v = [System.DBNull]::Value }
                [void]$cmd.Parameters.AddWithValue($k, $v)
            }
        }
        if ($NonQuery) {
            [void]$cmd.ExecuteNonQuery()
            return
        }
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        # Comma prevents the pipeline from unrolling a single-row result to a bare DataRow.
        $rows = @($dt.Rows)
        return , $rows
    } finally {
        $conn.Dispose()
    }
}

# --- Prompt helpers --------------------------------------------------------------
function Read-PromptLine {
    <# Prompt for one line. With redirected stdin (piped answers) it reads from
       [Console]::In exclusively - mixing Peek/ReadLine with Read-Host desyncs
       their buffers - and aborts cleanly at end of input instead of looping. #>
    param([Parameter(Mandatory)][string]$Label)
    if ([Console]::IsInputRedirected) {
        Write-Host "${Label}: " -NoNewline
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            Write-Host ''
            throw 'Input ended before all prompts were answered - aborting.'
        }
        Write-Host $line
        return $line
    }
    return Read-Host $Label
}

function Read-Answer {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $label = $Prompt
    if ($Default) { $label = "$Prompt [$Default]" }
    $answer = Read-PromptLine $label
    if (-not $answer) { return $Default }
    return $answer.Trim()
}

function Read-FixSelection {
    <# Prompts for finding numbers, 'all', or blank (= none). Returns int[]. #>
    param([Parameter(Mandatory)][int]$Count)
    while ($true) {
        $raw = Read-PromptLine "Fix findings - numbers (e.g. 1,3), 'all', or Enter to exit"
        if (-not $raw -or -not $raw.Trim()) { return @() }
        if ($raw.Trim().ToLower() -eq 'all') { return @(1..$Count) }
        $picked = New-Object System.Collections.Generic.List[int]
        $valid = $true
        foreach ($part in ($raw -split ',')) {
            $n = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $Count) {
                Write-Warn "'$($part.Trim())' is not a valid choice (1-$Count or 'all')."
                $valid = $false
                break
            }
            if (-not $picked.Contains($n)) { $picked.Add($n) }
        }
        if ($valid) { return $picked.ToArray() }
    }
}

function ConvertTo-PlainText {
    param([securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Connection -------------------------------------------------------------------
function Connect-CdcServer {
    <# Prompts for server + credentials, verifies connectivity, returns server name. #>
    $defaultServer = ''
    if ($env:DBA_SERVERS) { $defaultServer = ($env:DBA_SERVERS -split ';')[0].Trim() }

    while ($true) {
        $server = Read-Answer 'Server name' $defaultServer
        if (-not $server) { Write-Warn 'A server name is required.'; continue }

        if ($env:DBA_USERNAME) {
            $script:SqlUser = $env:DBA_USERNAME
            $script:SqlPassword = $env:DBA_PASSWORD
        } else {
            $script:SqlUser = Read-Answer 'Login (blank for Windows authentication)'
            if ($script:SqlUser) {
                if ([Console]::IsInputRedirected) {
                    $script:SqlPassword = Read-PromptLine 'Password'
                } else {
                    $script:SqlPassword = ConvertTo-PlainText (Read-Host 'Password' -AsSecureString)
                }
            }
        }

        try {
            $info = Invoke-CdcSql -Server $server -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS v, CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) AS e"
            Write-Ok "Connected to $server (SQL Server $($info[0].v), $($info[0].e))"
            return $server
        } catch {
            Write-Err "Could not connect to '$server': $($_.Exception.GetBaseException().Message)"
            $defaultServer = ''
        }
    }
}

# --- Shared CDC/AG plumbing (same approach as setup-cdc.ps1) -----------------------
$script:CheckPrimaryStepName = 'Check To See If Primary'
# ISNULL makes the guard fail CLOSED: if the AG name does not match anything the
# subquery returns NULL, and NULL <> 'PRIMARY' is UNKNOWN in T-SQL - without the
# wrapper the step would silently pass and let the job run on a secondary.
$script:CheckPrimaryTemplate = @'
IF ISNULL((SELECT
    ars.role_desc
    FROM sys.dm_hadr_availability_replica_states AS ars
    INNER JOIN sys.availability_groups AS ag
    ON ars.group_id = ag.group_id
    WHERE ag.name = '{AGNAME}'
    AND ars.is_local = 1), 'NO MATCHING AG') <> 'PRIMARY'
BEGIN
    RAISERROR ('Stopping job, this is not the primary replica.', 11, 1)
    EXEC msdb.dbo.sp_stop_job @job_id=$(ESCAPE_SQUOTE(JOBID))
END
'@

function Get-ExpectedGuardCommand {
    param([string]$AgName)
    return $script:CheckPrimaryTemplate.Replace('{AGNAME}', $AgName.Replace("'", "''"))
}

function Set-CaptureJobSchedule {
    <# Ensures the capture job has the 'Start Every 5 Minutes' schedule attached. #>
    param([string]$Server, [string]$JobName)
    $schedName = 'Start Every 5 Minutes'
    $add = @'
DECLARE @sid int;
SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = @sched;
IF @sid IS NULL
    EXEC msdb.dbo.sp_add_schedule @schedule_name = @sched, @enabled = 1,
         @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 4, @freq_subday_interval = 5,
         @active_start_time = 0, @schedule_id = @sid OUTPUT;
EXEC msdb.dbo.sp_attach_schedule @job_name = @job, @schedule_id = @sid;
'@
    Invoke-CdcSql -Server $Server -Query $add -Parameters @{ '@job' = $JobName; '@sched' = $schedName } -NonQuery
}

function Test-CaptureJobSchedule {
    param([string]$Server, [string]$JobName)
    $check = @'
SELECT COUNT(*) AS attached
FROM msdb.dbo.sysjobschedules js
JOIN msdb.dbo.sysjobs j     ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
WHERE j.name = @job AND s.name = 'Start Every 5 Minutes'
'@
    $r = Invoke-CdcSql -Server $Server -Query $check -Parameters @{ '@job' = $JobName }
    return ([int]$r[0].attached -gt 0)
}

function Get-GuardStepState {
    <# Returns 'ok', 'missing', or 'outdated' for a job's guard step. #>
    param([string]$Server, [string]$JobName, [string]$AgName)
    $r = Invoke-CdcSql -Server $Server -Query @'
SELECT js.command
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @job AND js.step_name = @step
'@ -Parameters @{ '@job' = $JobName; '@step' = $script:CheckPrimaryStepName }
    if ($r.Count -eq 0) { return 'missing' }
    $expected = Get-ExpectedGuardCommand $AgName
    if ((([string]$r[0].command) -replace '\r?\n', "`n") -eq ($expected -replace '\r?\n', "`n")) { return 'ok' }
    return 'outdated'
}

function Set-CheckPrimaryStep {
    <# Adds or updates the guard step so it matches the expected command. #>
    param([string]$Server, [string]$JobName, [string]$AgName)
    $command = Get-ExpectedGuardCommand $AgName
    $existing = Invoke-CdcSql -Server $Server -Query @'
SELECT js.step_id
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @job AND js.step_name = @step
'@ -Parameters @{ '@job' = $JobName; '@step' = $script:CheckPrimaryStepName }

    if ($existing.Count -gt 0) {
        Invoke-CdcSql -Server $Server -Query 'EXEC msdb.dbo.sp_update_jobstep @job_name = @job, @step_id = @id, @command = @cmd' `
            -Parameters @{ '@job' = $JobName; '@id' = [int]$existing[0].step_id; '@cmd' = $command } -NonQuery
        return
    }
    Invoke-CdcSql -Server $Server -Query @'
EXEC msdb.dbo.sp_add_jobstep @job_name = @job, @step_id = 1, @step_name = @step,
     @subsystem = N'TSQL', @database_name = N'master', @command = @cmd,
     @on_success_action = 3, @on_fail_action = 2, @retry_attempts = 0, @retry_interval = 0;
EXEC msdb.dbo.sp_update_job @job_name = @job, @start_step_id = 1;
'@ -Parameters @{ '@job' = $JobName; '@step' = $script:CheckPrimaryStepName; '@cmd' = $command } -NonQuery
}

function Get-AgSecondaryReplicas {
    param([string]$Server, [string]$AgName)
    $q = @'
SELECT ar.replica_server_name
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = @ag AND ars.role_desc <> 'PRIMARY'
'@
    return @(Invoke-CdcSql -Server $Server -Query $q -Parameters @{ '@ag' = $AgName } | ForEach-Object { $_.replica_server_name })
}

function Initialize-SecondaryCdcMetadata {
    <# Ensures msdb.dbo.cdc_jobs and msdb.dbo.cdc_jobs_view exist on a replica. #>
    param([string]$Server)
    Invoke-CdcSql -Server $Server -Database 'msdb' -Query @'
IF OBJECT_ID('msdb.dbo.cdc_jobs', 'U') IS NULL
BEGIN
    CREATE TABLE msdb.[dbo].[cdc_jobs](
        [database_id] [int] NOT NULL,
        [job_type] [nvarchar](20) NOT NULL,
        [job_id] [uniqueidentifier] NULL,
        [maxtrans] [int] NULL,
        [maxscans] [int] NULL,
        [continuous] [bit] NULL,
        [pollinginterval] [bigint] NULL,
        [retention] [bigint] NULL,
        [threshold] [bigint] NULL,
    PRIMARY KEY CLUSTERED
    (
        [database_id] ASC,
        [job_type] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
    ) ON [PRIMARY]
END
'@ -NonQuery
    Invoke-CdcSql -Server $Server -Database 'msdb' -Query @'
IF OBJECT_ID('msdb.dbo.cdc_jobs_view', 'V') IS NULL
BEGIN
    EXEC('CREATE   VIEW dbo.cdc_jobs_view
    AS
    SELECT distinct db_id(s.database_name) as database_id,
    c.job_type,
    c.job_id,
    c.maxtrans,
    c.maxscans,
    c.continuous,
    c.pollinginterval,
    c.retention,
    c.threshold
    FROM cdc_jobs c join sysjobsteps s on c.job_id = s.job_id')
END
'@ -NonQuery
}

function Get-JobFingerprint {
    <# Canonical string of a job's definition (steps + schedules; owner excluded
       since it may legitimately differ per replica). $null when the job is missing. #>
    param([string]$Server, [string]$JobName)
    $job = Invoke-CdcSql -Server $Server -Query @'
SELECT j.enabled, j.start_step_id, ISNULL(j.description, '') AS description, c.name AS category
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
WHERE j.name = @n
'@ -Parameters @{ '@n' = $JobName }
    if ($job.Count -eq 0) { return $null }

    $steps = Invoke-CdcSql -Server $Server -Query @'
SELECT js.step_id, js.step_name, js.subsystem, ISNULL(js.database_name, '') AS database_name,
       js.on_success_action, js.on_success_step_id, js.on_fail_action, js.on_fail_step_id,
       js.retry_attempts, js.retry_interval, js.command
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @n
ORDER BY js.step_id
'@ -Parameters @{ '@n' = $JobName }

    $schedules = Invoke-CdcSql -Server $Server -Query @'
SELECT s.name, s.enabled, s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval,
       s.freq_relative_interval, s.freq_recurrence_factor,
       s.active_start_date, s.active_end_date, s.active_start_time, s.active_end_time
FROM msdb.dbo.sysschedules s
JOIN msdb.dbo.sysjobschedules js ON s.schedule_id = js.schedule_id
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @n
ORDER BY s.name
'@ -Parameters @{ '@n' = $JobName }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("job|$($job[0].enabled)|$($job[0].start_step_id)|$($job[0].description)|$($job[0].category)")
    foreach ($s in $steps) {
        $cmd = ([string]$s.command) -replace '\r?\n', "`n"
        $parts.Add("step|$($s.step_id)|$($s.step_name)|$($s.subsystem)|$($s.database_name)|$($s.on_success_action)|$($s.on_success_step_id)|$($s.on_fail_action)|$($s.on_fail_step_id)|$($s.retry_attempts)|$($s.retry_interval)|$cmd")
    }
    foreach ($sc in $schedules) {
        $parts.Add("sched|$($sc.name)|$($sc.enabled)|$($sc.freq_type)|$($sc.freq_interval)|$($sc.freq_subday_type)|$($sc.freq_subday_interval)|$($sc.freq_relative_interval)|$($sc.freq_recurrence_factor)|$($sc.active_start_date)|$($sc.active_end_date)|$($sc.active_start_time)|$($sc.active_end_time)")
    }
    return ($parts.ToArray() -join '~|~')
}

function Copy-AgentJob {
    <# Scripts a SQL Agent job from the source server and (re)creates it on the target. #>
    param([string]$SourceServer, [string]$TargetServer, [string]$JobName)

    $job = Invoke-CdcSql -Server $SourceServer -Query @'
SELECT j.name, j.enabled, ISNULL(j.description, '') AS description, j.start_step_id,
       c.name AS category_name, ISNULL(SUSER_SNAME(j.owner_sid), '') AS owner_name
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
WHERE j.name = @n
'@ -Parameters @{ '@n' = $JobName }
    if (-not $job) { throw "Job '$JobName' not found on $SourceServer" }
    $job = $job[0]

    $steps = Invoke-CdcSql -Server $SourceServer -Query @'
SELECT js.step_id, js.step_name, js.subsystem, js.command, ISNULL(js.database_name, '') AS database_name,
       js.on_success_action, js.on_success_step_id, js.on_fail_action, js.on_fail_step_id,
       js.retry_attempts, js.retry_interval
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @n
ORDER BY js.step_id
'@ -Parameters @{ '@n' = $JobName }

    $schedules = Invoke-CdcSql -Server $SourceServer -Query @'
SELECT s.name, s.enabled, s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval,
       s.freq_relative_interval, s.freq_recurrence_factor,
       s.active_start_date, s.active_end_date, s.active_start_time, s.active_end_time
FROM msdb.dbo.sysschedules s
JOIN msdb.dbo.sysjobschedules js ON s.schedule_id = js.schedule_id
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @n
'@ -Parameters @{ '@n' = $JobName }

    Invoke-CdcSql -Server $TargetServer -Query @'
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @cat AND category_class = 1)
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = @cat;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @name)
    EXEC msdb.dbo.sp_delete_job @job_name = @name;
DECLARE @owner sysname = @ownerName;
IF @owner = N'' OR SUSER_SID(@owner) IS NULL SET @owner = SUSER_SNAME();
EXEC msdb.dbo.sp_add_job @job_name = @name, @enabled = @enabled, @description = @desc,
     @category_name = @cat, @owner_login_name = @owner;
EXEC msdb.dbo.sp_add_jobserver @job_name = @name, @server_name = N'(local)';
'@ -Parameters @{
        '@name' = $job.name; '@enabled' = [int]$job.enabled; '@desc' = $job.description
        '@cat' = $job.category_name; '@ownerName' = $job.owner_name
    } -NonQuery

    foreach ($s in $steps) {
        Invoke-CdcSql -Server $TargetServer -Query @'
EXEC msdb.dbo.sp_add_jobstep @job_name = @job, @step_id = @id, @step_name = @stepName,
     @subsystem = @subsystem, @command = @command, @database_name = @dbName,
     @on_success_action = @okAct, @on_success_step_id = @okStep,
     @on_fail_action = @failAct, @on_fail_step_id = @failStep,
     @retry_attempts = @retry, @retry_interval = @retryInt;
'@ -Parameters @{
            '@job' = $job.name; '@id' = [int]$s.step_id; '@stepName' = $s.step_name
            '@subsystem' = $s.subsystem; '@command' = $s.command; '@dbName' = $s.database_name
            '@okAct' = [int]$s.on_success_action; '@okStep' = [int]$s.on_success_step_id
            '@failAct' = [int]$s.on_fail_action; '@failStep' = [int]$s.on_fail_step_id
            '@retry' = [int]$s.retry_attempts; '@retryInt' = [int]$s.retry_interval
        } -NonQuery
    }

    Invoke-CdcSql -Server $TargetServer -Query 'EXEC msdb.dbo.sp_update_job @job_name = @job, @start_step_id = @s' `
        -Parameters @{ '@job' = $job.name; '@s' = [int]$job.start_step_id } -NonQuery

    foreach ($sc in $schedules) {
        Invoke-CdcSql -Server $TargetServer -Query @'
EXEC msdb.dbo.sp_add_jobschedule @job_name = @job, @name = @schedName, @enabled = @enabled,
     @freq_type = @ft, @freq_interval = @fi, @freq_subday_type = @fst, @freq_subday_interval = @fsi,
     @freq_relative_interval = @fri, @freq_recurrence_factor = @frf,
     @active_start_date = @asd, @active_end_date = @aed,
     @active_start_time = @ast, @active_end_time = @aet;
'@ -Parameters @{
            '@job' = $job.name; '@schedName' = $sc.name; '@enabled' = [int]$sc.enabled
            '@ft' = [int]$sc.freq_type; '@fi' = [int]$sc.freq_interval
            '@fst' = [int]$sc.freq_subday_type; '@fsi' = [int]$sc.freq_subday_interval
            '@fri' = [int]$sc.freq_relative_interval; '@frf' = [int]$sc.freq_recurrence_factor
            '@asd' = [int]$sc.active_start_date; '@aed' = [int]$sc.active_end_date
            '@ast' = [int]$sc.active_start_time; '@aet' = [int]$sc.active_end_time
        } -NonQuery
    }
}

function Sync-CdcJobsMetadata {
    <# Copies the msdb.dbo.cdc_jobs rows for a database from primary to a secondary
       and remaps job_id to the secondary's own job ids. #>
    param([string]$PrimaryServer, [string]$SecondaryServer, [string]$Database)

    $rows = Invoke-CdcSql -Server $PrimaryServer -Query @'
SELECT job_type, maxtrans, maxscans, continuous, pollinginterval, retention, threshold
FROM msdb.dbo.cdc_jobs WHERE database_id = DB_ID(@db)
'@ -Parameters @{ '@db' = $Database }

    foreach ($r in $rows) {
        Invoke-CdcSql -Server $SecondaryServer -Query @'
DELETE FROM msdb.dbo.cdc_jobs WHERE database_id = DB_ID(@db) AND job_type = @jt;
INSERT INTO msdb.dbo.cdc_jobs
    (database_id, job_type, job_id, maxtrans, maxscans, continuous, pollinginterval, retention, threshold)
VALUES
    (DB_ID(@db), @jt, NULL, @maxtrans, @maxscans, @continuous, @pollinginterval, @retention, @threshold);
UPDATE c
SET c.job_id = s.job_id
FROM msdb.dbo.sysjobs s
JOIN msdb.dbo.cdc_jobs c
  ON s.name = 'cdc.' + DB_NAME(c.database_id) + '_' + c.job_type
WHERE DB_NAME(c.database_id) = @db AND c.job_type = @jt;
'@ -Parameters @{
            '@db' = $Database; '@jt' = $r.job_type
            '@maxtrans' = $r.maxtrans; '@maxscans' = $r.maxscans; '@continuous' = $r.continuous
            '@pollinginterval' = $r.pollinginterval; '@retention' = $r.retention; '@threshold' = $r.threshold
        } -NonQuery
    }
}

# --- Discovery / analysis ------------------------------------------------------------
function Get-CdcDatabases {
    <# CDC-enabled user databases on the connected server, with AG context. #>
    param([string]$Server)
    $q = @'
SELECT d.name,
       d.is_published,
       ag.name AS ag_name,
       (SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars
         WHERE ars.group_id = ar.group_id AND ars.is_local = 1) AS local_role,
       ags.primary_replica
FROM sys.databases d
LEFT JOIN sys.availability_replicas ar ON d.replica_id = ar.replica_id
LEFT JOIN sys.availability_groups  ag ON ar.group_id  = ag.group_id
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
WHERE d.database_id > 4 AND d.state = 0 AND d.is_cdc_enabled = 1
ORDER BY d.name
'@
    return Invoke-CdcSql -Server $Server -Query $q
}

function Get-SecondaryIssues {
    <# Compares one secondary against the primary. Returns a list of short
       issue descriptions (empty = in sync). #>
    param([string]$PrimaryServer, [string]$SecondaryServer, [string]$Database, [string[]]$JobNames)
    $issues = New-Object System.Collections.Generic.List[string]

    $obj = Invoke-CdcSql -Server $SecondaryServer -Query "SELECT CASE WHEN OBJECT_ID('msdb.dbo.cdc_jobs','U') IS NOT NULL THEN 1 ELSE 0 END AS t, CASE WHEN OBJECT_ID('msdb.dbo.cdc_jobs_view','V') IS NOT NULL THEN 1 ELSE 0 END AS v"
    if ([int]$obj[0].t -ne 1) { $issues.Add('msdb.dbo.cdc_jobs table missing') }
    if ([int]$obj[0].v -ne 1) { $issues.Add('msdb.dbo.cdc_jobs_view missing') }

    foreach ($jobName in $JobNames) {
        $secFp = Get-JobFingerprint $SecondaryServer $jobName
        if ($null -eq $secFp) {
            $issues.Add("job $jobName missing")
            continue
        }
        $priFp = Get-JobFingerprint $PrimaryServer $jobName
        if ($priFp -ne $secFp) { $issues.Add("job $jobName differs from primary") }
    }

    if ([int]$obj[0].t -eq 1) {
        $priRows = Invoke-CdcSql -Server $PrimaryServer -Query @'
SELECT job_type, maxtrans, maxscans, continuous, pollinginterval, retention, threshold
FROM msdb.dbo.cdc_jobs WHERE database_id = DB_ID(@db) ORDER BY job_type
'@ -Parameters @{ '@db' = $Database }
        $secRows = Invoke-CdcSql -Server $SecondaryServer -Query @'
SELECT c.job_type, c.maxtrans, c.maxscans, c.continuous, c.pollinginterval, c.retention, c.threshold,
       CASE WHEN s.name = 'cdc.' + DB_NAME(c.database_id) + '_' + c.job_type THEN 1 ELSE 0 END AS mapped
FROM msdb.dbo.cdc_jobs c
LEFT JOIN msdb.dbo.sysjobs s ON s.job_id = c.job_id
WHERE DB_NAME(c.database_id) = @db ORDER BY c.job_type
'@ -Parameters @{ '@db' = $Database }

        if ($priRows.Count -ne $secRows.Count) {
            $issues.Add('cdc_jobs metadata rows missing or extra')
        } else {
            for ($i = 0; $i -lt $priRows.Count; $i++) {
                $a = $priRows[$i]; $b = $secRows[$i]
                $rowA = "$($a.job_type)|$($a.maxtrans)|$($a.maxscans)|$($a.continuous)|$($a.pollinginterval)|$($a.retention)|$($a.threshold)"
                $rowB = "$($b.job_type)|$($b.maxtrans)|$($b.maxscans)|$($b.continuous)|$($b.pollinginterval)|$($b.retention)|$($b.threshold)"
                if ($rowA -ne $rowB) { $issues.Add("cdc_jobs $($a.job_type) row values differ"); continue }
                if ([int]$b.mapped -ne 1) { $issues.Add("cdc_jobs $($a.job_type) row job_id not mapped to local job") }
            }
        }
    }
    return , @($issues.ToArray())
}

function Get-CdcFindings {
    <# Analyses every CDC-enabled database and returns finding objects with a
       Text for display and a Fix descriptor (Type + arguments). #>
    param([string]$Server, [object[]]$Databases)
    $findings = New-Object System.Collections.Generic.List[object]

    foreach ($db in $Databases) {
        $dbName = [string]$db.name
        $inAg = $db.ag_name -isnot [System.DBNull]
        $agName = ''
        $primary = $Server
        if ($inAg) {
            $agName = [string]$db.ag_name
            if ($db.primary_replica -isnot [System.DBNull] -and [string]$db.primary_replica) {
                $primary = [string]$db.primary_replica
            }
        }
        $isPublished = [bool]$db.is_published
        $captureJob = "cdc.$($dbName)_capture"
        $cleanupJob = "cdc.$($dbName)_cleanup"

        $jobs = @(Invoke-CdcSql -Server $primary -Query 'SELECT name FROM msdb.dbo.sysjobs WHERE name IN (@cap, @cln)' `
            -Parameters @{ '@cap' = $captureJob; '@cln' = $cleanupJob } | ForEach-Object { $_.name })

        # Missing jobs on the primary. A published database uses the Log Reader
        # Agent for capture, so a missing capture job is expected there.
        if (-not $isPublished -and $jobs -notcontains $captureJob) {
            $findings.Add([pscustomobject]@{
                Text = "[$dbName] capture job $captureJob is missing on $primary"
                Fix  = @{ Type = 'add-job'; Server = $primary; Db = $dbName; JobType = 'capture'; InAg = $inAg; AgName = $agName }
            })
        }
        if ($jobs -notcontains $cleanupJob) {
            $findings.Add([pscustomobject]@{
                Text = "[$dbName] cleanup job $cleanupJob is missing on $primary"
                Fix  = @{ Type = 'add-job'; Server = $primary; Db = $dbName; JobType = 'cleanup'; InAg = $inAg; AgName = $agName }
            })
        }

        # Capture job restart schedule.
        if ($jobs -contains $captureJob -and -not (Test-CaptureJobSchedule $primary $captureJob)) {
            $findings.Add([pscustomobject]@{
                Text = "[$dbName] capture job is missing the 'Start Every 5 Minutes' schedule"
                Fix  = @{ Type = 'add-schedule'; Server = $primary; Job = $captureJob }
            })
        }

        if ($inAg) {
            # Guard steps on both jobs.
            foreach ($jobName in $jobs) {
                $state = Get-GuardStepState $primary $jobName $agName
                if ($state -ne 'ok') {
                    $what = 'missing'
                    if ($state -eq 'outdated') { $what = 'outdated or wrong AG name' }
                    $findings.Add([pscustomobject]@{
                        Text = "[$dbName] $jobName '$($script:CheckPrimaryStepName)' step is $what"
                        Fix  = @{ Type = 'fix-step'; Server = $primary; Job = $jobName; AgName = $agName }
                    })
                }
            }

            # Secondary replicas.
            foreach ($sec in (Get-AgSecondaryReplicas $primary $agName)) {
                try {
                    $issues = Get-SecondaryIssues $primary $sec $dbName $jobs
                } catch {
                    $findings.Add([pscustomobject]@{
                        Text = "[$dbName -> $sec] could not inspect secondary: $($_.Exception.GetBaseException().Message)"
                        Fix  = $null
                    })
                    continue
                }
                if ($issues.Count -gt 0) {
                    $findings.Add([pscustomobject]@{
                        Text = "[$dbName -> $sec] secondary out of sync: $($issues -join '; ')"
                        Fix  = @{ Type = 'sync-secondary'; Primary = $primary; Secondary = $sec; Db = $dbName; Jobs = $jobs }
                    })
                }
            }
        }
    }
    return , @($findings.ToArray())
}

function Invoke-CdcFix {
    <# Applies one finding's fix descriptor. #>
    param([hashtable]$Fix)
    switch ($Fix.Type) {
        'add-job' {
            Invoke-CdcSql -Server $Fix.Server -Database $Fix.Db -Query 'EXEC sys.sp_cdc_add_job @job_type = @t' `
                -Parameters @{ '@t' = $Fix.JobType } -NonQuery
            $jobName = "cdc.$($Fix.Db)_$($Fix.JobType)"
            if ($Fix.JobType -eq 'capture') { Set-CaptureJobSchedule $Fix.Server $jobName }
            if ($Fix.InAg) { Set-CheckPrimaryStep $Fix.Server $jobName $Fix.AgName }
        }
        'add-schedule' {
            Set-CaptureJobSchedule $Fix.Server $Fix.Job
        }
        'fix-step' {
            Set-CheckPrimaryStep $Fix.Server $Fix.Job $Fix.AgName
        }
        'sync-secondary' {
            Initialize-SecondaryCdcMetadata $Fix.Secondary
            foreach ($jobName in $Fix.Jobs) {
                Copy-AgentJob $Fix.Primary $Fix.Secondary $jobName
            }
            Sync-CdcJobsMetadata $Fix.Primary $Fix.Secondary $Fix.Db
        }
        default { throw "Unknown fix type: $($Fix.Type)" }
    }
}

# --- Main ------------------------------------------------------------------------
function Invoke-CdcSyncCheck {
    Write-Host ''
    Write-Host '=== CDC Job Sync Check ===' -ForegroundColor Cyan
    Write-Host ''

    $server = Connect-CdcServer

    $databases = Get-CdcDatabases $server
    if (-not $databases -or $databases.Count -eq 0) {
        Write-Warn 'No CDC-enabled databases found on this server.'
        return 0
    }

    # Topology rollup.
    Write-Host ''
    Write-Host 'CDC topology:' -ForegroundColor Cyan
    foreach ($db in $databases) {
        $dbName = [string]$db.name
        $inAg = $db.ag_name -isnot [System.DBNull]
        $primary = $server
        $where = 'standalone'
        if ($inAg) {
            if ($db.primary_replica -isnot [System.DBNull] -and [string]$db.primary_replica) {
                $primary = [string]$db.primary_replica
            }
            $secondaries = Get-AgSecondaryReplicas $primary ([string]$db.ag_name)
            $where = "AG $($db.ag_name) (primary $primary, $($secondaries.Count) secondary)"
        }
        $tables = '?'
        try {
            $t = Invoke-CdcSql -Server $primary -Database $dbName -Query 'SELECT COUNT(*) AS c FROM cdc.change_tables'
            $tables = [int]$t[0].c
        } catch { }
        $pub = ''
        if ([bool]$db.is_published) { $pub = ', published - capture via Log Reader Agent' }
        Write-Host ("  {0,-15} {1}  -  {2} tracked table(s){3}" -f $dbName, $where, $tables, $pub)
    }

    # Redirect note when the connected server is not the primary for an AG db.
    foreach ($db in $databases) {
        if ($db.ag_name -isnot [System.DBNull] -and $db.local_role -ne 'PRIMARY' -and $db.primary_replica -isnot [System.DBNull]) {
            Write-Info "This server is not the primary for '$($db.name)' - checks run against $($db.primary_replica)."
        }
    }

    # Analysis.
    Write-Host ''
    Write-Info 'Analyzing...'
    $findings = Get-CdcFindings $server $databases

    Write-Host ''
    if ($findings.Count -eq 0) {
        Write-Ok 'No issues found - CDC jobs are configured and in sync everywhere.'
        return 0
    }

    Write-Host "Findings ($($findings.Count)):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $findings.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i + 1), $findings[$i].Text)
    }
    Write-Host ''

    $picks = Read-FixSelection -Count $findings.Count
    if ($picks.Count -eq 0) {
        Write-Info 'No fixes applied.'
        return 0
    }

    Write-Host ''
    foreach ($n in ($picks | Sort-Object)) {
        $f = $findings[$n - 1]
        if ($null -eq $f.Fix) {
            Write-Warn "#$n has no automatic fix: $($f.Text)"
            continue
        }
        try {
            Invoke-CdcFix $f.Fix
            Write-Ok "#$n fixed: $($f.Text)"
        } catch {
            Write-Err "#$n failed: $($_.Exception.GetBaseException().Message)"
        }
    }

    # Re-scan so the user leaves knowing the real state.
    Write-Host ''
    Write-Info 'Re-scanning...'
    $remaining = Get-CdcFindings $server (Get-CdcDatabases $server)
    if ($remaining.Count -eq 0) {
        Write-Ok 'Re-scan clean - no issues remain.'
    } else {
        Write-Warn "Re-scan: $($remaining.Count) issue(s) remain:"
        for ($i = 0; $i -lt $remaining.Count; $i++) {
            Write-Host ("  {0,2}. {1}" -f ($i + 1), $remaining[$i].Text)
        }
    }
    return 0
}

# Dot-source the file to load functions without running (used by tests).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-CdcSyncCheck)
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}
