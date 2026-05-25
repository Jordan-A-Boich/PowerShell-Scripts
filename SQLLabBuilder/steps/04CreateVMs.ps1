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

#region VM creation helper
function New-LabVM {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [long]$MemoryMaxBytes,
        [long]$MemoryMinBytes,
        [long]$OSDiskGB,
        [bool]$AddDataDisk = $false,
        [long]$DataDiskGB  = 0
    )

    $vmFolder = Join-Path $VMPath $VMName
    if (-not (Test-Path $vmFolder)) { New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null }

    $osDiskPath   = Join-Path $vmFolder "OSDisk.vhdx"
    $dataDiskPath = Join-Path $vmFolder "SQLData.vhdx"

    #region Create VHDX(s)
    if (-not (Test-Path $osDiskPath)) {
        Write-Log "Creating OS VHDX: $osDiskPath ($OSDiskGB GB)..." INFO
        New-VHD -Path $osDiskPath -SizeBytes ($OSDiskGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
        Write-Log "Created OS VHDX." SUCCESS
    } else {
        Write-Log "OS VHDX already exists: $osDiskPath" INFO
    }

    if ($AddDataDisk -and -not (Test-Path $dataDiskPath)) {
        Write-Log "Creating data VHDX: $dataDiskPath ($DataDiskGB GB)..." INFO
        New-VHD -Path $dataDiskPath -SizeBytes ($DataDiskGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
        Write-Log "Created data VHDX." SUCCESS
    }
    #endregion

    #region Create VM
    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) {
        Write-Log "VM '$VMName' already exists — skipping creation." INFO
        return $existingVM
    }

    Write-Log "Creating VM: $VMName" INFO
    try {
        $vm = New-VM `
            -Name            $VMName `
            -Generation      2 `
            -MemoryStartupBytes $MemoryMinBytes `
            -VHDPath         $osDiskPath `
            -SwitchName      $SwitchName `
            -Path            $VMPath `
            -ErrorAction     Stop

        # Dynamic memory
        Set-VMMemory -VMName $VMName `
            -DynamicMemoryEnabled $true `
            -MinimumBytes         $MemoryMinBytes `
            -StartupBytes         $MemoryMinBytes `
            -MaximumBytes         $MemoryMaxBytes `
            -ErrorAction Stop

        # vCPUs
        Set-VMProcessor -VMName $VMName -Count 2 -ErrorAction Stop

        # MicrosoftWindows template — correct for DISM-applied Windows installations
        Set-VMFirmware -VMName $VMName `
            -EnableSecureBoot On `
            -SecureBootTemplate MicrosoftWindows `
            -ErrorAction Stop

        # Boot order: OS disk first — Windows is applied offline by step 05 (DISM)
        $hardDisk    = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
        $networkBoot = Get-VMNetworkAdapter -VMName $VMName
        Set-VMFirmware -VMName $VMName -BootOrder $hardDisk, $networkBoot -ErrorAction Stop

        # Attach data disk for SQL VMs
        if ($AddDataDisk) {
            Add-VMHardDiskDrive -VMName $VMName -Path $dataDiskPath -ErrorAction Stop
            Write-Log "Attached data VHDX to $VMName." INFO
        }

        Write-Log "VM '$VMName' created successfully." SUCCESS
        return $vm
    } catch {
        Write-Log "Failed to create VM '$VMName': $_" ERROR
        throw
    }
    #endregion
}
#endregion

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
