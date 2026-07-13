#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — SQL Server connectivity layer.

    All T-SQL in this tool goes through Invoke-DagSql (short statements) or
    Invoke-DagLongOp (BACKUP/RESTORE, which can run for hours on multi-TB
    databases and must report progress rather than appear hung).
#>

Set-StrictMode -Version Latest

#region ── Connection context ────────────────────────────────────────────────

# Set once by Initialize-DAG.ps1 after the credential prompt.
$script:DagCredential            = $null   # $null => Windows integrated auth
$script:DagTrustServerCert       = $true
$script:DagConnectTimeoutSeconds = 15

function Set-DagConnectionContext {
    param(
        [pscredential]$Credential,
        [bool]$TrustServerCertificate = $true,
        [int]$ConnectTimeoutSeconds = 15
    )
    $script:DagCredential            = $Credential
    $script:DagTrustServerCert       = $TrustServerCertificate
    $script:DagConnectTimeoutSeconds = $ConnectTimeoutSeconds
}

function Get-DagSqlSplat {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Database = 'master',
        [int]$QueryTimeout = 60
    )
    $splat = @{
        ServerInstance = $Instance
        Database       = $Database
        QueryTimeout   = $QueryTimeout
        ConnectionTimeout = $script:DagConnectTimeoutSeconds
        ErrorAction    = 'Stop'
    }
    if ($script:DagTrustServerCert) { $splat['TrustServerCertificate'] = $true }
    if ($script:DagCredential)      { $splat['Credential'] = $script:DagCredential }
    return $splat
}

function Get-DagConnectionString {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$Database = 'master'
    )
    $sb = "Server=$Instance;Database=$Database;Application Name=Initialize-DAG;Connect Timeout=$script:DagConnectTimeoutSeconds;Encrypt=False;"
    if ($script:DagTrustServerCert) { $sb += 'TrustServerCertificate=True;' }
    if ($script:DagCredential) {
        $user = $script:DagCredential.UserName
        $pass = $script:DagCredential.GetNetworkCredential().Password.Replace("'", "''")
        $sb += "User ID=$user;Password='$pass';"
    } else {
        $sb += 'Integrated Security=True;'
    }
    return $sb
}

#endregion

#region ── Short-running statements ──────────────────────────────────────────

function Invoke-DagSql {
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

    $splat = Get-DagSqlSplat -Instance $Instance -Database $Database -QueryTimeout $QueryTimeout
    $splat['Query'] = $Query

    Write-DagLog "SQL [$Instance] $($Query -replace '\s+',' ')" DEBUG

    $run = { Invoke-Sqlcmd @splat }

    $rows = if ($Retry) {
        Invoke-DagWithRetry -ScriptBlock $run -Activity "$Activity on $Instance"
    } else {
        & $run
    }

    # Invoke-Sqlcmd hands back a bare DataRow for a single-row result. Indexing that
    # DataRow with [0] yields its first COLUMN, not the row, which silently produces
    # nonsense. Normalising to an array here makes $rows[0] mean "first row" everywhere.
    #
    # The leading comma stops PowerShell unrolling the array on return, so a zero-row
    # result assigns as an empty array rather than $null. That only holds for direct
    # assignment: callers must NOT write @(Invoke-DagSql ...), because wrapping the
    # emitted empty array in @() yields a one-element array containing an empty array.
    return ,@($rows)
}

function Get-DagScalar {
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
    $rows = Invoke-DagSql -Instance $Instance -Query $Query -Database $Database -QueryTimeout $QueryTimeout -Retry -Activity 'scalar'
    if ($rows.Count -eq 0) { return $null }
    $val = $rows[0].v
    if ($val -is [System.DBNull]) { return $null }
    return $val
}

function Test-DagConnection {
    param([Parameter(Mandatory)][string]$Instance)
    try {
        $null = Invoke-DagSql -Instance $Instance -Query 'SELECT 1 AS v' -QueryTimeout 15
        return $true
    } catch {
        Write-DagLog "Cannot connect to '$Instance': $($_.Exception.Message.Split("`n")[0])" DEBUG
        return $false
    }
}

#endregion

#region ── Long-running statements with progress ─────────────────────────────

function Get-DagSqlClientType {
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

function Invoke-DagLongOp {
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

    $clientNs = Get-DagSqlClientType
    $started  = Get-Date

    if (-not $clientNs) {
        Write-DagLog "$Activity — running without progress reporting (no ADO.NET client type available)" WARN
        Invoke-DagSql -Instance $Instance -Query $Query -QueryTimeout 0 -Activity $Activity | Out-Null
        Write-DagLog ("{0} — completed in {1}" -f $Activity, (Format-DagDuration ((Get-Date) - $started))) SUCCESS
        return
    }

    $connStr = Get-DagConnectionString -Instance $Instance
    $conn    = New-Object "$clientNs.SqlConnection" $connStr

    # InfoMessage carries BACKUP/RESTORE's own progress + "Processed N pages" summaries.
    $infoHandler = {
        param($sender, $e)
        foreach ($err in $e.Errors) {
            if ($err.Class -le 10) { Write-DagLog "  $($err.Message)" DEBUG }
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

        Write-DagLog "$Activity — started (spid $spid)" INFO

        $lastPct = -1
        while (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($PollSeconds))) {
            try {
                $p = Invoke-DagSql -Instance $Instance -QueryTimeout 20 -Query @"
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
                        Write-DagLog ("  {0}: {1:N1}% complete, ~{2:N1} min remaining" -f $Activity, $pct, $eta) INFO
                        $lastPct = $pct
                    }
                }
            } catch {
                # A failed progress poll must never abort the operation it is watching.
                Write-DagLog "  (progress poll failed: $($_.Exception.Message.Split("`n")[0]))" DEBUG
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

        Write-DagLog ("{0} — completed in {1}" -f $Activity, (Format-DagDuration ((Get-Date) - $started))) SUCCESS
    } finally {
        try { $conn.remove_InfoMessage($infoHandler) } catch { }
        if ($conn.State -ne 'Closed') { $conn.Close() }
        $conn.Dispose()
    }
}

#endregion
