#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — common primitives: logging, identifier quoting, retry, misc helpers.

    Dot-sourced by Initialize-DAG.ps1. Defines functions only; performs no actions.
#>

Set-StrictMode -Version Latest

#region ── Logging ───────────────────────────────────────────────────────────

# Populated by Initialize-DAG.ps1 before any logging occurs.
$script:DagLogFile = $null

function Initialize-DagLog {
    param([Parameter(Mandatory)][string]$LogDirectory)

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:DagLogFile = Join-Path $LogDirectory "Initialize-DAG_$stamp.log"
    Write-DagLog "Log file: $script:DagLogFile" INFO
    return $script:DagLogFile
}

function Write-DagLog {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO','SUCCESS','WARN','ERROR','STEP','DEBUG')][string]$Level = 'INFO'
    )

    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1,-7}] {2}' -f $ts, $Level, $Message

    switch ($Level) {
        'SUCCESS' { Write-Host $Message -ForegroundColor Green }
        'WARN'    { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "ERROR: $Message" -ForegroundColor Red }
        'STEP'    { Write-Host ''; Write-Host $Message -ForegroundColor Cyan }
        'DEBUG'   { Write-Verbose $Message }
        default   { Write-Host $Message }
    }

    if ($script:DagLogFile) {
        # Never let a logging failure take down a long-running seed.
        try { Add-Content -Path $script:DagLogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function Write-DagBanner {
    param([Parameter(Mandatory)][string]$Text)
    $bar = '=' * 78
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ("  {0}" -f $Text) -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkCyan
    if ($script:DagLogFile) {
        try { Add-Content -Path $script:DagLogFile -Value "`r`n=== $Text ===" -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

#endregion

#region ── T-SQL identifier / literal quoting ─────────────────────────────────

<#
    Every dynamic value that reaches T-SQL goes through one of these. Database and
    AG names can legally contain ']' and "'", and a mis-quoted name is both a
    correctness bug and an injection vector.
#>

function ConvertTo-DagQuotedName {
    param([Parameter(Mandatory)][string]$Name)
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-DagQuotedString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

#endregion

#region ── Retry ─────────────────────────────────────────────────────────────

# Errors worth retrying: transport blips, login throttling, deadlock victims,
# and the "AG is not ready / still transitioning" family. Explicitly NOT
# retried: syntax errors, permission errors, or anything a retry cannot fix.
$script:DagTransientPatterns = @(
    'transport-level error'
    'existing connection was forcibly closed'
    'semaphore timeout'
    'A network-related or instance-specific error'
    'deadlocked on lock resources'
    'Timeout expired'
    'is not currently available'
    'try the operation again'
    'The connection is broken'
    'Connection Timeout Expired'
    'wait operation timed out'
)

function Test-DagTransientError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    foreach ($p in $script:DagTransientPatterns) {
        if ($msg -like "*$p*") { return $true }
    }
    return $false
}

function Invoke-DagWithRetry {
    <#
    .SYNOPSIS
        Runs a scriptblock, retrying only on transient faults with linear backoff.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5,
        [string]$Activity = 'operation'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $isLast = ($attempt -eq $MaxAttempts)
            if ($isLast -or -not (Test-DagTransientError -ErrorRecord $_)) { throw }
            $wait = $DelaySeconds * $attempt
            Write-DagLog ("Transient failure during {0} (attempt {1}/{2}): {3}" -f `
                $Activity, $attempt, $MaxAttempts, $_.Exception.Message.Split("`n")[0]) WARN
            Write-DagLog "Retrying in $wait second(s)..." INFO
            Start-Sleep -Seconds $wait
        }
    }
}

#endregion

#region ── Waiting / polling ─────────────────────────────────────────────────

function Wait-DagCondition {
    <#
    .SYNOPSIS
        Polls a predicate until it returns $true or the timeout expires.
    .OUTPUTS
        [bool] $true if the condition was met, $false on timeout.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Activity,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 10,
        [scriptblock]$ProgressMessage
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastMsg = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) {
            Write-DagLog ("{0}: satisfied after {1:N0}s" -f $Activity, $sw.Elapsed.TotalSeconds) SUCCESS
            return $true
        }
        if ($ProgressMessage) {
            $msg = & $ProgressMessage
            if ($msg -and $msg -ne $lastMsg) {
                Write-DagLog ("{0}: {1}" -f $Activity, $msg) INFO
                $lastMsg = $msg
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-DagLog ("{0}: TIMED OUT after {1}s" -f $Activity, $TimeoutSeconds) WARN
    return $false
}

#endregion

#region ── Formatting ────────────────────────────────────────────────────────

function Format-DagBytes {
    param([Parameter(Mandatory)][double]$Bytes)
    $units = 'B','KB','MB','GB','TB','PB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes /= 1024; $i++ }
    '{0:N2} {1}' -f $Bytes, $units[$i]
}

function Format-DagDuration {
    param([Parameter(Mandatory)][timespan]$Span)
    if ($Span.TotalHours -ge 1) { return '{0:N0}h {1:N0}m {2:N0}s' -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds }
    if ($Span.TotalMinutes -ge 1) { return '{0:N0}m {1:N0}s' -f [math]::Floor($Span.TotalMinutes), $Span.Seconds }
    '{0:N1}s' -f $Span.TotalSeconds
}

#endregion

#region ── Path helpers ──────────────────────────────────────────────────────

function Join-DagPath {
    <#
    .SYNOPSIS
        Joins UNC/Windows path segments without depending on the local filesystem.
        Join-Path can behave oddly with UNC roots and requires the path to be valid
        for the *local* provider — which it never is here, since the backup share is
        only reachable from the SQL Server hosts, not from this orchestrator.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ChildPath
    )
    $result = $Path.TrimEnd('\')
    foreach ($c in $ChildPath) {
        $result = $result + '\' + $c.Trim('\')
    }
    return $result
}

function Get-DagSafeFileToken {
    <#
    .SYNOPSIS
        Makes a database name safe to embed in a file/folder name.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]@('\','/',':','*','?','"','<','>','|',' ')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

#endregion
