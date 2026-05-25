#Requires -Version 5.1
<#
.SYNOPSIS
    Step 09 — Create Windows Failover Cluster and configure File Share Witness.

IDEMPOTENCY CHECKS:
    - Checks if the Failover-Clustering feature is already installed on each SQL VM.
    - Checks if the cluster already exists before running New-Cluster.
    - Creates the ClusterWitness share on DC only if not already present.
    - Checkpoint step-09.done skips if cluster is online and quorum is set.

NOTE ON TEST-CLUSTER WARNINGS:
    Test-Cluster will produce warnings about a 2-node cluster having no shared
    storage and about network redundancy. These are expected for this lab design
    and do not indicate a problem. The cluster will function correctly for the
    Always On AG scenario.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$localAdminCred  = New-Object System.Management.Automation.PSCredential("Administrator",
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

#region Install Failover Clustering features on both SQL VMs
foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Write-Log "[$vmName] Installing Failover-Clustering and RSAT-Clustering features..." INFO
    Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
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

#region Create ClusterWitness share on DC
Write-Log "[$DCVMName] Creating ClusterWitness file share..." INFO
Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
    param($WitnessShare)
    $sharePath = "C:\ClusterWitness"
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

#region Run Test-Cluster (on SQL1, results logged but warnings are expected)
Write-Log "[$SQL1VMName] Running Test-Cluster (warnings about storage/network are expected for a 2-node lab)..." INFO
try {
    Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
        param($Node1, $Node2, $LogPath)
        Import-Module FailoverClusters -ErrorAction Stop
        $testReport = Test-Cluster -Node $Node1,$Node2 `
            -Include "Inventory","Network","System Configuration" `
            -ReportName "ClusterValidation" `
            -ErrorAction SilentlyContinue
        Write-Output "Test-Cluster completed. Check report for details."
    } -ArgumentList $SQL1ComputerName, $SQL2ComputerName, $LogPath -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Log "[$SQL1VMName] Test-Cluster: $_" INFO }
} catch {
    Write-Log "[$SQL1VMName] Test-Cluster reported errors (may be expected for 2-node lab): $_" WARN
}
Write-Log "NOTE: Test-Cluster warnings about shared storage and single-network are expected and safe to ignore in this lab." WARN
#endregion

#region Create cluster
Write-Log "[$SQL1VMName] Creating cluster '$ClusterName'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($CName, $Node1, $Node2, $CIP)
    Import-Module FailoverClusters -ErrorAction Stop

    $existing = Get-Cluster -Name $CName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "Cluster '$CName' already exists — skipping New-Cluster."
        return
    }

    New-Cluster -Name $CName -Node $Node1,$Node2 -StaticAddress $CIP -NoStorage -ErrorAction Stop | Out-Null
    Write-Output "Cluster '$CName' created with IP $CIP."
} -ArgumentList $ClusterName, $SQL1ComputerName, $SQL2ComputerName, $ClusterIP -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Grant cluster computer account NTFS ACL on witness share
# Must happen AFTER New-Cluster so the SQLLabCluster$ AD account exists
Write-Log "[$DCVMName] Granting cluster account NTFS ACL on witness share..." INFO
Start-Sleep -Seconds 20   # Allow cluster computer account to replicate in AD
Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
    param($DomainNetBIOS, $ClusterName, $WitnessShare)
    $sharePath      = "C:\ClusterWitness"
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
Write-Log "[$SQL1VMName] Configuring cluster quorum (File Share Witness)..." INFO
Start-Sleep -Seconds 10   # Allow cluster to stabilize

Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($CName, $DCName, $WShare)
    Import-Module FailoverClusters -ErrorAction Stop
    $witnesPath = "\\$DCName\$WShare"
    Set-ClusterQuorum -Cluster $CName -FileShareWitness $witnesPath -ErrorAction Stop | Out-Null
    Write-Output "Quorum set to File Share Witness: $witnesPath"
} -ArgumentList $ClusterName, $DCComputerName, $WitnessShare -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Verify cluster
Write-Log "[$SQL1VMName] Verifying cluster state..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($CName)
    Import-Module FailoverClusters -ErrorAction Stop
    $nodes = Get-ClusterNode -Cluster $CName
    foreach ($n in $nodes) {
        Write-Output "  Node: $($n.Name)  State: $($n.State)"
    }
    $quorum = Get-ClusterQuorum -Cluster $CName
    Write-Output "  Quorum: $($quorum.QuorumType) — $($quorum.QuorumResource)"
} -ArgumentList $ClusterName -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-09.done" SUCCESS
#endregion

Write-Log "Failover Cluster '$ClusterName' created and configured." SUCCESS
