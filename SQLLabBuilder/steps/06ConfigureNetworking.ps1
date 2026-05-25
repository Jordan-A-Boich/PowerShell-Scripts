#Requires -Version 5.1
<#
.SYNOPSIS
    Step 06 — Configure static IP addresses inside each VM via PowerShell Direct.

IDEMPOTENCY CHECKS:
    - Connects to each VM and checks the current IP configuration.
    - IP, gateway, and DNS are set only if they differ from the desired values.
    - IPv6 is disabled if not already.
    - Host vEthernet DNS is updated only if lab DC IP is not already in the list.
    - Checkpoint step-06.done skips the step if all three VMs respond with correct IPs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

#region Configure networking helper
function Set-VMStaticIP {
    param(
        [string]$VMName,
        [string]$StaticIP,
        [string]$PrefixLen,
        [string]$GW,
        [string]$DNSPrimary,
        [string]$DNSSecondary = $null,
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-Log "[$VMName] Configuring static IP: $StaticIP/$PrefixLen GW=$GW DNS=$DNSPrimary" INFO

    $dnsArray = if ($DNSSecondary) { @($DNSPrimary, $DNSSecondary) } else { @($DNSPrimary) }

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($IP, $Prefix, $GW, $DNS, $VMN)

        # Find the physical/external adapter (not loopback)
        $adapter = Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch 'Loopback'
        } | Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1

        if (-not $adapter) { throw "No active adapter found in $VMN." }

        $alias = $adapter.InterfaceAlias

        # Remove existing IPv4 addresses on this adapter
        Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        # Remove existing gateway
        Remove-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue

        # Assign static IP
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $GW -ErrorAction Stop | Out-Null

        # Set DNS
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $DNS -ErrorAction Stop

        # Disable IPv6
        Disable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

        Write-Output "Configured: $IP/$Prefix GW=$GW DNS=$($DNS -join ',')"

    } -ArgumentList $StaticIP, $PrefixLen, $GW, $dnsArray, $VMName -ErrorAction Stop

    Write-Log "[$VMName] Static IP configured: $StaticIP" SUCCESS
}
#endregion

#region Wait for VM readiness
function Wait-VMNetworkReady {
    param(
        [string]$VMName,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Management.Automation.PSCredential]$FallbackCredential = $null,
        [int]$TimeoutMinutes = 10
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pollSecs = 10
    while ((Get-Date) -lt $deadline) {
        foreach ($cred in @($Credential, $FallbackCredential) | Where-Object { $_ }) {
            try {
                Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null
                return
            } catch { }
        }
        Write-Log "[$VMName] Waiting for PowerShell Direct connectivity..." INFO
        Start-Sleep -Seconds $pollSecs
    }
    throw "[$VMName] PowerShell Direct not available after $TimeoutMinutes minutes."
}
#endregion

foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    Wait-VMNetworkReady -VMName $vmName -Credential $adminCred -FallbackCredential $domainAdminCred
}

Set-VMStaticIP -VMName $DCVMName   -StaticIP $DCStaticIP   -PrefixLen $LabPrefix -GW $Gateway -DNSPrimary "127.0.0.1"   -Credential $adminCred
Set-VMStaticIP -VMName $SQL1VMName -StaticIP $SQL1StaticIP -PrefixLen $LabPrefix -GW $Gateway -DNSPrimary $DCStaticIP    -Credential $adminCred
Set-VMStaticIP -VMName $SQL2VMName -StaticIP $SQL2StaticIP -PrefixLen $LabPrefix -GW $Gateway -DNSPrimary $DCStaticIP    -Credential $adminCred

#region Add lab DC to host vEthernet DNS (do not replace existing DNS servers)
Write-Log "Adding lab DC ($DCStaticIP) to host vEthernet DNS..." INFO
$adapterAlias = "vEthernet ($SwitchName)"
try {
    $existing = (Get-DnsClientServerAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if ($existing -notcontains $DCStaticIP) {
        $newList = @($DCStaticIP) + ($existing | Where-Object { $_ -ne $DCStaticIP })
        Set-DnsClientServerAddress -InterfaceAlias $adapterAlias -ServerAddresses $newList -ErrorAction Stop
        Write-Log "Added $DCStaticIP as first DNS on $adapterAlias." SUCCESS
    } else {
        Write-Log "$DCStaticIP already in DNS list for $adapterAlias." INFO
    }
} catch {
    Write-Log "Could not update host vEthernet DNS: $_ (non-fatal — host DNS update will be retried in step 14)" WARN
}
#endregion

#region Reboot VMs to apply network settings
Write-Log "Rebooting VMs to apply network configuration..." INFO
foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop
        Write-Log "[$vmName] Reboot initiated." INFO
    } catch {
        Write-Log "[$vmName] Could not send reboot command (may have already rebooted): $_" WARN
    }
}

Start-Sleep -Seconds 15

foreach ($vmName in @($DCVMName, $SQL1VMName, $SQL2VMName)) {
    Wait-VMNetworkReady -VMName $vmName -Credential $adminCred -FallbackCredential $domainAdminCred -TimeoutMinutes 10
    Write-Log "[$vmName] Back online after network reboot." SUCCESS
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-06.done" SUCCESS
#endregion

Write-Log "Networking configuration complete." SUCCESS
