#Requires -Version 5.1
<#
.SYNOPSIS
    Step 03 — Create Hyper-V internal switch and NAT network.

IDEMPOTENCY CHECKS:
    - VM switch: created only if a switch named $SwitchName does not exist.
    - NAT:       created only if a NAT named $NatName does not exist.
    - Host IP:   assigned only if 192.168.100.1 is not already on the vEthernet adapter.
    - Checkpoint step-03.done skips the entire step if present and configuration verifies.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-03.done"
if (Test-Path $cpFile) {
    $switchOK = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    $natOK    = Get-NetNat   -Name $NatName    -ErrorAction SilentlyContinue
    $ipOK     = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -IPAddress $HostIP -ErrorAction SilentlyContinue
    if ($switchOK -and $natOK -and $ipOK) {
        Write-Log "Step 03 checkpoint found — switch, NAT, and host IP all verified. Skipping." SUCCESS
        return
    }
    Write-Log "Step 03 checkpoint found but configuration incomplete — re-running." WARN
}
#endregion

#region VM Switch
$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Log "VM switch '$SwitchName' already exists (type: $($existingSwitch.SwitchType))." INFO
    if ($existingSwitch.SwitchType -ne 'Internal') {
        Write-Log "WARNING: Existing switch is not Internal. This may cause issues. Expected Internal switch." WARN
    }
} else {
    Write-Log "Creating Internal VM switch: $SwitchName" INFO
    try {
        New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
        Write-Log "Created VM switch: $SwitchName" SUCCESS
    } catch {
        Write-Log "Failed to create VM switch: $_" ERROR
        throw
    }
}
#endregion

#region Host vEthernet IP
$adapterAlias = "vEthernet ($SwitchName)"

# Wait for the adapter to appear (can take a moment after switch creation)
$timeout = 30
$elapsed = 0
while (-not (Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue) -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 2
    $elapsed += 2
}

if (-not (Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue)) {
    throw "vEthernet adapter '$adapterAlias' did not appear within $timeout seconds."
}

$existingIP = Get-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $HostIP -ErrorAction SilentlyContinue
if ($existingIP) {
    Write-Log "Host IP $HostIP already assigned to $adapterAlias." INFO
} else {
    Write-Log "Assigning static IP $HostIP/$LabPrefix to $adapterAlias..." INFO
    try {
        New-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $HostIP -PrefixLength $LabPrefix -ErrorAction Stop | Out-Null
        Write-Log "Assigned $HostIP/$LabPrefix to $adapterAlias." SUCCESS
    } catch {
        Write-Log "Failed to assign host IP: $_" ERROR
        throw
    }
}
#endregion

#region NAT
$existingNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($existingNat) {
    Write-Log "NAT '$NatName' already exists (prefix: $($existingNat.InternalIPInterfaceAddressPrefix))." INFO
} else {
    Write-Log "Creating NAT '$NatName' on $LabSubnet/$LabPrefix..." INFO
    try {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix "$LabSubnet/$LabPrefix" -ErrorAction Stop | Out-Null
        Write-Log "Created NAT: $NatName ($LabSubnet/$LabPrefix)" SUCCESS
    } catch {
        # Check if a conflicting NAT exists on the same prefix
        $conflict = Get-NetNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq "$LabSubnet/$LabPrefix" }
        if ($conflict) {
            Write-Log "A conflicting NAT already exists on $LabSubnet/${LabPrefix}: $($conflict.Name)." WARN
            Write-Log "The lab subnet is already NATted — continuing." WARN
        } else {
            Write-Log "Failed to create NAT: $_" ERROR
            throw
        }
    }
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-03.done" SUCCESS
#endregion

Write-Log "VM switch and NAT configuration complete." SUCCESS
