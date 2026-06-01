#Requires -Version 5.1
<#
.SYNOPSIS
    Step 05 — Install Windows Server on each VM VHDX using offline DISM image application.
    Applies the WIM image directly from the host — no DVD boot required.

APPROACH:
    For each VM's OSDisk.vhdx (VM must be off):
      1. Mount the VHDX on the host.
      2. Initialize GPT: EFI (100 MB FAT32) + MSR (128 MB) + Windows (rest, NTFS).
      3. Apply the WIM with DISM /Apply-Image (index 2 = Standard Desktop Experience).
      4. Run bcdboot to write UEFI boot files to the EFI partition.
      5. Inject unattend.xml (specialize + oobeSystem) into \Windows\Panther\.
      6. Dismount the VHDX.
    Then remove autounattend helper VHDs, set boot order to HDD, start VMs,
    and wait for PowerShell Direct readiness.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

#region Unattend XML — specialize + oobeSystem only
# windowsPE pass is intentionally omitted — DISM handles disk partitioning and image apply.
function New-UnattendXml {
    param([string]$ComputerName, [string]$Password)
    $passB64 = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Password + "AdministratorPassword"))
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>Eastern Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active>
          <Group>Remote Desktop</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <AutoLogon>
        <Password><Value>$passB64</Value><PlainText>false</PlainText></Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$passB64</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0"</CommandLine>
          <Description>Disable auto-logon after first boot</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
}
#endregion

#region bcdboot helper
# Writes UEFI boot files using the bcdboot.exe from the *applied image* (not the host).
# The host (Win11 26200) is a newer build than the Server 2025 image (26100); the host's
# bcdboot fails to copy the older boot binaries ("Failure when attempting to copy boot
# files", exit 193 / ERROR_BAD_EXE_FORMAT).
function Write-UefiBootFiles {
    param([string]$VMName, [string]$WinDrive, [string]$EfiDrive)

    $imageBcdboot = "${WinDrive}:\Windows\System32\bcdboot.exe"
    if (-not (Test-Path $imageBcdboot)) {
        throw "[$VMName] bcdboot.exe not found in applied image at $imageBcdboot"
    }
    Write-Log "[$VMName] Running bcdboot (from applied image) to write UEFI boot files to ${EfiDrive}:..." INFO
    $bcdOut  = & $imageBcdboot "${WinDrive}:\Windows" /s "${EfiDrive}:" /f UEFI /l en-US 2>&1
    $bcdExit = $LASTEXITCODE
    $bcdOut | ForEach-Object { Write-Log "[$VMName] bcdboot: $_" INFO }
    if ($bcdExit -ne 0) {
        throw "[$VMName] bcdboot failed (exit $bcdExit). Output: $($bcdOut -join '; ')"
    }
    Write-Log "[$VMName] UEFI boot files written." SUCCESS
}
#endregion

#region DISM offline image application
function Install-WindowsToVHDX {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [string]$OSDiskPath,
        [string]$WimPath,
        [int]   $ImageIndex
    )

    if (-not (Test-Path $OSDiskPath)) {
        throw "[$VMName] OSDisk VHDX not found: $OSDiskPath"
    }

    Write-Log "[$VMName] Mounting VHDX: $OSDiskPath" INFO
    Mount-VHD -Path $OSDiskPath -ErrorAction Stop
    try {
        Start-Sleep -Seconds 3
        $vhd     = Get-VHD -Path $OSDiskPath
        $diskNum = $vhd.DiskNumber

        # Check if Windows is already installed (idempotent re-run)
        $existingParts = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue
        $installedPart = $existingParts | Where-Object {
            $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe")
        } | Select-Object -First 1

        if ($installedPart) {
            Write-Log "[$VMName] Windows already present on disk — skipping DISM." SUCCESS
            $winDrive = $installedPart.DriveLetter

            # Locate the EFI System Partition and ensure it has a drive letter.
            $efiPart = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
                       Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
                       Select-Object -First 1
            if (-not $efiPart) {
                throw "[$VMName] Windows partition found but no EFI System Partition on disk $diskNum."
            }
            if (-not $efiPart.DriveLetter) {
                $efiPart | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
                Start-Sleep -Seconds 2
                $efiPart = Get-Partition -DiskNumber $diskNum -PartitionNumber $efiPart.PartitionNumber
            }
            $efiDrive = $efiPart.DriveLetter

            # Repair boot files if a prior run applied the image but failed at bcdboot.
            if (-not (Test-Path "${efiDrive}:\EFI\Microsoft\Boot\bootmgfw.efi")) {
                Write-Log "[$VMName] EFI boot files missing — writing them now." WARN
                Write-UefiBootFiles -VMName $VMName -WinDrive $winDrive -EfiDrive $efiDrive
            }

            $pantherPath = "${winDrive}:\Windows\Panther"
            if (-not (Test-Path "$pantherPath\unattend.xml")) {
                New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
                (New-UnattendXml -ComputerName $ComputerName -Password $AdminPassword) |
                    Set-Content -Path "$pantherPath\unattend.xml" -Encoding UTF8
                Write-Log "[$VMName] Injected missing unattend.xml." INFO
            }
            return
        }

        # Partition the disk (GPT) — skip if already partitioned (e.g. prior failed run)
        $existingGPT = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
                       Where-Object { $_.Type -ne 'Unknown' }

        if ($existingGPT) {
            Write-Log "[$VMName] Disk $diskNum already has partitions — reusing existing layout." WARN
            # Find EFI (FAT32) and Windows (NTFS) partitions by filesystem label or size
            $allParts = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue
            $efiPart  = $allParts | Where-Object { $_.Size -le 200MB -and $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
            $winPart  = $allParts | Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' } | Select-Object -First 1

            if (-not $efiPart -or -not $winPart) {
                # Can't identify expected layout — wipe and repartition
                Write-Log "[$VMName] Cannot identify EFI/Windows partitions — clearing disk and re-partitioning." WARN
                Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
                $efiPart = $null; $winPart = $null
            }
        } else {
            Write-Log "[$VMName] Initializing GPT partitions on disk $diskNum..." INFO
            Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
            $efiPart = $null; $winPart = $null
        }

        if (-not $efiPart) {
            $efiPart = New-Partition -DiskNumber $diskNum `
                -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -Size 100MB
            Format-Volume -Partition $efiPart -FileSystem FAT32 `
                -NewFileSystemLabel "System" -Confirm:$false | Out-Null
        }

        if (-not (Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
                  Where-Object { $_.GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' })) {
            New-Partition -DiskNumber $diskNum `
                -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 128MB | Out-Null
        }

        if (-not $winPart) {
            $winPart = New-Partition -DiskNumber $diskNum -UseMaximumSize
            Format-Volume -Partition $winPart -FileSystem NTFS `
                -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
        }

        # Assign drive letters if not already assigned
        if (-not (Get-Partition -DiskNumber $diskNum -PartitionNumber $efiPart.PartitionNumber).DriveLetter) {
            $efiPart | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        }
        if (-not (Get-Partition -DiskNumber $diskNum -PartitionNumber $winPart.PartitionNumber).DriveLetter) {
            $winPart | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        }
        Start-Sleep -Seconds 3

        $efiDrive = (Get-Partition -DiskNumber $diskNum -PartitionNumber $efiPart.PartitionNumber).DriveLetter
        $winDrive = (Get-Partition -DiskNumber $diskNum -PartitionNumber $winPart.PartitionNumber).DriveLetter

        if (-not $efiDrive -or -not $winDrive) {
            throw "[$VMName] Could not obtain drive letters. EFI='$efiDrive' Win='$winDrive'"
        }
        Write-Log "[$VMName] EFI=${efiDrive}: Windows=${winDrive}:" INFO

        # Apply WIM image
        Write-Log "[$VMName] Applying Windows image (WIM index $ImageIndex) — 5 to 15 minutes..." INFO
        $dismLog = Join-Path $LogPath "dism-${VMName}.log"
        $proc = Start-Process dism.exe -ArgumentList @(
            "/Apply-Image",
            "/ImageFile:$WimPath",
            "/Index:$ImageIndex",
            "/ApplyDir:${winDrive}:\",
            "/LogPath:$dismLog"
        ) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "[$VMName] DISM failed (exit $($proc.ExitCode)). Log: $dismLog"
        }
        Write-Log "[$VMName] DISM image applied successfully." SUCCESS

        # Create UEFI boot configuration.
        Write-UefiBootFiles -VMName $VMName -WinDrive $winDrive -EfiDrive $efiDrive

        # Inject unattend.xml for specialize and OOBE passes
        $pantherPath = "${winDrive}:\Windows\Panther"
        New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
        (New-UnattendXml -ComputerName $ComputerName -Password $AdminPassword) |
            Set-Content -Path "$pantherPath\unattend.xml" -Encoding UTF8
        Write-Log "[$VMName] unattend.xml injected to $pantherPath." SUCCESS

    } finally {
        Dismount-VHD -Path $OSDiskPath -ErrorAction SilentlyContinue
        Write-Log "[$VMName] VHDX dismounted." INFO
    }
}
#endregion

#region Mount ISO and apply Windows to all VMs
$winISOPath = Join-Path $ISOPath $WinServerISOName
Write-Log "Mounting Windows Server ISO: $winISOPath" INFO
$isoImage    = Mount-DiskImage -ImagePath $winISOPath -PassThru -ErrorAction Stop
$isoDriveLet = ($isoImage | Get-Volume).DriveLetter

$wimPath = "${isoDriveLet}:\sources\install.wim"
if (-not (Test-Path $wimPath)) {
    $wimPath = "${isoDriveLet}:\sources\install.esd"
    if (-not (Test-Path $wimPath)) {
        Dismount-DiskImage -ImagePath $winISOPath | Out-Null
        throw "install.wim / install.esd not found on ISO at ${isoDriveLet}:\sources\"
    }
}
Write-Log "WIM source: $wimPath" INFO

$vmConfigs = @(
    @{ VMName = $DCVMName;   ComputerName = $DCComputerName   }
    @{ VMName = $SQL1VMName; ComputerName = $SQL1ComputerName }
    @{ VMName = $SQL2VMName; ComputerName = $SQL2ComputerName }
)

try {
    foreach ($cfg in $vmConfigs) {
        $osDiskPath = Join-Path $VMPath "$($cfg.VMName)\OSDisk.vhdx"
        Install-WindowsToVHDX `
            -VMName       $cfg.VMName `
            -ComputerName $cfg.ComputerName `
            -OSDiskPath   $osDiskPath `
            -WimPath      $wimPath `
            -ImageIndex   2
    }
} finally {
    Write-Log "Dismounting Windows Server ISO..." INFO
    Dismount-DiskImage -ImagePath $winISOPath -ErrorAction SilentlyContinue
}
#endregion

#region Remove autounattend helper VHDs and fix VM boot order
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $floppies = Get-VMHardDiskDrive -VMName $vmName |
                Where-Object { $_.Path -like "*autounattend*" }
    foreach ($f in $floppies) {
        Remove-VMHardDiskDrive -VMName $vmName `
            -ControllerType     $f.ControllerType `
            -ControllerNumber   $f.ControllerNumber `
            -ControllerLocation $f.ControllerLocation -ErrorAction Stop
        Write-Log "[$vmName] Removed autounattend VHD from VM." INFO
    }

    # HDD first — Windows is pre-installed on the OS disk via DISM
    $hardDisk = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
    $network  = Get-VMNetworkAdapter -VMName $vmName
    Set-VMFirmware -VMName $vmName -BootOrder $hardDisk, $network -ErrorAction Stop

    # MicrosoftWindows Secure Boot template is correct for a DISM-installed OS
    Set-VMFirmware -VMName $vmName `
        -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop

    Write-Log "[$vmName] Boot order and Secure Boot configured." INFO
}
#endregion

#region Start VMs and wait for PowerShell Direct
Write-Log "Starting all VMs..." INFO
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    if ((Get-VM -Name $vmName).State -eq 'Off') {
        Start-VM -Name $vmName -ErrorAction Stop
        Write-Log "Started: $vmName" SUCCESS
    }
}

function Wait-VMReady {
    param([string]$VMName, [int]$TimeoutMinutes = 45)
    $cred     = New-Object System.Management.Automation.PSCredential("Administrator",
                    (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "[$VMName] Waiting for specialize/OOBE and PowerShell Direct..." INFO
    while ((Get-Date) -lt $deadline) {
        try {
            $caption = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
                (Get-WmiObject Win32_OperatingSystem).Caption
            } -ErrorAction Stop
            Write-Log "[$VMName] Ready: $caption" SUCCESS
            return
        } catch {
            Start-Sleep -Seconds 15
        }
    }
    throw "[$VMName] Timed out after $TimeoutMinutes minutes waiting for OS readiness."
}

foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    Wait-VMReady -VMName $vmName -TimeoutMinutes 45
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-05.done" SUCCESS
#endregion

Write-Log "Windows Server installed on all VMs via DISM offline application." SUCCESS
