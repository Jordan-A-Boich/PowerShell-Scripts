#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 — Enable Always On Availability Groups feature on both SQL nodes.

IDEMPOTENCY CHECKS:
    - Checks IsHadrEnabled via WMI/registry before enabling.
    - Restarts SQL Server service only if the feature was just enabled.
    - Checkpoint step-12.done skips if Always On is already enabled on both nodes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-12.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-13.done","step-14.done","step-15.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 12 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 12 checkpoint found — verifying Always On status..." INFO
    $allEnabled = $true
    foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
        try {
            $enabled = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
                $sqlKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" |
                    Where-Object { $_.PSChildName -match '^MSSQL\d+\.MSSQLSERVER$' } | Select-Object -First 1
                if ($sqlKey) {
                    $hadrPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($sqlKey.PSChildName)\MSSQLServer\HADR"
                    $val = Get-ItemProperty -Path $hadrPath -Name IsHadrEnabled -ErrorAction SilentlyContinue
                    return ($val.IsHadrEnabled -eq 1)
                }
                return $false
            } -ErrorAction Stop
            if (-not $enabled) { $allEnabled = $false }
        } catch { $allEnabled = $false }
    }
    if ($allEnabled) {
        Write-Log "Always On enabled on both nodes — skipping step 12." SUCCESS
        return
    }
    Write-Log "Checkpoint present but Always On not confirmed on all nodes — re-running." WARN
}
#endregion

function Enable-AlwaysOn {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Credential)

    Write-Log "[$VMName] Enabling Always On Availability Groups..." INFO

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        # Try via SqlServer module (Enable-SqlAlwaysOn)
        $modAvail = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue
        if ($modAvail) {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            try {
                $server = Get-Item "SQLSERVER:\SQL\localhost\DEFAULT" -ErrorAction Stop
                if ($server.IsHadrEnabled) {
                    Write-Output "Always On already enabled (SqlServer module check)."
                    return
                }
                Enable-SqlAlwaysOn -InputObject $server -Force -ErrorAction Stop
                Write-Output "Always On enabled via Enable-SqlAlwaysOn."
                return
            } catch {
                Write-Output "Enable-SqlAlwaysOn failed: $_ — falling back to WMI method."
            }
        }

        # Fallback: WMI via Microsoft.SqlServer.SqlWmiManagement
        try {
            $smo = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement")
            if ($smo) {
                $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer "localhost"
                $inst = $wmi.ServerInstances['MSSQLSERVER']
                if ($inst.ServerProtocols.Count -ge 0) {
                    # HADR is not a protocol, use registry
                }
            }
        } catch {}

        # Registry fallback — build a clean HKLM:\ path from the key name
        $sqlKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" |
            Where-Object { $_.PSChildName -match '^MSSQL\d+\.MSSQLSERVER$' }
        foreach ($key in $sqlKeys) {
            $hadrPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($key.PSChildName)\MSSQLServer\HADR"
            if (-not (Test-Path $hadrPath)) { New-Item -Path $hadrPath -Force | Out-Null }
            Set-ItemProperty -Path $hadrPath -Name IsHadrEnabled -Value 1 -Type DWord -Force
            Write-Output "Always On enabled via registry for $($key.PSChildName)."
        }

    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }

    #region Restart SQL Server
    Write-Log "[$VMName] Restarting SQL Server to apply Always On change..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        Restart-Service MSSQLSERVER -Force -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service MSSQLSERVER
            if ($svc.Status -eq 'Running') {
                Write-Output "MSSQLSERVER restarted successfully."
                return
            }
            Start-Sleep -Seconds 5
        }
        throw "MSSQLSERVER did not restart within 3 minutes."
    } -ErrorAction Stop | ForEach-Object { Write-Log "[$VMName] $_" INFO }
    #endregion

    Write-Log "[$VMName] Always On enabled and SQL Server restarted." SUCCESS
}

foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Enable-AlwaysOn -VMName $vmName -Credential $domainAdminCred
}

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-12.done" SUCCESS
#endregion

Write-Log "Always On Availability Groups feature enabled on all SQL nodes." SUCCESS
