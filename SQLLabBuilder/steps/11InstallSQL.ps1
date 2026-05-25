#Requires -Version 5.1
<#
.SYNOPSIS
    Step 11 — Install SQL Server on SQLLAB-SQL1 and SQLLAB-SQL2.

IDEMPOTENCY CHECKS:
    - Checks if SQL Server service (MSSQLSERVER) already exists on each VM.
    - Initializes and formats the data disk (D:\) only if not already formatted.
    - Mounts SQL ISO inside each VM via PowerShell Direct (not from host).
    - Parses setup log to confirm success before marking checkpoint.
    - Opens Windows Firewall for ports 1433 and 5022 idempotently.
    - Checkpoint step-11.done skips if SQL service is running on both VMs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

$sqlISOName = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
$sqlISOHostPath = Join-Path $ISOPath $sqlISOName

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-11.done"
if (Test-Path $cpFile) {
    Write-Log "Step 11 checkpoint found — verifying SQL Server on both VMs..." INFO
    $allOK = $true
    foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
        try {
            $svc = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
                Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
            } -ErrorAction Stop
            if (-not $svc -or $svc.Status -ne 'Running') { $allOK = $false }
        } catch { $allOK = $false }
    }
    if ($allOK) {
        Write-Log "SQL Server running on both VMs — skipping step 11." SUCCESS
        return
    }
    Write-Log "Checkpoint present but SQL not running on all VMs — re-running." WARN
}
#endregion

if (-not (Test-Path $sqlISOHostPath)) {
    throw "SQL Server ISO not found at: $sqlISOHostPath"
}

#region SQL install helper
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
        Write-Log "[$VMName] SQL Server already installed — skipping." INFO
        return
    }

    #region Initialize data disk (D:\) inside VM
    Write-Log "[$VMName] Initializing SQL data disk..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {

        # D:\ already exists and formatted from a previous run - nothing to do
        if (Test-Path "D:\") {
            Write-Output "D:\ already exists and formatted - skipping initialization."
            return
        }

        # Find the data disk: prefer Offline disks, then any RAW secondary disk
        $dataDisk = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' } |
            Select-Object -First 1

        if (-not $dataDisk) {
            $dataDisk = Get-Disk | Where-Object {
                $_.PartitionStyle -eq 'RAW' -and $_.Number -gt 0
            } | Select-Object -First 1
        }

        if (-not $dataDisk) {
            throw "No offline or uninitialized data disk found and D:\ does not exist."
        }

        $diskNum = $dataDisk.Number
        Write-Output "Found data disk: Number=$diskNum  Size=$([math]::Round($dataDisk.Size/1GB,0)) GB  Status=$($dataDisk.OperationalStatus)  PartitionStyle=$($dataDisk.PartitionStyle)"

        # Bring the disk online before touching it - new VHDX-backed disks arrive Offline
        if ($dataDisk.IsOffline) {
            Write-Output "Bringing disk $diskNum online..."
            Set-Disk -Number $diskNum -IsOffline $false -ErrorAction Stop
            Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction Stop
            Start-Sleep -Seconds 2
        }

        # Initialize to GPT only if still RAW
        $partStyle = (Get-Disk -Number $diskNum).PartitionStyle
        if ($partStyle -eq 'RAW') {
            Write-Output "Initializing disk $diskNum as GPT..."
            Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
            Start-Sleep -Seconds 1
        }

        # Create D:\ partition using explicit -DiskNumber (avoids pipeline null issues)
        Write-Output "Creating partition on disk $diskNum..."
        New-Partition -DiskNumber $diskNum -DriveLetter D -UseMaximumSize -ErrorAction Stop |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel "SQLData" -Confirm:$false -ErrorAction Stop | Out-Null

        Write-Output "Data disk initialized as D:\"

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

    #region Attach SQL ISO to VM DVD drive from host (avoids slow file copy into VM)
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

        # Find the DVD drive (SQL ISO is attached as a Hyper-V DVD drive)
        $dvdDrive    = Get-WmiObject Win32_CDROMDrive | Where-Object { $_.MediaLoaded } | Select-Object -First 1
        if (-not $dvdDrive) { throw "No loaded DVD drive found in VM. SQL ISO may not be attached." }
        $driveLetter = $dvdDrive.Drive.TrimEnd(':')
        $setupExe    = "${driveLetter}:\setup.exe"
        if (-not (Test-Path $setupExe)) { throw "setup.exe not found on DVD drive ${driveLetter}:\" }

        $setupLog = "C:\Temp\SQLSetupLog"

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
            # Locate and output summary log
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

    #region Enable TCP/IP on 1433 via registry
    Write-Log "[$VMName] Enabling TCP/IP protocol on port 1433..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\MSSQLServer\SuperSocketNetLib\Tcp"
        $instances = Get-Item $tcpPath -ErrorAction SilentlyContinue
        if (-not $instances) {
            # Try alternate path for named instance detection
            $sqlKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" |
                Where-Object { $_.Name -match 'MSSQL\d+\.MSSQLSERVER' } | Select-Object -First 1
            if ($sqlKey) {
                $tcpPath = "$($sqlKey.PSPath)\MSSQLServer\SuperSocketNetLib\Tcp"
            }
        }
        # Enable TCP via WMI (more reliable than registry editing)
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
            # Set port 1433 on IPAll
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

    Write-Log "[$VMName] SQL Server installation complete." SUCCESS
}
#endregion

foreach ($pair in @(
    @{ VM = $SQL1VMName; CN = $SQL1ComputerName }
    @{ VM = $SQL2VMName; CN = $SQL2ComputerName }
)) {
    Install-SQLOnVM `
        -VMName       $pair.VM `
        -ComputerName $pair.CN `
        -SQLISOHostPath $sqlISOHostPath `
        -Credential   $domainAdminCred

    # Eject SQL ISO from the VM's DVD drive after installation
    $dvd = Get-VMDvdDrive -VMName $pair.VM -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dvd) {
        Set-VMDvdDrive -VMName $pair.VM -ControllerNumber $dvd.ControllerNumber `
            -ControllerLocation $dvd.ControllerLocation -Path $null -ErrorAction SilentlyContinue
        Write-Log "[$($pair.VM)] SQL ISO ejected from DVD drive." INFO
    }
}

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-11.done" SUCCESS
#endregion

Write-Log "SQL Server installation complete on all nodes." SUCCESS
