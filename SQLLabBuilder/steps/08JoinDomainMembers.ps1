#Requires -Version 5.1
<#
.SYNOPSIS
    Step 08 — Join SQLLAB-SQL1 and SQLLAB-SQL2 to sqllab.local.

IDEMPOTENCY CHECKS:
    - Checks the domain membership of each SQL VM before attempting a join.
    - Skips domain join if VM already reports correct domain.
    - Polls until each VM is back online and confirming domain membership.
    - Checkpoint step-08.done skips if both VMs are domain-joined.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$localAdminCred  = New-Object System.Management.Automation.PSCredential("Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-08.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-09.done","step-10.done","step-11.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 08 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 08 checkpoint found — verifying domain membership..." INFO
    $allJoined = $true
    foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
        try {
            $dom = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
                (Get-WmiObject Win32_ComputerSystem).Domain
            } -ErrorAction Stop
            if ($dom -ne $DomainName) { $allJoined = $false }
        } catch { $allJoined = $false }
    }
    if ($allJoined) {
        Write-Log "Both SQL VMs confirmed domain-joined. Skipping step 08." SUCCESS
        return
    }
    Write-Log "Checkpoint present but domain join incomplete — re-running." WARN
}
#endregion

#region Helper: wait for PS Direct
function Wait-VMReachable {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Cred, [int]$Mins = 15)
    $deadline = (Get-Date).AddMinutes($Mins)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null
            return
        } catch { Start-Sleep -Seconds 10 }
    }
    throw "[$VMName] PowerShell Direct unreachable after $Mins minutes."
}
#endregion

foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Write-Log "[$vmName] Checking current domain membership..." INFO
    Wait-VMReachable -VMName $vmName -Cred $localAdminCred -Mins 10

    $currentDomain = Invoke-Command -VMName $vmName -Credential $localAdminCred -ScriptBlock {
        (Get-WmiObject Win32_ComputerSystem).Domain
    } -ErrorAction Stop

    if ($currentDomain -eq $DomainName) {
        Write-Log "[$vmName] Already joined to '$DomainName' — skipping." INFO
        continue
    }

    Write-Log "[$vmName] Current domain: '$currentDomain'. Joining '$DomainName'..." INFO

    try {
        Invoke-Command -VMName $vmName -Credential $localAdminCred -ScriptBlock {
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

#region Wait for SQL VMs to come back as domain members
Write-Log "Waiting for SQL VMs to reboot and confirm domain membership..." INFO
Start-Sleep -Seconds 30

foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    $deadline  = (Get-Date).AddMinutes(15)
    $confirmed = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $dom = Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
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
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-08.done" SUCCESS
#endregion

Write-Log "Domain join complete for all SQL nodes." SUCCESS
