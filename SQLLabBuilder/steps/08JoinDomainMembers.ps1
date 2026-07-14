#Requires -Version 5.1
<#
.SYNOPSIS
    Step 08 — Join SQLLAB-SQL1 and SQLLAB-SQL2 to sqllab.local.

    The join-and-confirm logic lives in Join-LabNodesToDomain in
    steps\_shared\LabFunctions.ps1 and is shared with AddCluster.ps1.

IDEMPOTENCY CHECKS:
    - Skips domain join if a VM already reports the correct domain.
    - Checkpoint step-08.done skips if both VMs are domain-joined.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared domain-join implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$localAdminCred  = New-Object System.Management.Automation.PSCredential("Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

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

Join-LabNodesToDomain -NodeSpecs @(
    @{ VMName = $SQL1VMName }
    @{ VMName = $SQL2VMName }
) -LocalAdminCred $localAdminCred -DomainAdminCred $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-08.done" SUCCESS
#endregion

Write-Log "Domain join complete for all SQL nodes." SUCCESS
