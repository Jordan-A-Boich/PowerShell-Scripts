#Requires -Version 5.1
<#
.SYNOPSIS
    Step 00 — Preflight checks.

IDEMPOTENCY CHECKS:
    - Elevation: re-checked every run (cannot be skipped).
    - Hyper-V features: re-checked every run.
    - SqlServer module: installed if absent; no-op if present.
    - Passwords: generated and written to config.ps1 only if blank.
    - Checkpoint: written after all checks pass. If checkpoint exists, only
      password/module checks are re-run (they are fast and safe to repeat).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "..\config.ps1"

#region 1. Elevation check
Write-Log "Checking administrator elevation..." INFO
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "This script must be run as Administrator. Re-launch PowerShell as Administrator and retry." ERROR
    throw "Not running as Administrator."
}
Write-Log "Running as Administrator." SUCCESS
#endregion

#region 2. Hyper-V check
Write-Log "Checking Hyper-V features..." INFO
$hvFeature   = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -ErrorAction SilentlyContinue
$hvPSFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V-Management-PowerShell" -ErrorAction SilentlyContinue

if ($hvFeature.State -ne 'Enabled' -or $hvPSFeature.State -ne 'Enabled') {
    Write-Log "Hyper-V is not fully enabled on this host." ERROR
    Write-Log "Enable it with: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" ERROR
    Write-Log "Or via Server Manager > Add Roles and Features > Hyper-V." ERROR
    Write-Log "A reboot will be required. Re-run this script after enabling Hyper-V." ERROR
    throw "Hyper-V features not enabled."
}
Write-Log "Hyper-V features are enabled." SUCCESS
#endregion

#region 3. Host RAM check
Write-Log "Checking host available memory..." INFO
$totalRAMGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$availRAMGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
Write-Log "Host RAM — Total: ${totalRAMGB} GB   Available: ${availRAMGB} GB" INFO
if ($availRAMGB -lt 10) {
    Write-Log "WARNING: Only ${availRAMGB} GB RAM is currently available. The lab requires approximately 10 GB to run all 3 VMs simultaneously." WARN
    Write-Log "Running on a laptop with limited RAM may cause heavy swapping and very slow build times." WARN
    $proceed = Read-Host "Available RAM is low (${availRAMGB} GB free). Continue anyway? (Y/N)"
    if ($proceed -ne 'Y' -and $proceed -ne 'y') {
        throw "Build cancelled by user — insufficient available RAM."
    }
} else {
    Write-Log "Available RAM is sufficient (${availRAMGB} GB free)." SUCCESS
}
#endregion

#region 4. SqlServer PowerShell module
Write-Log "Checking for SqlServer PowerShell module..." INFO
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Log "SqlServer module not found. Installing (this may take a minute)..." WARN
    Install-Module SqlServer -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
    Write-Log "SqlServer module installed." SUCCESS
} else {
    Write-Log "SqlServer module already installed." SUCCESS
}
#endregion

#region 4. Password generation — write to config.ps1 if fields are blank
Write-Log "Checking password configuration..." INFO

function New-LabPassword {
    param([int]$Length = 18)
    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower   = 'abcdefghijklmnopqrstuvwxyz'
    $digits  = '0123456789'
    $special = '!@#$%^&*()-_=+'
    $all     = $upper + $lower + $digits + $special
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes   = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    $chars   = $bytes | ForEach-Object { $all[$_ % $all.Length] }
    # Guarantee at least one of each class
    $chars[0] = $upper[(Get-Random -Maximum $upper.Length)]
    $chars[1] = $digits[(Get-Random -Maximum $digits.Length)]
    $chars[2] = $special[(Get-Random -Maximum $special.Length)]
    $chars[3] = $lower[(Get-Random -Maximum $lower.Length)]
    # Shuffle
    $shuffled = $chars | Sort-Object { Get-Random }
    return -join $shuffled
}

$configContent = Get-Content -Path $configPath -Raw -ErrorAction Stop

$needsWrite = $false
$passwords  = @{}

foreach ($varName in @('AdminPassword','SQLServiceAccountPassword','SAPassword','LabAdminPassword')) {
    if ($configContent -match "\`$$varName\s*=\s*`"(.+?)`"") {
        $existing = $Matches[1]
        $passwords[$varName] = $existing
        Write-Log "$varName already set — preserving." INFO
    } else {
        # Field is blank
        if ($varName -eq 'LabAdminPassword' -and $passwords['SAPassword']) {
            $passwords[$varName] = $passwords['SAPassword']
        } else {
            $passwords[$varName] = New-LabPassword
        }
        $needsWrite = $true
        Write-Log "Generated password for $varName." INFO
    }
}

if ($needsWrite) {
    Write-Log "Writing generated passwords to config.ps1..." INFO
    foreach ($varName in $passwords.Keys) {
        $escapedPwd = $passwords[$varName] -replace '`', '``' -replace '\$', '`$'
        $configContent = $configContent -replace "(\`$$varName\s*=\s*`")(`")", "`${1}$($passwords[$varName])`""
    }
    Set-Content -Path $configPath -Value $configContent -Encoding UTF8 -ErrorAction Stop
    Write-Log "Passwords written to config.ps1." SUCCESS
    Write-Log "IMPORTANT: Keep config.ps1 safe — it contains your lab credentials." WARN
}

# Re-dot-source config so caller has the fresh values
. $configPath
#endregion

#region 5. Checkpoint
if ($CheckpointPath) {
    if (-not (Test-Path $CheckpointPath)) { New-Item -ItemType Directory -Path $CheckpointPath -Force | Out-Null }
    $cpFile = Join-Path $CheckpointPath "step-00.done"
    if (-not (Test-Path $cpFile)) {
        New-Item -ItemType File -Path $cpFile -Force | Out-Null
        Write-Log "Checkpoint written: step-00.done" SUCCESS
    }
}
#endregion

Write-Log "Preflight complete — all checks passed." SUCCESS
