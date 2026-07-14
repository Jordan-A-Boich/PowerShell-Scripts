#Requires -Version 5.1
<#
.SYNOPSIS
    Step 09 — Create Windows Failover Cluster and configure File Share Witness.

    The full cluster build (install clustering features, create the witness share on
    the DC, Test-Cluster, New-Cluster with retries, grant the cluster account ACL,
    set the File Share Witness quorum, verify) lives in New-LabWSFC in
    steps\_shared\LabFunctions.ps1 and is shared with AddCluster.ps1 — so every
    Windows Failover Cluster in the lab is built identically.

IDEMPOTENCY CHECKS:
    - Checkpoint step-09.done skips if the cluster already exists and is online.

NOTE ON TEST-CLUSTER WARNINGS:
    Test-Cluster warns about a 2-node cluster having no shared storage and about
    network redundancy. These are expected for this lab design and do not indicate
    a problem.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared cluster implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-09.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-10.done","step-11.done","step-12.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 09 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 09 checkpoint found — verifying cluster..." INFO
    try {
        $clusterState = Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
            Import-Module FailoverClusters -ErrorAction Stop
            $c = Get-Cluster -Name $using:ClusterName -ErrorAction Stop
            return $c.Name
        } -ErrorAction Stop
        Write-Log "Cluster '$clusterState' verified. Skipping step 09." SUCCESS
        return
    } catch { Write-Log "Checkpoint check failed — re-running step 09." WARN }
}
#endregion

New-LabWSFC `
    -ClusterName     $ClusterName `
    -ClusterIP       $ClusterIP `
    -Node1VMName     $SQL1VMName `
    -Node1Computer   $SQL1ComputerName `
    -Node2VMName     $SQL2VMName `
    -Node2Computer   $SQL2ComputerName `
    -WitnessShare    $WitnessShare `
    -DCVMName        $DCVMName `
    -DCComputer      $DCComputerName `
    -DomainAdminCred $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-09.done" SUCCESS
#endregion

Write-Log "Failover Cluster '$ClusterName' created and configured." SUCCESS
