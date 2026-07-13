#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Main entry point.
    Orchestrates all steps to build a local Hyper-V SQL Server Always On lab.

.PARAMETER SQLVersion
    SQL Server Developer Edition version to install: "2019", "2022" (default), or "2025".

.PARAMETER ContainedAG
    Creates a Contained Availability Group instead of a standard AG.
    Contained AGs replicate instance-level metadata (logins, SQL Agent jobs, etc.)
    across replicas. Requires SQL Server 2022 or later; cannot be combined with
    -SQLVersion 2019.

.PARAMETER Start
    Delegates to StartLab.ps1 to power on the ENTIRE lab at once after a shutdown —
    the domain controller plus every built cluster's SQL nodes (primary AG and any
    add-cluster AGs) — bringing each node's data disk online and starting the
    cluster service, SQL Server, and SQL Agent. Use this instead of re-running the
    build once you have more than one cluster, since a plain re-run only starts the
    primary three VMs.

.PARAMETER Teardown
    Delegates to TeardownLab.ps1 instead of running the build.

.PARAMETER Force
    Used with -Teardown to skip the confirmation prompt.

.PARAMETER AddCluster
    Delegates to AddCluster.ps1 to add ANOTHER independent 2-node Always On AG
    (on its own Windows Failover Cluster) to an already-built lab, reusing the
    existing domain controller, virtual switch and sqlsvc account. Repeatable —
    each run adds the next cluster. Combine with -ContainedAG for a Contained AG,
    or -SQLVersion to pin the new nodes' SQL version (defaults to the lab's ISO).

.EXAMPLE
    .\StartLabBuild.ps1
    .\StartLabBuild.ps1 -SQLVersion 2019
    .\StartLabBuild.ps1 -SQLVersion 2025
    .\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
    .\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
    .\StartLabBuild.ps1 -AddCluster
    .\StartLabBuild.ps1 -AddCluster -ContainedAG
    .\StartLabBuild.ps1 -Start
    .\StartLabBuild.ps1 -Teardown
    .\StartLabBuild.ps1 -Teardown -Force
#>

[CmdletBinding()]
param(
    [ValidateSet("2019","2022","2025")]
    [string]$SQLVersion = "2022",

    [switch]$ContainedAG,

    [switch]$AddCluster,

    [switch]$Start,

    [switch]$Teardown,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot

#region Execution Policy Check
$policy = Get-ExecutionPolicy -Scope Process
if ($policy -eq 'Restricted') {
    Write-Warning "Execution policy is Restricted. Setting to RemoteSigned for this process only."
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
}
#endregion

#region Teardown shortcut
if ($Teardown) {
    $teardownScript = Join-Path $ScriptRoot "TeardownLab.ps1"
    if (-not (Test-Path $teardownScript)) {
        Write-Error "Teardown-Lab.ps1 not found at: $teardownScript"
        exit 1
    }
    if ($Force) {
        & $teardownScript -Force
    } else {
        & $teardownScript
    }
    # $LASTEXITCODE is only set after a native command; under StrictMode, reading
    # it when unset throws. Default to 0 if the teardown ran no native commands.
    $teardownExit = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    exit $teardownExit
}
#endregion

#region Start-lab shortcut
if ($Start) {
    $startScript = Join-Path $ScriptRoot "StartLab.ps1"
    if (-not (Test-Path $startScript)) {
        Write-Error "StartLab.ps1 not found at: $startScript"
        exit 1
    }
    & $startScript
    $startExit = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    exit $startExit
}
#endregion

#region Add-cluster shortcut
if ($AddCluster) {
    $addScript = Join-Path $ScriptRoot "AddCluster.ps1"
    if (-not (Test-Path $addScript)) {
        Write-Error "AddCluster.ps1 not found at: $addScript"
        exit 1
    }
    $addArgs = @{}
    # Only forward -SQLVersion when the user explicitly set it, so AddCluster can
    # auto-detect the lab's already-downloaded SQL ISO by default.
    if ($PSBoundParameters.ContainsKey('SQLVersion')) { $addArgs['SQLVersion'] = $SQLVersion }
    if ($ContainedAG) { $addArgs['ContainedAG'] = $true }
    & $addScript @addArgs
    $addExit = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    exit $addExit
}
#endregion

#region Shared Write-Log — available before config is loaded
$global:LogFile = $null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry   = "[$ts] [$Level] $Message"
    $color   = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        default   { 'Cyan'   }
    }
    Write-Host $entry -ForegroundColor $color
    if ($global:LogFile) {
        Add-Content -Path $global:LogFile -Value $entry -Encoding UTF8
    }
}
#endregion

#region Dot-source config
$configPath = Join-Path $ScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 not found at: $configPath"
    exit 1
}
. $configPath
#endregion

#region VM utilities — available to all dot-sourced step files
function Start-LabVMs {
    param(
        [string[]]$VMNames,
        [int]$TimeoutSeconds = 120
    )
    if (-not $VMNames -or $VMNames.Count -eq 0) {
        $VMNames = @($DCVMName, $SQL1VMName, $SQL2VMName)
    }
    $toStart = @()
    foreach ($vmName in $VMNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { Write-Log "[$vmName] VM not found - skipping start." WARN; continue }
        if ($vm.State -ne 'Running') {
            Write-Log "[$vmName] VM is '$($vm.State)' - starting..." INFO
            Start-VM -Name $vmName -ErrorAction Stop
            $toStart += $vmName
        }
    }
    if ($toStart.Count -eq 0) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pending  = [System.Collections.Generic.List[string]]$toStart
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $stillPending = @()
        foreach ($vmName in $pending) {
            $state = (Get-VM -Name $vmName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Running') { Write-Log "[$vmName] Running." SUCCESS }
            else                      { $stillPending += $vmName }
        }
        $pending = [System.Collections.Generic.List[string]]$stillPending
        if ($pending.Count -gt 0) { Start-Sleep -Seconds 5 }
    }
    if ($pending.Count -gt 0) {
        throw "VMs did not reach Running state within $TimeoutSeconds s: $($pending -join ', ')"
    }
}
#endregion

#region Step runner
function Invoke-Step {
    param(
        [string]$StepFile,
        [string]$StepLabel
    )

    $stepPath = Join-Path $ScriptRoot "steps\$StepFile"
    if (-not (Test-Path $stepPath)) {
        Write-Log "Step file not found: $stepPath" ERROR
        throw "Missing step file: $StepFile"
    }

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "STEP: $StepLabel" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray

    try {
        . $stepPath
    } catch {
        Write-Log "STEP FAILED: $StepLabel — $_" ERROR
        Write-Log "Full error: $($_.ScriptStackTrace)" ERROR
        throw
    }
}
#endregion

#region Main Build
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            SQL LAB BUILDER — Starting Build              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
if ($ContainedAG -and $SQLVersion -eq "2019") {
    Write-Error "Contained Availability Groups require SQL Server 2022 or later. Remove -ContainedAG or use -SQLVersion 2022 or 2025."
    exit 1
}

Write-Log "SQL Version selected: $SQLVersion" INFO
Write-Log "Contained AG: $($ContainedAG.IsPresent)" INFO
Write-Log "Script root: $ScriptRoot" INFO

# Expose build options globally so all dot-sourced step scripts can read them
$global:SQLVersion   = $SQLVersion
$global:ContainedAG  = $ContainedAG.IsPresent

try {
    Invoke-Step "00Preflight.ps1"      "00 — Preflight checks"
    # Re-dot-source config after preflight (passwords may have been written)
    . $configPath

    # Now that LabRoot is set (by 01-SelectDrive inside 00-Preflight or standalone),
    # initialize the log file
    Invoke-Step "01SelectDrive.ps1"    "01 — Drive selection"
    . $configPath   # pick up LabRoot, LogPath etc. written by step 01

    # Create log directory and open log file
    if ($LogPath -and -not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $timestamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
    $global:LogFile   = Join-Path $LogPath "lab-build-$timestamp.log"
    New-Item -ItemType File -Path $global:LogFile -Force | Out-Null
    Write-Log "Log file: $global:LogFile" INFO

    # Re-source config one more time so LogPath etc. are in scope for all subsequent steps
    . $configPath

    Invoke-Step "02DownloadISOs.ps1"              "02 — Download ISOs"
    Invoke-Step "03CreateVMSwitch.ps1"            "03 — Create VM switch & NAT"
    Invoke-Step "04CreateVMs.ps1"                 "04 — Create virtual machines"
    Invoke-Step "05UnattendedWindowsSetup.ps1"    "05 — Inject unattended answer files"
    Invoke-Step "06ConfigureNetworking.ps1"       "06 — Configure guest networking"
    Invoke-Step "07PromoteDomainController.ps1"   "07 — Promote domain controller"
    Invoke-Step "08JoinDomainMembers.ps1"         "08 — Join SQL nodes to domain"
    Invoke-Step "09CreateCluster.ps1"             "09 — Create Windows Failover Cluster"
    Invoke-Step "10CreateSQLServiceAccount.ps1"   "10 — Create SQL service account"
    Invoke-Step "11InstallSQL.ps1"                "11 — Install SQL Server"
    Invoke-Step "12EnableAGFeature.ps1"           "12 — Enable Always On feature"
    Invoke-Step "13ConfigureAG.ps1"               "13 — Configure Availability Group"
    Invoke-Step "14ConfigureHostAccess.ps1"       "14 — Configure host SSMS access"
    Invoke-Step "15SummaryReport.ps1"             "15 — Generate summary report"

} catch {
    Write-Log "BUILD FAILED: $_" ERROR
    Write-Host ""
    Write-Host "The lab build encountered a fatal error. Review the log above." -ForegroundColor Red
    Write-Host "Fix the issue and re-run — completed steps will be skipped via checkpoints." -ForegroundColor Yellow
    if ($global:LogFile) { Write-Host "Full log: $global:LogFile" -ForegroundColor Yellow }
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              SQL LAB BUILD COMPLETE                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
#endregion
