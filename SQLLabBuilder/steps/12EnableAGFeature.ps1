#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 - Enable Always On Availability Groups feature on both SQL nodes.

    The per-node enable (bring D:\ online, write the HADR registry key, call
    ChangeHadrServiceSetting, clean-restart SQL, verify IsHadrEnabled) plus the
    Agent XPs / SQL Agent startup lives in Enable-AlwaysOn / Enable-LabAlwaysOn in
    steps\_shared\LabFunctions.ps1 and is shared with AddCluster.ps1.

IDEMPOTENCY CHECKS:
    - Verifies via SERVERPROPERTY('IsHadrEnabled') - actual SQL runtime state.
    - When later steps are done, runs a resume-recovery pass (bring disks/services
      back after a VM restart) instead of re-enabling.
    - Checkpoint step-12.done skips only if SQL confirms Always On enabled on both nodes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared Always-On implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-12.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-13.done","step-14.done","step-15.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 12 checkpoint found and later steps confirmed - verifying SQL nodes are healthy after VM resume..." INFO

        $resumeRecoveryBlock = {
            $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not ($vol -and $vol.FileSystem -eq 'NTFS' -and (Test-Path 'D:\'))) {
                Write-Output 'D:\ not accessible - locating and bringing data disk online...'
                $wmiDisk = Get-WmiObject -Class Win32_DiskDrive |
                    Where-Object { $_.Index -gt 0 } | Sort-Object Index | Select-Object -First 1
                if (-not $wmiDisk) { throw 'No secondary data disk found via Win32_DiskDrive.' }
                $diskNum = [int]$wmiDisk.Index
                $disk = Get-Disk -Number $diskNum -ErrorAction Stop
                if ($disk.IsOffline) {
                    Set-Disk -Number $diskNum -IsOffline $false -ErrorAction Stop
                    Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction SilentlyContinue
                }
                Set-StorageSetting -NewDiskPolicy OnlineAll -ErrorAction SilentlyContinue
                $waited = 0
                while (-not (Test-Path 'D:\') -and $waited -lt 30) {
                    Start-Sleep -Seconds 3; $waited += 3
                }
                if (-not (Test-Path 'D:\')) { throw 'D:\ not accessible after bring-online attempt.' }
                Write-Output "D:\ brought online (waited ${waited}s)."
            } else {
                Write-Output 'D:\ already online.'
            }

            foreach ($sqlDir in @('D:\SQLData','D:\SQLLog','D:\SQLBackup','D:\SQLTemp')) {
                if (-not (Test-Path $sqlDir)) {
                    New-Item -ItemType Directory -Path $sqlDir -Force | Out-Null
                    Write-Output "Recreated missing directory: $sqlDir"
                }
            }

            $clusSvc = Get-Service ClusSvc -ErrorAction SilentlyContinue
            if ($clusSvc -and $clusSvc.Status -ne 'Running') {
                Write-Output 'ClusSvc stopped - starting...'
                Start-Service ClusSvc -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 8
                Write-Output "ClusSvc status: $((Get-Service ClusSvc -ErrorAction SilentlyContinue).Status)"
            } else {
                Write-Output "ClusSvc: $($clusSvc.Status)"
            }

            $sqlSvc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
            if (-not $sqlSvc) { throw 'MSSQLSERVER service not found - verify step 11 completed.' }
            if ($sqlSvc.Status -ne 'Running') {
                Write-Output "MSSQLSERVER is '$($sqlSvc.Status)' - starting..."
                Start-Service MSSQLSERVER -ErrorAction Stop
                $sqlDeadline = (Get-Date).AddMinutes(2)
                while ((Get-Date) -lt $sqlDeadline) {
                    Start-Sleep -Seconds 5
                    $sqlStatus = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status
                    if ($sqlStatus -eq 'Running') { Write-Output 'MSSQLSERVER started.'; break }
                    Write-Output "Waiting for MSSQLSERVER ($sqlStatus)..."
                }
                if ((Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status -ne 'Running') {
                    throw 'MSSQLSERVER did not reach Running state within 2 minutes.'
                }
            } else {
                Write-Output 'MSSQLSERVER already running.'
            }

            $agentSvc = Get-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
            if ($agentSvc -and $agentSvc.Status -ne 'Running') {
                Write-Output 'SQLSERVERAGENT stopped - starting...'
                Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
                Write-Output "SQLSERVERAGENT status: $((Get-Service SQLSERVERAGENT -ErrorAction SilentlyContinue).Status)"
            } elseif ($agentSvc) {
                Write-Output 'SQLSERVERAGENT already running.'
            }
        }

        foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
            Write-Log "[$vmName] Checking data disk and SQL Server health..." INFO
            try {
                $nodeOutput = Invoke-Command -VMName $vmName -Credential $domainAdminCred `
                    -ScriptBlock $resumeRecoveryBlock -ErrorAction Stop
                $nodeOutput | ForEach-Object { Write-Log "[$vmName] $_" INFO }
                Write-Log "[$vmName] SQL node healthy." SUCCESS
            } catch {
                Write-Log "[$vmName] Recovery warning: $_ - if SQL is still down, re-run the script." WARN
            }
        }

        Write-Log 'Step 12 skipped - SQL node recovery complete.' SUCCESS
        return
    }

    Write-Log 'Step 12 checkpoint found - verifying Always On runtime state via SQL...' INFO
    $allEnabled = $true
    foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
        try {
            $result = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
                $deadline = (Get-Date).AddSeconds(30)
                $val = $null
                while ($null -eq $val -and (Get-Date) -lt $deadline) {
                    foreach ($cs in @(
                        'Server=lpc:localhost;Database=master;Integrated Security=True;Connect Timeout=5',
                        'Server=tcp:localhost,1433;Database=master;Integrated Security=True;Connect Timeout=5'
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
        Write-Log 'Always On confirmed active on both nodes - skipping step 12.' SUCCESS
        return
    }
    Write-Log 'Checkpoint present but Always On not active on all nodes - re-running.' WARN
}
#endregion

Enable-LabAlwaysOn -Node1VMName $SQL1VMName -Node2VMName $SQL2VMName -Credential $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log 'Checkpoint written: step-12.done' SUCCESS
#endregion

Write-Log 'Always On Availability Groups feature enabled on all SQL nodes.' SUCCESS
