#Requires -Version 5.1
<#
.SYNOPSIS
    Step 06 — Configure static IP addresses inside each VM via PowerShell Direct.

    The per-node work (wait for PS Direct, assign static IP/DNS, disable IPv6, update
    host vEthernet DNS, reboot, wait) lives in Set-LabNodesNetworking /
    Set-VMStaticIP in steps\_shared\LabFunctions.ps1 and is shared with AddCluster.ps1.

IDEMPOTENCY CHECKS:
    - Connects to each VM and checks the current IP configuration.
    - Checkpoint step-06.done skips the step if all three VMs respond with correct IPs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Shared networking implementation (used by both the primary build and AddCluster.ps1).
. (Join-Path $PSScriptRoot "_shared\LabFunctions.ps1")

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-06.done"
if (Test-Path $cpFile) {
    # If any later step completed, step 06 definitely worked — no need to re-verify via PS Direct
    $laterDone = @("step-07.done","step-08.done","step-09.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 06 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 06 checkpoint found — verifying network config..." INFO
    $allOK    = $true
    $localCred = New-Object System.Management.Automation.PSCredential("Administrator",
                    (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    foreach ($pair in @(
        @{ VM = $DCVMName;   IP = $DCStaticIP   }
        @{ VM = $SQL1VMName; IP = $SQL1StaticIP }
        @{ VM = $SQL2VMName; IP = $SQL2StaticIP }
    )) {
        try {
            $ips = Invoke-Command -VMName $pair.VM -Credential $localCred -ScriptBlock {
                (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            } -ErrorAction Stop
            if ($ips -notcontains $pair.IP) { $allOK = $false }
        } catch { $allOK = $false }
    }
    if ($allOK) {
        Write-Log "All VMs have correct IPs — skipping step 06." SUCCESS
        return
    }
    Write-Log "Checkpoint present but IP verification inconclusive — re-running step 06." WARN
}
#endregion

$adminCred       = New-Object System.Management.Automation.PSCredential("Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

# DC points DNS at itself (127.0.0.1); SQL nodes point at the DC. Host vEthernet
# DNS gains the DC as first resolver.
Set-LabNodesNetworking -NodeSpecs @(
    @{ VMName = $DCVMName;   IP = $DCStaticIP;   DNSPrimary = "127.0.0.1" }
    @{ VMName = $SQL1VMName; IP = $SQL1StaticIP; DNSPrimary = $DCStaticIP }
    @{ VMName = $SQL2VMName; IP = $SQL2StaticIP; DNSPrimary = $DCStaticIP }
) -HostDnsIP $DCStaticIP -AdminCred $adminCred -DomainAdminCred $domainAdminCred

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-06.done" SUCCESS
#endregion

Write-Log "Networking configuration complete." SUCCESS
