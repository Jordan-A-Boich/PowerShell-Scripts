#Requires -Version 5.1
<#
.SYNOPSIS
    Step 11 — Install SQL Server on SQLLAB-SQL1 and SQLLAB-SQL2.

    The per-node install (initialize the data disk, attach the SQL ISO, run silent
    setup, enable TCP/1433, open the firewall, start SQL + Agent) lives in
    Install-SQLOnVM / Install-LabSQLNodes in steps\_shared\LabFunctions.ps1 and is
    shared with AddCluster.ps1.

IDEMPOTENCY CHECKS:
    - Skips a node whose MSSQLSERVER service already exists.
    - Checkpoint step-11.done skips if SQL is running on both VMs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared SQL-install implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

$sqlISOName = switch ($global:SQLVersion) { "2019" { $SQL2019ISOName } "2025" { $SQL2025ISOName } default { $SQL2022ISOName } }
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

Install-LabSQLNodes -NodeSpecs @(
    @{ VMName = $SQL1VMName; ComputerName = $SQL1ComputerName }
    @{ VMName = $SQL2VMName; ComputerName = $SQL2ComputerName }
) -SQLISOHostPath $sqlISOHostPath -Credential $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-11.done" SUCCESS
#endregion

Write-Log "SQL Server installation complete on all nodes." SUCCESS
