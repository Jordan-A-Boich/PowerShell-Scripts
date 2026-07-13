#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — durable plan + per-database progress, so an interrupted run resumes.

.DESCRIPTION
    The state file is a HINT, never the source of truth. Every step re-checks the live
    server state before acting, so a deleted, stale or hand-edited state file can slow a
    re-run down but cannot make it do the wrong thing. What the file buys us is:

      * the operator is not re-prompted for the whole plan on a resume, and
      * a completed multi-terabyte FULL backup can be reused instead of retaken.

    Credentials are never written to disk.
#>

Set-StrictMode -Version Latest

$script:DagStateDirectory = $null

function Initialize-DagState {
    param([Parameter(Mandatory)][string]$StateDirectory)
    if (-not (Test-Path $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }
    $script:DagStateDirectory = $StateDirectory
}

function Get-DagStatePath {
    param([Parameter(Mandatory)][string]$DagName)
    Join-Path $script:DagStateDirectory ("{0}.json" -f (Get-DagSafeFileToken $DagName))
}

function Save-DagPlan {
    param([Parameter(Mandatory)][psobject]$Plan)

    $path = Get-DagStatePath -DagName $Plan.DagName
    $copy = $Plan | Select-Object -Property * -ExcludeProperty Credential
    $copy | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    Write-DagLog "Saved plan state: $path" DEBUG
}

function Get-DagSavedPlan {
    <#
    .OUTPUTS
        The saved plan, or $null when there is none / it cannot be parsed.
    #>
    param([Parameter(Mandatory)][string]$DagName)

    $path = Get-DagStatePath -DagName $DagName
    if (-not (Test-Path $path)) { return $null }
    try {
        return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-DagLog "Ignoring unreadable state file '$path': $($_.Exception.Message)" WARN
        return $null
    }
}

function New-DagProgressRecord {
    <#
    .SYNOPSIS
        Empty per-database progress record used by the manual seeding path.
    #>
    param([Parameter(Mandatory)][string]$DatabaseName)
    [pscustomobject]@{
        DatabaseName    = $DatabaseName
        FullBackupFiles = @()
        FullBackupUtc   = $null
        FullCheckpointLsn = $null
        RestoredOn      = @()      # replicas that have the FULL applied
        JoinedOn        = @()      # replicas where the db is joined to the forwarder AG
        Completed       = $false
    }
}

function Get-DagProgress {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rec = @($Plan.Progress | Where-Object { $_.DatabaseName -eq $DatabaseName })
    if ($rec.Count -gt 0) { return $rec[0] }
    return $null
}

function Set-DagProgress {
    <#
    .SYNOPSIS
        Replaces the progress record for one database and persists the plan.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][psobject]$Record
    )
    $others = @($Plan.Progress | Where-Object { $_.DatabaseName -ne $Record.DatabaseName })
    $Plan.Progress = @($others + $Record)
    Save-DagPlan -Plan $Plan
}
