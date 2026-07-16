#Requires -Version 5.1
<#
.SYNOPSIS
    Build-VM - Interactive, prompt-driven builder for internet-connected
    Windows Server 2025 Hyper-V VMs.

    Designed so any teammate on a Windows machine with Hyper-V can run it with
    zero memorized parameters. It scans the machine's drives, lets the user pick
    where to store the VM, downloads the Windows Server 2025 ISO once (reused
    afterward), then builds a ready-to-use VM and prints the connection details.

    Each VM is a 2 vCPU / 4 GB RAM Generation-2 VM with a single OS disk (only
    C:\ is visible inside the guest) connected to the internet via Hyper-V's
    Default Switch. You can build one VM after another in a single run.

    NO Microsoft account / "connect work or school" is ever required: Windows is
    applied offline (DISM) and configured with a local-account answer file.

.NOTES
    Run as Administrator. If PowerShell blocks the script, launch it with:
        powershell -ExecutionPolicy Bypass -File .\Build-VM.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
#  Fixed settings (per requirements)
# ============================================================================
$Script:VMCpuCount       = 2
$Script:VMMemoryBytes     = 4GB          # assigned RAM
$Script:VMOSDiskGB        = 80           # dynamic - only consumes what is used
$Script:AdministratorUser = "Administrator"
$Script:AdministratorPass = "Connect123"
$Script:VMAdminUser       = "VMAdmin"
$Script:VMAdminPass       = "Connect123"

$Script:WinServerISOName  = "WindowsServer2025.iso"
# Direct Windows Server 2025 evaluation ISO (64-bit, English) - build 26100,
# file 26100.*.SERVER_EVAL_x64FRE_en-us.iso. NOTE: linkid=2195280 is the older
# Server 2022 ISO - do not use it here. If Microsoft ever retires this link,
# download manually from the Evaluation Center and drop the file in the ISOs
# folder - the script detects it automatically.
$Script:WinServerISOUrl   = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
$Script:WinServerEvalPage = "https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025"

# Preferred Hyper-V switch for internet access (present by default on Windows
# client Hyper-V and provides NAT + DHCP with zero configuration).
$Script:PreferredSwitch   = "Default Switch"

# Fallback NAT switch (only created if no Default/External switch exists).
$Script:FallbackSwitch    = "BuildVM-Switch"
$Script:FallbackNatName   = "BuildVM-NAT"
$Script:FallbackSubnet    = "192.168.211.0"
$Script:FallbackPrefix    = 24
$Script:FallbackHostIP    = "192.168.211.1"

$Script:LogFile           = $null   # set once a storage location is chosen

# ============================================================================
#  Logging
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','STEP')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'   }
        'WARN'    { 'Yellow'  }
        'ERROR'   { 'Red'     }
        'STEP'    { 'Magenta' }
        default   { 'Cyan'    }
    }
    Write-Host $entry -ForegroundColor $color
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value $entry -Encoding UTF8 } catch { }
    }
}

function Write-Banner {
    param([string]$Text, [string]$Color = 'Cyan')
    $line = "=" * 64
    Write-Host ""
    Write-Host $line  -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host $line  -ForegroundColor $Color
    Write-Host ""
}

# ============================================================================
#  Preflight - Administrator + Hyper-V availability
# ============================================================================
function Test-Prerequisites {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host ""
        Write-Host "  This script must be run as Administrator." -ForegroundColor Red
        Write-Host "  Right-click PowerShell and choose 'Run as administrator', then re-run." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "  Hyper-V PowerShell cmdlets were not found." -ForegroundColor Red
        Write-Host "  Enable Hyper-V (Windows Pro/Enterprise/Education), then reboot:" -ForegroundColor Yellow
        Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }

    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Log "Hyper-V Virtual Machine Management service is not running - starting it..." WARN
        try { Start-Service vmms -ErrorAction Stop } catch {
            Write-Log "Could not start the Hyper-V service (vmms): $_" ERROR
            exit 1
        }
    }
}

# ============================================================================
#  Prompt helpers
# ============================================================================
function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        $val = (Read-Host $Prompt).Trim()
        if ($val) { return $val }
        Write-Host "  A value is required." -ForegroundColor Red
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }
    while ($true) {
        $ans = (Read-Host "$Prompt $suffix").Trim().ToLower()
        if (-not $ans) { return $DefaultYes }
        if ($ans -in @('y','yes')) { return $true }
        if ($ans -in @('n','no'))  { return $false }
        Write-Host "  Please answer y or n." -ForegroundColor Red
    }
}

# Sanitize a user-supplied VM name into a valid NetBIOS computer name
# (<=15 chars, letters/digits/hyphen only).
function ConvertTo-ComputerName {
    param([string]$Name)
    $clean = ($Name -replace '[^A-Za-z0-9-]', '')
    if (-not $clean) { $clean = "BuildVM" }
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15) }
    return $clean.ToUpper()
}

# ============================================================================
#  Step 1 - choose storage location (scans local + external drives)
# ============================================================================
function Select-StorageRoot {
    Write-Banner "STEP 1 of 4  -  Choose where to store the VM" 'Cyan'
    Write-Log "Scanning available drives (local and external)..." INFO

    $volumes = Get-Volume | Where-Object {
        $_.DriveLetter -and
        $_.DriveType -in @('Fixed','Removable') -and
        $_.FileSystem -eq 'NTFS'
    } | Sort-Object DriveLetter

    if (-not $volumes) {
        throw "No usable NTFS drives with a drive letter were found. Attach an NTFS drive and retry."
    }

    Write-Host "  Available drives:" -ForegroundColor White
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    $list = @()
    $i = 1
    foreach ($v in $volumes) {
        $totalGB = [math]::Round($v.Size / 1GB, 1)
        $freeGB  = [math]::Round($v.SizeRemaining / 1GB, 1)
        $label   = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { "(no label)" }
        $kind    = if ($v.DriveType -eq 'Removable') { "external" } else { "local" }
        Write-Host ("  [{0}] {1}:\  {2,-18} {3,-9} Total {4,7} GB  Free {5,7} GB" -f `
                     $i, $v.DriveLetter, $label, $kind, $totalGB, $freeGB)
        $list += [PSCustomObject]@{ Index = $i; Letter = $v.DriveLetter; FreeGB = $freeGB; Type = $v.DriveType }
        $i++
    }
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host "  Recommended free space: ~60 GB (ISO ~5 GB + VM growth)." -ForegroundColor Yellow
    Write-Host ""

    $sel = $null
    while (-not $sel) {
        $choice = Read-Host "  Enter the number of the drive to use"
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            $sel = $list[$n - 1]
        } else {
            Write-Host "  Enter a number between 1 and $($list.Count)." -ForegroundColor Red
        }
    }

    if ($sel.FreeGB -lt 60) {
        Write-Log "Drive $($sel.Letter): has only $($sel.FreeGB) GB free (60 GB recommended)." WARN
        if (-not (Read-YesNo "  Continue anyway?" $false)) {
            throw "Cancelled - insufficient free space."
        }
    }
    if ($sel.Type -eq 'Removable') {
        Write-Log "Note: '$($sel.Letter):' is an external/removable drive. The VM will only run while it is connected." WARN
    }

    $root = "$($sel.Letter):\BuildVM"
    foreach ($dir in @($root, "$root\ISOs", "$root\VMs", "$root\logs")) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $Script:LogFile = Join-Path "$root\logs" ("build-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
    Write-Log "Storage location: $root" SUCCESS

    return [PSCustomObject]@{
        Root    = $root
        ISOPath = "$root\ISOs"
        VMPath  = "$root\VMs"
        LogPath = "$root\logs"
    }
}

# ============================================================================
#  Step 2 - acquire the Windows Server 2025 ISO (download once, reuse after)
# ============================================================================
function Get-WindowsServerISO {
    param([string]$ISOPath)
    Write-Banner "STEP 2 of 4  -  Windows Server 2025 ISO" 'Cyan'

    $dest = Join-Path $ISOPath $Script:WinServerISOName
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1GB) {
        $sizeGB = [math]::Round((Get-Item $dest).Length / 1GB, 2)
        Write-Log "ISO already present ($sizeGB GB) - reusing: $dest" SUCCESS
        return $dest
    }

    Write-Log "ISO not found locally - downloading (this is a one-time ~5 GB download)..." INFO
    Write-Log "  From: $Script:WinServerISOUrl" INFO
    Write-Log "  To:   $dest" INFO

    $ok = $false
    # Attempt 1: BITS (shows a progress bar and resumes well)
    try {
        Start-BitsTransfer -Source $Script:WinServerISOUrl -Destination $dest `
            -DisplayName "Windows Server 2025 ISO" -Description "Downloading Windows Server 2025 ISO" `
            -ErrorAction Stop
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1GB) { $ok = $true }
    } catch {
        Write-Log "BITS download failed: $_ - trying an alternate method..." WARN
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    }

    # Attempt 2: Invoke-WebRequest with a browser user-agent
    if (-not $ok) {
        try {
            $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36' }
            Invoke-WebRequest -Uri $Script:WinServerISOUrl -OutFile $dest -UseBasicParsing -Headers $headers -ErrorAction Stop
            if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1GB) { $ok = $true }
        } catch {
            Write-Log "WebRequest download failed: $_" WARN
            if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($ok) {
        $sizeGB = [math]::Round((Get-Item $dest).Length / 1GB, 2)
        Write-Log "ISO downloaded ($sizeGB GB)." SUCCESS
        return $dest
    }

    # Manual fallback - poll until the file appears
    Write-Host ""
    Write-Host "  Automatic download did not succeed." -ForegroundColor Yellow
    Write-Host "  Download the ISO manually:" -ForegroundColor Yellow
    Write-Host "    1. Go to: $Script:WinServerEvalPage" -ForegroundColor Cyan
    Write-Host "    2. Choose 'Download the ISO' (64-bit) and complete the short form." -ForegroundColor White
    Write-Host "    3. Save/rename the file to exactly: $Script:WinServerISOName" -ForegroundColor White
    Write-Host "    4. Place it at: $dest" -ForegroundColor Cyan
    Write-Host "  The build continues automatically once the file is detected." -ForegroundColor DarkGray
    Write-Host ""
    while (-not ((Test-Path $dest) -and (Get-Item $dest -ErrorAction SilentlyContinue).Length -gt 1GB)) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Waiting for $Script:WinServerISOName ..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 30
    }
    Write-Log "ISO detected." SUCCESS
    return $dest
}

# ============================================================================
#  Networking - resolve a switch that gives the guest internet access
# ============================================================================
function Resolve-InternetSwitch {
    # 1. Default Switch (NAT + DHCP, present on Windows client Hyper-V)
    if (Get-VMSwitch -Name $Script:PreferredSwitch -ErrorAction SilentlyContinue) {
        Write-Log "Using '$Script:PreferredSwitch' for internet access." INFO
        return [PSCustomObject]@{ Name = $Script:PreferredSwitch; Mode = 'DHCP' }
    }

    # 2. Any existing External switch
    $ext = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ext) {
        Write-Log "Using external switch '$($ext.Name)' for internet access." INFO
        return [PSCustomObject]@{ Name = $ext.Name; Mode = 'DHCP' }
    }

    # 3. Create a private NAT switch (guest gets a static IP after boot)
    Write-Log "No Default/External switch found - creating a NAT switch '$Script:FallbackSwitch'." WARN
    if (-not (Get-VMSwitch -Name $Script:FallbackSwitch -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $Script:FallbackSwitch -SwitchType Internal -ErrorAction Stop | Out-Null
    }
    $alias = "vEthernet ($Script:FallbackSwitch)"
    if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $Script:FallbackHostIP -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $Script:FallbackHostIP `
            -PrefixLength $Script:FallbackPrefix -ErrorAction Stop | Out-Null
    }
    if (-not (Get-NetNat -Name $Script:FallbackNatName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $Script:FallbackNatName `
            -InternalIPInterfaceAddressPrefix "$Script:FallbackSubnet/$Script:FallbackPrefix" -ErrorAction Stop | Out-Null
    }
    return [PSCustomObject]@{ Name = $Script:FallbackSwitch; Mode = 'STATIC' }
}

# Compute the next free static IP on the fallback NAT subnet based on how many
# VMs are already attached to that switch (avoids collisions across builds).
function Get-NextFallbackIP {
    $used = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
        Get-VMNetworkAdapter -VM $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.SwitchName -eq $Script:FallbackSwitch }).Count
    $octet = 10 + $used
    if ($octet -gt 250) { $octet = 250 }
    $base = ($Script:FallbackSubnet -split '\.')[0..2] -join '.'
    return "$base.$octet"
}

# ============================================================================
#  Answer file - local Administrator account only, no MSA, RDP enabled
# ============================================================================
function New-BuildUnattendXml {
    param([string]$ComputerName, [string]$AdminPassword)
    # PlainText=false requires Base64(UTF-16LE(password + "AdministratorPassword")).
    $adminB64 = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($AdminPassword + "AdministratorPassword"))
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
      <UserAccounts>
        <AdministratorPassword>
          <Value>$adminB64</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
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

# ============================================================================
#  UEFI boot files - write the BCD/boot files to the EFI System Partition.
#  Prefer the HOST's bcdboot; fall back to the applied image's bcdboot only if
#  the host's fails. (The image's bcdboot.exe can fail to execute off a mounted
#  guest volume - e.g. exit 0xC0E90002 with no output on the WS2025 image - while
#  the host's works; the reverse mismatch is also possible, hence the fallback.)
# ============================================================================
function Write-UefiBootFiles {
    param([string]$VMName, [string]$WinDrive, [string]$EfiDrive)

    $candidates = @(
        @{ Label = 'host';  Exe = "$env:SystemRoot\System32\bcdboot.exe" },
        @{ Label = 'image'; Exe = "${WinDrive}:\Windows\System32\bcdboot.exe" }
    )
    $errors = @()
    foreach ($c in $candidates) {
        if (-not (Test-Path $c.Exe)) { continue }
        Write-Log "[$VMName] Writing UEFI boot files to ${EfiDrive}: (using $($c.Label) bcdboot)..." INFO
        $out  = & $c.Exe "${WinDrive}:\Windows" /s "${EfiDrive}:" /f UEFI /l en-US 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0 -and (Test-Path "${EfiDrive}:\EFI\Microsoft\Boot\bootmgfw.efi")) {
            Write-Log "[$VMName] UEFI boot files written." SUCCESS
            return
        }
        $errors += "$($c.Label) bcdboot exit ${code}: $(($out -join '; ').Trim())"
        Write-Log "[$VMName] $($c.Label) bcdboot did not succeed (exit $code) - trying fallback if available." WARN
    }
    throw "[$VMName] Could not write UEFI boot files. $($errors -join '  ||  ')"
}

# ============================================================================
#  Offline Windows apply - partition the VHDX, DISM the image, inject unattend
# ============================================================================
function Install-WindowsToVHDX {
    param(
        [string]$VMName,
        [string]$ComputerName,
        [string]$OSDiskPath,
        [string]$WimPath,
        [int]   $ImageIndex
    )

    Write-Log "[$VMName] Mounting OS disk: $OSDiskPath" INFO
    Mount-VHD -Path $OSDiskPath -ErrorAction Stop
    try {
        Start-Sleep -Seconds 3
        $diskNum = (Get-VHD -Path $OSDiskPath).DiskNumber

        Write-Log "[$VMName] Creating GPT partitions (EFI + MSR + Windows)..." INFO
        Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop

        # EFI System Partition (hidden inside guest)
        $efiPart = New-Partition -DiskNumber $diskNum `
            -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -Size 100MB
        Format-Volume -Partition $efiPart -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null

        # Microsoft Reserved (MSR) - no volume, no drive letter
        New-Partition -DiskNumber $diskNum `
            -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 128MB | Out-Null

        # Windows partition - the ONLY drive the user sees inside the guest (C:)
        $winPart = New-Partition -DiskNumber $diskNum -UseMaximumSize
        Format-Volume -Partition $winPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

        $efiPart | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        $winPart | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        Start-Sleep -Seconds 3

        $efiDrive = (Get-Partition -DiskNumber $diskNum -PartitionNumber $efiPart.PartitionNumber).DriveLetter
        $winDrive = (Get-Partition -DiskNumber $diskNum -PartitionNumber $winPart.PartitionNumber).DriveLetter
        if (-not $efiDrive -or -not $winDrive) {
            throw "[$VMName] Could not obtain drive letters (EFI='$efiDrive' Win='$winDrive')."
        }
        Write-Log "[$VMName] EFI=${efiDrive}:  Windows=${winDrive}:" INFO

        Write-Log "[$VMName] Applying Windows image (index $ImageIndex) - typically 5-15 minutes..." INFO
        $dismLog = Join-Path (Split-Path $Script:LogFile) "dism-$VMName.log"
        $proc = Start-Process dism.exe -ArgumentList @(
            "/Apply-Image",
            "/ImageFile:$WimPath",
            "/Index:$ImageIndex",
            "/ApplyDir:${winDrive}:\",
            "/LogPath:$dismLog"
        ) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "[$VMName] DISM failed (exit $($proc.ExitCode)). See log: $dismLog"
        }
        Write-Log "[$VMName] Windows image applied." SUCCESS

        Write-UefiBootFiles -VMName $VMName -WinDrive $winDrive -EfiDrive $efiDrive

        $panther = "${winDrive}:\Windows\Panther"
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        (New-BuildUnattendXml -ComputerName $ComputerName -AdminPassword $Script:AdministratorPass) |
            Set-Content -Path "$panther\unattend.xml" -Encoding UTF8
        Write-Log "[$VMName] Answer file injected (local Administrator, RDP enabled)." SUCCESS
    }
    finally {
        Dismount-VHD -Path $OSDiskPath -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#  Wait for the guest to finish setup (PowerShell Direct over VMBus)
# ============================================================================
function Wait-VMReady {
    param([string]$VMName, [int]$TimeoutMinutes = 45)
    $cred = New-Object System.Management.Automation.PSCredential(
        $Script:AdministratorUser,
        (ConvertTo-SecureString $Script:AdministratorPass -AsPlainText -Force))
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "[$VMName] Waiting for Windows setup to finish (first boot can take a while)..." INFO
    while ((Get-Date) -lt $deadline) {
        try {
            $caption = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem).Caption
            } -ErrorAction Stop
            Write-Log "[$VMName] Guest is ready: $caption" SUCCESS
            return $cred
        } catch {
            Start-Sleep -Seconds 15
        }
    }
    throw "[$VMName] Timed out after $TimeoutMinutes minutes waiting for the guest."
}

# ============================================================================
#  Post-boot guest configuration - create VMAdmin, confirm RDP, static IP
# ============================================================================
function Set-GuestConfig {
    param(
        [string]$VMName,
        [System.Management.Automation.PSCredential]$Cred,
        [string]$NetMode,
        [string]$StaticIP
    )

    Write-Log "[$VMName] Creating '$Script:VMAdminUser' account and confirming Remote Desktop..." INFO
    Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock {
        param($user, $pass)
        $sec = ConvertTo-SecureString $pass -AsPlainText -Force
        if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $user -Password $sec
        } else {
            New-LocalUser -Name $user -Password $sec -FullName $user `
                -Description "BuildVM administrator" -PasswordNeverExpires -AccountNeverExpires | Out-Null
        }
        Add-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name fDenyTSConnections -Value 0 -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    } -ArgumentList $Script:VMAdminUser, $Script:VMAdminPass

    if ($NetMode -eq 'STATIC' -and $StaticIP) {
        $base = ($StaticIP -split '\.')[0..2] -join '.'
        $gw   = "$base.1"
        Write-Log "[$VMName] Assigning static IP $StaticIP (gateway $gw) for internet via NAT..." INFO
        Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock {
            param($ip, $prefix, $gw)
            $ad = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Loopback' } |
                  Sort-Object LinkSpeed -Descending | Select-Object -First 1
            Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $ad.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $ad.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses @('8.8.8.8','1.1.1.1')
        } -ArgumentList $StaticIP, $Script:FallbackPrefix, $gw
    }

    # Report the guest's active IPv4 address for the connection summary.
    try {
        $ip = Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock {
            (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1).IPAddress
        } -ErrorAction Stop
        return $ip
    } catch { return $null }
}

# ============================================================================
#  Build a single VM end-to-end
# ============================================================================
function New-SingleVM {
    param(
        [string]$VMName,
        [PSCustomObject]$Paths,
        [string]$WimPath,
        [int]$ImageIndex,
        [PSCustomObject]$Switch
    )

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "A VM named '$VMName' already exists. Choose a different name."
    }

    $computerName = ConvertTo-ComputerName $VMName
    $vmFolder     = Join-Path $Paths.VMPath $VMName
    $osDisk       = Join-Path $vmFolder "OSDisk.vhdx"
    if (-not (Test-Path $vmFolder)) { New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null }

    Write-Log "[$VMName] Creating $($Script:VMOSDiskGB) GB dynamic OS disk..." INFO
    New-VHD -Path $osDisk -SizeBytes ($Script:VMOSDiskGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null

    # Apply Windows to the disk BEFORE creating the VM shell.
    Install-WindowsToVHDX -VMName $VMName -ComputerName $computerName `
        -OSDiskPath $osDisk -WimPath $WimPath -ImageIndex $ImageIndex

    Write-Log "[$VMName] Creating the Generation-2 VM (2 vCPU, 4 GB RAM)..." INFO
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $Script:VMMemoryBytes `
        -VHDPath $osDisk -SwitchName $Switch.Name -Path $Paths.VMPath -ErrorAction Stop | Out-Null

    Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $Script:VMMemoryBytes -ErrorAction Stop
    Set-VMProcessor -VMName $VMName -Count $Script:VMCpuCount -ErrorAction Stop
    Set-VMFirmware  -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop

    $hardDisk = Get-VMHardDiskDrive   -VMName $VMName | Select-Object -First 1
    $netAdapt = Get-VMNetworkAdapter  -VMName $VMName
    Set-VMFirmware -VMName $VMName -BootOrder $hardDisk, $netAdapt -ErrorAction Stop

    Write-Log "[$VMName] Starting the VM..." INFO
    Start-VM -Name $VMName -ErrorAction Stop

    $cred     = Wait-VMReady -VMName $VMName
    $staticIP = if ($Switch.Mode -eq 'STATIC') { Get-NextFallbackIP } else { $null }
    $guestIP  = Set-GuestConfig -VMName $VMName -Cred $cred -NetMode $Switch.Mode -StaticIP $staticIP

    return [PSCustomObject]@{
        VMName       = $VMName
        ComputerName = $computerName
        Folder       = $vmFolder
        Switch       = $Switch.Name
        GuestIP      = $guestIP
    }
}

# ============================================================================
#  Connection summary
# ============================================================================
function Show-ConnectionInfo {
    param([PSCustomObject]$Info)
    Write-Banner "VM READY  -  $($Info.VMName)" 'Green'
    Write-Host "  Connect with Hyper-V Manager:" -ForegroundColor White
    Write-Host "     Open 'Hyper-V Manager' -> right-click '$($Info.VMName)' -> Connect" -ForegroundColor Cyan
    if ($Info.GuestIP) {
        Write-Host ""
        Write-Host "  Or connect with Remote Desktop (mstsc):" -ForegroundColor White
        Write-Host "     Computer: $($Info.GuestIP)" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Sign-in accounts (both are local administrators):" -ForegroundColor White
    Write-Host "     ------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "     Primary user   ->  Username: $Script:VMAdminUser" -ForegroundColor Green
    Write-Host "                        Password: $Script:VMAdminPass" -ForegroundColor Green
    Write-Host "     ------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "     Administrator  ->  Username: $Script:AdministratorUser" -ForegroundColor Yellow
    Write-Host "                        Password: $Script:AdministratorPass" -ForegroundColor Yellow
    Write-Host "     ------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Computer name : $($Info.ComputerName)" -ForegroundColor White
    Write-Host "  Internet      : via '$($Info.Switch)'" -ForegroundColor White
    Write-Host "  Disk (guest)  : single C:\ drive" -ForegroundColor White
    Write-Host "  Files on host : $($Info.Folder)" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
#  MAIN
# ============================================================================
Write-Banner "Build-VM  -  Windows Server 2025 VM Builder" 'Magenta'
Write-Host "  Builds internet-connected Hyper-V VMs for installing client VPNs." -ForegroundColor White
Write-Host "  Just answer the prompts - no parameters to remember." -ForegroundColor White

Test-Prerequisites

$paths  = Select-StorageRoot
$isoPath = Get-WindowsServerISO -ISOPath $paths.ISOPath

# Mount the ISO once and determine the Standard "Desktop Experience" image index.
Write-Banner "STEP 3 of 4  -  Preparing the Windows image" 'Cyan'
Write-Log "Mounting ISO to read image editions..." INFO
$mounted   = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
$builtVMs  = @()
try {
    $isoDrive = ($mounted | Get-Volume).DriveLetter
    $wimPath  = "${isoDrive}:\sources\install.wim"
    if (-not (Test-Path $wimPath)) { $wimPath = "${isoDrive}:\sources\install.esd" }
    if (-not (Test-Path $wimPath)) { throw "install.wim/install.esd not found on the ISO." }

    $images = Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop
    $target = $images | Where-Object { $_.ImageName -match 'Desktop Experience' -and $_.ImageName -match 'Standard' } | Select-Object -First 1
    if (-not $target) { $target = $images | Where-Object { $_.ImageName -match 'Desktop Experience' } | Select-Object -First 1 }
    if (-not $target) { $target = $images | Where-Object { $_.ImageIndex -eq 2 } | Select-Object -First 1 }
    if (-not $target) { $target = $images | Select-Object -First 1 }
    $imageIndex = [int]$target.ImageIndex
    Write-Log "Selected edition: $($target.ImageName) (index $imageIndex)" SUCCESS

    $switch = Resolve-InternetSwitch

    # -- Build loop ----------------------------------------------------------
    Write-Banner "STEP 4 of 4  -  Build VM(s)" 'Cyan'
    do {
        Write-Host ""
        $vmName = Read-NonEmpty "  What should this VM be named?"
        while (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            Write-Host "  A VM named '$vmName' already exists." -ForegroundColor Red
            $vmName = Read-NonEmpty "  Enter a different VM name"
        }

        Write-Log "Building '$vmName' - this runs mostly unattended." STEP
        try {
            $info = New-SingleVM -VMName $vmName -Paths $paths -WimPath $wimPath `
                        -ImageIndex $imageIndex -Switch $switch
            $builtVMs += $info
            Show-ConnectionInfo -Info $info
        } catch {
            Write-Log "Build of '$vmName' failed: $_" ERROR
            Write-Host "  You can try again with another name." -ForegroundColor Yellow
        }

        $again = Read-YesNo "  Build another VM?" $false
    } while ($again)
}
finally {
    Write-Log "Dismounting ISO..." INFO
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
}

# -- Final rollup ------------------------------------------------------------
if ($builtVMs.Count -gt 0) {
    Write-Banner "ALL DONE  -  $($builtVMs.Count) VM(s) built" 'Green'
    foreach ($v in $builtVMs) {
        $rdp = if ($v.GuestIP) { "  RDP: $($v.GuestIP)" } else { "" }
        Write-Host ("  - {0}  (login {1} / {2}){3}" -f $v.VMName, $Script:VMAdminUser, $Script:VMAdminPass, $rdp) -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Built-in Administrator password is also: $Script:AdministratorPass" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Log "No VMs were built." WARN
}
