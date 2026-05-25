#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Main entry point.
    Orchestrates all steps to build a local Hyper-V SQL Server Always On lab.

.PARAMETER SQLVersion
    SQL Server version to install: "2022" (default) or "2025".

.PARAMETER Teardown
    Delegates to Teardown-Lab.ps1 instead of running the build.

.PARAMETER Force
    Used with -Teardown to skip the confirmation prompt.

.EXAMPLE
    .\Start-LabBuild.ps1
    .\Start-LabBuild.ps1 -SQLVersion 2025
    .\Start-LabBuild.ps1 -Teardown
    .\Start-LabBuild.ps1 -Teardown -Force
#>

[CmdletBinding()]
param(
    [ValidateSet("2022","2025")]
    [string]$SQLVersion = "2022",

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
    $teardownScript = Join-Path $ScriptRoot "Teardown-Lab.ps1"
    if (-not (Test-Path $teardownScript)) {
        Write-Error "Teardown-Lab.ps1 not found at: $teardownScript"
        exit 1
    }
    if ($Force) {
        & $teardownScript -Force
    } else {
        & $teardownScript
    }
    exit $LASTEXITCODE
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
Write-Log "SQL Version selected: $SQLVersion" INFO
Write-Log "Script root: $ScriptRoot" INFO

# Expose SQLVersion globally so step scripts can read it
$global:SQLVersion = $SQLVersion

try {
    Invoke-Step "00-Preflight.ps1"      "00 — Preflight checks"
    # Re-dot-source config after preflight (passwords may have been written)
    . $configPath

    # Now that LabRoot is set (by 01-SelectDrive inside 00-Preflight or standalone),
    # initialize the log file
    Invoke-Step "01-SelectDrive.ps1"    "01 — Drive selection"
    . $configPath   # pick up LabRoot, LogPath etc. written by step 01

    # Create log directory and open log file
    if ($LogPath -and -not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $timestamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
    $global:LogFile   = Join-Path $LogPath "lab-build-$timestamp.log"
    New-Item -ItemType File -Path $global:LogFile -Force | Out-Null
    Write-Log "Log file: $global:LogFile" INFO

    # Re-source config one more time so LogPath etc. are in scope for all subsequent steps
    . $configPath

    Invoke-Step "02-DownloadISOs.ps1"              "02 — Download ISOs"
    Invoke-Step "03-CreateVMSwitch.ps1"            "03 — Create VM switch & NAT"
    Invoke-Step "04-CreateVMs.ps1"                 "04 — Create virtual machines"
    Invoke-Step "05-UnattendedWindowsSetup.ps1"    "05 — Inject unattended answer files"
    Invoke-Step "06-ConfigureNetworking.ps1"       "06 — Configure guest networking"
    Invoke-Step "07-PromoteDomainController.ps1"   "07 — Promote domain controller"
    Invoke-Step "08-JoinDomainMembers.ps1"         "08 — Join SQL nodes to domain"
    Invoke-Step "09-CreateCluster.ps1"             "09 — Create Windows Failover Cluster"
    Invoke-Step "10-CreateSQLServiceAccount.ps1"   "10 — Create SQL service account"
    Invoke-Step "11-InstallSQL.ps1"                "11 — Install SQL Server"
    Invoke-Step "12-EnableAGFeature.ps1"           "12 — Enable Always On feature"
    Invoke-Step "13-ConfigureAG.ps1"               "13 — Configure Availability Group"
    Invoke-Step "14-ConfigureHostAccess.ps1"       "14 — Configure host SSMS access"
    Invoke-Step "15-SummaryReport.ps1"             "15 — Generate summary report"

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
