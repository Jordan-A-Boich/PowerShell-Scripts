#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 05: the availability group listener and read-only routing.

.DESCRIPTION
    A listener that cannot be created is reported, never fatal. By far the most common cause
    is Active Directory: the cluster name object (CNO) is not allowed to create the listener's
    computer object. The availability group and its databases are perfectly usable without a
    listener, so the run carries on seeding and the rollup says what to fix.
#>

Set-StrictMode -Version Latest

function Get-AgListenerSql {
    param(
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][psobject]$Listener
    )
    $ipClause = if ($Listener.Dhcp) {
        if ($Listener.DhcpSubnet) {
            "WITH DHCP ON ($(ConvertTo-AgQuotedString $Listener.DhcpSubnet.SubnetIp), $(ConvertTo-AgQuotedString $Listener.DhcpSubnet.SubnetMask))"
        } else { 'WITH DHCP' }
    } else {
        'WITH IP (' + (($Listener.Addresses | ForEach-Object {
            "($(ConvertTo-AgQuotedString $_.IpAddress), $(ConvertTo-AgQuotedString $_.SubnetMask))"
        }) -join ', ') + ')'
    }
    @"
ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $AgName)
ADD LISTENER $(ConvertTo-AgQuotedString $Listener.Name) (
    $ipClause,
    PORT = $([int]$Listener.Port)
);
"@
}

function Invoke-AgListener {
    <#
    .OUTPUTS
        $true when the listener exists at the end (or none was requested), $false when it
        could not be created.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $l = $Plan.Listener
    if (-not $l -or -not $l.Create) { return $true }

    Write-AgBanner "LISTENER [$($l.Name)]"
    $p = $Plan.PrimaryReplica

    $topo = Get-AgTopology -Instance $p -AgName $Plan.AgName
    if (@($topo.Listeners | Where-Object { $_.DnsName -eq $l.Name }).Count -gt 0) {
        Write-AgLog "  Listener $($l.Name) already exists on [$($Plan.AgName)]." SUCCESS
        return $true
    }
    if ($topo.Listeners.Count -gt 0) {
        Write-AgLog "  [$($Plan.AgName)] already has listener(s) $(($topo.Listeners | ForEach-Object { $_.DnsName }) -join ', '); adding $($l.Name) as well." INFO
    }

    $sql = Get-AgListenerSql -AgName $Plan.AgName -Listener $l
    try {
        Invoke-AgSql -Instance $p -QueryTimeout 300 -Activity 'create listener' -Query $sql | Out-Null
    } catch {
        $msg = $_.Exception.Message.Split("`n")[0]
        Write-AgLog "Could not create listener $($l.Name): $msg" ERROR
        Write-Host ''
        Write-Host 'Usual causes:' -ForegroundColor Yellow
        Write-Host "  * The cluster name object '$($Plan.ClusterName)$' may not create computer objects in its" -ForegroundColor DarkGray
        Write-Host '    organizational unit. Grant it "Create Computer objects" on the OU, or pre-stage a' -ForegroundColor DarkGray
        Write-Host "    disabled computer object named $($l.Name) and give the CNO full control of it." -ForegroundColor DarkGray
        Write-Host '  * The IP address is already in use, or is not in the subnet of a cluster network.' -ForegroundColor DarkGray
        Write-Host '  * A DNS record for the name exists and the CNO cannot update it.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'When fixed, run this on the primary:' -ForegroundColor White
        Write-Host $sql -ForegroundColor DarkGray
        Write-AgLog 'Carrying on without the listener — the availability group and its databases do not depend on it.' WARN
        return $false
    }

    $ok = Wait-AgCondition -Activity "listener $($l.Name) online" -TimeoutSeconds 120 -PollSeconds 5 -Condition {
        $t = Get-AgTopology -Instance $p -AgName $Plan.AgName
        $mine = @($t.Listeners | Where-Object { $_.DnsName -eq $l.Name })
        $mine.Count -eq 1 -and ($l.Dhcp -or @($mine[0].Addresses | Where-Object { $_.State -eq 'ONLINE' }).Count -gt 0)
    }
    if (-not $ok) { Write-AgLog "Listener $($l.Name) was created but no address came ONLINE yet. Check the cluster role in Failover Cluster Manager." WARN }
    else { Write-AgLog "Listener $($l.Name),$($l.Port) is online." SUCCESS }

    if ($l.Addresses.Count -gt 1) {
        Write-Host ''
        Write-Host 'Multi-subnet listener tips:' -ForegroundColor White
        Write-Host '  * Clients: add MultiSubnetFailover=True to every connection string.' -ForegroundColor DarkGray
        Write-Host '  * Legacy clients that cannot: lower the DNS TTL so they reconnect quickly after a failover.' -ForegroundColor DarkGray
        Write-Host '    On a cluster node:' -ForegroundColor DarkGray
        Write-Host "      Get-ClusterResource -Name '$($Plan.AgName)_$($l.Name)' | Set-ClusterParameter -Name HostRecordTTL -Value 300" -ForegroundColor DarkGray
    }
    return $true
}

function Set-AgReadOnlyRouting {
    <#
    .SYNOPSIS
        Routing URL on every replica, and a load-balanced routing list for each replica's
        primary role: the other READABLE replicas first, itself last as the fallback.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    if (-not $Plan.ConfigureReadOnlyRouting) { return }
    Write-AgLog 'Configuring read-only routing...' STEP
    $p  = $Plan.PrimaryReplica
    $ag = ConvertTo-AgQuotedName $Plan.AgName

    foreach ($r in $Plan.Replicas) {
        Invoke-AgSql -Instance $p -QueryTimeout 120 -Activity 'routing url' -Query @"
ALTER AVAILABILITY GROUP $ag MODIFY REPLICA ON $(ConvertTo-AgQuotedString $r.Name)
WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = $(ConvertTo-AgQuotedString $r.ReadOnlyRoutingUrl)));
"@ | Out-Null
    }
    foreach ($r in $Plan.Replicas) {
        $others = @($Plan.Replicas | Where-Object { $_.Name -ne $r.Name -and $_.SecondaryConnections -ne 'NO' } | ForEach-Object { ConvertTo-AgQuotedString $_.Name })
        if ($others.Count -eq 0) { continue }
        $self = ConvertTo-AgQuotedString $r.Name
        $list = if ($others.Count -gt 1 -and $Plan.MinMajorVersion -ge 13) { "(($($others -join ', ')), $self)" } else { "($($others -join ', '), $self)" }
        Invoke-AgSql -Instance $p -QueryTimeout 120 -Activity 'routing list' -Query @"
ALTER AVAILABILITY GROUP $ag MODIFY REPLICA ON $self
WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = $list));
"@ | Out-Null
        Write-AgLog "  [$($r.Name)] as primary routes read-intent connections to $list" SUCCESS
    }
}
