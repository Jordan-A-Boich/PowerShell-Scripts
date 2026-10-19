<#
.SYNOPSIS
    Interactive CDC wire-up for databases migrated side-by-side to a new
    SQL Server instance, including Availability Group aware job creation.

.DESCRIPTION
    A side-by-side migration moves a CDC-enabled database (its internal CDC
    metadata and tracked tables travel with it) but NOT the msdb pieces that
    make CDC actually run: the capture/cleanup Agent jobs and their
    msdb.dbo.cdc_jobs rows stay behind on the old server. This tool wires
    those up on the new server.

    Prompt-driven - no parameters to memorize. Run it from an interactive
    PowerShell console and answer the prompts:

      1. Server name (connect to the PRIMARY replica for AG databases).
      2. Pick database(s) from a numbered list of CDC-enabled databases,
         each shown with its current wiring status.
      3. Cleanup retention in minutes when a cleanup job must be created
         (default 5760).

    For every selected database it:
      - Ensures msdb.dbo.cdc_jobs and msdb.dbo.cdc_jobs_view exist,
        creating them when missing.
      - Removes stale msdb.dbo.cdc_jobs rows that point at jobs which no
        longer exist (sys.sp_cdc_add_job refuses to run while they linger).
      - Creates the capture job (sys.sp_cdc_add_job @job_type = 'capture',
        @start_job = 1) unless the database is published for transactional
        replication - there the Log Reader Agent performs capture, so no
        capture job is needed.
      - Creates the cleanup job (sys.sp_cdc_add_job @job_type = 'cleanup',
        @start_job = 1, @retention = <prompted>).
      - Adds a 'Start Every 5 Minutes' schedule to the capture job so
        capture restarts automatically if it ever stops.

    For databases in an Availability Group it additionally:
      - Adds a 'Check To See If Primary' first step to the capture and
        cleanup jobs so they self-stop on non-primary replicas.
      - Ensures msdb.dbo.cdc_jobs and msdb.dbo.cdc_jobs_view exist on every
        secondary replica.
      - Scripts the capture/cleanup jobs from the primary onto every
        secondary and syncs the msdb.dbo.cdc_jobs metadata rows so CDC keeps
        working after a failover.

    Re-running against an already wired database is safe: existing jobs are
    left alone and only the missing pieces (schedule, guard steps, secondary
    sync) are filled in.

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

function Read-Selection {
    <# Prompts for comma-separated numbers between 1 and Count. Returns int[].
       With -AllowEmpty, a blank answer returns @(). With -AllowAll, typing
       'all' selects every item. #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Count,
        [switch]$AllowEmpty,
        [switch]$AllowAll
    )
    while ($true) {
        $raw = Read-PromptLine $Prompt
        if (-not $raw -or -not $raw.Trim()) {
            if ($AllowEmpty) { return @() }
            Write-Warn 'Enter at least one number.'
            continue
        }
        if ($AllowAll -and $raw.Trim().ToLower() -eq 'all') { return @(1..$Count) }
        $picked = New-Object System.Collections.Generic.List[int]
        $valid = $true
        foreach ($part in ($raw -split ',')) {
            $n = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $Count) {
                Write-Warn "'$($part.Trim())' is not a valid choice (1-$Count)."
                $valid = $false
                break
            }
            if (-not $picked.Contains($n)) { $picked.Add($n) }
        }
        if ($valid) { return $picked.ToArray() }
    }
}

function Read-Retention {
    <# Prompts for the cleanup job retention in minutes. Returns an int.
       Blank accepts the default; the value must fit sp_cdc_add_job's
       allowed range (1 .. 52494800, i.e. up to ~100 years). #>
    param([int]$Default = 5760)
    while ($true) {
        $raw = Read-Answer 'Cleanup retention in minutes' "$Default"
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le 52494800) { return $n }
        Write-Warn "'$raw' is not a valid retention (1-52494800 minutes)."
    }
}

function ConvertTo-PlainText {
    param([securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Connection / preflight -------------------------------------------------------
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

function Test-ReplicationInstalled {
    <# CDC needs the replication components installed. #>
    param([string]$Server)
    try {
        $r = Invoke-CdcSql -Server $Server -Query 'DECLARE @i int; EXEC @i = sys.sp_MS_replication_installed; SELECT @i AS installed'
        return ([int]$r[0].installed -eq 1)
    } catch {
        return $false
    }
}

# --- Discovery ---------------------------------------------------------------------
function Get-CdcEnabledDatabases {
    <# CDC-enabled user databases with replication/AG context and current job wiring. #>
    param([string]$Server)
    $q = @'
SELECT d.name,
       d.is_published,
       ag.name AS ag_name,
       (SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars
         WHERE ars.group_id = ar.group_id AND ars.is_local = 1) AS local_role,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs j WHERE j.name = 'cdc.' + d.name + '_capture') THEN 1 ELSE 0 END AS has_capture_job,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs j WHERE j.name = 'cdc.' + d.name + '_cleanup') THEN 1 ELSE 0 END AS has_cleanup_job
FROM sys.databases d
LEFT JOIN sys.availability_replicas ar ON d.replica_id = ar.replica_id
LEFT JOIN sys.availability_groups  ag ON ar.group_id  = ag.group_id
WHERE d.database_id > 4 AND d.state = 0 AND d.is_read_only = 0 AND d.is_distributor = 0
  AND d.is_cdc_enabled = 1
ORDER BY d.name
'@
    return Invoke-CdcSql -Server $Server -Query $q
}

function Get-TrackedTableCount {
    <# Number of CDC capture instances inside the database - proof the internal
       CDC metadata survived the migration. #>
    param([string]$Server, [string]$Database)
    $r = Invoke-CdcSql -Server $Server -Database $Database -Query 'SELECT COUNT(*) AS c FROM cdc.change_tables'
    return [int]$r[0].c
}

function Get-CdcJobNames {
    <# Returns the cdc capture/cleanup job names for a database that exist in msdb. #>
    param([string]$Server, [string]$Database)
    $q = "SELECT name FROM msdb.dbo.sysjobs WHERE name IN (@cap, @cln)"
    $p = @{ '@cap' = "cdc.$($Database)_capture"; '@cln' = "cdc.$($Database)_cleanup" }
    return @(Invoke-CdcSql -Server $Server -Query $q -Parameters $p | ForEach-Object { $_.name })
}

# --- msdb metadata objects ---------------------------------------------------------
function Initialize-CdcMetadataObjects {
    <# Ensures msdb.dbo.cdc_jobs and msdb.dbo.cdc_jobs_view exist on a server.
       Returns a status string for display. #>
    param([string]$Server)
    $tableDdl = @'
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
    SELECT 'created' AS r
END
ELSE SELECT 'exists' AS r
'@
    $r1 = Invoke-CdcSql -Server $Server -Database 'msdb' -Query $tableDdl

    $viewDdl = @'
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
    SELECT 'created' AS r
END
ELSE SELECT 'exists' AS r
'@
    $r2 = Invoke-CdcSql -Server $Server -Database 'msdb' -Query $viewDdl
    return "cdc_jobs table $($r1[0].r), cdc_jobs_view $($r2[0].r)"
}

# --- Job creation --------------------------------------------------------------------
function Remove-StaleCdcJobsRow {
    <# Deletes an msdb.dbo.cdc_jobs row for the database/job type when the Agent
       job it points at no longer exists - sys.sp_cdc_add_job refuses to create
       the job while the stale row lingers. Returns $true when a row was removed. #>
    param([string]$Server, [string]$Database, [string]$JobType)
    $q = @'
DELETE c
FROM msdb.dbo.cdc_jobs c
WHERE c.database_id = DB_ID(@db) AND c.job_type = @jt
  AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs s WHERE s.job_id = c.job_id);
SELECT @@ROWCOUNT AS removed
'@
    $r = Invoke-CdcSql -Server $Server -Query $q -Parameters @{ '@db' = $Database; '@jt' = $JobType }
    return ([int]$r[0].removed -gt 0)
}

function Add-CdcJob {
    <# Creates the capture or cleanup job for a database via sys.sp_cdc_add_job.
       Must run in the database's own context. #>
    param([string]$Server, [string]$Database, [string]$JobType, [int]$Retention = 0)
    if ($JobType -eq 'cleanup') {
        Invoke-CdcSql -Server $Server -Database $Database -Query `
            "EXEC sys.sp_cdc_add_job @job_type = N'cleanup', @start_job = 1, @retention = @ret" `
            -Parameters @{ '@ret' = $Retention } -NonQuery
    } else {
        Invoke-CdcSql -Server $Server -Database $Database -Query `
            "EXEC sys.sp_cdc_add_job @job_type = N'capture', @start_job = 1" -NonQuery
    }
}

function Set-CaptureJobSchedule {
    <# Ensures the capture job has the 'Start Every 5 Minutes' schedule attached. Returns 'added' or 'exists'. #>
    param([string]$Server, [string]$JobName)
    $schedName = 'Start Every 5 Minutes'
    $check = @'
SELECT COUNT(*) AS attached
FROM msdb.dbo.sysjobschedules js
JOIN msdb.dbo.sysjobs j     ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
WHERE j.name = @job AND s.name = @sched
'@
    $r = Invoke-CdcSql -Server $Server -Query $check -Parameters @{ '@job' = $JobName; '@sched' = $schedName }
    if ([int]$r[0].attached -gt 0) { return 'exists' }

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
    return 'added'
}

# --- AG-specific steps -------------------------------------------------------------------
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

function Set-CheckPrimaryStep {
    <# Ensures the job's first step is 'Check To See If Primary' with the expected
       command text. Returns 'added', 'updated' (existing step had a different AG
       name or an outdated template), or 'exists'. #>
    param([string]$Server, [string]$JobName, [string]$AgName)
    $command = $script:CheckPrimaryTemplate.Replace('{AGNAME}', $AgName.Replace("'", "''"))
    $check = @'
SELECT js.step_id, js.command
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @job AND js.step_name = @step
'@
    $p = @{ '@job' = $JobName; '@step' = $script:CheckPrimaryStepName }
    $existing = Invoke-CdcSql -Server $Server -Query $check -Parameters $p

    if ($existing.Count -gt 0) {
        if (($existing[0].command -replace '\r?\n', "`n") -eq ($command -replace '\r?\n', "`n")) { return 'exists' }
        Invoke-CdcSql -Server $Server -Query 'EXEC msdb.dbo.sp_update_jobstep @job_name = @job, @step_id = @id, @command = @cmd' `
            -Parameters @{ '@job' = $JobName; '@id' = [int]$existing[0].step_id; '@cmd' = $command } -NonQuery
        return 'updated'
    }

    $add = @'
EXEC msdb.dbo.sp_add_jobstep @job_name = @job, @step_id = 1, @step_name = @step,
     @subsystem = N'TSQL', @database_name = N'master', @command = @cmd,
     @on_success_action = 3, @on_fail_action = 2, @retry_attempts = 0, @retry_interval = 0;
EXEC msdb.dbo.sp_update_job @job_name = @job, @start_step_id = 1;
'@
    $p['@cmd'] = $command
    Invoke-CdcSql -Server $Server -Query $add -Parameters $p -NonQuery
    return 'added'
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

    # Recreate the job shell (drop first so repeated runs stay in sync with the primary).
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

    return "$($steps.Count) step(s), $($schedules.Count) schedule(s)"
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

function Test-SecondaryInSync {
    <# True when a secondary already has the metadata objects, identical job
       definitions, and matching cdc_jobs rows with valid job_id mapping. #>
    param([string]$PrimaryServer, [string]$SecondaryServer, [string]$Database, [string[]]$JobNames)

    $obj = Invoke-CdcSql -Server $SecondaryServer -Query "SELECT CASE WHEN OBJECT_ID('msdb.dbo.cdc_jobs','U') IS NOT NULL AND OBJECT_ID('msdb.dbo.cdc_jobs_view','V') IS NOT NULL THEN 1 ELSE 0 END AS ok"
    if ([int]$obj[0].ok -ne 1) { return $false }

    foreach ($jobName in $JobNames) {
        $priFp = Get-JobFingerprint $PrimaryServer $jobName
        $secFp = Get-JobFingerprint $SecondaryServer $jobName
        if ($null -eq $secFp -or $priFp -ne $secFp) { return $false }
    }

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

    if ($priRows.Count -ne $secRows.Count) { return $false }
    for ($i = 0; $i -lt $priRows.Count; $i++) {
        if ([int]$secRows[$i].mapped -ne 1) { return $false }
        $a = $priRows[$i]; $b = $secRows[$i]
        $rowA = "$($a.job_type)|$($a.maxtrans)|$($a.maxscans)|$($a.continuous)|$($a.pollinginterval)|$($a.retention)|$($a.threshold)"
        $rowB = "$($b.job_type)|$($b.maxtrans)|$($b.maxscans)|$($b.continuous)|$($b.pollinginterval)|$($b.retention)|$($b.threshold)"
        if ($rowA -ne $rowB) { return $false }
    }
    return $true
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
    return $rows.Count
}

function Get-ExistingGuardAgName {
    <# If every job already has a guard step referencing the same AG, returns that
       AG name so re-runs do not have to re-ask. Returns $null otherwise. #>
    param([string]$Server, [string[]]$JobNames)
    $agName = $null
    foreach ($jobName in $JobNames) {
        $r = Invoke-CdcSql -Server $Server -Query @'
SELECT js.command
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @job AND js.step_name = @step
'@ -Parameters @{ '@job' = $jobName; '@step' = $script:CheckPrimaryStepName }
        if ($r.Count -eq 0) { return $null }
        $m = [regex]::Match([string]$r[0].command, "ag\.name\s*=\s*'([^']*)'")
        if (-not $m.Success) { return $null }
        $parsed = $m.Groups[1].Value.Replace("''", "'")
        if ($agName -and $parsed -ne $agName) { return $null }
        $agName = $parsed
    }
    return $agName
}

# --- Main ------------------------------------------------------------------------
function Invoke-CdcWireUp {
    Write-Host ''
    Write-Host '=== CDC Wire-Up (Post-Migration) ===' -ForegroundColor Cyan
    Write-Host ''

    $server = Connect-CdcServer

    if (-not (Test-ReplicationInstalled $server)) {
        Write-Err 'The SQL Server Replication feature is not installed on this instance. CDC requires it - install the replication components and re-run.'
        return 1
    }

    # msdb metadata objects on the connected server first - job creation and the
    # wiring-status list below both depend on them.
    $meta = Initialize-CdcMetadataObjects $server
    Write-Ok "msdb metadata objects: $meta"

    $databases = Get-CdcEnabledDatabases $server
    if (-not $databases -or $databases.Count -eq 0) {
        Write-Warn 'No CDC-enabled databases found on this server. Wire-up applies to migrated databases that arrived with CDC already enabled.'
        return 1
    }

    Write-Host ''
    Write-Host 'CDC-enabled databases:'
    for ($i = 0; $i -lt $databases.Count; $i++) {
        $d = $databases[$i]
        $isPublished = [bool]$d.is_published
        $needsCapture = (-not $isPublished) -and ([int]$d.has_capture_job -eq 0)
        $needsCleanup = ([int]$d.has_cleanup_job -eq 0)
        $tags = ''
        if ($needsCapture -or $needsCleanup) {
            $missing = @()
            if ($needsCapture) { $missing += 'capture' }
            if ($needsCleanup) { $missing += 'cleanup' }
            $tags += " [missing: $($missing -join ', ')]"
        } else {
            $tags += ' [jobs wired]'
        }
        if ($isPublished) { $tags += ' [published - Log Reader Agent captures]' }
        if ($d.ag_name -isnot [System.DBNull]) { $tags += " [AG: $($d.ag_name)]" }
        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $d.name, $tags)
    }
    Write-Host ''
    $dbPicks = Read-Selection -Prompt "Select database(s) to wire up (e.g. 1,3 or 'all')" -Count $databases.Count -AllowAll
    $selected = @($dbPicks | Sort-Object | ForEach-Object { $databases[$_ - 1] })

    # AG notice for any selected database that is in an Availability Group.
    $agSelected = @($selected | Where-Object { $_.ag_name -isnot [System.DBNull] })
    if ($agSelected.Count -gt 0) {
        Write-Host ''
        Write-Host 'High Availability detected for database(s):' -ForegroundColor Yellow
        foreach ($d in $agSelected) { Write-Host "  - $($d.name) (AG: $($d.ag_name))" }
        Write-Host 'Capture and cleanup jobs will be properly synchronized in the AG so functionality persists after failover.'
    }

    $agNameCache = @{}
    $summary = New-Object System.Collections.Generic.List[string]

    foreach ($db in $selected) {
        $dbName = $db.name
        $inAg = $db.ag_name -isnot [System.DBNull]
        Write-Host ''
        Write-Host "--- $dbName ---" -ForegroundColor Cyan

        # AG databases can only be configured from the primary replica.
        if ($inAg -and $db.local_role -ne 'PRIMARY') {
            Write-Err "$dbName is in AG '$($db.ag_name)' and this server is not the primary replica. Connect to the primary and re-run."
            $summary.Add("$dbName - skipped (not primary replica)")
            continue
        }

        # Confirm the internal CDC metadata really made the trip.
        try {
            $trackedCount = Get-TrackedTableCount $server $dbName
        } catch {
            Write-Err "Could not read cdc.change_tables in '$dbName': $($_.Exception.GetBaseException().Message)"
            $summary.Add("$dbName - failed (cdc metadata unreadable)")
            continue
        }
        if ($trackedCount -eq 0) {
            Write-Warn 'No tracked tables found (cdc.change_tables is empty). Jobs will be wired, but nothing is captured until tables are enabled - use the Setup CDC tool for that.'
        } else {
            Write-Info "$trackedCount tracked table(s) found - internal CDC metadata is intact."
        }

        # Which jobs does this database need? Transactional replication uses the
        # Log Reader Agent for capture, so a published database has no capture job.
        $isPublished = [bool]$db.is_published
        if ($isPublished) {
            Write-Info 'Transactional replication detected - the Log Reader Agent handles capture; only the cleanup job is used.'
        }
        $captureJob = "cdc.$($dbName)_capture"
        $cleanupJob = "cdc.$($dbName)_cleanup"

        $jobs = Get-CdcJobNames $server $dbName
        $created = @()
        $failed = $false

        $wanted = @()
        if (-not $isPublished) { $wanted += 'capture' }
        $wanted += 'cleanup'

        foreach ($jobType in $wanted) {
            $jobName = "cdc.$($dbName)_$jobType"
            if ($jobs -contains $jobName) {
                Write-Info "$jobName already exists - leaving it as is."
                continue
            }
            try {
                if (Remove-StaleCdcJobsRow $server $dbName $jobType) {
                    Write-Warn "Removed stale msdb.dbo.cdc_jobs $jobType row (it pointed at a job that no longer exists)."
                }
                if ($jobType -eq 'cleanup') {
                    $retention = Read-Retention
                    Add-CdcJob $server $dbName 'cleanup' $retention
                    Write-Ok "$jobName created and started (retention $retention min)"
                } else {
                    Add-CdcJob $server $dbName 'capture'
                    Write-Ok "$jobName created and started"
                }
                $created += $jobType
            } catch {
                Write-Err "Could not create the $jobType job: $($_.Exception.GetBaseException().Message)"
                $failed = $true
            }
        }
        if ($failed) {
            $summary.Add("$dbName - job creation FAILED")
            continue
        }

        # Capture job restart schedule (applies whether the job is new or pre-existing).
        $jobs = Get-CdcJobNames $server $dbName
        if ($jobs -contains $captureJob) {
            $res = Set-CaptureJobSchedule $server $captureJob
            Write-Ok "Capture job schedule 'Start Every 5 Minutes' - $res"
        }

        # AG synchronization.
        if ($inAg) {
            $agName = [string]$db.ag_name

            # Re-runs should not re-ask: reuse the AG name already embedded in the
            # guard steps when all jobs agree and the AG really exists.
            if (-not $agNameCache.ContainsKey($agName)) {
                $existingAg = Get-ExistingGuardAgName $server $jobs
                if ($existingAg) {
                    $chk = Invoke-CdcSql -Server $server -Query 'SELECT COUNT(*) AS n FROM sys.availability_groups WHERE name = @n' -Parameters @{ '@n' = $existingAg }
                    if ([int]$chk[0].n -gt 0) {
                        $agNameCache[$agName] = $existingAg
                        Write-Info "Using Availability Group '$existingAg' from the existing job configuration."
                    } else {
                        Write-Warn "Existing guard steps reference AG '$existingAg', which does not exist on $server - please re-select."
                    }
                }
            }
            if (-not $agNameCache.ContainsKey($agName)) {
                # Numbered pick list from sys.availability_groups - typing the name by
                # hand risks baking a typo into the job-step guard on every replica.
                $ags = @(Invoke-CdcSql -Server $server -Query 'SELECT name FROM sys.availability_groups ORDER BY name' | ForEach-Object { $_.name })
                if ($ags.Count -eq 0) {
                    $agNameCache[$agName] = $agName   # cannot happen for an AG database; keep the detected name
                } else {
                    $detectedIdx = [array]::IndexOf($ags, $agName)
                    Write-Host 'Availability Groups on this server:'
                    for ($i = 0; $i -lt $ags.Count; $i++) {
                        $tag = ''
                        if ($i -eq $detectedIdx) { $tag = " (detected for $dbName)" }
                        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $ags[$i], $tag)
                    }
                    while ($true) {
                        $picks = Read-Selection -Prompt 'Select the Availability Group (Enter to accept detected)' -Count $ags.Count -AllowEmpty
                        if ($picks.Count -eq 0 -and $detectedIdx -ge 0) { $agNameCache[$agName] = $ags[$detectedIdx]; break }
                        if ($picks.Count -eq 1) { $agNameCache[$agName] = $ags[$picks[0] - 1]; break }
                        Write-Warn 'Select exactly one Availability Group.'
                    }
                }
            }
            $agAnswer = $agNameCache[$agName]

            foreach ($jobName in $jobs) {
                $res = Set-CheckPrimaryStep $server $jobName $agAnswer
                Write-Ok "'$($script:CheckPrimaryStepName)' step on $jobName - $res"
            }

            $secondaries = Get-AgSecondaryReplicas $server $agName
            if ($secondaries.Count -eq 0) {
                Write-Warn 'No secondary replicas found to synchronize.'
            }
            $syncFailures = 0
            foreach ($sec in $secondaries) {
                try {
                    # Skip the heavy sync when the secondary already matches the primary.
                    if (Test-SecondaryInSync $server $sec $dbName $jobs) {
                        Write-Ok "$sec - already in sync, nothing to do"
                        continue
                    }
                    Write-Info "Synchronizing to secondary replica $sec"
                    $secMeta = Initialize-CdcMetadataObjects $sec
                    Write-Ok "$sec - $secMeta"
                    foreach ($jobName in $jobs) {
                        $detail = Copy-AgentJob $server $sec $jobName
                        Write-Ok "$sec - job $jobName synced ($detail)"
                    }
                    $rowCount = Sync-CdcJobsMetadata $server $sec $dbName
                    Write-Ok "$sec - cdc_jobs metadata synced ($rowCount row(s), job ids remapped)"
                } catch {
                    Write-Err "$sec - synchronization failed: $($_.Exception.GetBaseException().Message)"
                    $syncFailures++
                }
            }
            $what = 'already wired'
            if ($created.Count -gt 0) { $what = "jobs created: $($created -join ', ')" }
            if ($syncFailures -gt 0) {
                $summary.Add("$dbName - $what, AG sync FAILED for $syncFailures replica(s)")
            } else {
                $summary.Add("$dbName - $what, AG-synced to $($secondaries.Count) secondary replica(s)")
            }
        } else {
            $what = 'already wired'
            if ($created.Count -gt 0) { $what = "jobs created: $($created -join ', ')" }
            $summary.Add("$dbName - $what")
        }
    }

    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    foreach ($line in $summary) { Write-Host "  $line" }
    Write-Host ''
    return 0
}

# Dot-source the file to load functions without running (used by tests).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-CdcWireUp)
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}
