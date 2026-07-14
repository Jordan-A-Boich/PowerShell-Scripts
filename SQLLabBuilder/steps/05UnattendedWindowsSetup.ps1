#Requires -Version 5.1
<#
.SYNOPSIS
    Step 05 — Install Windows Server on each VM VHDX using offline DISM image application.
    Applies the WIM image directly from the host — no DVD boot required.

APPROACH:
    The heavy lifting (mount VHDX, GPT partition, DISM /Apply-Image, bcdboot, inject
    unattend.xml, dismount, fix boot order, start, wait for PowerShell Direct) lives in
    Install-LabWindows / Install-WindowsToVHDX in steps\_shared\LabFunctions.ps1, so the
    primary build and AddCluster.ps1 apply Windows the exact same way.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared Windows-apply implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-05.done"
if (Test-Path $cpFile) {
    Write-Log "Step 05 checkpoint found — Windows already installed. Skipping." SUCCESS
    return
}
#endregion

#region Ensure VMs are off before mounting VHDXs
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -ne 'Off') {
        Write-Log "Stopping $vmName before VHDX operations..." INFO
        Stop-VM -Name $vmName -TurnOff -Force -ErrorAction Stop
    }
}
#endregion

#region Apply Windows to all VMs, fix boot order, start and wait
Install-LabWindows -NodeSpecs @(
    @{ VMName = $DCVMName;   ComputerName = $DCComputerName   }
    @{ VMName = $SQL1VMName; ComputerName = $SQL1ComputerName }
    @{ VMName = $SQL2VMName; ComputerName = $SQL2ComputerName }
) -ImageIndex 2
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-05.done" SUCCESS
#endregion

Write-Log "Windows Server installed on all VMs via DISM offline application." SUCCESS
