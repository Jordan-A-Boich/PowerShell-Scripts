#Requires -Version 5.1
<#
.SYNOPSIS
    Step 10 — Create the SQL Server service account in Active Directory.

IDEMPOTENCY CHECKS:
    - Checks if the 'sqlsvc' user already exists in AD before creating.
    - Grants 'Log on as a service' right on each SQL VM only if not already present.
    - Checkpoint step-10.done skips if account exists and policy is confirmed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared Grant-LogonAsService implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-10.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-11.done","step-12.done","step-13.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 10 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 10 checkpoint found — verifying SQL service account..." INFO
    try {
        $exists = Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
            Import-Module ActiveDirectory -ErrorAction Stop
            $null -ne (Get-ADUser -Filter { SamAccountName -eq 'sqlsvc' } -ErrorAction SilentlyContinue)
        } -ErrorAction Stop
        if ($exists) {
            Write-Log "SQL service account 'sqlsvc' verified. Skipping step 10." SUCCESS
            return
        }
    } catch { Write-Log "Checkpoint check failed — re-running step 10." WARN }
}
#endregion

#region Create domain user 'sqlsvc'
Write-Log "[$DCVMName] Creating domain account '$SQLSvcAccountName'..." INFO
Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
    param($AccountName, $Password)
    Import-Module ActiveDirectory -ErrorAction Stop

    $existing = Get-ADUser -Filter { SamAccountName -eq $AccountName } -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "User '$AccountName' already exists — skipping creation."
    } else {
        $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
        New-ADUser `
            -Name                  $AccountName `
            -SamAccountName        $AccountName `
            -UserPrincipalName     "$AccountName@sqllab.local" `
            -AccountPassword       $secPwd `
            -Enabled               $true `
            -PasswordNeverExpires  $true `
            -CannotChangePassword  $false `
            -ErrorAction           Stop
        Write-Output "Created AD user: $AccountName"
    }
} -ArgumentList $SQLSvcAccountName, $SQLServiceAccountPassword -ErrorAction Stop |
    ForEach-Object { Write-Log "[$DCVMName] $_" INFO }
#endregion

#region Grant 'Log on as a service' on both SQL VMs via secedit (shared function)
foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Write-Log "[$vmName] Granting 'Log on as a service' to '$SQLSvcAccount'..." INFO
    Grant-LogonAsService -VMName $vmName -Credential $domainAdminCred
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-10.done" SUCCESS
#endregion

Write-Log "SQL service account setup complete." SUCCESS
