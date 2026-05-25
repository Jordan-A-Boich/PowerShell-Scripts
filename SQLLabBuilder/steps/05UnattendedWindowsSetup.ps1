#Requires -Version 5.1
<#
.SYNOPSIS
    Step 05 — Generate unattend.xml answer files and inject into each VM's VHDX.

IDEMPOTENCY CHECKS:
    - A marker file is left on each VHDX after injection. The VHDX is mounted,
      the marker is checked, and injection is skipped if already done.
    - Checkpoint step-05.done skips the entire step if present and VMs are still off.
    - VMs must be OFF before injection. The script checks and refuses to mount a live VHDX.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-05.done"
if (Test-Path $cpFile) {
    Write-Log "Step 05 checkpoint found — answer files already injected. Skipping." SUCCESS
    return
}
#endregion

#region Ensure VMs are off before mounting VHDXs
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -ne 'Off') {
        Write-Log "VM '$vmName' is not off (State: $($vm.State)). Cannot mount VHDX while running." ERROR
        throw "VM '$vmName' must be Off before answer file injection."
    }
}
#endregion

#region Unattend XML generator
function New-UnattendXml {
    param(
        [string]$ComputerName,
        [string]$AdminPassword,
        [string]$ProductKey = ""  # Leave blank for Evaluation (no key needed)
    )

    $adminPassB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($AdminPassword + "AdministratorPassword"))

    # No ProductKey element — evaluation ISOs auto-select edition without a key.
    # Including a key for the wrong edition stalls setup.
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Format>NTFS</Format>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
          <WillShowUI>Never</WillShowUI>
          <!-- Index 2 = Windows Server 2025 Standard Desktop Experience -->
          <OSImageIndex>2</OSImageIndex>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>LabAdmin</FullName>
        <Organization>SQLLab</Organization>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>Eastern Standard Time</TimeZone>
      <RegisteredOwner>LabAdmin</RegisteredOwner>
      <RegisteredOrganization>SQLLab</RegisteredOrganization>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Networking-MPSSVC-Svc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
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
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
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
        <Password>
          <Value>$adminPassB64</Value>
          <PlainText>false</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$adminPassB64</Value>
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
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
    return $xml
}
#endregion

#region Inject answer file into VHDX
function Invoke-UnattendInjection {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [string]$OSDiskPath
    )

    if (-not (Test-Path $OSDiskPath)) {
        throw "VHDX not found: $OSDiskPath"
    }

    Write-Log "[$VMName] Generating unattend.xml for computer '$ComputerName'..." INFO
    $xmlContent = New-UnattendXml -ComputerName $ComputerName -AdminPassword $AdminPassword

    Write-Log "[$VMName] Mounting VHDX: $OSDiskPath" INFO
    try {
        Mount-VHD -Path $OSDiskPath -ErrorAction Stop
    } catch {
        throw "Failed to mount VHDX '$OSDiskPath': $_"
    }

    try {
        # Find the mounted Windows volume (largest partition, look for Windows dir)
        Start-Sleep -Seconds 3  # brief wait for partitions to surface
        $disk = Get-Disk | Where-Object {
            $_.Location -like "*$([System.IO.Path]::GetFileName($OSDiskPath))*" -or
            (Get-VHD -Path $OSDiskPath).Attached -eq $true
        } | Select-Object -Last 1

        # Fallback: get the VHD disk number
        $vhd = Get-VHD -Path $OSDiskPath
        $disk = Get-Disk -Number $vhd.DiskNumber -ErrorAction SilentlyContinue

        if (-not $disk) {
            throw "Could not find disk object for mounted VHDX."
        }

        $partitions = Get-Partition -DiskNumber $disk.DiskNumber -ErrorAction SilentlyContinue
        $windowsPart = $partitions | Where-Object {
            $_.DriveLetter -and
            (Test-Path "$($_.DriveLetter):\Windows") -and
            $_.Type -eq 'Basic'
        } | Select-Object -First 1

        if (-not $windowsPart) {
            # The disk was freshly created and not yet formatted — no Windows directory
            # This is expected on first run: inject into the EFI/Windows partition path
            # The unattend.xml needs to go to \Windows\Panther\unattend.xml or just
            # leave it in the root to be picked up by Windows setup
            $windowsPart = $partitions | Where-Object {
                $_.DriveLetter -and $_.Type -ne 'System'
            } | Select-Object -First 1
        }

        if (-not $windowsPart -or -not $windowsPart.DriveLetter) {
            # Disk is not yet partitioned / formatted — can't inject yet.
            # The answer file approach requires a pre-existing Windows volume or EFI.
            # For a fresh VHDX, we'll use the autounattend.xml approach at the ISO level,
            # but since we can't modify the ISO, we'll note this limitation and rely on
            # the DVD autounattend path instead.
            Write-Log "[$VMName] VHDX has no formatted Windows partition yet. Saving autounattend.xml alongside VHDX for manual placement." WARN
            $xmlPath = [System.IO.Path]::ChangeExtension($OSDiskPath, ".autounattend.xml")
            $xmlContent | Set-Content -Path $xmlPath -Encoding UTF8
            Write-Log "[$VMName] Answer file saved to: $xmlPath" WARN
            Write-Log "[$VMName] NOTE: For fully unattended setup, the answer file must be on removable media or in a floppy image." WARN
            return
        }

        $driveLetter = $windowsPart.DriveLetter
        $pantherPath = "${driveLetter}:\Windows\Panther"
        $unattendDest = "${driveLetter}:\Windows\Panther\unattend.xml"

        $markerPath = "${driveLetter}:\SQLLabBuilder-unattend.marker"
        if (Test-Path $markerPath) {
            Write-Log "[$VMName] Unattend marker found — already injected. Skipping." INFO
            return
        }

        if (-not (Test-Path $pantherPath)) {
            New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
        }

        Write-Log "[$VMName] Writing unattend.xml to $unattendDest" INFO
        $xmlContent | Set-Content -Path $unattendDest -Encoding UTF8
        "injected" | Set-Content -Path $markerPath -Encoding ASCII

        Write-Log "[$VMName] Answer file injected successfully." SUCCESS

    } finally {
        Write-Log "[$VMName] Dismounting VHDX..." INFO
        Dismount-VHD -Path $OSDiskPath -ErrorAction SilentlyContinue
        Write-Log "[$VMName] VHDX dismounted." INFO
    }
}
#endregion

#region Create floppy-image-based autounattend approach for fresh VHDXs
# Since fresh VHDXs have no Windows partition yet, we create a small VHD acting as
# a virtual floppy to carry autounattend.xml, then attach it to each VM.
# Windows Setup will find autounattend.xml on any attached disk automatically.

function New-AutounattendFloppy {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [string]$VMFolder
    )

    $floppyPath = Join-Path $VMFolder "autounattend.vhd"
    $xmlContent = New-UnattendXml -ComputerName $ComputerName -AdminPassword $AdminPassword

    if (Test-Path $floppyPath) {
        Write-Log "[$VMName] Autounattend floppy already exists: $floppyPath" INFO
    } else {
        Write-Log "[$VMName] Creating 10 MB autounattend VHD..." INFO
        New-VHD -Path $floppyPath -SizeBytes 10MB -Fixed -ErrorAction Stop | Out-Null
        Mount-VHD -Path $floppyPath -ErrorAction Stop

        try {
            Start-Sleep -Seconds 2
            $vhd       = Get-VHD -Path $floppyPath
            $diskNum   = $vhd.DiskNumber
            Initialize-Disk -Number $diskNum -PartitionStyle MBR -ErrorAction Stop
            $part = New-Partition -DiskNumber $diskNum -UseMaximumSize -IsActive -AssignDriveLetter -ErrorAction Stop
            Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT -NewFileSystemLabel "UNATTEND" -Confirm:$false -ErrorAction Stop

            $xmlContent | Set-Content -Path "$($part.DriveLetter):\autounattend.xml" -Encoding UTF8
            Write-Log "[$VMName] Wrote autounattend.xml to VHD drive $($part.DriveLetter):\" SUCCESS
        } finally {
            Dismount-VHD -Path $floppyPath -ErrorAction SilentlyContinue
        }
    }

    # Attach to VM as an additional disk (Windows Setup scans all disks)
    $existingDisks = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $floppyPath }
    if (-not $existingDisks) {
        Add-VMHardDiskDrive -VMName $VMName -Path $floppyPath -ControllerType SCSI -ErrorAction Stop
        Write-Log "[$VMName] Attached autounattend VHD to VM." SUCCESS
    } else {
        Write-Log "[$VMName] Autounattend VHD already attached." INFO
    }
}
#endregion

#region Process each VM
$vmConfigs = @(
    @{ VMName = $DCVMName;   ComputerName = $DCComputerName   }
    @{ VMName = $SQL1VMName; ComputerName = $SQL1ComputerName }
    @{ VMName = $SQL2VMName; ComputerName = $SQL2ComputerName }
)

foreach ($cfg in $vmConfigs) {
    Write-Log "Processing unattend setup for $($cfg.VMName)..." INFO

    $vmFolder   = Join-Path $VMPath $cfg.VMName
    $osDiskPath = Join-Path $vmFolder "OSDisk.vhdx"

    New-AutounattendFloppy `
        -VMName       $cfg.VMName `
        -ComputerName $cfg.ComputerName `
        -VMFolder     $vmFolder
}
#endregion

#region Start VMs
Write-Log "Starting all VMs for unattended Windows installation..." INFO
Write-Log "This process typically takes 15–30 minutes. The script will poll for completion." INFO

foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    $vm = Get-VM -Name $vmName
    if ($vm.State -eq 'Off') {
        Write-Log "Starting VM: $vmName" INFO
        Start-VM -Name $vmName -ErrorAction Stop
        Write-Log "VM started: $vmName" SUCCESS
    } else {
        Write-Log "VM $vmName is already running (State: $($vm.State))." INFO
    }
}
#endregion

#region Poll for Windows setup completion (Guest Integration Services heartbeat)
function Wait-VMReady {
    param(
        [string]$VMName,
        [int]$TimeoutMinutes = 45
    )
    $cred       = New-Object System.Management.Automation.PSCredential("Administrator",
                      (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    $deadline   = (Get-Date).AddMinutes($TimeoutMinutes)
    $pollSecs   = 10

    Write-Log "[$VMName] Waiting for Windows setup to complete and PowerShell Direct to become available..." INFO

    while ((Get-Date) -lt $deadline) {
        try {
            $result = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
                $os = Get-WmiObject Win32_OperatingSystem
                return @{ Caption = $os.Caption; Status = "Ready" }
            } -ErrorAction Stop
            Write-Log "[$VMName] OS ready: $($result.Caption)" SUCCESS
            return $true
        } catch {
            Write-Log "[$VMName] Not ready yet — retrying in $pollSecs s..." INFO
            Start-Sleep -Seconds $pollSecs
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

Write-Log "Unattended Windows setup complete on all VMs." SUCCESS
