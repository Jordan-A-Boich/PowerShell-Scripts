#Requires -Version 5.1
<#
.SYNOPSIS
    Step 04 — Create Hyper-V virtual machines.

IDEMPOTENCY CHECKS:
    - Each VM is created only if it does not already exist by name.
    - VHDX files are created only if they do not exist.
    - ISO attachment is applied only if not already attached.
    - Checkpoint step-04.done skips the step when all three VMs are verified present.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-04.done"
if (Test-Path $cpFile) {
    $allExist = @($DCVMName, $SQL1VMName, $SQL2VMName) | ForEach-Object {
        Get-VM -Name $_ -ErrorAction SilentlyContinue
    }
    if (($allExist | Measure-Object).Count -eq 3) {
        Write-Log "Step 04 checkpoint found — all three VMs exist. Skipping." SUCCESS
        return
    }
    Write-Log "Step 04 checkpoint found but VMs missing — re-running." WARN
}
#endregion

# Shared implementation of New-LabVM (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

#region Create VMs
# DC: 2 vCPU, 512 MB min / 2 GB max, 60 GB OS
New-LabVM `
    -VMName          $DCVMName `
    -ComputerName    $DCComputerName `
    -MemoryMaxBytes  (2GB) `
    -MemoryMinBytes  (512MB) `
    -OSDiskGB        60 `
    -AddDataDisk     $false

# SQL1: 2 vCPU, 1 GB min / 4 GB max, 80 GB OS + 40 GB data
New-LabVM `
    -VMName          $SQL1VMName `
    -ComputerName    $SQL1ComputerName `
    -MemoryMaxBytes  (4GB) `
    -MemoryMinBytes  (1GB) `
    -OSDiskGB        80 `
    -AddDataDisk     $true `
    -DataDiskGB      40

# SQL2: same as SQL1
New-LabVM `
    -VMName          $SQL2VMName `
    -ComputerName    $SQL2ComputerName `
    -MemoryMaxBytes  (4GB) `
    -MemoryMinBytes  (1GB) `
    -OSDiskGB        80 `
    -AddDataDisk     $true `
    -DataDiskGB      40
#endregion

#region Summary
Write-Log "VM inventory:" INFO
Get-VM -Name @($DCVMName, $SQL1VMName, $SQL2VMName) | ForEach-Object {
    Write-Log "  $($_.Name)  State=$($_.State)  vCPU=$($_.ProcessorCount)  MemMax=$([math]::Round($_.MemoryMaximum/1GB,1))GB" INFO
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-04.done" SUCCESS
#endregion

Write-Log "VM creation complete." SUCCESS
