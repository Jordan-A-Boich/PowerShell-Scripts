<#
.SYNOPSIS
    Interactive detection and repair of CDC column drift - tables whose columns
    were added or dropped after CDC was enabled, so the capture instance no
    longer matches the source table.

.DESCRIPTION
    By default CDC does NOT pick up DDL changes: a column added after
    sys.sp_cdc_enable_table is simply not tracked, and a dropped column stays
    in the capture instance forever. This tool finds that drift and fixes it
    with a hot swap that keeps recent change data:

      1. A temporary capture instance '<schema>_<table>_New' is created with
         the current column list (same role, net-changes and filegroup
         settings as the original).
      2. Recent rows from the original change table are copied into it
         (window is prompted, default last 3 hours).
      3. The original capture instance is dropped and recreated - it now
         tracks the current columns.
      4. Everything in the temporary instance is copied back into the
         recreated original, and the temporary instance is removed.

    Three 20-second safety delays per table let the capture job drain between
    swaps, so expect about a minute per table. Tables with a custom-named
    capture instance or two capture instances are reported but must be handled
    manually.

    For Availability Group databases run this against the primary replica -
    the change tables live inside the database, so the swap replicates to
    secondaries automatically.

    Optional environment variables (skip the matching prompt when set):
      DBA_SERVERS   - server name
      DBA_USERNAME  - SQL login (omit for Windows authentication)
      DBA_PASSWORD  - SQL password
#>

$ErrorActionPreference = 'Stop'

# --- Script-scoped state ---------------------------------------------------------
$script:SqlUser = ''
$script:SqlPassword = ''
# Safety delay between swap phases. Internal override for automated tests only.
$script:SwapDelaySeconds = 20
if ($env:DBA_CDC_SWAP_DELAY_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:DBA_CDC_SWAP_DELAY_SECONDS, [ref]$parsed) -and $parsed -ge 0) {
        $script:SwapDelaySeconds = $parsed
    }
}

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
        $cmd.CommandTimeout = 300
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
    <# Explicit yes/no gate. Defaults to NO. #>
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

# --- Discovery / analysis ------------------------------------------------------------
function Get-CdcDatabases {
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

function Get-ColumnDrift {
    <# One row per capture instance with comma-separated lists of source columns
       not captured (added after enable) and captured columns no longer in the
       source table (dropped after enable). Computed columns are ignored - CDC
       does not capture them. #>
    param([string]$Server, [string]$Database)
    $q = @'
SELECT ct.capture_instance,
       s.name AS schema_name,
       t.name AS table_name,
       ct.role_name,
       ct.supports_net_changes,
       ct.filegroup_name,
       ISNULL(STUFF((SELECT ', ' + c.name
              FROM sys.columns c
              WHERE c.object_id = ct.source_object_id AND c.is_computed = 0
                AND NOT EXISTS (SELECT 1 FROM cdc.captured_columns cc
                                WHERE cc.[object_id] = ct.[object_id] AND cc.column_name = c.name)
              ORDER BY c.column_id
              FOR XML PATH('')), 1, 2, ''), '') AS added_columns,
       ISNULL(STUFF((SELECT ', ' + cc.column_name
              FROM cdc.captured_columns cc
              WHERE cc.[object_id] = ct.[object_id]
                AND NOT EXISTS (SELECT 1 FROM sys.columns c
                                WHERE c.object_id = ct.source_object_id AND c.name = cc.column_name)
              FOR XML PATH('')), 1, 2, ''), '') AS removed_columns,
       (SELECT COUNT(*) FROM cdc.change_tables ct2 WHERE ct2.source_object_id = ct.source_object_id) AS instance_count
FROM cdc.change_tables ct
JOIN sys.tables t ON t.object_id = ct.source_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
ORDER BY s.name, t.name
'@
    return Invoke-CdcSql -Server $Server -Database $Database -Query $q
}

function Get-CapturedColumns {
    param([string]$Server, [string]$Database, [string]$CaptureInstance)
    $q = @'
SELECT cc.column_name
FROM cdc.captured_columns cc
JOIN cdc.change_tables ct ON cc.[object_id] = ct.[object_id]
WHERE ct.capture_instance = @ci
ORDER BY cc.column_ordinal
'@
    return @(Invoke-CdcSql -Server $Server -Database $Database -Query $q -Parameters @{ '@ci' = $CaptureInstance } | ForEach-Object { $_.column_name })
}

# --- Hot swap ---------------------------------------------------------------------
function Get-BracketName {
    param([string]$Name)
    return '[' + $Name.Replace(']', ']]') + ']'
}

function Invoke-SwapDelay {
    param([int]$Number)
    if ($script:SwapDelaySeconds -gt 0) {
        Write-Info "Safety delay $Number of 3 ($($script:SwapDelaySeconds)s) - letting the capture job drain..."
        Start-Sleep -Seconds $script:SwapDelaySeconds
    }
}

function Invoke-CaptureInstanceSwap {
    <# Recreates one table's capture instance with the current column list while
       preserving recent change data via a temporary '_New' instance. #>
    param(
        [string]$Server, [string]$Database,
        [string]$SchemaName, [string]$TableName,
        [object]$RoleName,            # may be DBNull
        [int]$SupportsNetChanges,
        [object]$FilegroupName,       # may be DBNull
        [int]$PreserveHours
    )
    $ci = "$($SchemaName)_$($TableName)"
    $ciNew = "$($ci)_New"
    $ctOld = "cdc." + (Get-BracketName "$($ci)_CT")
    $ctNew = "cdc." + (Get-BracketName "$($ciNew)_CT")

    $role = $null
    if ($RoleName -isnot [System.DBNull] -and $RoleName) { $role = [string]$RoleName }
    $fg = $null
    if ($FilegroupName -isnot [System.DBNull] -and $FilegroupName) { $fg = [string]$FilegroupName }

    $enableParams = @{ '@s' = $SchemaName; '@t' = $TableName; '@r' = $role; '@n' = $SupportsNetChanges }
    $enableSql = 'EXEC sys.sp_cdc_enable_table @source_schema = @s, @source_name = @t, @role_name = @r, @supports_net_changes = @n'
    if ($fg) {
        $enableSql += ', @filegroup_name = @fg'
        $enableParams['@fg'] = $fg
    }

    # 1. Temporary capture instance with the CURRENT column list.
    $newParams = @{} + $enableParams
    $newParams['@ci'] = $ciNew
    Invoke-CdcSql -Server $Server -Database $Database -Query ($enableSql + ', @capture_instance = @ci') -Parameters $newParams -NonQuery
    Write-Ok "temporary capture instance '$ciNew' created"

    # 2. Copy recent history old -> new. The insert column list is the
    #    intersection of old and new captured columns, which handles column
    #    adds, drops, and both at once.
    $oldCols = Get-CapturedColumns $Server $Database $ci
    $newCols = Get-CapturedColumns $Server $Database $ciNew
    $common = @($oldCols | Where-Object { $newCols -contains $_ })
    $colList = (@($common | ForEach-Object { Get-BracketName $_ }) -join ', ')
    $meta = '[__$start_lsn], [__$end_lsn], [__$seqval], [__$operation], [__$update_mask], [__$command_id]'

    $copyOld = @"
DECLARE @from binary(10) = sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', DATEADD(HOUR, -@hours, SYSDATETIME()));
DECLARE @to binary(10) = sys.fn_cdc_get_max_lsn();
INSERT INTO $ctNew ($meta, $colList)
SELECT $meta, $colList
FROM $ctOld
WHERE [__`$start_lsn] BETWEEN @from AND @to;
SELECT @@ROWCOUNT AS copied;
"@
    $r = Invoke-CdcSql -Server $Server -Database $Database -Query $copyOld -Parameters @{ '@hours' = $PreserveHours }
    Write-Ok "$($r[0].copied) change row(s) from the last $PreserveHours hour(s) copied to '$ciNew'"

    Invoke-SwapDelay 1

    # 3. Drop the drifted original instance.
    Invoke-CdcSql -Server $Server -Database $Database -Query 'EXEC sys.sp_cdc_disable_table @source_schema = @s, @source_name = @t, @capture_instance = @ci' `
        -Parameters @{ '@s' = $SchemaName; '@t' = $TableName; '@ci' = $ci } -NonQuery
    Write-Ok "original capture instance '$ci' dropped"

    Invoke-SwapDelay 2

    # 4. Recreate the original instance - it now tracks the current columns.
    Invoke-CdcSql -Server $Server -Database $Database -Query $enableSql -Parameters $enableParams -NonQuery
    Write-Ok "capture instance '$ci' recreated with the current column list"

    # 5. Copy everything back new -> recreated original. A FRESH max LSN keeps
    #    changes captured during the swap (the original script read it before
    #    the swap, which could lose the in-between rows).
    $copyBack = @"
DECLARE @to binary(10) = sys.fn_cdc_get_max_lsn();
INSERT INTO $ctOld ($meta, $colList)
SELECT $meta, $colList
FROM $ctNew
WHERE [__`$start_lsn] <= @to;
SELECT @@ROWCOUNT AS copied;
"@
    $r = Invoke-CdcSql -Server $Server -Database $Database -Query $copyBack
    Write-Ok "$($r[0].copied) change row(s) carried into the recreated '$ci'"

    Invoke-SwapDelay 3

    # 6. Remove the temporary instance.
    Invoke-CdcSql -Server $Server -Database $Database -Query 'EXEC sys.sp_cdc_disable_table @source_schema = @s, @source_name = @t, @capture_instance = @ci' `
        -Parameters @{ '@s' = $SchemaName; '@t' = $TableName; '@ci' = $ciNew } -NonQuery
    Write-Ok "temporary capture instance '$ciNew' removed"
}

# --- Main ------------------------------------------------------------------------
function Invoke-CdcColumnSync {
    Write-Host ''
    Write-Host '=== Sync CDC Tracked Columns ===' -ForegroundColor Cyan
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
    $dbPicks = Read-Selection -Prompt 'Select database(s) to analyze (e.g. 1,3)' -Count $databases.Count
    $selected = @($dbPicks | Sort-Object | ForEach-Object { $databases[$_ - 1] })

    $summary = New-Object System.Collections.Generic.List[string]

    foreach ($db in $selected) {
        $dbName = [string]$db.name
        $inAg = $db.ag_name -isnot [System.DBNull]
        Write-Host ''
        Write-Host "--- $dbName ---" -ForegroundColor Cyan

        if ($inAg -and $db.local_role -ne 'PRIMARY') {
            Write-Err "$dbName is in AG '$($db.ag_name)' and this server is not the primary replica. Connect to the primary and re-run."
            $summary.Add("$dbName - skipped (not primary replica)")
            continue
        }

        $drift = Get-ColumnDrift $server $dbName
        if ($drift.Count -eq 0) {
            Write-Info 'No CDC-tracked tables in this database.'
            $summary.Add("$dbName - no tracked tables")
            continue
        }

        $fixable = New-Object System.Collections.Generic.List[object]
        $manual  = New-Object System.Collections.Generic.List[string]
        $inSync  = New-Object System.Collections.Generic.List[string]
        foreach ($row in $drift) {
            $qualified = "$($row.schema_name).$($row.table_name)"
            $hasDrift = ([string]$row.added_columns -ne '') -or ([string]$row.removed_columns -ne '')
            if (-not $hasDrift) {
                if ($inSync -notcontains $qualified) { $inSync.Add($qualified) }
                continue
            }
            $defaultCi = "$($row.schema_name)_$($row.table_name)"
            if ([int]$row.instance_count -gt 1) {
                $manual.Add("$qualified (two capture instances - resolve manually)")
            } elseif ([string]$row.capture_instance -ne $defaultCi) {
                $manual.Add("$qualified (custom capture instance '$($row.capture_instance)' - resolve manually)")
            } else {
                $fixable.Add($row)
            }
        }

        # Rolled-up analysis.
        if ($fixable.Count -eq 0 -and $manual.Count -eq 0) {
            Write-Ok "All $($inSync.Count) tracked table(s) match their capture instances - no column drift."
            $summary.Add("$dbName - no drift")
            continue
        }
        if ($fixable.Count -gt 0) {
            Write-Host 'Tables with column drift:' -ForegroundColor Yellow
            for ($i = 0; $i -lt $fixable.Count; $i++) {
                $row = $fixable[$i]
                $parts = @()
                if ([string]$row.added_columns -ne '')   { $parts += "untracked column(s): $($row.added_columns)" }
                if ([string]$row.removed_columns -ne '') { $parts += "dropped column(s) still captured: $($row.removed_columns)" }
                Write-Host ("  {0,2}. {1}.{2} - {3}" -f ($i + 1), $row.schema_name, $row.table_name, ($parts -join ' | '))
            }
        }
        foreach ($m in $manual) { Write-Warn "drift on $m" }
        if ($inSync.Count -gt 0) {
            Write-Info "In sync: $($inSync -join ', ')"
        }

        if ($fixable.Count -eq 0) {
            $summary.Add("$dbName - drift found but only on manual-resolution tables")
            continue
        }

        Write-Host ''
        $picks = Read-Selection -Prompt "Select table(s) to sync ('all' for every table, Enter to skip)" -Count $fixable.Count -AllowEmpty -AllowAll
        if ($picks.Count -eq 0) {
            Write-Info 'No tables selected.'
            $summary.Add("$dbName - drift found, nothing synced")
            continue
        }
        $chosen = @($picks | Sort-Object | ForEach-Object { $fixable[$_ - 1] })

        $hoursRaw = Read-Answer 'Hours of change history to preserve' '3'
        $hours = 3
        if (-not [int]::TryParse($hoursRaw, [ref]$hours) -or $hours -lt 0) { $hours = 3 }

        Write-Warn "Each selected table's capture instance will be recreated via a temporary '_New' instance. Change data from the last $hours hour(s) is carried over; OLDER change rows are NOT. Three $($script:SwapDelaySeconds)-second safety delays run per table."
        if (-not (Read-Confirmation 'Continue')) {
            Write-Info 'Cancelled - no changes made.'
            $summary.Add("$dbName - cancelled")
            continue
        }

        $synced = 0
        foreach ($row in $chosen) {
            Write-Host ''
            Write-Info "Syncing $($row.schema_name).$($row.table_name)..."
            try {
                Invoke-CaptureInstanceSwap -Server $server -Database $dbName `
                    -SchemaName ([string]$row.schema_name) -TableName ([string]$row.table_name) `
                    -RoleName $row.role_name -SupportsNetChanges ([int][bool]$row.supports_net_changes) `
                    -FilegroupName $row.filegroup_name -PreserveHours $hours
                $synced++
            } catch {
                Write-Err "swap failed for $($row.schema_name).$($row.table_name): $($_.Exception.GetBaseException().Message)"
                Write-Warn "Check cdc.change_tables in '$dbName' - a leftover '_New' capture instance may need manual cleanup (sys.sp_cdc_disable_table)."
            }
        }

        # Verify the drift is really gone (manual-resolution tables are excluded -
        # they were already called out above and this tool does not touch them).
        # Assign before piping: piping the function directly hands Where-Object
        # the whole row array as a single $_ (the ,-wrapped return unrolls only
        # one pipeline level).
        $recheckRows = Get-ColumnDrift $server $dbName
        $recheck = @($recheckRows | Where-Object {
            (([string]$_.added_columns -ne '') -or ([string]$_.removed_columns -ne '')) -and
            ([int]$_.instance_count -eq 1) -and
            ([string]$_.capture_instance -eq "$($_.schema_name)_$($_.table_name)")
        })
        if ($recheck.Count -eq 0) {
            Write-Ok "Re-check clean - all auto-syncable tables now match their capture instances."
        } else {
            Write-Warn "Re-check: $($recheck.Count) table(s) still show drift."
        }
        $summary.Add("$dbName - synced $synced table(s)")
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
        exit (Invoke-CdcColumnSync)
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}
