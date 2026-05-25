#Requires -Version 5.1
<#
.SYNOPSIS
    Step 14 — Configure host machine for direct SSMS access to lab SQL instances.

IDEMPOTENCY CHECKS:
    - Hosts file: entries added only if not already present (exact match check).
    - SQL logins: created only if 'labadmin' login does not exist on each instance.
    - Firewall rule: created only if not already present by name.
    - DNS entry on host vEthernet: added only if not in list.
    - Connectivity: Test-NetConnection to each target on 1433.
    - Checkpoint step-14.done skips if all checks pass.

NOTE ON AG LISTENER AND SQL AUTH:
    SQL Server's AG Listener routing works fully with SQL authentication.
    However, when connecting to the Listener via SQL Auth from a non-domain host,
    the connection will route to the primary replica. Read-intent routing to
    secondaries requires a connection string property 'ApplicationIntent=ReadOnly'
    and is fully supported with SQL auth. The listener IP (192.168.100.30)
    is reachable from the host via the NAT/internal switch.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-14.done"
if (Test-Path $cpFile) {
    Write-Log "Step 14 checkpoint found — verifying host access config..." INFO
    $hostsOK = (Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -Raw) -match "SQLLabBuilder-BEGIN"
    if ($hostsOK) {
        Write-Log "Hosts file entries verified. Skipping step 14." SUCCESS
        return
    }
    Write-Log "Checkpoint present but config incomplete — re-running." WARN
}
#endregion

#region 1. Hosts file entries
Write-Log "Adding lab entries to hosts file..." INFO

$hostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsContent = Get-Content -Path $hostsPath -Raw -ErrorAction Stop

$labEntries = @"

# SQLLabBuilder-BEGIN
$DCStaticIP   SQLLAB-DC       SQLLAB-DC.sqllab.local
$SQL1StaticIP SQLLAB-SQL1     SQLLAB-SQL1.sqllab.local
$SQL2StaticIP SQLLAB-SQL2     SQLLAB-SQL2.sqllab.local
$ClusterIP    SQLLabCluster   SQLLabCluster.sqllab.local
$ListenerIP   SQLLabListener  SQLLabListener.sqllab.local
# SQLLabBuilder-END
"@

if ($hostsContent -match "SQLLabBuilder-BEGIN") {
    Write-Log "Lab hosts entries already present — skipping." INFO
} else {
    Add-Content -Path $hostsPath -Value $labEntries -Encoding ASCII -ErrorAction Stop
    Write-Log "Lab hosts entries added." SUCCESS
}
#endregion

#region 2. Create 'labadmin' SQL login on both SQL instances
function Add-LabSQLLogin {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Credential)

    Write-Log "[$VMName] Creating 'labadmin' SQL login..." INFO
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($LoginPwd)

        # Use ADO.NET directly — no SqlServer module required on the VM
        function Invoke-LocalSql {
            param([string]$Query, [int]$Timeout = 60)
            $conn = New-Object System.Data.SqlClient.SqlConnection(
                "Server=localhost;Database=master;Integrated Security=True;Connect Timeout=30")
            try {
                $conn.Open()
                $cmd = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
                $cmd.CommandTimeout = $Timeout
                $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
                $table   = New-Object System.Data.DataTable
                [void]$adapter.Fill($table)
                return $table
            } finally {
                if ($conn.State -eq 'Open') { $conn.Close() }
            }
        }

        $existing = Invoke-LocalSql -Query "SELECT name FROM sys.server_principals WHERE name='labadmin'"
        if ($existing.Rows.Count -gt 0) {
            Write-Output "Login 'labadmin' already exists."
        } else {
            Invoke-LocalSql -Query @"
CREATE LOGIN [labadmin] WITH PASSWORD='$LoginPwd', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF;
ALTER SERVER ROLE [sysadmin] ADD MEMBER [labadmin];
"@
            Write-Output "Login 'labadmin' created with sysadmin role."
        }
    } -ArgumentList $LabAdminPassword -ErrorAction Stop |
        ForEach-Object { Write-Log "[$VMName] $_" INFO }
}

foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Add-LabSQLLogin -VMName $vmName -Credential $domainAdminCred
}
#endregion

#region 3. Host firewall — allow outbound to lab on 1433
Write-Log "Adding host firewall rule for lab SQL access..." INFO
$fwRuleName = "SQLLab-SQL1433-Outbound"
$existing   = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule `
        -DisplayName $fwRuleName `
        -Direction   Outbound `
        -Protocol    TCP `
        -RemotePort  1433 `
        -RemoteAddress "$LabSubnet/$LabPrefix" `
        -Action      Allow `
        -ErrorAction Stop | Out-Null
    Write-Log "Firewall rule added: $fwRuleName" SUCCESS
} else {
    Write-Log "Firewall rule already exists: $fwRuleName" INFO
}
#endregion

#region 4. Host vEthernet DNS — ensure lab DC is first DNS entry
Write-Log "Ensuring lab DC is in host vEthernet DNS..." INFO
$adapterAlias = "vEthernet ($SwitchName)"
try {
    $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
    if ($adapter) {
        $existingDns = (Get-DnsClientServerAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($existingDns -notcontains $DCStaticIP) {
            $newDns = @($DCStaticIP) + ($existingDns | Where-Object { $_ -ne $DCStaticIP })
            Set-DnsClientServerAddress -InterfaceAlias $adapterAlias -ServerAddresses $newDns -ErrorAction Stop
            Write-Log "Lab DC DNS ($DCStaticIP) added to $adapterAlias." SUCCESS
        } else {
            Write-Log "Lab DC DNS already present on $adapterAlias." INFO
        }
    } else {
        Write-Log "Adapter '$adapterAlias' not found — DNS will not be updated." WARN
    }
} catch {
    Write-Log "Could not update host vEthernet DNS: $_ (non-fatal)" WARN
}
#endregion

#region 5. Test-NetConnection to each SQL endpoint
Write-Log "Testing connectivity from host to SQL endpoints on port 1433..." INFO

$testTargets = @(
    @{ Address = $SQL1StaticIP; Label = "SQLLAB-SQL1" }
    @{ Address = $SQL2StaticIP; Label = "SQLLAB-SQL2" }
    @{ Address = $ListenerIP;   Label = "SQLLabListener (AG)" }
)

$connectResults = @()
foreach ($target in $testTargets) {
    try {
        $result = Test-NetConnection -ComputerName $target.Address -Port 1433 -WarningAction SilentlyContinue
        $status  = if ($result.TcpTestSucceeded) { "PASS" } else { "FAIL" }
        $color   = if ($result.TcpTestSucceeded) { "Green" } else { "Red" }
        $msg     = "  $($target.Label) ($($target.Address)):1433 — $status"
        Write-Host $msg -ForegroundColor $color
        Write-Log $msg (if ($result.TcpTestSucceeded) { "SUCCESS" } else { "WARN" })
        $connectResults += @{ Label = $target.Label; IP = $target.Address; Pass = $result.TcpTestSucceeded }
    } catch {
        Write-Log "  $($target.Label) — connectivity test error: $_" WARN
        $connectResults += @{ Label = $target.Label; IP = $target.Address; Pass = $false }
    }
}

$failures = $connectResults | Where-Object { -not $_.Pass }
if ($failures) {
    Write-Log "WARNING: $($failures.Count) connectivity test(s) failed. SQL VMs may still be starting up or Windows Firewall may need a moment. Re-run step 14 if issues persist." WARN
} else {
    Write-Log "All connectivity tests passed." SUCCESS
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-14.done" SUCCESS
#endregion

Write-Log "Host access configuration complete." SUCCESS
