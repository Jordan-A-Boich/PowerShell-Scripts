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

# We need both the Hyper-V platform and the Hyper-V PowerShell module enabled.
# The "official" query is Get-WindowsOptionalFeature, but the underlying DISM/CBS
# COM provider is corrupt on some hosts and hangs ~2 min before throwing a
# *terminating* "Class not registered" (0x80040154) exception that -ErrorAction
# can't suppress. Win32_OptionalFeature (CIM) returns the same data, is fast, and
# works even when DISM is broken — so we query it first and only fall back to
# DISM if CIM itself is unavailable.
function Test-FeatureEnabled {
    param([string[]]$FeatureName)

    # Primary: Win32_OptionalFeature. InstallState 1 = Enabled.
    try {
        $cim = Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop |
            Where-Object { $FeatureName -contains $_.Name }
        if ($cim | Where-Object { $_.InstallState -eq 1 }) { return $true }
        # CIM answered but none of the features are enabled — authoritative, no fallback.
        if ($cim) { return $false }
    } catch {
        Write-Log "Win32_OptionalFeature query failed ($($_.Exception.Message.Trim())); trying DISM." WARN
    }

    # Fallback: DISM optional-feature provider (may hang/throw on corrupt hosts).
    try {
        foreach ($name in $FeatureName) {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
            if ($f.State -eq 'Enabled') { return $true }
        }
    } catch {
        Write-Log "Get-WindowsOptionalFeature unavailable ($($_.Exception.Message.Trim()))." WARN
    }

    return $false
}

$hvEnabled = Test-FeatureEnabled -FeatureName @('Microsoft-Hyper-V','Microsoft-Hyper-V-All')

# The PowerShell module is what the build drives Hyper-V with; treat the module
# actually being importable as authoritative for the management-tools side.
$hvPSEnabled = (Test-FeatureEnabled -FeatureName @('Microsoft-Hyper-V-Management-PowerShell')) -or
               [bool](Get-Module -ListAvailable -Name Hyper-V) -and
               [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)

if (-not $hvEnabled -or -not $hvPSEnabled) {
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

#region Lab subnet conflict check
# Only needed before the VM switch exists — once step-03 is done the vEthernet adapter
# already owns the subnet and there is nothing left to conflict with.
$step03Done = $CheckpointPath -and (Test-Path (Join-Path $CheckpointPath "step-03.done") -ErrorAction SilentlyContinue)
if (-not $step03Done) {
    Write-Log "Checking for subnet conflicts with existing network adapters..." INFO

    $currentBase = ($LabSubnet -split '\.' | Select-Object -First 3) -join '.'

    # Any active adapter (physical, VPN, etc.) that already holds an IP in the target /24
    # would cause routing confusion on the host once the lab vEthernet is added.
    $conflicting = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceAlias -notmatch 'Loopback' -and
            $_.InterfaceAlias -ne "vEthernet ($SwitchName)" -and
            $_.IPAddress      -like "$currentBase.*"
        }

    if ($conflicting) {
        $adapterList = ($conflicting |
            ForEach-Object { "'$($_.InterfaceAlias)' ($($_.IPAddress))" }) -join ', '
        Write-Log "Subnet conflict: $currentBase.0/$LabPrefix overlaps with your existing network on $adapterList." WARN
        Write-Log "Auto-selecting a non-conflicting subnet to protect your network connectivity..." INFO

        # Candidate /24 bases tried in order — first free one wins.
        $candidates = @("192.168.200","192.168.150","192.168.210","10.100.100","10.200.100")
        $newBase = $null
        foreach ($base in $candidates) {
            $taken = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.InterfaceAlias -notmatch 'Loopback' -and
                    $_.InterfaceAlias -ne "vEthernet ($SwitchName)" -and
                    $_.IPAddress      -like "$base.*"
                }
            if (-not $taken) { $newBase = $base; break }
        }

        if (-not $newBase) {
            Write-Log "All candidate subnets conflict with existing adapters." ERROR
            Write-Log "Manually edit the Network region in config.ps1 to a free /24 subnet, then re-run." ERROR
            throw "No available subnet found — edit config.ps1 manually."
        }

        $subnetContent = Get-Content -Path $configPath -Raw -ErrorAction Stop
        $subnetContent = $subnetContent -replace [regex]::Escape($currentBase), $newBase
        Set-Content -Path $configPath -Value $subnetContent -Encoding UTF8 -ErrorAction Stop
        . $configPath

        Write-Log "config.ps1 updated: lab subnet changed from $currentBase.0/24 to $newBase.0/$LabPrefix." SUCCESS
    } else {
        Write-Log "Lab subnet ($LabSubnet/$LabPrefix) is clear — no conflicts detected." SUCCESS
    }
} else {
    Write-Log "VM switch already created (step-03 done) — subnet conflict check skipped." INFO
}
#endregion

#region 4. Password generation — write to config.ps1 if fields are blank
Write-Log "Checking password configuration..." INFO

# Simple, generic lab password used for all accounts when a field is blank.
# Still satisfies Windows/AD/SQL complexity (upper + lower + digit + symbol) so
# DC promotion and SQL install don't fail. This is a throwaway lab — not secret.
$DefaultLabPassword = "SqlLab2025!"

function New-LabPassword {
    return $DefaultLabPassword
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
