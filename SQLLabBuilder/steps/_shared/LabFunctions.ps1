#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Shared lab functions.

    Single source of truth for the reusable per-node and per-cluster build logic.
    Both the primary build (steps 04-13) and the add-cluster build (AddCluster.ps1)
    dot-source this file and call the same functions, so there is one implementation
    of every complex operation (Windows apply, SQL install, HADR enable, AG create).

SCOPE MODEL:
    Functions take node/cluster identity (VM names, computer names, IPs, cluster/AG
    names) as PARAMETERS. Lab-wide values that are identical for every cluster
    (paths, switch name, ISO names, domain, sqlsvc account, admin password) are read
    ambiently from the dot-sourced config.ps1 scope — exactly as the original steps did.

    This file defines functions only. It performs no actions when dot-sourced.
    It expects Write-Log (defined in StartLabBuild.ps1 / AddCluster.ps1) to be in scope.
#>

Set-StrictMode -Version Latest

#region ── VM creation ───────────────────────────────────────────────────────
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

#region ── Windows offline install (DISM) ────────────────────────────────────
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
            $allParts = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue
            $efiPart  = $allParts | Where-Object { $_.Size -le 200MB -and $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
            $winPart  = $allParts | Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' } | Select-Object -First 1

            if (-not $efiPart -or -not $winPart) {
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

# Applies Windows to every node in $NodeSpecs (array of @{ VMName; ComputerName }),
# then removes autounattend helper VHDs, fixes boot order, starts the VMs and waits
# for PowerShell Direct. Mirrors the orchestration in step 05.
function Install-LabWindows {
    param(
        [object[]]$NodeSpecs,
        [int]$ImageIndex = 2
    )

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

    try {
        foreach ($cfg in $NodeSpecs) {
            $osDiskPath = Join-Path $VMPath "$($cfg.VMName)\OSDisk.vhdx"
            Install-WindowsToVHDX `
                -VMName       $cfg.VMName `
                -ComputerName $cfg.ComputerName `
                -OSDiskPath   $osDiskPath `
                -WimPath      $wimPath `
                -ImageIndex   $ImageIndex
        }
    } finally {
        Write-Log "Dismounting Windows Server ISO..." INFO
        Dismount-DiskImage -ImagePath $winISOPath -ErrorAction SilentlyContinue
    }

    #region Remove autounattend helper VHDs and fix VM boot order
    foreach ($cfg in $NodeSpecs) {
        $vmName   = $cfg.VMName
        $floppies = Get-VMHardDiskDrive -VMName $vmName |
                    Where-Object { $_.Path -like "*autounattend*" }
        foreach ($f in $floppies) {
            Remove-VMHardDiskDrive -VMName $vmName `
                -ControllerType     $f.ControllerType `
                -ControllerNumber   $f.ControllerNumber `
                -ControllerLocation $f.ControllerLocation -ErrorAction Stop
            Write-Log "[$vmName] Removed autounattend VHD from VM." INFO
        }

        $hardDisk = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
        $network  = Get-VMNetworkAdapter -VMName $vmName
        Set-VMFirmware -VMName $vmName -BootOrder $hardDisk, $network -ErrorAction Stop
        Set-VMFirmware -VMName $vmName `
            -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        Write-Log "[$vmName] Boot order and Secure Boot configured." INFO
    }
    #endregion

    #region Start VMs and wait for PowerShell Direct
    Write-Log "Starting nodes..." INFO
    foreach ($cfg in $NodeSpecs) {
        if ((Get-VM -Name $cfg.VMName).State -eq 'Off') {
            Start-VM -Name $cfg.VMName -ErrorAction Stop
            Write-Log "Started: $($cfg.VMName)" SUCCESS
        }
    }
    foreach ($cfg in $NodeSpecs) {
        Wait-VMReady -VMName $cfg.VMName -TimeoutMinutes 45
    }
    #endregion
}
#endregion

#region ── Guest networking ──────────────────────────────────────────────────
function Set-VMStaticIP {
    param(
        [string]$VMName,
        [string]$StaticIP,
        [string]$PrefixLen,
        [string]$GW,
        [string]$DNSPrimary,
        [string]$DNSSecondary = $null,
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-Log "[$VMName] Configuring static IP: $StaticIP/$PrefixLen GW=$GW DNS=$DNSPrimary" INFO

    $dnsArray = if ($DNSSecondary) { @($DNSPrimary, $DNSSecondary) } else { @($DNSPrimary) }

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($IP, $Prefix, $GW, $DNS, $VMN)

        $adapter = Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch 'Loopback'
        } | Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1

        if (-not $adapter) { throw "No active adapter found in $VMN." }

        $alias = $adapter.InterfaceAlias

        Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Remove-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceAlias $alias -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $GW -ErrorAction Stop | Out-Null

        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $DNS -ErrorAction Stop

        Disable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

        Write-Output "Configured: $IP/$Prefix GW=$GW DNS=$($DNS -join ',')"

    } -ArgumentList $StaticIP, $PrefixLen, $GW, $dnsArray, $VMName -ErrorAction Stop

    Write-Log "[$VMName] Static IP configured: $StaticIP" SUCCESS
}

function Wait-VMNetworkReady {
    param(
        [string]$VMName,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Management.Automation.PSCredential]$FallbackCredential = $null,
        [int]$TimeoutMinutes = 10
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pollSecs = 10
    while ((Get-Date) -lt $deadline) {
        foreach ($cred in @($Credential, $FallbackCredential) | Where-Object { $_ }) {
            try {
                Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null
                return
            } catch { }
        }
        Write-Log "[$VMName] Waiting for PowerShell Direct connectivity..." INFO
        Start-Sleep -Seconds $pollSecs
    }
    throw "[$VMName] PowerShell Direct not available after $TimeoutMinutes minutes."
}

# Adds an IP to the host vEthernet adapter's DNS list without replacing existing servers.
function Add-HostVEthernetDns {
    param([string]$DnsIP)
    $adapterAlias = "vEthernet ($SwitchName)"
    try {
        $existing = (Get-DnsClientServerAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($existing -notcontains $DnsIP) {
            $newList = @($DnsIP) + ($existing | Where-Object { $_ -ne $DnsIP })
            Set-DnsClientServerAddress -InterfaceAlias $adapterAlias -ServerAddresses $newList -ErrorAction Stop
            Write-Log "Added $DnsIP as first DNS on $adapterAlias." SUCCESS
        } else {
            Write-Log "$DnsIP already in DNS list for $adapterAlias." INFO
        }
    } catch {
        Write-Log "Could not update host vEthernet DNS: $_ (non-fatal)" WARN
    }
}

# Configures static IPs on every node in $NodeSpecs (array of
# @{ VMName; IP; DNSPrimary }), points the host vEthernet DNS at $HostDnsIP,
# then reboots the nodes and waits for them to return. Mirrors step 06.
function Set-LabNodesNetworking {
    param(
        [object[]]$NodeSpecs,
        [string]$HostDnsIP,
        [System.Management.Automation.PSCredential]$AdminCred,
        [System.Management.Automation.PSCredential]$DomainAdminCred
    )

    foreach ($spec in $NodeSpecs) {
        Wait-VMNetworkReady -VMName $spec.VMName -Credential $AdminCred -FallbackCredential $DomainAdminCred
    }

    foreach ($spec in $NodeSpecs) {
        Set-VMStaticIP -VMName $spec.VMName -StaticIP $spec.IP -PrefixLen $LabPrefix `
            -GW $Gateway -DNSPrimary $spec.DNSPrimary -Credential $AdminCred
    }

    Write-Log "Ensuring lab DC ($HostDnsIP) is in host vEthernet DNS..." INFO
    Add-HostVEthernetDns -DnsIP $HostDnsIP

    Write-Log "Rebooting nodes to apply network configuration..." INFO
    foreach ($spec in $NodeSpecs) {
        try {
            Invoke-Command -VMName $spec.VMName -Credential $AdminCred -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop
            Write-Log "[$($spec.VMName)] Reboot initiated." INFO
        } catch {
            Write-Log "[$($spec.VMName)] Could not send reboot command (may have already rebooted): $_" WARN
        }
    }

    Start-Sleep -Seconds 15

    foreach ($spec in $NodeSpecs) {
        Wait-VMNetworkReady -VMName $spec.VMName -Credential $AdminCred -FallbackCredential $DomainAdminCred -TimeoutMinutes 10
        Write-Log "[$($spec.VMName)] Back online after network reboot." SUCCESS
    }
}
#endregion

#region ── Domain join ───────────────────────────────────────────────────────
# Joins every node in $NodeSpecs (array of @{ VMName }) to the lab domain, then
# waits for each to confirm membership. Mirrors step 08.
function Join-LabNodesToDomain {
    param(
        [object[]]$NodeSpecs,
        [System.Management.Automation.PSCredential]$LocalAdminCred,
        [System.Management.Automation.PSCredential]$DomainAdminCred
    )

    foreach ($spec in $NodeSpecs) {
        $vmName = $spec.VMName
        Write-Log "[$vmName] Checking current domain membership..." INFO
        Wait-VMNetworkReady -VMName $vmName -Credential $LocalAdminCred -FallbackCredential $DomainAdminCred -TimeoutMinutes 10

        $currentDomain = Invoke-Command -VMName $vmName -Credential $LocalAdminCred -ScriptBlock {
            (Get-WmiObject Win32_ComputerSystem).Domain
        } -ErrorAction Stop

        if ($currentDomain -eq $DomainName) {
            Write-Log "[$vmName] Already joined to '$DomainName' — skipping." INFO
            continue
        }

        Write-Log "[$vmName] Current domain: '$currentDomain'. Joining '$DomainName'..." INFO
        try {
            Invoke-Command -VMName $vmName -Credential $LocalAdminCred -ScriptBlock {
                param($Domain, $User, $Pass)
                $cred = New-Object System.Management.Automation.PSCredential($User,
                            (ConvertTo-SecureString $Pass -AsPlainText -Force))
                Add-Computer -DomainName $Domain -Credential $cred -Restart -Force -ErrorAction Stop
            } -ArgumentList $DomainName, "$NetBIOSName\Administrator", $AdminPassword -ErrorAction Stop
            Write-Log "[$vmName] Domain join command sent. VM rebooting..." INFO
        } catch {
            Write-Log "[$vmName] Domain join failed: $_" ERROR
            throw
        }
    }

    Write-Log "Waiting for nodes to reboot and confirm domain membership..." INFO
    Start-Sleep -Seconds 30

    foreach ($spec in $NodeSpecs) {
        $vmName    = $spec.VMName
        $deadline  = (Get-Date).AddMinutes(15)
        $confirmed = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $dom = Invoke-Command -VMName $vmName -Credential $DomainAdminCred -ScriptBlock {
                    (Get-WmiObject Win32_ComputerSystem).Domain
                } -ErrorAction Stop
                if ($dom -eq $DomainName) {
                    Write-Log "[$vmName] Domain membership confirmed: $dom" SUCCESS
                    $confirmed = $true
                    break
                }
            } catch {
                Write-Log "[$vmName] Not ready yet — retrying in 15 s..." INFO
            }
            Start-Sleep -Seconds 15
        }
        if (-not $confirmed) {
            throw "[$vmName] Could not confirm domain membership after 15 minutes."
        }
    }
}
#endregion

#region ── Failover cluster ──────────────────────────────────────────────────
# Creates a Windows Failover Cluster from the two named nodes with a file share
# witness on the DC. Every cluster gets its own name, IP and witness share, so
# multiple independent WSFCs can coexist on the same domain. Mirrors step 09.
function New-LabWSFC {
    param(
        [string]$ClusterName,
        [string]$ClusterIP,
        [string]$Node1VMName,
        [string]$Node1Computer,
        [string]$Node2VMName,
        [string]$Node2Computer,
        [string]$WitnessShare,
        [string]$DCVMName,
        [string]$DCComputer,
        [System.Management.Automation.PSCredential]$DomainAdminCred
    )

    #region Install Failover Clustering features on both nodes
    foreach ($vmName in @($Node1VMName, $Node2VMName)) {
        Write-Log "[$vmName] Installing Failover-Clustering and RSAT-Clustering features..." INFO
        Invoke-Command -VMName $vmName -Credential $DomainAdminCred -ScriptBlock {
            $features = @('Failover-Clustering','RSAT-Clustering','RSAT-Clustering-PowerShell','RSAT-Clustering-Mgmt')
            $result   = Get-WindowsFeature $features
            $toInstall= $result | Where-Object { -not $_.Installed }
            if ($toInstall) {
                Install-WindowsFeature $toInstall.Name -IncludeManagementTools -ErrorAction Stop | Out-Null
                Write-Output "Installed: $($toInstall.Name -join ', ')"
            } else {
                Write-Output "All clustering features already installed."
            }
        } -ErrorAction Stop | ForEach-Object { Write-Log "[$vmName] $_" INFO }
    }
    #endregion

    #region Create witness share on DC
    Write-Log "[$DCVMName] Creating '$WitnessShare' file share..." INFO
    Invoke-Command -VMName $DCVMName -Credential $DomainAdminCred -ScriptBlock {
        param($WitnessShare)
        $sharePath = "C:\$WitnessShare"
        if (-not (Test-Path $sharePath)) {
            New-Item -ItemType Directory -Path $sharePath -Force | Out-Null
        }
        $share = Get-SmbShare -Name $WitnessShare -ErrorAction SilentlyContinue
        if (-not $share) {
            New-SmbShare -Name $WitnessShare -Path $sharePath -FullAccess "Everyone" -ErrorAction Stop | Out-Null
            Write-Output "Created share: \\$env:COMPUTERNAME\$WitnessShare"
        } else {
            Write-Output "Share already exists: \\$env:COMPUTERNAME\$WitnessShare"
        }
    } -ArgumentList $WitnessShare -ErrorAction Stop |
        ForEach-Object { Write-Log "[$DCVMName] $_" INFO }
    #endregion

    #region Run Test-Cluster (warnings expected for a 2-node lab)
    Write-Log "[$Node1VMName] Running Test-Cluster (warnings about storage/network are expected for a 2-node lab)..." INFO
    try {
        Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
            param($Node1, $Node2)
            Import-Module FailoverClusters -ErrorAction Stop
            Test-Cluster -Node $Node1,$Node2 `
                -Include "Inventory","Network","System Configuration" `
                -ReportName "ClusterValidation" `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Output "Test-Cluster completed. Check report for details."
        } -ArgumentList $Node1Computer, $Node2Computer -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "[$Node1VMName] Test-Cluster: $_" INFO }
    } catch {
        Write-Log "[$Node1VMName] Test-Cluster reported errors (may be expected for 2-node lab): $_" WARN
    }
    Write-Log "NOTE: Test-Cluster warnings about shared storage and single-network are expected and safe to ignore in this lab." WARN
    #endregion

    #region Create cluster
    Write-Log "[$Node1VMName] Waiting 30 s before creating cluster (network topology settle time)..." INFO
    Start-Sleep -Seconds 30

    Write-Log "[$Node1VMName] Creating cluster '$ClusterName'..." INFO
    Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
        param($CName, $Node1, $Node2, $CIP)
        Import-Module FailoverClusters -ErrorAction Stop

        $existing = Get-Cluster -Name $CName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Output "Cluster '$CName' already exists - skipping New-Cluster."
            return
        }

        $attempt  = 0
        $maxTries = 3
        $created  = $false
        while (-not $created -and $attempt -lt $maxTries) {
            $attempt++
            try {
                New-Cluster -Name $CName -Node $Node1,$Node2 -StaticAddress $CIP -NoStorage -ErrorAction Stop | Out-Null
                Write-Output "Cluster '$CName' created with IP $CIP."
                $created = $true
            } catch {
                $msg = $_.Exception.Message -replace '\r?\n.*',''
                if ($attempt -lt $maxTries) {
                    Write-Output "New-Cluster attempt $attempt failed: $msg - retrying in 30 s..."
                    Start-Sleep -Seconds 30
                } else {
                    throw
                }
            }
        }
    } -ArgumentList $ClusterName, $Node1Computer, $Node2Computer, $ClusterIP -ErrorAction Stop |
        ForEach-Object { Write-Log "[$Node1VMName] $_" INFO }
    #endregion

    #region Grant cluster computer account NTFS ACL on witness share
    Write-Log "[$DCVMName] Granting cluster account NTFS ACL on witness share..." INFO
    Start-Sleep -Seconds 20   # Allow cluster computer account to replicate in AD
    Invoke-Command -VMName $DCVMName -Credential $DomainAdminCred -ScriptBlock {
        param($DomainNetBIOS, $ClusterName, $WitnessShare)
        $sharePath      = "C:\$WitnessShare"
        $clusterAccount = "$DomainNetBIOS\$ClusterName`$"
        $acl = Get-Acl $sharePath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $clusterAccount, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -Path $sharePath -AclObject $acl -ErrorAction Stop
        Write-Output "ACL granted to $clusterAccount"
    } -ArgumentList $NetBIOSName, $ClusterName, $WitnessShare -ErrorAction Stop |
        ForEach-Object { Write-Log "[$DCVMName] $_" INFO }
    #endregion

    #region Configure File Share Witness
    Write-Log "[$Node1VMName] Configuring cluster quorum (File Share Witness)..." INFO
    Start-Sleep -Seconds 10
    Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
        param($CName, $DCName, $WShare)
        Import-Module FailoverClusters -ErrorAction Stop
        $witnesPath = "\\$DCName\$WShare"
        Set-ClusterQuorum -Cluster $CName -FileShareWitness $witnesPath -ErrorAction Stop | Out-Null
        Write-Output "Quorum set to File Share Witness: $witnesPath"
    } -ArgumentList $ClusterName, $DCComputer, $WitnessShare -ErrorAction Stop |
        ForEach-Object { Write-Log "[$Node1VMName] $_" INFO }
    #endregion

    #region Verify cluster
    Write-Log "[$Node1VMName] Verifying cluster state..." INFO
    Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
        param($CName)
        Import-Module FailoverClusters -ErrorAction Stop
        $nodes = Get-ClusterNode -Cluster $CName
        foreach ($n in $nodes) {
            Write-Output "  Node: $($n.Name)  State: $($n.State)"
        }
        $quorum = Get-ClusterQuorum -Cluster $CName
        Write-Output "  Quorum: $($quorum.QuorumType) — $($quorum.QuorumResource)"
    } -ArgumentList $ClusterName -ErrorAction Stop |
        ForEach-Object { Write-Log "[$Node1VMName] $_" INFO }
    #endregion

    Write-Log "Failover Cluster '$ClusterName' created and configured." SUCCESS
}
#endregion

#region ── SQL service account / logon-as-service ────────────────────────────
function Grant-LogonAsService {
    param(
        [string]$VMName,
        [System.Management.Automation.PSCredential]$Credential
    )

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($SvcAccount)

        $infPath = "$env:TEMP\sqlsvc-loas.inf"
        $dbPath  = "$env:TEMP\sqlsvc-loas.sdb"
        $logPath = "$env:TEMP\sqlsvc-loas.log"

        secedit /export /cfg $infPath /quiet

        $current = Get-Content $infPath -Raw
        if ($current -match "SeServiceLogonRight\s*=\s*(.+)") {
            $currentRights = $Matches[1].Trim()
            if ($currentRights -notlike "*$SvcAccount*") {
                $newRights = "$currentRights,$SvcAccount"
                $current   = $current -replace "SeServiceLogonRight\s*=\s*.+", "SeServiceLogonRight = $newRights"
            } else {
                Write-Output "SeServiceLogonRight already granted to $SvcAccount"
                return
            }
        } else {
            $current += "`r`n[Privilege Rights]`r`nSeServiceLogonRight = $SvcAccount"
        }

        $current | Set-Content -Path $infPath -Encoding Unicode
        secedit /configure /db $dbPath /cfg $infPath /log $logPath /quiet
        Remove-Item $infPath, $dbPath, $logPath -Force -ErrorAction SilentlyContinue
        Write-Output "Granted SeServiceLogonRight to $SvcAccount"

    } -ArgumentList "$NetBIOSName\$SQLSvcAccountName" -ErrorAction Stop |
        ForEach-Object { Write-Log "[$VMName] $_" INFO }
}
#endregion

#region ── SQL Server install ────────────────────────────────────────────────
function Install-SQLOnVM {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [string]$SQLISOHostPath,
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-Log "[$VMName] Checking if SQL Server is already installed..." INFO
    $alreadyInstalled = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $null -ne (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue)
    } -ErrorAction Stop

    if ($alreadyInstalled) {
        Write-Log "[$VMName] SQL Server already installed - skipping." INFO
        return
    }

    #region Remove any existing DVD drive before disk operations
    $existingDvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingDvd) {
        Write-Log "[$VMName] Removing DVD drive before disk operations (prevents D:\ drive letter conflict)..." INFO
        Remove-VMDvdDrive -VMName $VMName `
            -ControllerNumber   $existingDvd.ControllerNumber `
            -ControllerLocation $existingDvd.ControllerLocation `
            -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    #endregion

    #region Initialize data disk (D:\) inside VM
    Write-Log "[$VMName] Initializing SQL data disk..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        if (Test-Path "D:\") {
            $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
            if ($vol -and $vol.FileSystem -eq 'NTFS') {
                Write-Output "D:\ is already NTFS - skipping disk initialization."
                return
            }
            Write-Output "D:\ exists but FileSystem is '$($vol.FileSystem)' - not a data disk; will initialize the actual data disk."
        }

        $wmiDisk = Get-WmiObject -Class Win32_DiskDrive |
            Where-Object { $_.Index -gt 0 } |
            Sort-Object Index |
            Select-Object -First 1

        if (-not $wmiDisk) {
            throw "No secondary disk found via Win32_DiskDrive. Verify the data VHDX is attached to the VM."
        }

        $diskNum = [int]$wmiDisk.Index
        Write-Output "Found data disk: WMI Index=$diskNum  Size=$([math]::Round([long]$wmiDisk.Size/1GB,0)) GB"

        $disk = Get-Disk -Number $diskNum -ErrorAction Stop
        Write-Output "  Status=$($disk.OperationalStatus)  PartitionStyle=$($disk.PartitionStyle)"

        if ($disk.IsOffline) {
            Write-Output "Bringing disk $diskNum online..."
            Set-Disk -Number $diskNum -IsOffline  $false -ErrorAction Stop
            Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction Stop
            Start-Sleep -Seconds 2
        }

        if ((Get-Disk -Number $diskNum).PartitionStyle -eq 'RAW') {
            Write-Output "Initializing disk $diskNum as GPT..."
            Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
            Start-Sleep -Seconds 1
        }

        Write-Output "Creating D:\ partition on disk $diskNum..."
        New-Partition -DiskNumber $diskNum -DriveLetter D -UseMaximumSize -ErrorAction Stop |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel "SQLData" -Confirm:$false -ErrorAction Stop | Out-Null

        Write-Output "Data disk initialized as D:\"

        Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
        Write-Output "SAN policy set to OnlineAll."

    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Create SQL data directories
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        foreach ($dir in @('D:\SQLData','D:\SQLLog','D:\SQLBackup','D:\SQLTemp')) {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
    } -ErrorAction Stop
    Write-Log "[$VMName] SQL data directories created." INFO
    #endregion

    #region Attach SQL ISO to VM DVD drive from host
    Write-Log "[$VMName] Attaching SQL ISO to VM DVD drive..." INFO
    $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dvd) {
        Set-VMDvdDrive -VMName $VMName -ControllerNumber $dvd.ControllerNumber `
            -ControllerLocation $dvd.ControllerLocation -Path $SQLISOHostPath -ErrorAction Stop
    } else {
        Add-VMDvdDrive -VMName $VMName -Path $SQLISOHostPath -ErrorAction Stop
    }
    Write-Log "[$VMName] SQL ISO attached to DVD drive." SUCCESS
    #endregion

    #region Run SQL setup
    Write-Log "[$VMName] Running SQL Server setup (silent)..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($SvcUser, $SvcPass, $SAPass, $DomainAdmin, $AdmPass, $DomainName, $NetBIOS)

        $dvdDrive    = Get-WmiObject Win32_CDROMDrive | Where-Object { $_.MediaLoaded } | Select-Object -First 1
        if (-not $dvdDrive) { throw "No loaded DVD drive found in VM. SQL ISO may not be attached." }
        $driveLetter = $dvdDrive.Drive.TrimEnd(':')
        $setupExe    = "${driveLetter}:\setup.exe"
        if (-not (Test-Path $setupExe)) { throw "setup.exe not found on DVD drive ${driveLetter}:\" }

        $svcSecPwd = ConvertTo-SecureString $SvcPass -AsPlainText -Force
        $saSecPwd  = ConvertTo-SecureString $SAPass  -AsPlainText -Force

        $args = @(
            "/Q",
            "/ACTION=Install",
            "/FEATURES=SQLENGINE,REPLICATION,FULLTEXT",
            "/INSTANCENAME=MSSQLSERVER",
            "/SQLSVCACCOUNT=`"$SvcUser`"",
            "/SQLSVCPASSWORD=`"$SvcPass`"",
            "/AGTSVCACCOUNT=`"$SvcUser`"",
            "/AGTSVCPASSWORD=`"$SvcPass`"",
            "/AGTSVCSTARTUPTYPE=Automatic",
            "/SQLSVCSTARTUPTYPE=Automatic",
            "/SECURITYMODE=SQL",
            "/SAPWD=`"$SAPass`"",
            "/SQLSYSADMINACCOUNTS=`"$NetBIOS\Domain Admins`"",
            "/SQLUSERDBDIR=D:\SQLData",
            "/SQLUSERDBLOGDIR=D:\SQLLog",
            "/SQLBACKUPDIR=D:\SQLBackup",
            "/SQLTEMPDBDIR=D:\SQLTemp",
            "/SQLTEMPDBLOGDIR=D:\SQLTemp",
            "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS",
            "/IACCEPTSQLSERVERLICENSETERMS",
            "/INDICATEPROGRESS",
            "/UPDATEENABLED=False",
            "/NPENABLED=1",
            "/TCPENABLED=1"
        )

        Write-Output "Launching SQL Server setup..."
        $proc = Start-Process -FilePath $setupExe -ArgumentList $args -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -notin @(0, 3010)) {
            $summaryLog = Get-ChildItem "C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log" `
                -Filter "Summary*.txt" -Recurse -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($summaryLog) {
                $tail = Get-Content $summaryLog.FullName -Tail 30
                Write-Output "Setup log tail:`n$($tail -join "`n")"
            }
            throw "SQL Server setup exited with code: $($proc.ExitCode)"
        }
        Write-Output "SQL Server setup completed. Exit code: $($proc.ExitCode)"

    } -ArgumentList $SQLSvcAccount, $SQLServiceAccountPassword, $SAPassword, `
        "$NetBIOSName\Administrator", $AdminPassword, $DomainName, $NetBIOSName `
        -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Enable TCP/IP on 1433 via WMI
    Write-Log "[$VMName] Enabling TCP/IP protocol on port 1433..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $smo = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement")
        if ($smo) {
            $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer "localhost"
            $tcp = $wmi.ServerInstances['MSSQLSERVER'].ServerProtocols['Tcp']
            if (-not $tcp.IsEnabled) {
                $tcp.IsEnabled = $true
                $tcp.Alter()
                Write-Output "TCP/IP enabled via SMO WMI."
            } else {
                Write-Output "TCP/IP already enabled."
            }
            $ipAll = $tcp.IPAddresses['IPAll']
            $ipAll.IPAddressProperties['TcpPort'].Value = '1433'
            $ipAll.IPAddressProperties['TcpDynamicPorts'].Value = ''
            $tcp.Alter()
            Write-Output "Port 1433 configured on IPAll."
        } else {
            Write-Output "SMO WMI assembly not available — TCP may need manual verification."
        }
    } -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Open firewall ports
    Write-Log "[$VMName] Opening firewall ports 1433 and 5022..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $rules = @(
            @{ Name = "SQLLab-SQL1433"; Port = 1433; Display = "SQL Server 1433 (SQLLab)" }
            @{ Name = "SQLLab-AG5022"; Port = 5022; Display = "SQL AG Endpoint 5022 (SQLLab)" }
        )
        foreach ($rule in $rules) {
            $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
            if (-not $existing) {
                New-NetFirewallRule `
                    -Name        $rule.Name `
                    -DisplayName $rule.Display `
                    -Direction   Inbound `
                    -Protocol    TCP `
                    -LocalPort   $rule.Port `
                    -Action      Allow `
                    -ErrorAction Stop | Out-Null
                Write-Output "Opened port $($rule.Port)."
            } else {
                Write-Output "Port $($rule.Port) already open."
            }
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Restart SQL Server
    Write-Log "[$VMName] Restarting SQL Server service..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        Restart-Service MSSQLSERVER -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
        $svc = Get-Service MSSQLSERVER
        Write-Output "MSSQLSERVER status: $($svc.Status)"
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Enable Agent XPs and start SQL Server Agent
    Write-Log "[$VMName] Enabling Agent XPs and starting SQL Server Agent..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $conn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=localhost;Database=master;Integrated Security=True;Connect Timeout=30")
        try {
            $conn.Open()
            foreach ($q in @(
                "EXEC sp_configure 'show advanced options', 1; RECONFIGURE WITH OVERRIDE",
                "EXEC sp_configure 'Agent XPs', 1; RECONFIGURE WITH OVERRIDE"
            )) {
                $cmd = New-Object System.Data.SqlClient.SqlCommand($q, $conn)
                $cmd.CommandTimeout = 30
                [void]$cmd.ExecuteNonQuery()
            }
            Write-Output "Agent XPs enabled."
        } finally {
            if ($conn.State -eq 'Open') { $conn.Close() }
        }

        Set-Service SQLSERVERAGENT -StartupType Automatic -ErrorAction SilentlyContinue
        $agentSvc = Get-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
        if ($agentSvc) {
            if ($agentSvc.Status -ne 'Running') {
                Start-Service SQLSERVERAGENT -ErrorAction Stop
                Start-Sleep -Seconds 3
                $agentSvc = Get-Service SQLSERVERAGENT
            }
            Write-Output "SQL Server Agent status: $($agentSvc.Status)"
        } else {
            Write-Output "SQLSERVERAGENT service not found — skipping."
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    Write-Log "[$VMName] SQL Server installation complete." SUCCESS
}

# Installs SQL Server on every node in $NodeSpecs (array of @{ VMName; ComputerName }),
# then removes the DVD drive so a future re-run does not find a stale DVD on D:\.
function Install-LabSQLNodes {
    param(
        [object[]]$NodeSpecs,
        [string]$SQLISOHostPath,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not (Test-Path $SQLISOHostPath)) {
        throw "SQL Server ISO not found at: $SQLISOHostPath"
    }

    foreach ($spec in $NodeSpecs) {
        Install-SQLOnVM `
            -VMName         $spec.VMName `
            -ComputerName   $spec.ComputerName `
            -SQLISOHostPath $SQLISOHostPath `
            -Credential     $Credential

        $dvd = Get-VMDvdDrive -VMName $spec.VMName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dvd) {
            Remove-VMDvdDrive -VMName $spec.VMName -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation -ErrorAction SilentlyContinue
            Write-Log "[$($spec.VMName)] DVD drive removed after SQL installation." INFO
        }
    }
}
#endregion

#region ── Enable Always On ──────────────────────────────────────────────────
function Enable-AlwaysOn {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Credential)

    $alreadyOn = $false
    try {
        $alreadyOn = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            try {
                $conn = New-Object System.Data.SqlClient.SqlConnection(
                    'Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5')
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS INT)"
                $v = $cmd.ExecuteScalar()
                $conn.Close()
                return ($v -eq 1)
            } catch { return $false }
        } -ErrorAction Stop
    } catch { $alreadyOn = $false }
    if ($alreadyOn) {
        Write-Log "[$VMName] HADR already active - skipping enable process." SUCCESS
        return
    }

    #region Bring D:\ data disk online
    Write-Log "[$VMName] Ensuring D:\ data disk is online..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vol -and $vol.FileSystem -eq 'NTFS' -and (Test-Path 'D:\')) {
            $volGB = [math]::Round($vol.Size / 1GB, 0)
            Write-Output ('D:\ already online (NTFS, ' + $volGB + ' GB).')
            Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
        } else {
            Write-Output 'D:\ not accessible - locating and bringing data disk online...'
            $wmiDisk = Get-WmiObject -Class Win32_DiskDrive |
                Where-Object { $_.Index -gt 0 } | Sort-Object Index | Select-Object -First 1
            if (-not $wmiDisk) { throw 'No secondary data disk found via Win32_DiskDrive.' }
            $diskNum   = [int]$wmiDisk.Index
            $diskSizeGB = [math]::Round([long]$wmiDisk.Size / 1GB, 0)
            Write-Output ('Data disk: WMI Index=' + $diskNum + '  Size=' + $diskSizeGB + ' GB')
            $disk = Get-Disk -Number $diskNum -ErrorAction Stop
            if ($disk.IsOffline) {
                Set-Disk -Number $diskNum -IsOffline $false -ErrorAction Stop
                Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction SilentlyContinue
                Write-Output "Disk $diskNum brought online."
            }
            Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
            $waited = 0
            while (-not (Test-Path 'D:\') -and $waited -lt 15) {
                Start-Sleep -Seconds 3; $waited += 3
            }
            if (-not (Test-Path 'D:\')) {
                throw 'D:\ not accessible after bring-online attempt.'
            }
            Write-Output "D:\ now online, waited ${waited}s."
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Write HADR registry key and call ChangeHadrServiceSetting via Invoke-WmiMethod
    Write-Log "[$VMName] Writing HADR registry key and enabling via WMI..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        if (-not (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue)) {
            throw 'MSSQLSERVER service not found - verify SQL install completed.'
        }

        $svcObj = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
        $instanceKey = $null
        if ($svcObj.PathName -match '\\(MSSQL\d+\.MSSQLSERVER)\\') {
            $instanceKey = $Matches[1]
        }
        if (-not $instanceKey) {
            $sqlKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' |
                Where-Object { $_.Name -match '\\MSSQL\d+\.MSSQLSERVER$' } |
                Sort-Object Name -Descending | Select-Object -First 1
            if (-not $sqlKey) { throw 'SQL Server instance registry key not found.' }
            $instanceKey = $sqlKey.PSChildName
        }
        Write-Output "SQL Server instance key: $instanceKey"

        $hadrPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\' + $instanceKey + '\MSSQLServer\HADR'
        if (-not (Test-Path $hadrPath)) { New-Item -Path $hadrPath -Force | Out-Null }
        Set-ItemProperty -Path $hadrPath -Name 'IsHadrEnabled' -Value 1 -Type DWord -Force
        Write-Output "HADR IsHadrEnabled=1 written at $instanceKey\MSSQLServer\HADR."

        $verNum = if ($instanceKey -match 'MSSQL(\d+)\.') { [int]$Matches[1] } else { 17 }
        $cmNs   = 'ROOT\Microsoft\SqlServer\ComputerManagement' + $verNum
        Write-Output "SQL WMI namespace: $cmNs"

        $wmiSet = $false
        try {
            $chResult = Invoke-WmiMethod `
                -Namespace $cmNs `
                -Class SqlService `
                -Name ChangeHadrServiceSetting `
                -ArgumentList @([int]1) `
                -Filter "ServiceName='MSSQLSERVER'" `
                -ErrorAction Stop
            Write-Output "Invoke-WmiMethod ChangeHadrServiceSetting ReturnValue: $($chResult.ReturnValue)"
            if ($chResult.ReturnValue -eq 0) {
                $wmiSet = $true
                Write-Output 'HADR enabled via WMI ChangeHadrServiceSetting.'
            } else {
                Write-Output "ChangeHadrServiceSetting returned non-zero: $($chResult.ReturnValue) - will try SMO fallback."
            }
        } catch {
            Write-Output "Invoke-WmiMethod ChangeHadrServiceSetting error: $($_.Exception.Message -replace '\r?\n.*','')"
        }

        if (-not $wmiSet) {
            try {
                $smo = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement')
                if ($smo) {
                    $mc     = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer 'localhost'
                    $svcSMO = $mc.Services['MSSQLSERVER']
                    if ($svcSMO) {
                        $svcSMO.ChangeHadrServiceSetting(1)
                        Write-Output 'HADR enabled via SMO ManagedComputer.ChangeHadrServiceSetting.'
                        $wmiSet = $true
                    } else {
                        Write-Output 'SMO: MSSQLSERVER not found in ManagedComputer.Services.'
                    }
                } else {
                    Write-Output 'SMO WMI assembly could not be loaded.'
                }
            } catch {
                Write-Output "SMO ChangeHadrServiceSetting error: $($_.Exception.Message -replace '\r?\n.*','')"
            }
        }

        if (-not $wmiSet) {
            Write-Output 'WARN: All WMI/SMO ChangeHadrServiceSetting methods failed.'
            Write-Output 'WARN: Registry key IsHadrEnabled=1 is written - SQL 2019+ reads this on start.'
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Restart MSSQLSERVER with HADR enabled
    Write-Log "[$VMName] Restarting MSSQLSERVER with HADR enabled..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') {
            Write-Output 'Stopping MSSQLSERVER (was running)...'
            Stop-Service MSSQLSERVER -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
        } else {
            Write-Output 'MSSQLSERVER already stopped.'
        }

        Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
        $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue | Select-Object -First 1
        $dAccessible = ($vol -and $vol.FileSystem -eq 'NTFS') -and (Test-Path 'D:\')
        if (-not $dAccessible) {
            Write-Output 'D:\ not accessible after service stop - bringing back online...'
            $wmiDisk = Get-WmiObject -Class Win32_DiskDrive |
                Where-Object { $_.Index -gt 0 } | Sort-Object Index | Select-Object -First 1
            if ($wmiDisk) {
                $diskNum = [int]$wmiDisk.Index
                Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
                Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction SilentlyContinue
            }
            $waited = 0
            while (-not (Test-Path 'D:\') -and $waited -lt 15) {
                Start-Sleep -Seconds 3; $waited += 3
            }
            if (-not (Test-Path 'D:\')) { throw 'D:\ not accessible after bring-online attempt.' }
            Write-Output "D:\ restored, waited ${waited}s."
        } else {
            Write-Output 'D:\ online.'
        }

        foreach ($dir in @('D:\SQLData','D:\SQLLog','D:\SQLBackup','D:\SQLTemp')) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Output "Created missing directory: $dir"
            }
        }

        $clusSvc = Get-Service ClusSvc -ErrorAction SilentlyContinue
        if ($clusSvc) {
            if ($clusSvc.Status -ne 'Running') {
                Write-Output 'ClusSvc stopped - starting...'
                Start-Service ClusSvc -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 8
            }
            Write-Output "ClusSvc status: $((Get-Service ClusSvc -ErrorAction SilentlyContinue).Status)"

            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            $clNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
            if ($clNode) {
                Write-Output "Cluster node $($clNode.Name): State=$($clNode.State)"
                if ($clNode.State -eq 'Paused') {
                    Write-Output 'Node is Paused - resuming before SQL start...'
                    Resume-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
                    $waited = 0
                    while ($waited -lt 45) {
                        Start-Sleep -Seconds 3; $waited += 3
                        $clNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
                        if ($clNode.State -eq 'Up') { break }
                    }
                    Write-Output "Cluster node state after resume: $($clNode.State) (waited ${waited}s)"
                }
                if ($clNode.State -ne 'Up') {
                    Write-Output "WARN: Cluster node state is $($clNode.State) - HADR may not initialize."
                }
            } else {
                Write-Output "WARN: $env:COMPUTERNAME not found as a cluster member - verify WSFC setup."
            }
        } else {
            Write-Output 'ClusSvc not found - WSFC may not be configured.'
        }

        Write-Output 'Starting MSSQLSERVER...'
        Start-Service MSSQLSERVER -ErrorAction Stop
        Write-Output 'MSSQLSERVER start initiated.'
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Wait for MSSQLSERVER to reach Running state
    Write-Log "[$VMName] Waiting for MSSQLSERVER to reach Running state (up to 1 min)..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $deadline = (Get-Date).AddMinutes(1)
        while ((Get-Date) -lt $deadline) {
            $status = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status
            if ($status -eq 'Running') { Write-Output 'MSSQLSERVER running.'; return }
            Write-Output "MSSQLSERVER status: $status - waiting..."
            Start-Sleep -Seconds 5
        }
        throw 'MSSQLSERVER did not reach Running state within 1 minute.'
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Verify Always On is active via SERVERPROPERTY
    Write-Log "[$VMName] Verifying Always On via SERVERPROPERTY..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $deadline = (Get-Date).AddMinutes(8)
        $result   = $null
        $connUsed = $null
        while ((Get-Date) -lt $deadline) {
            $svcStatus = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status
            if ($svcStatus -ne 'Running') {
                throw "MSSQLSERVER stopped while waiting for connections (status: $svcStatus) - SQL crashed."
            }

            $lastErr = $null
            foreach ($cs in @(
                'Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5',
                'Server=tcp:localhost,1433;Database=master;Integrated Security=True;Connect Timeout=5'
            )) {
                try {
                    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
                    $conn.Open()
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS INT)"
                    $val  = $cmd.ExecuteScalar()
                    $conn.Close()
                    if ($val -eq 1) {
                        $result   = $val
                        $connUsed = $cs -replace ';.*',''
                        break
                    }
                    $lastErr = "IsHadrEnabled=$val (HADR not yet active)"
                } catch { $lastErr = $_.Exception.Message -replace '\r?\n.*','' }
            }
            if ($result -eq 1) { break }
            Write-Output "SQL state (svc=$svcStatus) - $lastErr - retrying in 5 s..."
            Start-Sleep -Seconds 5
        }

        if ($null -eq $result) {
            throw 'Could not confirm HADR active on SQL (Shared Memory or TCP) within 8 min.'
        }
        Write-Output "Always On confirmed active (IsHadrEnabled=$result) via $connUsed."
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    Write-Log "[$VMName] Always On enabled and verified." SUCCESS
}

# Enables Always On on both nodes (with a settle pause between), then enables
# Agent XPs and starts SQL Server Agent on each. Mirrors step 12.
function Enable-LabAlwaysOn {
    param(
        [string]$Node1VMName,
        [string]$Node2VMName,
        [System.Management.Automation.PSCredential]$Credential
    )

    $nodeList = @($Node1VMName, $Node2VMName)
    for ($i = 0; $i -lt $nodeList.Count; $i++) {
        Enable-AlwaysOn -VMName $nodeList[$i] -Credential $Credential
        if ($i -lt $nodeList.Count - 1) {
            Write-Log 'Pausing 20 s for cluster to stabilize between nodes...' INFO
            Start-Sleep -Seconds 20
        }
    }

    foreach ($vmName in $nodeList) {
        Write-Log "[$vmName] Enabling Agent XPs and starting SQL Server Agent..." INFO
        Invoke-Command -VMName $vmName -Credential $Credential -ScriptBlock {
            $connStr = 'Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=30'
            $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
            try {
                $conn.Open()
                $cmd = $conn.CreateCommand()
                foreach ($sql in @(
                    "EXEC sp_configure 'show advanced options', 1; RECONFIGURE WITH OVERRIDE",
                    "EXEC sp_configure 'Agent XPs', 1; RECONFIGURE WITH OVERRIDE"
                )) {
                    $cmd.CommandText = $sql
                    $cmd.ExecuteNonQuery() | Out-Null
                }
                Write-Output 'Agent XPs enabled.'
            } finally {
                if ($conn.State -eq 'Open') { $conn.Close() }
            }

            $agentSvc = Get-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
            if ($agentSvc) {
                Set-Service SQLSERVERAGENT -StartupType Automatic -ErrorAction SilentlyContinue
                if ($agentSvc.Status -ne 'Running') {
                    Start-Service SQLSERVERAGENT -ErrorAction Stop
                    Write-Output 'SQL Server Agent started (set to Automatic).'
                } else {
                    Write-Output 'SQL Server Agent already running.'
                }
            } else {
                Write-Output 'WARN: SQLSERVERAGENT service not found - verify SQL installation.'
            }
        } -ErrorAction Stop | ForEach-Object { Write-Log "[$vmName] $_" INFO }
    }
}
#endregion

#region ── Availability Group ────────────────────────────────────────────────
# ADO.NET SQL helper injected into each remote node — single-statement only.
$Global:InvokeLocalSqlDef = {
    function Invoke-LocalSql {
        param(
            [string]$Query,
            [string]$Server   = "localhost",
            [string]$Database = "master",
            [int]   $Timeout  = 300
        )
        $connStr = "Server=$Server;Database=$Database;Integrated Security=True;Connect Timeout=30"
        $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
        try {
            $conn.Open()
            $cmd                = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
            $cmd.CommandTimeout = $Timeout
            $adapter            = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $table              = New-Object System.Data.DataTable
            [void]$adapter.Fill($table)
            return $table
        } finally {
            if ($conn.State -eq 'Open') { $conn.Close() }
        }
    }
}

# Creates the HADR endpoints, the Availability Group + listener, joins the
# secondary, validates health, and creates the labadmin login on both nodes.
# Every AG gets its own name, listener name/IP and endpoint. Mirrors step 13.
function New-LabAG {
    param(
        [string]$Node1VMName,
        [string]$Node1Computer,
        [string]$Node1IP,
        [string]$Node2VMName,
        [string]$Node2Computer,
        [string]$Node2IP,
        [string]$AGName,
        [string]$ListenerName,
        [string]$ListenerIP,
        [int]   $ListenerPort,
        [int]   $EndpointPort,
        [bool]  $IsContained,
        [System.Management.Automation.PSCredential]$DomainAdminCred
    )

    $sqlDef = $Global:InvokeLocalSqlDef.ToString()

    #region Create AG endpoint on both nodes
    foreach ($pair in @(
        @{ VM = $Node1VMName; IP = $Node1IP }
        @{ VM = $Node2VMName; IP = $Node2IP }
    )) {
        Write-Log "[$($pair.VM)] Creating AG endpoint on port $EndpointPort..." INFO
        Invoke-Command -VMName $pair.VM -Credential $DomainAdminCred -ScriptBlock {
            param($Port, $SvcAccount, $InvokeLocalSqlDef)
            . ([scriptblock]::Create($InvokeLocalSqlDef))

            $existing = Invoke-LocalSql -Query "SELECT name, state_desc FROM sys.endpoints WHERE name = 'Hadr_endpoint'"
            if ($existing.Rows.Count -gt 0) {
                Write-Output "AG endpoint already exists (state: $($existing.Rows[0]['state_desc']))"
            } else {
                try {
                    Invoke-LocalSql -Query "CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED AS TCP (LISTENER_PORT = $Port) FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES)"
                    Write-Output "Endpoint created on port $Port."
                } catch {
                    if ($_.Exception.Message -notmatch 'already exists') { throw }
                    Write-Output "Endpoint 'Hadr_endpoint' already exists (caught on create) — continuing."
                }
            }

            Invoke-LocalSql -Query "ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED"
            Write-Output "Endpoint state confirmed STARTED."

            $loginExists = Invoke-LocalSql -Query "SELECT name FROM sys.server_principals WHERE name = '$SvcAccount'"
            if ($loginExists.Rows.Count -eq 0) {
                try {
                    Invoke-LocalSql -Query "CREATE LOGIN [$SvcAccount] FROM WINDOWS"
                    Write-Output "Created login for '$SvcAccount'."
                } catch {
                    if ($_.Exception.Message -notmatch 'already exists') { throw }
                    Write-Output "Login '$SvcAccount' already exists (caught on create) — continuing."
                }
            } else {
                Write-Output "Login '$SvcAccount' already exists."
            }

            $grantExists = Invoke-LocalSql -Query @"
SELECT 1 AS granted
FROM sys.server_permissions p
JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
WHERE sp.name = '$SvcAccount' AND p.permission_name = 'CONNECT'
"@
            if ($grantExists.Rows.Count -eq 0) {
                Invoke-LocalSql -Query "GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$SvcAccount]"
                Write-Output "CONNECT granted to '$SvcAccount' on endpoint."
            } else {
                Write-Output "CONNECT already granted to '$SvcAccount'."
            }

            $fwRule = Get-NetFirewallRule -DisplayName "SQL HADR Endpoint" -ErrorAction SilentlyContinue
            if (-not $fwRule) {
                New-NetFirewallRule -DisplayName "SQL HADR Endpoint" -Direction Inbound `
                    -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                Write-Output "Firewall rule added: allow TCP inbound port $Port."
            } else {
                Write-Output "Firewall rule 'SQL HADR Endpoint' already exists."
            }

        } -ArgumentList $EndpointPort, $SQLSvcAccount, $sqlDef -ErrorAction Stop |
            ForEach-Object { Write-Log "[$($pair.VM)] $_" INFO }
    }
    #endregion

    #region Create Availability Group on node 1
    $agTypeLabel = if ($IsContained) { "Contained Availability Group" } else { "Availability Group" }
    Write-Log "[$Node1VMName] Creating $agTypeLabel '$AGName'..." INFO
    Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
        param($AGName, $SQL1Name, $SQL2Name, $ListenerName, $ListenerIP, $ListenerPort, $EPPort, $InvokeLocalSqlDef, $IsContained)
        . ([scriptblock]::Create($InvokeLocalSqlDef))
        $agTypeLabel = if ($IsContained) { "Contained AG" } else { "AG" }

        $existingAG = Invoke-LocalSql -Query "SELECT name FROM sys.availability_groups WHERE name='$AGName'"
        if ($existingAG.Rows.Count -gt 0) {
            Write-Output "$agTypeLabel '$AGName' already exists."
        } else {
            $domain = $env:USERDNSDOMAIN
            $containedClause = if ($IsContained) { "CONTAINED, " } else { "" }
            $seedingClause   = if ($IsContained) { ",`n    SEEDING_MODE        = AUTOMATIC" } else { "" }
            try {
                Invoke-LocalSql -Query "
CREATE AVAILABILITY GROUP [$AGName]
WITH (${containedClause}AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR
REPLICA ON
  N'$SQL1Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL1Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)${seedingClause}
  ),
  N'$SQL2Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL2Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)${seedingClause}
  )" -Timeout 120
                Write-Output "$agTypeLabel '$AGName' created."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { throw }
                Write-Output "$agTypeLabel '$AGName' already exists (caught on create) — continuing."
            }

            try {
                Invoke-LocalSql -Query "
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER N'$ListenerName' (
    WITH IP (('$ListenerIP','255.255.255.0')),
    PORT=$ListenerPort
)" -Timeout 60
                Write-Output "Listener '$ListenerName' added at $ListenerIP`:$ListenerPort."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists|already has a listener') { throw }
                Write-Output "Listener '$ListenerName' already exists (caught on create) — continuing."
            }
        }

        if ($IsContained) {
            foreach ($replicaName in @($SQL1Name, $SQL2Name)) {
                try {
                    Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] MODIFY REPLICA ON N'$replicaName' WITH (SEEDING_MODE = AUTOMATIC)"
                    Write-Output "SEEDING_MODE = AUTOMATIC confirmed on '$replicaName'."
                } catch {
                    Write-Output "MODIFY REPLICA warning on '$replicaName' (non-fatal): $($_.Exception.Message -replace '\r?\n.*','')"
                }
            }
            try {
                Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE"
                Write-Output "Granted CREATE ANY DATABASE on primary — auto-seeding authorized."
            } catch {
                if ($_.Exception.Message -notmatch 'already') { throw }
                Write-Output "CREATE ANY DATABASE already granted on primary."
            }
        }

    } -ArgumentList $AGName, $Node1Computer, $Node2Computer,
        $ListenerName, $ListenerIP, $ListenerPort, $EndpointPort, $sqlDef, $IsContained -ErrorAction Stop |
        ForEach-Object { Write-Log "[$Node1VMName] $_" INFO }
    #endregion

    #region Join node 2 to AG
    Write-Log "[$Node2VMName] Joining replica to AG '$AGName'..." INFO
    Invoke-Command -VMName $Node2VMName -Credential $DomainAdminCred -ScriptBlock {
        param($AGName, $InvokeLocalSqlDef, $IsContained)
        . ([scriptblock]::Create($InvokeLocalSqlDef))

        $inReplica = Invoke-LocalSql -Query "
SELECT r.replica_server_name
FROM sys.availability_replicas r
JOIN sys.availability_groups g ON r.group_id = g.group_id
WHERE g.name = '$AGName' AND r.replica_server_name = @@SERVERNAME"
        if ($inReplica.Rows.Count -eq 0) {
            try {
                Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] JOIN"
                Write-Output "Replica joined AG '$AGName'."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists|already joined') { throw }
                Write-Output "Replica already joined to AG '$AGName'."
            }
        } else {
            Write-Output "Replica already joined to AG '$AGName'."
        }

        if ($IsContained) {
            try {
                Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE"
                Write-Output "Granted CREATE ANY DATABASE to Contained AG '$AGName'."
            } catch {
                if ($_.Exception.Message -notmatch 'already') { throw }
                Write-Output "CREATE ANY DATABASE already granted — continuing."
            }
        }

    } -ArgumentList $AGName, $sqlDef, $IsContained -ErrorAction Stop |
        ForEach-Object { Write-Log "[$Node2VMName] $_" INFO }
    #endregion

    #region Validate AG health
    Write-Log "[$Node1VMName] Validating AG health..." INFO
    Start-Sleep -Seconds 15
    try {
        Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
            param($AGName, $InvokeLocalSqlDef)
            . ([scriptblock]::Create($InvokeLocalSqlDef))

            $health = Invoke-LocalSql -Query "
SELECT
    ag.name                            AS AGName,
    ar.replica_server_name             AS ReplicaServer,
    ars.role_desc                      AS Role,
    ars.synchronization_health_desc    AS SyncHealth,
    ars.connected_state_desc           AS ConnectedState,
    ars.operational_state_desc         AS OperationalState
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar            ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AGName'"

            if ($null -eq $health -or $health.Rows.Count -eq 0) {
                Write-Output "No replica health data available yet — AG may still be initializing."
                return
            }

            foreach ($row in $health.Rows) {
                if ($null -eq $row) { continue }
                $server    = if (-not $row.IsNull('ReplicaServer')) { [string]$row['ReplicaServer'] } else { '' }
                $role      = if (-not $row.IsNull('Role'))          { [string]$row['Role'] }          else { '' }
                $sync      = if (-not $row.IsNull('SyncHealth'))    { [string]$row['SyncHealth'] }    else { '' }
                $connected = if (-not $row.IsNull('ConnectedState')){ [string]$row['ConnectedState'] } else { '' }
                Write-Output ("  {0,-20} Role={1,-12} Sync={2,-15} Connected={3}" -f $server, $role, $sync, $connected)
            }

            $unhealthy = $health.Rows | Where-Object { $null -ne $_ -and -not $_.IsNull('SyncHealth') -and $_['SyncHealth'] -ne 'HEALTHY' }
            if ($unhealthy) {
                Write-Output "WARNING: Some replicas not yet synchronized — typically resolves within 60 s."
            }
        } -ArgumentList $AGName, $sqlDef -ErrorAction Stop |
            ForEach-Object { Write-Log "[$Node1VMName] AG Health: $_" INFO }
    } catch {
        Write-Log "[$Node1VMName] AG health check failed (non-fatal — AG was configured successfully): $($_.Exception.Message -replace '\r?\n.*','')" WARN
    }
    #endregion

    #region Create labadmin logins on both nodes
    foreach ($vmName in @($Node1VMName, $Node2VMName)) {
        Write-Log "[$vmName] Creating server-level login '$LabAdminUser'..." INFO
        Invoke-Command -VMName $vmName -Credential $DomainAdminCred -ScriptBlock {
            param($SqlUser, $SqlPass, $InvokeLocalSqlDef)
            . ([scriptblock]::Create($InvokeLocalSqlDef))

            $escapedPass = $SqlPass -replace "'","''"
            try {
                Invoke-LocalSql -Query "CREATE LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF"
                Write-Output "Created server-level login '$SqlUser'."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { throw }
                $existing = Invoke-LocalSql -Query "SELECT type FROM sys.server_principals WHERE name = '$SqlUser' COLLATE SQL_Latin1_General_CP1_CI_AS"
                if ($existing.Rows.Count -gt 0 -and [string]$existing.Rows[0]['type'] -eq 'S') {
                    Invoke-LocalSql -Query "ALTER LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF"
                    Write-Output "Server-level login '$SqlUser' already exists - password confirmed."
                } else {
                    $t = if ($existing.Rows.Count -gt 0) { [string]$existing.Rows[0]['type'] } else { 'unknown' }
                    Write-Output "Principal '$SqlUser' already exists as type '$t' - skipping."
                }
            }

            $isSA = Invoke-LocalSql -Query "SELECT 1 AS r FROM sys.server_role_members rm JOIN sys.server_principals rp ON rm.role_principal_id = rp.principal_id JOIN sys.server_principals mp ON rm.member_principal_id = mp.principal_id WHERE rp.name = 'sysadmin' AND mp.name = '$SqlUser'"
            if ($isSA.Rows.Count -eq 0) {
                try {
                    Invoke-LocalSql -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER [$SqlUser]"
                    Write-Output "Granted sysadmin to '$SqlUser'."
                } catch {
                    if ($_.Exception.Message -notmatch 'already') { throw }
                    Write-Output "sysadmin already granted to '$SqlUser'."
                }
            } else {
                Write-Output "sysadmin already granted to '$SqlUser'."
            }

        } -ArgumentList $LabAdminUser, $LabAdminPassword, $sqlDef -ErrorAction Stop |
            ForEach-Object { Write-Log "[$vmName] $_" INFO }
    }

    if ($IsContained) {
        Write-Log "[$Node1VMName] Creating server-level login '$LabAdminUser' via listener (Contained AG context)..." INFO
        Invoke-Command -VMName $Node1VMName -Credential $DomainAdminCred -ScriptBlock {
            param($ListenerName, $ListenerPort, $SqlUser, $SqlPass, $InvokeLocalSqlDef)
            . ([scriptblock]::Create($InvokeLocalSqlDef))

            $escapedPass = $SqlPass -replace "'","''"
            try {
                Invoke-LocalSql -Query "CREATE LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF" `
                    -Server "$ListenerName,$ListenerPort"
                Write-Output "Created login '$SqlUser' via listener."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { throw }
                Write-Output "Login '$SqlUser' already exists via listener — continuing."
            }
            try {
                Invoke-LocalSql -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER [$SqlUser]" `
                    -Server "$ListenerName,$ListenerPort"
                Write-Output "Granted sysadmin to '$SqlUser' via listener."
            } catch {
                if ($_.Exception.Message -notmatch 'already') { throw }
                Write-Output "sysadmin already granted to '$SqlUser' via listener."
            }
        } -ArgumentList $ListenerName, $ListenerPort, $LabAdminUser, $LabAdminPassword, $sqlDef -ErrorAction Stop |
            ForEach-Object { Write-Log "[$Node1VMName] Listener login: $_" INFO }
    }
    #endregion

    Write-Log "Availability Group '$AGName' configuration complete." SUCCESS
}
#endregion

#region ── Host access ───────────────────────────────────────────────────────
# Adds hosts-file entries for one cluster's nodes/cluster/listener under a
# per-cluster marker block so teardown can remove each independently.
function Add-LabClusterHostEntries {
    param([hashtable]$Ctx)

    $hostsPath    = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content -Path $hostsPath -Raw -ErrorAction Stop
    $marker       = $Ctx.HostsMarker

    if ($hostsContent -match [regex]::Escape("$marker-BEGIN")) {
        Write-Log "Hosts entries for '$marker' already present — skipping." INFO
        return
    }

    $dom = $DomainName
    $labEntries = @"

# $marker-BEGIN
$($Ctx.Node1IP) $($Ctx.Node1Computer)     $($Ctx.Node1Computer).$dom
$($Ctx.Node2IP) $($Ctx.Node2Computer)     $($Ctx.Node2Computer).$dom
$($Ctx.ClusterIP)    $($Ctx.ClusterName)   $($Ctx.ClusterName).$dom
$($Ctx.ListenerIP)   $($Ctx.ListenerName)  $($Ctx.ListenerName).$dom
# $marker-END
"@
    Add-Content -Path $hostsPath -Value $labEntries -Encoding ASCII -ErrorAction Stop
    Write-Log "Hosts entries added for '$marker'." SUCCESS
}
#endregion
