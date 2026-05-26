#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Full lab teardown.
    Removes all VMs, virtual switches, NAT, host file entries, and DNS settings
    created by the build. Does NOT delete the SQLLabBuilder folder or ISOs by default.

.PARAMETER Force
    Skip the confirmation prompt.
#>

[CmdletBinding()]
param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"   # Keep going through teardown even if individual steps fail

$ScriptRoot = $PSScriptRoot

#region Write-Log
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        default   { 'Cyan'   }
    }
    Write-Host $entry -ForegroundColor $color
    if ($TeardownLog) { Add-Content -Path $TeardownLog -Value $entry -Encoding UTF8 }
}
#endregion

#region Dot-source config
$configPath = Join-Path $ScriptRoot "config.ps1"
if (Test-Path $configPath) { . $configPath }
else {
    Write-Warning "config.ps1 not found — using hard-coded defaults for teardown."
    $DCVMName    = "SQLLab-DC"
    $SQL1VMName  = "SQLLab-SQL1"
    $SQL2VMName  = "SQLLab-SQL2"
    $SwitchName  = "SQLLabSwitch"
    $NatName     = "SQLLabNAT"
    $HostIP      = "192.168.100.1"
    $DCStaticIP  = "192.168.100.10"
    $SQL1StaticIP= "192.168.100.11"
    $SQL2StaticIP= "192.168.100.12"
    $ClusterIP   = "192.168.100.20"
    $ListenerIP  = "192.168.100.30"
    $VMPath      = ""
    $LabRoot     = ""
    $LogPath     = ""
}
#endregion

#region Elevation check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Error "Teardown must be run as Administrator. Re-launch PowerShell as Administrator."
    exit 1
}
#endregion

#region Confirmation
if (-not $Force) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║               SQL LAB TEARDOWN WARNING                  ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "This will permanently destroy:" -ForegroundColor Yellow
    Write-Host "  • VMs: SQLLab-DC, SQLLab-SQL1, SQLLab-SQL2" -ForegroundColor Yellow
    Write-Host "  • All VM VHDX files under: $VMPath" -ForegroundColor Yellow
    Write-Host "  • Hyper-V switch: $SwitchName" -ForegroundColor Yellow
    Write-Host "  • NAT: $NatName" -ForegroundColor Yellow
    Write-Host "  • Hosts file entries for the lab" -ForegroundColor Yellow
    Write-Host "  • Lab DNS entry on host vEthernet adapter" -ForegroundColor Yellow
    Write-Host "  • Lab firewall rules" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Type 'YES' to confirm teardown"
    if ($confirm -ne 'YES') {
        Write-Host "Teardown cancelled." -ForegroundColor Green
        exit 0
    }
}
#endregion

#region Log setup
if ($LogPath -and (Test-Path $LogPath)) {
    $TeardownLog = Join-Path $LogPath ("teardown-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
} else {
    $TeardownLog = $null
}

Write-Log "=== TEARDOWN STARTED ===" INFO

#region 1. Stop and remove VMs
Write-Log "Stopping VMs..." INFO
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        try {
            if ($vm.State -ne 'Off') {
                Write-Log "Stopping $vmName..." INFO
                Stop-VM -Name $vmName -Force -TurnOff -ErrorAction Stop
                Write-Log "Stopped $vmName" SUCCESS
            } else {
                Write-Log "$vmName already off" INFO
            }
        } catch { Write-Log "Error stopping ${vmName}: $_" WARN }
    } else {
        Write-Log "VM $vmName not found — skipping" WARN
    }
}

Write-Log "Removing VMs..." INFO
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        try {
            Remove-VM -Name $vmName -Force -ErrorAction Stop
            Write-Log "Removed VM: $vmName" SUCCESS
        } catch { Write-Log "Error removing ${vmName}: $_" WARN }
    }
}
#endregion

#region 2. Delete VHDX files / VM folders
if ($VMPath -and (Test-Path $VMPath)) {
    Write-Log "Deleting VM files under: $VMPath" INFO
    try {
        Remove-Item -Path $VMPath -Recurse -Force -ErrorAction Stop
        Write-Log "Deleted VM path: $VMPath" SUCCESS
    } catch { Write-Log "Error deleting VM path: $_" WARN }
} else {
    Write-Log "VMPath not set or does not exist — skipping disk cleanup" WARN
}
#endregion

#region 3. Remove VM switch
Write-Log "Removing VM switch: $SwitchName" INFO
$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($sw) {
    try {
        Remove-VMSwitch -Name $SwitchName -Force -ErrorAction Stop
        Write-Log "Removed VM switch: $SwitchName" SUCCESS
    } catch { Write-Log "Error removing switch: $_" WARN }
} else {
    Write-Log "Switch $SwitchName not found — skipping" WARN
}
#endregion

#region 4. Remove NAT
Write-Log "Removing NAT: $NatName" INFO
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($nat) {
    try {
        Remove-NetNat -Name $NatName -Confirm:$false -ErrorAction Stop
        Write-Log "Removed NAT: $NatName" SUCCESS
    } catch { Write-Log "Error removing NAT: $_" WARN }
} else {
    Write-Log "NAT $NatName not found — skipping" WARN
}
#endregion

#region 5. Remove host vEthernet IP for 192.168.100.1
Write-Log "Removing host vEthernet IP assignment for $HostIP..." INFO
try {
    $adapterAlias = "vEthernet ($SwitchName)"
    $existingIP = Get-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $HostIP -ErrorAction SilentlyContinue
    if ($existingIP) {
        Remove-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $HostIP -Confirm:$false -ErrorAction Stop
        Write-Log "Removed IP $HostIP from $adapterAlias" SUCCESS
    } else {
        Write-Log "IP $HostIP not found on $adapterAlias — skipping" WARN
    }
} catch { Write-Log "Error removing host vEthernet IP: $_" WARN }
#endregion

#region 6. Remove host DNS entry pointing to lab DC
Write-Log "Removing lab DNS entry from host vEthernet adapter..." INFO
try {
    $adapterAlias = "vEthernet ($SwitchName)"
    $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
    if ($adapter) {
        $dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4).ServerAddresses
        if ($dnsServers -contains $DCStaticIP) {
            $newDns = $dnsServers | Where-Object { $_ -ne $DCStaticIP }
            Set-DnsClientServerAddress -InterfaceAlias $adapterAlias -ServerAddresses $newDns -ErrorAction Stop
            Write-Log "Removed $DCStaticIP from DNS on $adapterAlias" SUCCESS
        } else {
            Write-Log "Lab DNS $DCStaticIP not found on $adapterAlias — skipping" WARN
        }
    }
} catch { Write-Log "Error removing lab DNS from host adapter: $_" WARN }
#endregion

#region 7. Remove hosts file entries
Write-Log "Removing lab entries from hosts file..." INFO
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$labMarkerStart = "# SQLLabBuilder-BEGIN"
$labMarkerEnd   = "# SQLLabBuilder-END"
try {
    $content = Get-Content -Path $hostsPath -Raw -ErrorAction Stop
    if ($content -match [regex]::Escape($labMarkerStart)) {
        $pattern = "(?s)$([regex]::Escape($labMarkerStart)).*?$([regex]::Escape($labMarkerEnd))\r?\n?"
        $newContent = $content -replace $pattern, ""
        Set-Content -Path $hostsPath -Value $newContent -Encoding ASCII -ErrorAction Stop
        Write-Log "Removed lab entries from hosts file" SUCCESS
    } else {
        Write-Log "No lab hosts entries found — skipping" WARN
    }
} catch { Write-Log "Error modifying hosts file: $_" WARN }
#endregion

#region 8. Remove lab firewall rules
Write-Log "Removing lab firewall rules..." INFO
@("SQLLab-SSMS-Host-Access","SQLLab-SQL1433-Outbound") | ForEach-Object {
    $rule = Get-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue
    if ($rule) {
        try {
            Remove-NetFirewallRule -DisplayName $_ -ErrorAction Stop
            Write-Log "Removed firewall rule: $_" SUCCESS
        } catch { Write-Log "Error removing firewall rule $($_): $($Error[0])" WARN }
    } else {
        Write-Log "Firewall rule '$_' not found — skipping" WARN
    }
}
#endregion

#region 9. Optional: Delete ISOs
Write-Host ""
$deleteISOs = Read-Host "Do you also want to delete the downloaded ISOs? (Y/N)"
if ($deleteISOs -eq 'Y' -or $deleteISOs -eq 'y') {
    if ($ISOPath -and (Test-Path $ISOPath)) {
        try {
            Remove-Item -Path $ISOPath -Recurse -Force -ErrorAction Stop
            Write-Log "Deleted ISO path: $ISOPath" SUCCESS
        } catch { Write-Log "Error deleting ISO path: $_" WARN }
    } else {
        Write-Log "ISOPath not set or not found — skipping ISO deletion" WARN
    }
} else {
    Write-Log "ISOs preserved at: $ISOPath" INFO
}
#endregion

Write-Host ""
Write-Log "=== TEARDOWN COMPLETE ===" SUCCESS
Write-Host ""
Write-Host "The following were NOT deleted:" -ForegroundColor Yellow
Write-Host "  • $ScriptRoot\SQLLabBuilder folder and step scripts" -ForegroundColor Yellow
if ($deleteISOs -notin @('Y','y')) {
    Write-Host "  • Downloaded ISOs (preserved for future runs)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "To rebuild the lab, run: .\Start-LabBuild.ps1" -ForegroundColor Cyan
Write-Host ""
