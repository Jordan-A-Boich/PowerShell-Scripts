#Requires -Version 5.1
<#
.SYNOPSIS
    Step 07 — Promote SQLLAB-DC to a domain controller for sqllab.local.

IDEMPOTENCY CHECKS:
    - Checks if AD Domain Services role is already installed inside the VM.
    - Checks if the forest already exists before running Install-ADDSForest.
    - Polls AD Web Services port (9389) until responding before returning.
    - Checkpoint step-07.done skips if DC is responding and domain is confirmed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$adminCred       = New-Object System.Management.Automation.PSCredential("Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-07.done"
if (Test-Path $cpFile) {
    # If any later step completed, DC promotion definitely worked — skip without PS Direct check
    $laterDone = @("step-08.done","step-09.done","step-10.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 07 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 07 checkpoint found — verifying DC readiness..." INFO
    try {
        $domain = Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
            Import-Module ActiveDirectory -ErrorAction Stop
            (Get-ADDomain -ErrorAction Stop).DNSRoot
        } -ErrorAction Stop
        if ($domain -eq $DomainName) {
            Write-Log "DC verified — domain $domain is healthy. Skipping step 07." SUCCESS
            return
        }
    } catch { Write-Log "Checkpoint check failed — re-running step 07." WARN }
}
#endregion

#region Wait for DC VM
function Wait-VMPS {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Cred, [int]$Mins = 10)
    $deadline = (Get-Date).AddMinutes($Mins)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null
            return
        } catch { Start-Sleep -Seconds 10 }
    }
    throw "PowerShell Direct to '$VMName' unavailable after $Mins minutes."
}
#endregion

Wait-VMPS -VMName $DCVMName -Cred $adminCred

#region Install AD DS role
Write-Log "[$DCVMName] Installing AD-Domain-Services role..." INFO
Invoke-Command -VMName $DCVMName -Credential $adminCred -ScriptBlock {
    $feature = Get-WindowsFeature AD-Domain-Services
    if ($feature.Installed) {
        Write-Output "AD-Domain-Services already installed."
    } else {
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Output "AD-Domain-Services installed."
    }
} -ErrorAction Stop | ForEach-Object { Write-Log "[$DCVMName] $_" INFO }
#endregion

#region Promote to DC
Write-Log "[$DCVMName] Checking if domain already exists..." INFO

$domainExists = Invoke-Command -VMName $DCVMName -Credential $adminCred -ScriptBlock {
    try {
        Import-Module ADDSDeployment -ErrorAction Stop
        $null = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        return $true
    } catch { return $false }
} -ErrorAction Stop

if ($domainExists) {
    Write-Log "[$DCVMName] Domain already configured — skipping Install-ADDSForest." INFO
} else {
    Write-Log "[$DCVMName] Running Install-ADDSForest for domain '$DomainName'..." INFO

    $smPwdSecure = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

    Invoke-Command -VMName $DCVMName -Credential $adminCred -ScriptBlock {
        param($Domain, $NetBIOS, $SMPwd)
        Import-Module ADDSDeployment -ErrorAction Stop

        $params = @{
            DomainName                    = $Domain
            DomainNetbiosName             = $NetBIOS
            SafeModeAdministratorPassword = (ConvertTo-SecureString $SMPwd -AsPlainText -Force)
            InstallDns                    = $true
            NoRebootOnCompletion          = $false
            Force                         = $true
        }
        Install-ADDSForest @params | Out-Null
    } -ArgumentList $DomainName, $NetBIOSName, $AdminPassword -ErrorAction Stop

    Write-Log "[$DCVMName] Install-ADDSForest initiated. VM will reboot." INFO
}
#endregion

#region Wait for DC reboot + AD readiness
Write-Log "Waiting for DC to reboot and AD to become ready (up to 20 minutes)..." INFO
Start-Sleep -Seconds 30   # Allow shutdown to begin

$domainCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                  (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

$deadline  = (Get-Date).AddMinutes(20)
$adReady   = $false
while ((Get-Date) -lt $deadline) {
    try {
        $testResult = Invoke-Command -VMName $DCVMName -Credential $domainCred -ScriptBlock {
            Import-Module ActiveDirectory -ErrorAction Stop
            $d = Get-ADDomain -ErrorAction Stop
            return $d.DNSRoot
        } -ErrorAction Stop

        Write-Log "[$DCVMName] AD domain '$testResult' is responding." SUCCESS
        $adReady = $true
        break
    } catch {
        Write-Log "[$DCVMName] AD not ready yet — retrying in 15 s..." INFO
        Start-Sleep -Seconds 15
    }
}

if (-not $adReady) {
    throw "[$DCVMName] AD did not become ready within 20 minutes."
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-07.done" SUCCESS
#endregion

Write-Log "Domain controller promotion complete. Domain: $DomainName" SUCCESS
