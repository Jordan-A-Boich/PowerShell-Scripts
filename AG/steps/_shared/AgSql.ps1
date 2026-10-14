#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — SQL Server connectivity layer.

    All T-SQL in this tool goes through Invoke-AgSql (short statements) or
    Invoke-AgLongOp (BACKUP/RESTORE, which can run for hours on multi-TB
    databases and must report progress rather than appear hung).
#>

Set-StrictMode -Version Latest

#region ── Connection context ────────────────────────────────────────────────

# Set once by the entry point after the credential prompt.
$script:AgCredential            = $null   # $null => Windows integrated auth
$script:AgTrustServerCert       = $true
$script:AgConnectTimeoutSeconds = 15

function Set-AgConnectionContext {
    param(
        [pscredential]$Credential,
        [bool]$TrustServerCertificate = $true,
        [int]$ConnectTimeoutSeconds = 15
    )
    $script:AgCredential            = $Credential
    $script:AgTrustServerCert       = $TrustServerCertificate
    $script:AgConnectTimeoutSeconds = $ConnectTimeoutSeconds
}

function Get-AgSqlSplat {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Database = 'master',
        [int]$QueryTimeout = 60
    )
    $splat = @{
        ServerInstance = $Instance
        Database       = $Database
        QueryTimeout   = $QueryTimeout
        ConnectionTimeout = $script:AgConnectTimeoutSeconds
        ErrorAction    = 'Stop'
    }
    if ($script:AgTrustServerCert) { $splat['TrustServerCertificate'] = $true }
    if ($script:AgCredential)      { $splat['Credential'] = $script:AgCredential }
    return $splat
}

function Get-AgConnectionString {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Database = 'master'
    )
    $sb = "Server=$Instance;Database=$Database;Application Name=AG-Toolkit;Connect Timeout=$script:AgConnectTimeoutSeconds;Encrypt=False;"
    if ($script:AgTrustServerCert) { $sb += 'TrustServerCertificate=True;' }
    if ($script:AgCredential) {
        $user = $script:AgCredential.UserName
        $pass = $script:AgCredential.GetNetworkCredential().Password.Replace("'", "''")
        $sb += "User ID=$user;Password='$pass';"
    } else {
        $sb += 'Integrated Security=True;'
    }
    return $sb
}

#endregion

#region ── Short-running statements ──────────────────────────────────────────

function Invoke-AgSql {
    <#
    .SYNOPSIS
        Executes T-SQL and returns rows (or nothing for DDL/DML).
    .PARAMETER Retry
        Retry transient faults. Safe for reads and for idempotent DDL. Do NOT use
        for non-idempotent statements.
    .PARAMETER QueryTimeout
        Seconds; 0 means wait indefinitely.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$QueryTimeout = 60,
        [switch]$Retry,
        [string]$Activity = 'query'
    )

    # A BACKUP or RESTORE must never reach the retry path. 'Timeout expired' counts as
    # transient, and a client-side timeout on a long RESTORE means SQL Server took an
    # ATTENTION and rolled the whole restore back — so a retry reissues it from zero, hits
    # the same timeout at the same point, and loops. That is the exact shape of the
    # multi-terabyte re-restore loop this tool is built to avoid. Long operations belong in
    # Invoke-AgLongOp, which sets CommandTimeout = 0 and does not retry.
    # HEADERONLY / FILELISTONLY / VERIFYONLY are reads and stay retryable.
    if ($Retry -and $Query -match '(?im)^\s*(BACKUP\s+(DATABASE|LOG)|RESTORE\s+(DATABASE|LOG))\b') {
        throw 'Invoke-AgSql -Retry must not be used for BACKUP or RESTORE — use Invoke-AgLongOp.'
    }

    $splat = Get-AgSqlSplat -Instance $Instance -Database $Database -QueryTimeout $QueryTimeout
    $splat['Query'] = $Query

    Write-AgLog "SQL [$Instance] $($Query -replace '\s+',' ')" DEBUG

    $run = { Invoke-Sqlcmd @splat }

    $rows = if ($Retry) {
        Invoke-AgWithRetry -ScriptBlock $run -Activity "$Activity on $Instance"
    } else {
        & $run
    }

    # Invoke-Sqlcmd hands back a bare DataRow for a single-row result. Indexing that
    # DataRow with [0] yields its first COLUMN, not the row, which silently produces
    # nonsense. Normalising to an array here makes $rows[0] mean "first row" everywhere.
    #
    # The leading comma stops PowerShell unrolling the array on return, so a zero-row
    # result assigns as an empty array rather than $null. That only holds for direct
    # assignment: callers must NOT write @(Invoke-AgSql ...), because wrapping the
    # emitted empty array in @() yields a one-element array containing an empty array.
    return ,@($rows)
}

function Get-AgScalar {
    <#
    .SYNOPSIS
        Runs a query expected to yield exactly one column named 'v' on one row.
        Returns $null when the query produces no rows or the value is NULL.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$QueryTimeout = 60
    )
    $rows = Invoke-AgSql -Instance $Instance -Query $Query -Database $Database -QueryTimeout $QueryTimeout -Retry -Activity 'scalar'
    if ($rows.Count -eq 0) { return $null }
    $val = $rows[0].v
    if ($val -is [System.DBNull]) { return $null }
    return $val
}

function Get-AgSqlErrorNumber {
    <#
    .SYNOPSIS
        Every SQL Server error number carried by an ErrorRecord.

    .DESCRIPTION
        RESTORE outcomes are classified by error NUMBER, never by message text. Message
        text is localized — a German or Japanese instance returns the same 4319 in
        entirely different words — and a matcher built on English strings fails open.
        For this tool, failing open means "I could not tell", and historically that
        meant "restore the multi-terabyte backup again".

        A failed RESTORE reports several errors at once: the specific cause, then 3119
        ("problems were identified while planning"), then 3013 ("terminating
        abnormally"). The whole collection is returned, so callers look for the number
        that carries the meaning rather than whichever one happens to surface first.

        Falls back to scraping 'Msg NNNN' from the text, which is how the number
        survives on the paths where Invoke-Sqlcmd has wrapped the SqlException.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $numbers = New-Object System.Collections.Generic.List[int]

    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.PSObject.Properties.Name -contains 'Errors' -and $ex.Errors) {
            foreach ($e in $ex.Errors) {
                if ($e.PSObject.Properties.Name -contains 'Number') { $numbers.Add([int]$e.Number) }
            }
        }
        $ex = $ex.InnerException
    }

    if ($numbers.Count -eq 0) {
        foreach ($m in [regex]::Matches([string]$ErrorRecord.Exception.Message, '(?im)\bMsg\s+(\d{3,5})\b')) {
            $numbers.Add([int]$m.Groups[1].Value)
        }
    }

    return @($numbers)
}

function Test-AgConnection {
    param([Parameter(Mandatory)][string]$Instance)
    try {
        $null = Invoke-AgSql -Instance $Instance -Query 'SELECT 1 AS v' -QueryTimeout 15
        return $true
    } catch {
        Write-AgLog "Cannot connect to '$Instance': $($_.Exception.Message.Split("`n")[0])" DEBUG
        return $false
    }
}

#endregion

#region ── Long-running statements with progress ─────────────────────────────

function Get-AgSqlClientType {
    <#
    .SYNOPSIS
        Resolves an available ADO.NET SqlConnection type.
        The SqlServer module ships Microsoft.Data.SqlClient; Windows PowerShell also
        has System.Data.SqlClient in the GAC. Returns $null when neither is loadable,
        in which case callers fall back to a plain (progress-less) Invoke-Sqlcmd.
    #>
    if ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) { return 'Microsoft.Data.SqlClient' }
    if ('System.Data.SqlClient.SqlConnection'    -as [type]) { return 'System.Data.SqlClient' }
    return $null
}

function Invoke-AgLongOp {
    <#
    .SYNOPSIS
        Executes a long-running statement (BACKUP / RESTORE) with no client timeout,
        polling sys.dm_exec_requests from a second connection so multi-terabyte
        operations report percent-complete and ETA instead of looking hung.

    .DESCRIPTION
        Runs the command asynchronously on its own connection, captures the SPID, and
        polls percent_complete / estimated_completion_time from the orchestrator.
        SQL Server InfoMessages (e.g. "Processed N pages") are folded into the log.
        Any server error is re-thrown to the caller — this never swallows failures.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Activity,
        [int]$PollSeconds = 15
    )

    $clientNs = Get-AgSqlClientType
    $started  = Get-Date

    if (-not $clientNs) {
        Write-AgLog "$Activity — running without progress reporting (no ADO.NET client type available)" WARN
        Invoke-AgSql -Instance $Instance -Query $Query -QueryTimeout 0 -Activity $Activity | Out-Null
        Write-AgLog ("{0} — completed in {1}" -f $Activity, (Format-AgDuration ((Get-Date) - $started))) SUCCESS
        return
    }

    $connStr = Get-AgConnectionString -Instance $Instance
    $conn    = New-Object "$clientNs.SqlConnection" $connStr

    # InfoMessage carries BACKUP/RESTORE's own progress + "Processed N pages" summaries.
    $infoHandler = {
        param($sender, $e)
        foreach ($err in $e.Errors) {
            if ($err.Class -le 10) { Write-AgLog "  $($err.Message)" DEBUG }
        }
    }
    $conn.add_InfoMessage($infoHandler)

    try {
        $conn.Open()

        $spidCmd = $conn.CreateCommand()
        $spidCmd.CommandText = 'SELECT @@SPID'
        $spid = [int]$spidCmd.ExecuteScalar()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = 0            # multi-TB: never time out client-side
        $async = $cmd.BeginExecuteNonQuery()

        Write-AgLog "$Activity — started (spid $spid)" INFO

        $lastPct = -1
        while (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($PollSeconds))) {
            try {
                $p = Invoke-AgSql -Instance $Instance -QueryTimeout 20 -Query @"
SELECT TOP 1
       CAST(r.percent_complete AS decimal(5,1))                       AS pct,
       CAST(r.estimated_completion_time / 60000.0 AS decimal(10,1))   AS eta_min,
       r.command
FROM sys.dm_exec_requests AS r
WHERE r.session_id = $spid;
"@
                if ($p.Count -gt 0 -and $p[0].pct -isnot [System.DBNull]) {
                    $pct = [double]$p[0].pct
                    $eta = if ($p[0].eta_min -is [System.DBNull]) { 0 } else { [double]$p[0].eta_min }
                    if ($pct -gt 0 -and [math]::Abs($pct - $lastPct) -ge 1) {
                        Write-AgLog ("  {0}: {1:N1}% complete, ~{2:N1} min remaining" -f $Activity, $pct, $eta) INFO
                        $lastPct = $pct
                    }
                }
            } catch {
                # A failed progress poll must never abort the operation it is watching.
                Write-AgLog "  (progress poll failed: $($_.Exception.Message.Split("`n")[0]))" DEBUG
            }
        }

        # Surfaces any server-side error raised by the BACKUP/RESTORE itself.
        try {
            [void]$cmd.EndExecuteNonQuery($async)
        } catch {
            # PowerShell wraps the SqlException from a .NET method call in a
            # MethodInvocationException. Re-throw the inner exception so callers match on
            # SQL Server's own text ("too recent to apply...") and operators read the
            # server's message rather than 'Exception calling "EndExecuteNonQuery"'.
            if ($_.Exception.InnerException) { throw $_.Exception.InnerException }
            throw
        }

        Write-AgLog ("{0} — completed in {1}" -f $Activity, (Format-AgDuration ((Get-Date) - $started))) SUCCESS
    } finally {
        try { $conn.remove_InfoMessage($infoHandler) } catch { }
        if ($conn.State -ne 'Closed') { $conn.Close() }
        $conn.Dispose()
    }
}

#endregion
