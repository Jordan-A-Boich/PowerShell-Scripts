#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — the Windows Server Failover Cluster underneath, the mirroring endpoints that
    carry the data, and the network facts a listener needs.

.DESCRIPTION
    Everything here is read through SQL Server (sys.dm_hadr_cluster*, sys.dm_server_services,
    xp_regread), never through the FailoverClusters module or WMI. The workstation running
    the script is frequently outside the domain or has no cluster tools installed, while a
    sysadmin connection to one replica sees the whole cluster.
#>

Set-StrictMode -Version Latest

#region ── Cluster ───────────────────────────────────────────────────────────

function Get-AgClusterInfo {
    <#
    .OUTPUTS
        Cluster name, quorum, member nodes and the networks each node sits on — or $null when
        the instance is not running on a WSFC node.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $c = Invoke-AgSql -Instance $Instance -Retry -Activity 'cluster discovery' `
        -Query 'SELECT cluster_name AS ClusterName, quorum_type_desc AS QuorumType, quorum_state_desc AS QuorumState FROM sys.dm_hadr_cluster'
    if ($c.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$c[0].ClusterName)) { return $null }

    $members = Invoke-AgSql -Instance $Instance -Retry -Activity 'cluster members' -Query @'
SELECT member_name AS MemberName, member_type_desc AS MemberType, member_state_desc AS MemberState,
       number_of_quorum_votes AS Votes
FROM sys.dm_hadr_cluster_members
'@
    $networks = Invoke-AgSql -Instance $Instance -Retry -Activity 'cluster networks' -Query @'
SELECT member_name AS MemberName, network_subnet_ip AS SubnetIp, network_subnet_ipv4_mask AS SubnetMask,
       network_subnet_prefix_length AS PrefixLength, CAST(is_public AS int) AS IsPublic, CAST(is_ipv4 AS int) AS IsIpv4
FROM sys.dm_hadr_cluster_networks
'@

    [pscustomobject]@{
        ClusterName = [string]$c[0].ClusterName
        QuorumType  = [string]$c[0].QuorumType
        QuorumState = [string]$c[0].QuorumState
        Nodes       = @($members | Where-Object { $_.MemberType -eq 'CLUSTER_NODE' } | ForEach-Object {
                        [pscustomobject]@{ Name = [string]$_.MemberName; State = [string]$_.MemberState; Votes = [int]$_.Votes } })
        Witnesses   = @($members | Where-Object { $_.MemberType -ne 'CLUSTER_NODE' } | ForEach-Object {
                        [pscustomobject]@{ Name = [string]$_.MemberName; Type = [string]$_.MemberType; State = [string]$_.MemberState } })
        Networks    = @($networks | ForEach-Object {
                        [pscustomobject]@{
                            Node         = [string]$_.MemberName
                            SubnetIp     = [string]$_.SubnetIp
                            SubnetMask   = [string]$_.SubnetMask
                            PrefixLength = [int]$_.PrefixLength
                            IsPublic     = ([int]$_.IsPublic -eq 1)
                            IsIpv4       = ([int]$_.IsIpv4 -eq 1)
                        } })
    }
}

function Get-AgListenerSubnet {
    <#
    .SYNOPSIS
        The distinct public IPv4 subnets the replicas' nodes sit on — one listener IP each.
    .DESCRIPTION
        A listener needs one static IP address in every subnet that hosts a replica: WSFC
        brings online the address whose subnet the current primary's node is on. Two replicas
        on one subnet share an address, so the answer is per SUBNET, not per replica.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Cluster,
        [Parameter(Mandatory)][string[]]$NodeNames
    )
    $nodes = @($NodeNames | ForEach-Object { $_.ToUpperInvariant() })
    $rows  = @($Cluster.Networks | Where-Object { $_.IsPublic -and $_.IsIpv4 -and ($nodes -contains $_.Node.ToUpperInvariant()) })
    return @($rows | Group-Object SubnetIp, SubnetMask | ForEach-Object {
        [pscustomobject]@{
            SubnetIp     = $_.Group[0].SubnetIp
            SubnetMask   = $_.Group[0].SubnetMask
            PrefixLength = $_.Group[0].PrefixLength
            Nodes        = @($_.Group | ForEach-Object { $_.Node } | Sort-Object -Unique)
        }
    })
}

#endregion

#region ── IP address helpers ────────────────────────────────────────────────

function ConvertTo-AgIpUInt32 {
    param([Parameter(Mandatory)][string]$Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $null }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $ip.GetAddressBytes()
    return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3]
}

function Test-AgIpInSubnet {
    <#
    .SYNOPSIS
        Is $Address a usable host address inside SubnetIp/SubnetMask (not the network or
        broadcast address)?
    #>
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$SubnetIp,
        [Parameter(Mandatory)][string]$SubnetMask
    )
    $a = ConvertTo-AgIpUInt32 $Address
    $n = ConvertTo-AgIpUInt32 $SubnetIp
    $m = ConvertTo-AgIpUInt32 $SubnetMask
    if ($null -eq $a -or $null -eq $n -or $null -eq $m) { return $false }
    if (($a -band $m) -ne ($n -band $m)) { return $false }
    $hostBits = (-bnot $m) -band [uint32]::MaxValue
    $hostPart = $a -band $hostBits
    return ($hostPart -ne 0 -and $hostPart -ne $hostBits)
}

function Test-AgIpInUse {
    <#
    .SYNOPSIS
        Best-effort "does something already answer on this address?" — one ping.
    .DESCRIPTION
        Not proof either way: a firewall can hide a live host, and an address can be reserved
        without being up. It catches the common mistake of picking a node's or the cluster's
        own address, which is what makes a listener fail to come online.
    #>
    param([Parameter(Mandatory)][string]$Address)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $reply = $p.Send($Address, 1000)
        return ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    }
}

function Resolve-AgDnsName {
    <#
    .OUTPUTS
        The addresses a name resolves to, or an empty array.
    #>
    param([Parameter(Mandatory)][string]$Name)
    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() })
    } catch {
        return @()
    }
}

function Test-AgNetbiosName {
    <#
    .SYNOPSIS
        A listener name becomes a computer object in Active Directory, so it is bound by
        NetBIOS rules: 1-15 characters, letters, digits and hyphens, not all digits.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return ($Name.Length -ge 1 -and $Name.Length -le 15 -and $Name -match '^[A-Za-z0-9-]+$' -and $Name -notmatch '^\d+$' -and $Name -notmatch '^-|-$')
}

#endregion

#region ── Service accounts and endpoint permissions ─────────────────────────

function Get-AgServiceNetworkLogin {
    <#
    .SYNOPSIS
        The Windows principal an instance presents to its peers over the AG endpoint.

    .DESCRIPTION
        Virtual accounts (NT SERVICE\MSSQLSERVER), LocalSystem and NetworkService all
        authenticate on the wire as the COMPUTER account, so granting CONNECT to the
        literal service_account string would silently grant nothing. Resolve to
        DOMAIN\MACHINE$ in those cases.
    #>
    param([Parameter(Mandatory)][psobject]$InstanceInfo)

    $acct = Get-AgScalar -Instance $InstanceInfo.Instance -Query @'
SELECT TOP 1 service_account AS v
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%'
'@
    if (-not $acct) { throw "Could not determine the SQL Server service account on '$($InstanceInfo.Instance)'." }

    $isMachineIdentity = ($acct -match '^(NT SERVICE\\|NT AUTHORITY\\)') -or ($acct -eq 'LocalSystem') -or ($acct -match '\$$')
    if ($isMachineIdentity -and $acct -notmatch '\$$') {
        return '{0}\{1}$' -f $InstanceInfo.NetbiosDomain, $InstanceInfo.PhysicalNode
    }
    return $acct
}

function Test-AgLoginIsSysadmin {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$LoginName
    )
    $v = Get-AgScalar -Instance $Instance -Query "SELECT CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin', $(ConvertTo-AgQuotedString $LoginName)), 0) AS int) AS v"
    return ([int]$v -eq 1)
}

function Grant-AgEndpointConnect {
    <#
    .SYNOPSIS
        Ensures $LoginName exists on $Instance and holds CONNECT on the mirroring endpoint.
        Idempotent; a no-op when the login is already a sysadmin.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$LoginName,
        [Parameter(Mandatory)][string]$EndpointName
    )

    if (Test-AgLoginIsSysadmin -Instance $Instance -LoginName $LoginName) {
        Write-AgLog "  [$Instance] '$LoginName' is sysadmin — CONNECT on the endpoint is implicit." DEBUG
        return
    }

    $granted = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.server_permissions AS perm
JOIN sys.server_principals AS sp ON sp.principal_id = perm.grantee_principal_id
JOIN sys.endpoints         AS e  ON e.endpoint_id   = perm.major_id
WHERE perm.class = 105
  AND perm.permission_name = 'CONNECT'
  AND perm.state IN ('G','W')
  AND e.name  = $(ConvertTo-AgQuotedString $EndpointName)
  AND sp.name = $(ConvertTo-AgQuotedString $LoginName)
"@
    if ([int]$granted -gt 0) {
        Write-AgLog "  [$Instance] '$LoginName' already has CONNECT on endpoint [$EndpointName]." DEBUG
        return
    }

    Write-AgLog "  [$Instance] granting CONNECT on [$EndpointName] to '$LoginName'..." INFO
    Invoke-AgSql -Instance $Instance -QueryTimeout 60 -Activity 'grant endpoint connect' -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $(ConvertTo-AgQuotedString $LoginName))
    CREATE LOGIN $(ConvertTo-AgQuotedName $LoginName) FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::$(ConvertTo-AgQuotedName $EndpointName) TO $(ConvertTo-AgQuotedName $LoginName);
"@ | Out-Null
    Write-AgLog "  [$Instance] granted CONNECT to '$LoginName'." SUCCESS
}

#endregion

#region ── Endpoints ─────────────────────────────────────────────────────────

function Test-AgPortInUse {
    <#
    .SYNOPSIS
        Is some other TCP listener on this instance already bound to $Port?
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][int]$Port
    )
    $v = Get-AgScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.dm_tcp_listener_states WHERE port = $Port"
    return ([int]$v -gt 0)
}

function New-AgMirroringEndpoint {
    <#
    .SYNOPSIS
        Creates and starts a database mirroring endpoint for availability groups.
    .DESCRIPTION
        Windows (NEGOTIATE) authentication with AES encryption required — the configuration
        the New Availability Group wizard creates, and the one every other part of this tool
        assumes. Owned by sa rather than by whoever ran the script: an endpoint owned by a
        person's login breaks the day that login is disabled.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$EndpointName = 'Hadr_endpoint',
        [int]$Port = 5022
    )
    Invoke-AgSql -Instance $Instance -QueryTimeout 120 -Activity 'create endpoint' -Query @"
CREATE ENDPOINT $(ConvertTo-AgQuotedName $EndpointName)
    AUTHORIZATION [sa]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $Port, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
"@ | Out-Null
    Write-AgLog "  [$Instance] created endpoint [$EndpointName] on port $Port (NEGOTIATE, AES) and started it." SUCCESS
}

function Start-AgMirroringEndpoint {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$EndpointName
    )
    Invoke-AgSql -Instance $Instance -QueryTimeout 60 -Activity 'start endpoint' `
        -Query "ALTER ENDPOINT $(ConvertTo-AgQuotedName $EndpointName) STATE = STARTED;" | Out-Null
    Write-AgLog "  [$Instance] started endpoint [$EndpointName]." SUCCESS
}

#endregion

#region ── AlwaysOn_health extended events session ───────────────────────────

function Enable-AgHealthSession {
    <#
    .SYNOPSIS
        Starts the AlwaysOn_health extended events session and sets it to start with the
        instance. It is what every post-mortem of a failover reads first, and on an instance
        that never had an AG it exists but is stopped.
    #>
    param([Parameter(Mandatory)][string]$Instance)
    try {
        Invoke-AgSql -Instance $Instance -QueryTimeout 60 -Activity 'AlwaysOn_health session' -Query @'
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'AlwaysOn_health')
BEGIN
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON);
    IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'AlwaysOn_health')
        ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;
END
'@ | Out-Null
        Write-AgLog "  [$Instance] AlwaysOn_health extended events session running, starts with the instance." SUCCESS
    } catch {
        Write-AgLog "  [$Instance] could not start AlwaysOn_health (not fatal): $($_.Exception.Message.Split("`n")[0])" WARN
    }
}

#endregion
