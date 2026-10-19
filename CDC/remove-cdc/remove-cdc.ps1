<#
.SYNOPSIS
    Interactive Change Data Capture (CDC) removal for SQL Server, including
    Availability Group cleanup.

.DESCRIPTION
    Prompt-driven - no parameters to memorize. Pick one or more CDC-enabled
    databases, then choose per database:

      [D]atabase - disable CDC for the whole database (sys.sp_cdc_disable_db).
                   Warns first: this turns off CDC for EVERY tracked table and
                   removes the capture and cleanup jobs. For AG databases the
                   capture/cleanup jobs and msdb.dbo.cdc_jobs rows are also
                   removed from every secondary replica.
      [T]ables   - stop tracking specific tables (sys.sp_cdc_disable_table
                   with @capture_instance = 'all'). Warns first: all captured
                   change data for the selected tables is removed. Database
                   level CDC and the jobs stay in place.

    Both paths require an explicit y/N confirmation before anything happens.

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

function Read-Confirmation {
    <# Explicit yes/no gate for destructive actions. Defaults to NO. #>
    param([Parameter(Mandatory)][string]$Prompt)
    $answer = Read-PromptLine "$Prompt (y/N)"
    return ($answer.Trim() -match '^(y|yes)$')
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

# --- Discovery ---------------------------------------------------------------------
function Get-CdcDatabases {
    <# CDC-enabled user databases on the connected server, with AG context. #>
    param([string]$Server)
    $q = @'
SELECT d.name,
       ag.name AS ag_name,
       (SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars
         WHERE ars.group_id = ar.group_id AND ars.is_local = 1) AS local_role
FROM sys.databases d
LEFT JOIN sys.availability_replicas ar ON d.replica_id = ar.replica_id
LEFT JOIN sys.availability_groups  ag ON ar.group_id  = ag.group_id
WHERE d.database_id > 4 AND d.state = 0 AND d.is_cdc_enabled = 1
ORDER BY d.name
'@
    return Invoke-CdcSql -Server $Server -Query $q
}

function Get-TrackedTables {
    <# Distinct source tables tracked by CDC in a database. #>
    param([string]$Server, [string]$Database)
    $q = @'
SELECT DISTINCT OBJECT_SCHEMA_NAME(source_object_id) AS schema_name,
       OBJECT_NAME(source_object_id) AS table_name
FROM cdc.change_tables
ORDER BY schema_name, table_name
'@
    return Invoke-CdcSql -Server $Server -Database $Database -Query $q
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

# --- Removal actions ------------------------------------------------------------------
function Stop-CdcJobs {
    <# Stops the capture/cleanup jobs if running so sp_cdc_disable_db does not
       hit the transient sp_repldone conflict (error 22912). #>
    param([string]$Server, [string]$Database)
    foreach ($jobType in 'capture', 'cleanup') {
        $jobName = "cdc.$($Database)_$jobType"
        try {
            Invoke-CdcSql -Server $Server -Query @'
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs j
           JOIN msdb.dbo.sysjobactivity ja ON j.job_id = ja.job_id
           WHERE j.name = @job AND ja.start_execution_date IS NOT NULL
             AND ja.stop_execution_date IS NULL
             AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions))
    EXEC msdb.dbo.sp_stop_job @job_name = @job;
'@ -Parameters @{ '@job' = $jobName } -NonQuery
        } catch { }
    }
}

function Disable-CdcDatabase {
    <# sp_cdc_disable_db with one retry: a mid-scan capture job can make the
       first attempt fail transiently even after a stop request. #>
    param([string]$Server, [string]$Database)
    Stop-CdcJobs $Server $Database
    try {
        Invoke-CdcSql -Server $Server -Database $Database -Query 'EXEC sys.sp_cdc_disable_db' -NonQuery
    } catch {
        Stop-CdcJobs $Server $Database
        Start-Sleep -Seconds 5
        Invoke-CdcSql -Server $Server -Database $Database -Query 'EXEC sys.sp_cdc_disable_db' -NonQuery
    }
}

function Remove-SecondaryCdcJobs {
    <# Drops the capture/cleanup jobs and cdc_jobs metadata rows for a database
       on one secondary replica. #>
    param([string]$SecondaryServer, [string]$Database)
    Invoke-CdcSql -Server $SecondaryServer -Query @'
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @cap) EXEC msdb.dbo.sp_delete_job @job_name = @cap;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @cln) EXEC msdb.dbo.sp_delete_job @job_name = @cln;
IF OBJECT_ID('msdb.dbo.cdc_jobs', 'U') IS NOT NULL
    DELETE FROM msdb.dbo.cdc_jobs WHERE database_id = DB_ID(@db);
'@ -Parameters @{
        '@cap' = "cdc.$($Database)_capture"
        '@cln' = "cdc.$($Database)_cleanup"
        '@db'  = $Database
    } -NonQuery
}

function Disable-CdcTable {
    param([string]$Server, [string]$Database, [string]$SchemaName, [string]$TableName)
    $q = "EXEC sys.sp_cdc_disable_table @source_schema = @s, @source_name = @t, @capture_instance = 'all'"
    Invoke-CdcSql -Server $Server -Database $Database -Query $q -Parameters @{ '@s' = $SchemaName; '@t' = $TableName } -NonQuery
}

# --- Main ------------------------------------------------------------------------
function Invoke-CdcRemoval {
    Write-Host ''
    Write-Host '=== Remove CDC ===' -ForegroundColor Cyan
    Write-Host ''

    $server = Connect-CdcServer

    $databases = Get-CdcDatabases $server
    if (-not $databases -or $databases.Count -eq 0) {
        Write-Warn 'No CDC-enabled databases found on this server.'
        return 0
    }

    Write-Host ''
    Write-Host 'CDC-enabled databases:'
    for ($i = 0; $i -lt $databases.Count; $i++) {
        $d = $databases[$i]
        $tag = ''
        if ($d.ag_name -isnot [System.DBNull]) { $tag = " [AG: $($d.ag_name)]" }
        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $d.name, $tag)
    }
    Write-Host ''
    $dbPicks = Read-Selection -Prompt 'Select database(s) to remove CDC from (e.g. 1,3)' -Count $databases.Count
    $selected = @($dbPicks | Sort-Object | ForEach-Object { $databases[$_ - 1] })

    $summary = New-Object System.Collections.Generic.List[string]

    foreach ($db in $selected) {
        $dbName = [string]$db.name
        $inAg = $db.ag_name -isnot [System.DBNull]
        Write-Host ''
        Write-Host "--- $dbName ---" -ForegroundColor Cyan

        # AG databases can only be changed from the primary replica.
        if ($inAg -and $db.local_role -ne 'PRIMARY') {
            Write-Err "$dbName is in AG '$($db.ag_name)' and this server is not the primary replica. Connect to the primary and re-run."
            $summary.Add("$dbName - skipped (not primary replica)")
            continue
        }

        $tracked = Get-TrackedTables $server $dbName
        Write-Info "$($tracked.Count) tracked table(s): $(@($tracked | ForEach-Object { "$($_.schema_name).$($_.table_name)" }) -join ', ')"

        # Whole database, specific tables, or skip?
        $mode = ''
        while ($mode -notin 'd', 't', 's') {
            $mode = (Read-Answer 'Remove CDC from the entire [D]atabase, specific [T]ables, or [S]kip' 's').ToLower()
            if ($mode -notin 'd', 't', 's') { Write-Warn "Enter D, T, or S." }
        }

        if ($mode -eq 's') {
            $summary.Add("$dbName - skipped")
            continue
        }

        if ($mode -eq 'd') {
            Write-Warn "This will turn OFF CDC for ALL $($tracked.Count) tracked table(s) in '$dbName', delete their captured change data, and remove the capture and cleanup jobs."
            if ($inAg) {
                Write-Warn "The capture/cleanup jobs and cdc_jobs metadata will also be removed from every secondary replica of AG '$($db.ag_name)'."
            }
            if (-not (Read-Confirmation 'Continue')) {
                Write-Info 'Cancelled - no changes made.'
                $summary.Add("$dbName - cancelled")
                continue
            }
            try {
                Disable-CdcDatabase $server $dbName
                Write-Ok "CDC disabled for '$dbName' (jobs removed on $server)"
            } catch {
                Write-Err "Could not disable CDC on '$dbName': $($_.Exception.GetBaseException().Message)"
                $summary.Add("$dbName - FAILED to disable CDC")
                continue
            }
            if ($inAg) {
                foreach ($sec in (Get-AgSecondaryReplicas $server ([string]$db.ag_name))) {
                    try {
                        Remove-SecondaryCdcJobs $sec $dbName
                        Write-Ok "$sec - capture/cleanup jobs and cdc_jobs rows removed"
                    } catch {
                        Write-Err "$sec - cleanup failed: $($_.Exception.GetBaseException().Message)"
                        $summary.Add("$dbName - secondary cleanup FAILED on $sec")
                    }
                }
            }
            $summary.Add("$dbName - CDC removed (database level)")
            continue
        }

        # mode 't' - specific tables.
        if ($tracked.Count -eq 0) {
            Write-Warn 'No tracked tables to remove.'
            $summary.Add("$dbName - no tracked tables")
            continue
        }
        Write-Host 'Tracked tables:'
        for ($i = 0; $i -lt $tracked.Count; $i++) {
            Write-Host ("  {0,2}. {1}.{2}" -f ($i + 1), $tracked[$i].schema_name, $tracked[$i].table_name)
        }
        $tablePicks = Read-Selection -Prompt "Select table(s) to stop tracking ('all' for every table, Enter to skip)" -Count $tracked.Count -AllowEmpty -AllowAll
        if ($tablePicks.Count -eq 0) {
            Write-Info 'No tables selected.'
            $summary.Add("$dbName - skipped")
            continue
        }
        $chosen = @($tablePicks | Sort-Object | ForEach-Object { $tracked[$_ - 1] })
        Write-Warn "All captured change data for the selected $($chosen.Count) table(s) will be removed: $(@($chosen | ForEach-Object { "$($_.schema_name).$($_.table_name)" }) -join ', ')"
        if (-not (Read-Confirmation 'Continue')) {
            Write-Info 'Cancelled - no changes made.'
            $summary.Add("$dbName - cancelled")
            continue
        }
        $removed = 0
        foreach ($t in $chosen) {
            try {
                Disable-CdcTable $server $dbName $t.schema_name $t.table_name
                Write-Ok "$($t.schema_name).$($t.table_name) - tracking stopped, change data removed"
                $removed++
            } catch {
                Write-Err "Could not disable $($t.schema_name).$($t.table_name): $($_.Exception.GetBaseException().Message)"
            }
        }
        if ($removed -eq $tracked.Count) {
            Write-Info "No tables are tracked anymore, but CDC is still enabled at the database level (capture/cleanup jobs remain). Re-run and choose [D]atabase to remove it fully."
        }
        $summary.Add("$dbName - stopped tracking $removed table(s)")
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
        exit (Invoke-CdcRemoval)
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}
