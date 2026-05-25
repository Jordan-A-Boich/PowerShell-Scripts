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

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-10.done"
if (Test-Path $cpFile) {
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

#region Grant 'Log on as a service' on both SQL VMs via secedit
function Grant-LogonAsService {
    param(
        [string]$VMName,
        [string]$AccountSid,
        [System.Management.Automation.PSCredential]$Credential
    )

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($SvcAccount)

        $infPath = "$env:TEMP\sqlsvc-loas.inf"
        $dbPath  = "$env:TEMP\sqlsvc-loas.sdb"
        $logPath = "$env:TEMP\sqlsvc-loas.log"

        # Export current security policy
        secedit /export /cfg $infPath /quiet

        $current = Get-Content $infPath -Raw
        if ($current -match "SeServiceLogonRight\s*=\s*(.+)") {
            $currentRights = $Matches[1].Trim()
            if ($currentRights -notlike "*$SvcAccount*") {
                $newRights = "$currentRights,$SvcAccount"
                $current   = $current -replace "SeServiceLogonRight\s*=\s*.+", "SeServiceLogonRight = $newRights"
            } else {
                Write-Output "SeServiceLogonRight already granted to $SvcAccount"
                return
            }
        } else {
            $current += "`r`n[Privilege Rights]`r`nSeServiceLogonRight = $SvcAccount"
        }

        $current | Set-Content -Path $infPath -Encoding Unicode
        secedit /configure /db $dbPath /cfg $infPath /log $logPath /quiet
        Remove-Item $infPath, $dbPath, $logPath -Force -ErrorAction SilentlyContinue
        Write-Output "Granted SeServiceLogonRight to $SvcAccount"

    } -ArgumentList "$NetBIOSName\$SQLSvcAccountName" -ErrorAction Stop |
        ForEach-Object { Write-Log "[$VMName] $_" INFO }
}

foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Write-Log "[$vmName] Granting 'Log on as a service' to '$SQLSvcAccount'..." INFO
    Grant-LogonAsService -VMName $vmName -AccountSid $SQLSvcAccount -Credential $domainAdminCred
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-10.done" SUCCESS
#endregion

Write-Log "SQL service account setup complete." SUCCESS
