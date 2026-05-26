#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 - Enable Always On Availability Groups feature on both SQL nodes.

IDEMPOTENCY CHECKS:
    - Verifies via SERVERPROPERTY('IsHadrEnabled') - actual SQL runtime state.
    - Brings D:\ data disk online if it went offline after VM restart.
    - Starts SQL Server if not running before calling dbatools.
    - Writes HADR registry key and calls ChangeHadrServiceSetting via Invoke-WmiMethod
      (the correct invocation path - dot-notation on ManagementObject does not work).
    - Checkpoint step-12.done skips only if SQL confirms Always On enabled on both nodes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-12.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-13.done","step-14.done","step-15.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 12 checkpoint found and later steps confirmed - skipping." SUCCESS
        return
    }

    Write-Log "Step 12 checkpoint found - verifying Always On runtime state via SQL..." INFO
    $allEnabled = $true
    foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
        try {
            $result = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
                # Try shared memory first (faster post-restart), then TCP.
                # Retry up to 30 s to handle transient timing after a prior run's SQL restart.
                $deadline = (Get-Date).AddSeconds(30)
                $val = $null
                while ($null -eq $val -and (Get-Date) -lt $deadline) {
                    foreach ($cs in @(
                        "Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5",
                        "Server=tcp:localhost,1433;Database=master;Integrated Security=True;Connect Timeout=5"
                    )) {
                        try {
                            $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
                            $conn.Open()
                            $cmd = $conn.CreateCommand()
                            $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS INT)"
                            $v = $cmd.ExecuteScalar()
                            $conn.Close()
                            if ($null -ne $v) { $val = $v; break }
                        } catch { }
                    }
                    if ($null -eq $val) { Start-Sleep -Seconds 5 }
                }
                return $val
            } -ErrorAction Stop
            if ($result -ne 1) { $allEnabled = $false }
        } catch { $allEnabled = $false }
    }
    if ($allEnabled) {
        Write-Log "Always On confirmed active on both nodes - skipping step 12." SUCCESS
        return
    }
    Write-Log "Checkpoint present but Always On not active on all nodes - re-running." WARN
}
#endregion

function Enable-AlwaysOn {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Credential)

    # Fast-path: if HADR is already active on this node, skip the full enable+restart.
    $alreadyOn = $false
    try {
        $alreadyOn = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            try {
                $conn = New-Object System.Data.SqlClient.SqlConnection(
                    "Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5")
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
            Write-Output "D:\ already online (NTFS, $([math]::Round($vol.Size/1GB,0)) GB)."
            Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
        } else {
            Write-Output "D:\ not accessible - locating and bringing data disk online..."
            $wmiDisk = Get-WmiObject -Class Win32_DiskDrive |
                Where-Object { $_.Index -gt 0 } | Sort-Object Index | Select-Object -First 1
            if (-not $wmiDisk) { throw "No secondary data disk found via Win32_DiskDrive." }
            $diskNum = [int]$wmiDisk.Index
            Write-Output "Data disk: WMI Index=$diskNum  Size=$([math]::Round([long]$wmiDisk.Size/1GB,0)) GB"
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
                throw "D:\ not accessible after bring-online attempt."
            }
            Write-Output "D:\ now online, waited ${waited}s."
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Write HADR registry key and call ChangeHadrServiceSetting via Invoke-WmiMethod
    Write-Log "[$VMName] Writing HADR registry key and enabling via WMI..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        if (-not (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue)) {
            throw "MSSQLSERVER service not found - verify step 11 completed."
        }

        # Derive the instance registry key from the service executable path.
        $svcObj = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
        $instanceKey = $null
        if ($svcObj.PathName -match '\\(MSSQL\d+\.MSSQLSERVER)\\') {
            $instanceKey = $Matches[1]
        }
        if (-not $instanceKey) {
            $sqlKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' |
                Where-Object { $_.Name -match '\\MSSQL\d+\.MSSQLSERVER$' } |
                Sort-Object Name -Descending | Select-Object -First 1
            if (-not $sqlKey) { throw "SQL Server instance registry key not found." }
            $instanceKey = $sqlKey.PSChildName
        }
        Write-Output "SQL Server instance key: $instanceKey"

        # Write registry key
        $hadrPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceKey\MSSQLServer\HADR"
        if (-not (Test-Path $hadrPath)) { New-Item -Path $hadrPath -Force | Out-Null }
        Set-ItemProperty -Path $hadrPath -Name 'IsHadrEnabled' -Value 1 -Type DWord -Force
        Write-Output "HADR IsHadrEnabled=1 written at $instanceKey\MSSQLServer\HADR."

        $verNum = if ($instanceKey -match 'MSSQL(\d+)\.') { [int]$Matches[1] } else { 17 }
        $cmNs   = "ROOT\Microsoft\SqlServer\ComputerManagement$verNum"
        Write-Output "SQL WMI namespace: $cmNs"

        # Dump advanced properties for diagnostics
        try {
            $allProps = @(Get-WmiObject -Namespace $cmNs -Class SqlServiceAdvancedProperty `
                -Filter "ServiceName='MSSQLSERVER'" -ErrorAction Stop)
            if ($allProps.Count -gt 0) {
                foreach ($p in $allProps) {
                    Write-Output "  Prop[$($p.PropertyName)] Num=$($p.PropertyNumValue) Str='$($p.PropertyStrValue)'"
                }
            } else {
                Write-Output "  No SqlServiceAdvancedProperty entries found for MSSQLSERVER."
            }
        } catch {
            Write-Output "  SqlServiceAdvancedProperty query failed: $($_.Exception.Message -replace '\r?\n.*','')"
        }

        # PRIMARY: Invoke-WmiMethod - the correct way to call WMI methods on ManagementObject.
        # Dot-notation (e.g. $obj.ChangeHadrServiceSetting(1)) does NOT work on ManagementObject
        # instances returned by Get-WmiObject - the method simply does not exist on the .NET
        # wrapper type, even though it exists on the WMI class itself.
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
                Write-Output "HADR enabled via WMI ChangeHadrServiceSetting."
            } else {
                Write-Output "ChangeHadrServiceSetting returned non-zero: $($chResult.ReturnValue) - will try SMO fallback."
            }
        } catch {
            Write-Output "Invoke-WmiMethod ChangeHadrServiceSetting error: $($_.Exception.Message -replace '\r?\n.*','')"
        }

        # FALLBACK 1: InvokeMethod via ManagementObject directly (works on some SQL/OS combos
        # where Invoke-WmiMethod cannot locate the instance via -Filter alone).
        if (-not $wmiSet) {
            try {
                $sqlSvcWmi = Get-WmiObject -Namespace $cmNs -Class SqlService `
                    -Filter "ServiceName='MSSQLSERVER'" -ErrorAction Stop
                if ($sqlSvcWmi) {
                    $inParams = $sqlSvcWmi.GetMethodParameters("ChangeHadrServiceSetting")
                    $inParams["HADREnabled"] = [uint32]1
                    $chResult2 = $sqlSvcWmi.InvokeMethod("ChangeHadrServiceSetting", $inParams, $null)
                    Write-Output "ManagementObject.InvokeMethod ChangeHadrServiceSetting ReturnValue: $($chResult2.ReturnValue)"
                    if ($chResult2.ReturnValue -eq 0) {
                        $wmiSet = $true
                        Write-Output "HADR enabled via ManagementObject.InvokeMethod."
                    }
                } else {
                    Write-Output "SqlService WMI object not found in $cmNs for fallback 1."
                }
            } catch {
                Write-Output "ManagementObject.InvokeMethod error: $($_.Exception.Message -replace '\r?\n.*','')"
            }
        }

        # FALLBACK 2: SMO ManagedComputer
        if (-not $wmiSet) {
            try {
                $smo = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement")
                if ($smo) {
                    $mc     = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer "localhost"
                    $svcSMO = $mc.Services['MSSQLSERVER']
                    if ($svcSMO) {
                        # HadrManagerStatus enum value 1 = Running (enabled)
                        $svcSMO.ChangeHadrServiceSetting(1)
                        Write-Output "HADR enabled via SMO ManagedComputer.ChangeHadrServiceSetting."
                        $wmiSet = $true
                    } else {
                        Write-Output "SMO: MSSQLSERVER not found in ManagedComputer.Services."
                    }
                } else {
                    Write-Output "SMO WMI assembly could not be loaded."
                }
            } catch {
                Write-Output "SMO ChangeHadrServiceSetting error: $($_.Exception.Message -replace '\r?\n.*','')"
            }
        }

        # FALLBACK 3: sqlservr.exe -f startup to force HADR flag via T-SQL (last resort).
        # If all WMI/SMO paths failed, the registry key alone may be enough on SQL 2019+
        # but we warn loudly so the operator knows to investigate.
        if (-not $wmiSet) {
            Write-Output "WARN: All WMI/SMO ChangeHadrServiceSetting methods failed."
            Write-Output "WARN: Registry key IsHadrEnabled=1 is written - SQL 2019+ reads this on start."
            Write-Output "WARN: If HADR does not activate, verify sqlsvc account permissions and WMI provider health."
        }
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Stop SQL if running, verify D:\, then do one clean start with HADR
    Write-Log "[$VMName] Restarting MSSQLSERVER with HADR enabled..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') {
            Write-Output "Stopping MSSQLSERVER (was running)..."
            Stop-Service MSSQLSERVER -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
        } else {
            Write-Output "MSSQLSERVER already stopped."
        }

        Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
        $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue | Select-Object -First 1
        $dAccessible = ($vol -and $vol.FileSystem -eq 'NTFS') -and (Test-Path 'D:\')
        if (-not $dAccessible) {
            Write-Output "D:\ not accessible after service stop - bringing back online..."
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
            if (-not (Test-Path 'D:\')) { throw "D:\ not accessible after bring-online attempt." }
            Write-Output "D:\ restored, waited ${waited}s."
        } else {
            Write-Output "D:\ online."
        }

        # Ensure SQL data directories exist
        foreach ($dir in @('D:\SQLData','D:\SQLLog','D:\SQLBackup','D:\SQLTemp')) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Output "Created missing directory: $dir"
            }
        }

        # Ensure ClusSvc is running and node is Up before starting SQL
        $clusSvc = Get-Service ClusSvc -ErrorAction SilentlyContinue
        if ($clusSvc) {
            if ($clusSvc.Status -ne 'Running') {
                Write-Output "ClusSvc stopped - starting..."
                Start-Service ClusSvc -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 8
            }
            Write-Output "ClusSvc status: $((Get-Service ClusSvc -ErrorAction SilentlyContinue).Status)"

            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            $clNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
            if ($clNode) {
                Write-Output "Cluster node $($clNode.Name): State=$($clNode.State)"
                if ($clNode.State -eq 'Paused') {
                    Write-Output "Node is Paused - resuming before SQL start..."
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
            Write-Output "ClusSvc not found - WSFC may not be configured."
        }

        Write-Output "Starting MSSQLSERVER..."
        Start-Service MSSQLSERVER -ErrorAction Stop
        Write-Output "MSSQLSERVER start initiated."
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Wait for MSSQLSERVER to reach Running state
    Write-Log "[$VMName] Waiting for MSSQLSERVER to reach Running state (up to 1 min)..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $deadline = (Get-Date).AddMinutes(1)
        while ((Get-Date) -lt $deadline) {
            $status = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status
            if ($status -eq 'Running') { Write-Output "MSSQLSERVER running."; return }
            Write-Output "MSSQLSERVER status: $status - waiting..."
            Start-Sleep -Seconds 5
        }
        throw "MSSQLSERVER did not reach Running state within 1 minute."
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    #region Verify Always On is active via SERVERPROPERTY
    # Shared Memory (lpc:) is ready before TCP - critical on low-RAM VMs.
    Write-Log "[$VMName] Verifying Always On via SERVERPROPERTY..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $deadline   = (Get-Date).AddMinutes(8)
        $result     = $null
        $connUsed   = $null
        $retryCount = 0

        while ((Get-Date) -lt $deadline) {
            $svcStatus = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status
            if ($svcStatus -ne 'Running') {
                $errLog = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\MSSQL\LOG\ERRORLOG' `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($errLog) {
                    Write-Output "--- ERRORLOG TAIL ---"
                    Get-Content $errLog.FullName -Tail 40 -ErrorAction SilentlyContinue |
                        ForEach-Object { Write-Output $_ }
                    Write-Output "--- END ERRORLOG ---"
                }
                throw "MSSQLSERVER stopped while waiting for connections (status: $svcStatus) - SQL crashed."
            }

            $lastErr = $null
            foreach ($cs in @(
                "Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5",
                "Server=tcp:localhost,1433;Database=master;Integrated Security=True;Connect Timeout=5"
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

            $retryCount++

            # On first retry: dump registry state, cluster state, and ERRORLOG to diagnose
            # why HADR did not activate. The ERRORLOG is the definitive source - look for
            # "Always On Availability Groups: Starting" or its absence.
            if ($retryCount -eq 1) {
                $svcDiag = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue
                if ($svcDiag -and $svcDiag.PathName -match '\\(MSSQL\d+\.MSSQLSERVER)\\') {
                    $diagKey = $Matches[1]
                    $diagReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$diagKey\MSSQLServer\HADR" `
                        -ErrorAction SilentlyContinue
                    Write-Output "Registry: $diagKey\MSSQLServer\HADR\IsHadrEnabled = $($diagReg.IsHadrEnabled)"

                    # Also dump the WMI HADR state so we can see if ChangeHadrServiceSetting took effect
                    $verNum2 = if ($diagKey -match 'MSSQL(\d+)\.') { [int]$Matches[1] } else { 17 }
                    $cmNs2   = "ROOT\Microsoft\SqlServer\ComputerManagement$verNum2"
                    try {
                        $wmiHadr = Invoke-WmiMethod `
                            -Namespace $cmNs2 `
                            -Class SqlService `
                            -Name "GetHadrServiceSetting" `
                            -Filter "ServiceName='MSSQLSERVER'" `
                            -ErrorAction Stop
                        Write-Output "WMI GetHadrServiceSetting ReturnValue=$($wmiHadr.ReturnValue) HADREnabled=$($wmiHadr.HADREnabled)"
                    } catch {
                        Write-Output "WMI GetHadrServiceSetting not available: $($_.Exception.Message -replace '\r?\n.*','')"
                    }
                }

                Import-Module FailoverClusters -ErrorAction SilentlyContinue
                $diagNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
                if ($diagNode) {
                    Write-Output "Cluster node $($diagNode.Name): State=$($diagNode.State)"
                } else {
                    Write-Output "Cluster node: not found in cluster"
                }

                $logPath = $null
                if ($svcDiag -and $svcDiag.PathName -match '\\(MSSQL\d+\.MSSQLSERVER)\\') {
                    $logPath = "C:\Program Files\Microsoft SQL Server\$($Matches[1])\MSSQL\Log\ERRORLOG"
                }
                if (-not $logPath -or -not (Test-Path $logPath)) {
                    $logPath = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\MSSQL\Log\ERRORLOG' `
                        -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
                        Select-Object -First 1 -ExpandProperty FullName
                }
                if ($logPath -and (Test-Path $logPath)) {
                    Write-Output "--- ERRORLOG ($logPath) ---"
                    Get-Content $logPath -ErrorAction SilentlyContinue |
                        Select-Object -First 120 | ForEach-Object { Write-Output $_ }
                    Write-Output "--- END ERRORLOG ---"
                }
            }

            Write-Output "SQL state (svc=$svcStatus) - $lastErr - retrying in 5 s..."
            Start-Sleep -Seconds 5
        }

        if ($null -eq $result) {
            # Final ERRORLOG dump before throwing so the operator has full context
            $errLog = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\MSSQL\Log\ERRORLOG' `
                -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($errLog) {
                Write-Output "--- FINAL ERRORLOG DUMP ---"
                Get-Content $errLog.FullName -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Output $_ }
                Write-Output "--- END FINAL ERRORLOG DUMP ---"
            }
            throw "Could not confirm HADR active on SQL (Shared Memory or TCP) within 8 min."
        }

        Write-Output "Always On confirmed active (IsHadrEnabled=$result) via $connUsed."
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    Write-Log "[$VMName] Always On enabled and verified." SUCCESS
}

$nodeList = @($SQL1VMName, $SQL2VMName)
for ($i = 0; $i -lt $nodeList.Count; $i++) {
    Enable-AlwaysOn -VMName $nodeList[$i] -Credential $domainAdminCred
    if ($i -lt $nodeList.Count - 1) {
        Write-Log "Pausing 20 s for cluster to stabilize between nodes..." INFO
        Start-Sleep -Seconds 20
    }
}

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-12.done" SUCCESS
#endregion

Write-Log "Always On Availability Groups feature enabled on all SQL nodes." SUCCESS