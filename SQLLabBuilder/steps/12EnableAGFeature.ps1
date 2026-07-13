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

        # Bring each node's data disk online and restart SQL/cluster services if a
        # VM restart left them down. Shared with StartLab.ps1 (see LabFunctions.ps1).
        foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
            Restore-LabNodeHealth -VMName $vmName -Credential $domainAdminCred | Out-Null
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
