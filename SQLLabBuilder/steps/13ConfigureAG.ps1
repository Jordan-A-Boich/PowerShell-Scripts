#Requires -Version 5.1
<#
.SYNOPSIS
    Step 13 — Create and configure the SQL Server Always On Availability Group.

    The full AG build (HADR endpoints + CONNECT grants, CREATE AVAILABILITY GROUP,
    listener, join the secondary, health check, labadmin logins, Contained-AG
    handling) lives in New-LabAG in steps\_shared\LabFunctions.ps1 and is shared
    with AddCluster.ps1 — so every AG in the lab is created identically.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared AG implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-13.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-14.done","step-15.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 13 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 13 checkpoint found — verifying AG health..." INFO
    try {
        $agState = Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
            $connStr = "Server=localhost;Database=master;Integrated Security=True;Connect Timeout=30"
            $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $conn.Open()
            $cmd             = $conn.CreateCommand()
            $cmd.CommandText = "SELECT name FROM sys.availability_groups"
            $reader          = $cmd.ExecuteReader()
            $names           = @()
            while ($reader.Read()) { $names += $reader['name'] }
            $conn.Close()
            return $names
        } -ErrorAction Stop
        if ($agState -contains $AGName) {
            Write-Log "AG '$AGName' verified healthy. Skipping step 13." SUCCESS
            return
        }
    } catch { Write-Log "Checkpoint check failed — re-running step 13." WARN }
}
#endregion

New-LabAG `
    -Node1VMName     $SQL1VMName `
    -Node1Computer   $SQL1ComputerName `
    -Node1IP         $SQL1StaticIP `
    -Node2VMName     $SQL2VMName `
    -Node2Computer   $SQL2ComputerName `
    -Node2IP         $SQL2StaticIP `
    -AGName          $AGName `
    -ListenerName    $ListenerName `
    -ListenerIP      $ListenerIP `
    -ListenerPort    $ListenerPort `
    -EndpointPort    $EndpointPort `
    -IsContained     $global:ContainedAG `
    -DomainAdminCred $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-13.done" SUCCESS
#endregion

Write-Log "Availability Group '$AGName' configuration complete." SUCCESS
