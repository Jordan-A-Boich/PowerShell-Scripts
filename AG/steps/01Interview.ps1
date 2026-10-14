#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 01: gather every decision up front and produce the plan.

.DESCRIPTION
    All user interaction lives here. Once the plan is confirmed the rest of the run is
    unattended. The operator types one thing — an instance name — and everything else is
    discovered and offered as a number, with a sensible default on ENTER. Free text is kept
    for what cannot be discovered: an AG or listener name (a default is still offered), an
    IP address, and a backup path when none of the offered ones will do.

    New-AgCreatePlan (Initialize-AG) and New-AgAddPlan (Add-AGDatabase) share the database,
    prerequisite and seeding interviews, so the two scripts ask those questions identically.
#>

Set-StrictMode -Version Latest

#region ── Plan shape ────────────────────────────────────────────────────────

function New-AgPlanObject {
    param(
        [Parameter(Mandatory)][ValidateSet('CREATE','ADD')][string]$Operation,
        [Parameter(Mandatory)][string]$AgName
    )
    [pscustomobject]@{
        PlanId               = "$Operation-$AgName"
        Operation            = $Operation
        CreatedUtc           = (Get-Date).ToUniversalTime().ToString('o')
        Completed            = $false

        AgName               = $AgName
        ClusterName          = $null
        IsContained          = $false
        ReuseSystemDatabases = $false
        IsBasic              = $false
        MinMajorVersion      = 0

        PrimaryReplica       = $null
        SecondaryReplicas    = @()
        ReplicaNames         = @()
        Replicas             = @()    # per-replica settings; see New-AgReplicaSetting
        AgOptions            = $null
        Listener             = $null
        ConfigureReadOnlyRouting = $false

        SeedingMode          = 'AUTOMATIC'
        OriginalSeedingModes = @()    # ADD only: what each replica had, restored afterwards
        MaxConcurrentSeeds   = 3
        SeedCompression      = $true
        ShareRoot            = $null
        ShareRoots           = @()
        StripeCount          = 4
        TLogIntervalMinutes  = 15
        KeepLogBackupJob     = $true
        FileLayoutMode       = 'SOURCE'
        FileLayout           = @()

        Databases            = @()
        Repairs              = @()    # per-database: SetFullRecovery / SetAutoCloseOff / TakeFullBackup
        RepairBackupDirectory= $null
        DropLeftoverCopies   = @()    # "database|replica" pairs agreed to be dropped
        ContainedLogins      = @()    # logins to create inside a contained AG
        Progress             = @()
    }
}

function New-AgReplicaSetting {
    param(
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [Parameter(Mandatory)][bool]$IsPrimary
    )
    [pscustomobject]@{
        Name                 = $InstanceInfo.ServerName
        IsPrimary            = $IsPrimary
        HostFqdn             = $InstanceInfo.HostFqdn
        PhysicalNode         = $InstanceInfo.PhysicalNode
        MajorVersion         = $InstanceInfo.MajorVersion
        TcpPort              = $InstanceInfo.TcpPort
        EndpointName         = 'Hadr_endpoint'
        EndpointPort         = 5022
        CreateEndpoint       = $false
        StartEndpoint        = $false
        EndpointUrl          = $null
        AvailabilityMode     = 'SYNCHRONOUS_COMMIT'
        FailoverMode         = 'AUTOMATIC'
        SecondaryConnections = 'NO'
        BackupPriority       = 50
        SessionTimeout       = 10
        ReadOnlyRoutingUrl   = $null
    }
}

#endregion

#region ── Connecting ────────────────────────────────────────────────────────

function Select-AgSeedInstance {
    <#
    .SYNOPSIS
        The one thing the operator types. Loops until it connects and qualifies.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default
    )
    while ($true) {
        $inst = Read-AgText -Prompt $Prompt -Default $Default
        Write-Host "  Connecting to $inst ..." -ForegroundColor DarkGray
        if (-not (Test-AgConnection -Instance $inst)) {
            Write-Host "  Could not connect to '$inst'. Check the name, that SQL Server is running, and that your credentials are valid." -ForegroundColor Yellow
            $Default = $null
            continue
        }
        $info = Get-AgInstanceInfo -Instance $inst
        if (-not $info.IsSysadmin) {
            Write-Host "  The connected login is not a sysadmin on '$inst'. Availability group configuration requires sysadmin." -ForegroundColor Yellow
            continue
        }
        if (-not $info.IsHadrEnabled) {
            Write-Host "  '$inst' does not have Always On availability groups enabled." -ForegroundColor Yellow
            Write-Host '  Enable it on every replica (this restarts SQL Server), then re-run:' -ForegroundColor DarkGray
            Write-Host "      Enable-SqlAlwaysOn -ServerInstance '$($info.ServerName)' -Force" -ForegroundColor DarkGray
            continue
        }
        Write-AgLog ("  Connected to {0} — {1} {2} ({3})" -f $info.ServerName, (Get-AgSqlVersionName $info.MajorVersion), $info.Edition, $info.ProductVersion) SUCCESS
        return $info
    }
}

function Get-AgCandidateInstanceName {
    <#
    .SYNOPSIS
        What to connect to for a cluster node: the node name, plus the instance name when the
        seed instance is a named instance (the usual layout puts the same instance name on
        every node).
    #>
    param(
        [Parameter(Mandatory)][string]$Node,
        [psobject]$SeedInfo
    )
    if ($SeedInfo -and $SeedInfo.InstanceName) { return "$Node\$($SeedInfo.InstanceName)" }
    return $Node
}

#endregion

#region ── CREATE: replicas ──────────────────────────────────────────────────

function Read-AgReplicaSet {
    <#
    .SYNOPSIS
        Discovers the SQL Server instances on the other cluster nodes, probes each one, and
        lets the operator choose which become secondary replicas.
    .OUTPUTS
        Instance-info objects for the chosen secondaries.
    #>
    param(
        [Parameter(Mandatory)][psobject]$PrimaryInfo,
        [Parameter(Mandatory)][psobject]$Cluster,
        [Parameter(Mandatory)][hashtable]$InstanceInfo
    )

    Write-Host ''
    Write-Host "Probing the other nodes of cluster '$($Cluster.ClusterName)' for SQL Server instances..." -ForegroundColor DarkGray

    $candidates = New-Object System.Collections.Generic.List[psobject]
    $unusable   = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Cluster.Nodes) {
        if ($n.Name -ieq $PrimaryInfo.PhysicalNode) { continue }
        $name = Get-AgCandidateInstanceName -Node $n.Name -SeedInfo $PrimaryInfo
        if ($n.State -ne 'UP') { $unusable.Add("$name — cluster node is $($n.State)"); continue }
        if (-not (Test-AgConnection -Instance $name)) { $unusable.Add("$name — cannot connect"); continue }
        $info = Get-AgInstanceInfo -Instance $name
        if (-not $info.IsSysadmin)    { $unusable.Add("$name — connected login is not sysadmin"); continue }
        if (-not $info.IsHadrEnabled) { $unusable.Add("$name — Always On is not enabled (Enable-SqlAlwaysOn -ServerInstance '$name' -Force)"); continue }
        if ($info.MajorVersion -lt $PrimaryInfo.MajorVersion) {
            $unusable.Add("$name — $(Get-AgSqlVersionName $info.MajorVersion) is older than the primary; databases cannot move to an older version"); continue
        }
        $InstanceInfo[$info.ServerName] = $info
        $candidates.Add($info)
    }

    if ($unusable.Count -gt 0) {
        Write-Host ''
        Write-Host 'These nodes cannot host a replica right now:' -ForegroundColor Yellow
        $unusable | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }

    $chosen = @()
    if ($candidates.Count -gt 0) {
        $chosen = @(Read-AgSelection -Title 'Which instances should be SECONDARY replicas?' -Items @($candidates.ToArray()) -AllowNone -Display {
            param($i) '{0,-28} {1} {2}' -f $i.ServerName, (Get-AgSqlVersionName $i.MajorVersion), $i.Edition
        })
    } else {
        Write-Host ''
        Write-Host 'No other cluster node has a usable SQL Server instance.' -ForegroundColor Yellow
    }

    # A named instance whose name differs per node, or an instance the probe could not
    # guess, can still be added by name.
    while (Read-AgYesNo -Question 'Add a replica that is not listed (e.g. a differently named instance)?' -DefaultYes $false) {
        $extra = Select-AgSeedInstance -Prompt 'Instance name (SERVER or SERVER\INSTANCE)'
        if ($extra.ServerName -eq $PrimaryInfo.ServerName -or @($chosen | Where-Object { $_.ServerName -eq $extra.ServerName }).Count -gt 0) {
            Write-Host '  That instance is already in the list.' -ForegroundColor Yellow
            continue
        }
        $extraCluster = Get-AgClusterInfo -Instance $extra.Instance
        if (-not $extraCluster -or $extraCluster.ClusterName -ne $Cluster.ClusterName) {
            Write-Host "  '$($extra.ServerName)' is not a node of cluster '$($Cluster.ClusterName)'. Every replica of a WSFC availability group must be." -ForegroundColor Yellow
            continue
        }
        $InstanceInfo[$extra.ServerName] = $extra
        $chosen += $extra
    }

    if ($chosen.Count -eq 0) {
        Write-Host ''
        Write-Host 'No secondary replicas chosen. The availability group will have a primary only;' -ForegroundColor Yellow
        Write-Host 'add replicas later with ALTER AVAILABILITY GROUP ... ADD REPLICA.' -ForegroundColor Yellow
        if (-not (Read-AgYesNo -Question 'Create a single-replica availability group?' -DefaultYes $false)) {
            throw 'An availability group needs at least one secondary replica to protect anything. Aborted by operator.'
        }
    }
    return @($chosen)
}

function Read-AgReplicaRoles {
    <#
    .SYNOPSIS
        Synchronous + automatic failover, synchronous + manual, or asynchronous, per replica.
    #>
    param(
        [Parameter(Mandatory)][psobject[]]$Replicas,   # replica settings, primary first
        [Parameter(Mandatory)][psobject]$Limit
    )

    if ($Replicas.Count -eq 1) {
        $Replicas[0].AvailabilityMode = 'SYNCHRONOUS_COMMIT'; $Replicas[0].FailoverMode = 'MANUAL'
        return
    }

    $label = { param($r) if ($r.IsPrimary) { "$($r.Name)  (primary)" } else { $r.Name } }

    while ($true) {
        $defaultAuto = [math]::Min($Replicas.Count, $Limit.MaxAutoFailover)
        $auto = @(Read-AgSelection -Title 'Which replicas should be SYNCHRONOUS commit with AUTOMATIC failover?' `
                    -Items $Replicas -Display $label -AllowNone -Default "1-$defaultAuto" `
                    -Hint "Automatic failover needs the primary and at least one secondary in this set. Up to $($Limit.MaxAutoFailover) replicas.")

        if ($auto.Count -gt $Limit.MaxAutoFailover) {
            Write-Host "  At most $($Limit.MaxAutoFailover) replicas can fail over automatically on this version." -ForegroundColor Yellow; continue
        }
        if ($auto.Count -gt 0 -and @($auto | Where-Object { $_.IsPrimary }).Count -eq 0) {
            Write-Host '  Automatic failover only works when the primary is in the set too — adding it.' -ForegroundColor DarkGray
            $auto = @($Replicas | Where-Object { $_.IsPrimary }) + $auto
            if ($auto.Count -gt $Limit.MaxAutoFailover) {
                Write-Host "  That makes $($auto.Count), over the limit of $($Limit.MaxAutoFailover). Choose again." -ForegroundColor Yellow; continue
            }
        }
        if ($auto.Count -eq 1) {
            Write-Host '  A single replica cannot fail over automatically to anything; it will be synchronous with manual failover.' -ForegroundColor DarkGray
        }

        $rest = @($Replicas | Where-Object { $auto -notcontains $_ })
        $syncManual = @()
        if ($rest.Count -gt 0) {
            $syncManual = @(Read-AgSelection -Title 'Of the remaining replicas, which should be SYNCHRONOUS commit with MANUAL failover?' `
                            -Items $rest -Display $label -AllowNone -Default 'none' `
                            -Hint 'Anything not chosen here becomes ASYNCHRONOUS commit with manual failover — the right choice for a distant DR site.')
        }

        $syncCount = $auto.Count + $syncManual.Count
        if ($syncCount -gt $Limit.MaxSync) {
            Write-Host "  At most $($Limit.MaxSync) replicas (the primary included) can be synchronous on this version. Choose again." -ForegroundColor Yellow; continue
        }

        foreach ($r in $Replicas) {
            if ($auto -contains $r -and $auto.Count -gt 1) {
                $r.AvailabilityMode = 'SYNCHRONOUS_COMMIT'; $r.FailoverMode = 'AUTOMATIC'
            } elseif ($auto -contains $r -or $syncManual -contains $r) {
                $r.AvailabilityMode = 'SYNCHRONOUS_COMMIT'; $r.FailoverMode = 'MANUAL'
            } else {
                $r.AvailabilityMode = 'ASYNCHRONOUS_COMMIT'; $r.FailoverMode = 'MANUAL'
            }
        }
        return
    }
}

function Set-AgEndpointPlan {
    <#
    .SYNOPSIS
        Decides, per replica, whether its mirroring endpoint exists, needs starting, or must
        be created — and on which port — so the operator is not asked about any of it.
    .DESCRIPTION
        Endpoints that exist are used as they are. Missing ones are created on the port the
        other replicas already use (5022 when none has one), moving up a port only if that
        one is taken on this instance.
    #>
    param(
        [Parameter(Mandatory)][psobject[]]$Replicas,
        [bool]$UseFqdn = $true
    )
    $existing = @{}
    foreach ($r in $Replicas) { $existing[$r.Name] = Get-AgEndpointInfo -Instance $r.Name }
    $ports = @($existing.Values | Where-Object { $_ } | ForEach-Object { $_.Port } | Sort-Object -Unique)
    $basePort = if ($ports.Count -gt 0) { [int]$ports[0] } else { 5022 }

    foreach ($r in $Replicas) {
        $ep = $existing[$r.Name]
        if ($ep) {
            $r.EndpointName   = $ep.EndpointName
            $r.EndpointPort   = $ep.Port
            $r.CreateEndpoint = $false
            $r.StartEndpoint  = ($ep.StateDesc -ne 'STARTED')
        } else {
            $port = $basePort
            while (Test-AgPortInUse -Instance $r.Name -Port $port) { $port++ }
            $r.EndpointName   = 'Hadr_endpoint'
            $r.EndpointPort   = $port
            $r.CreateEndpoint = $true
            $r.StartEndpoint  = $false
        }
        $hostName = if ($UseFqdn) { $r.HostFqdn } else { ($r.HostFqdn -split '\.')[0] }
        $r.EndpointUrl = 'TCP://{0}:{1}' -f $hostName, $r.EndpointPort
        $r.ReadOnlyRoutingUrl = 'TCP://{0}:{1}' -f $hostName, $r.TcpPort
    }
}

function Read-AgName {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$ClusterName
    )
    # sys.availability_groups_cluster lists every AG in the WSFC, including ones this
    # instance does not host — the name must be unique across the cluster.
    $rows  = Invoke-AgSql -Instance $Instance -Retry -Activity 'existing AG names' `
                -Query 'SELECT name FROM sys.availability_groups_cluster UNION SELECT name FROM sys.availability_groups'
    $taken = @($rows | ForEach-Object { [string]$_.name })
    $n = 1
    while ($taken -contains "AG$n") { $n++ }
    $default = "AG$n"
    if ($taken.Count -gt 0) {
        Write-Host ''
        Write-Host "Availability groups already in cluster '$ClusterName': $($taken -join ', ')" -ForegroundColor DarkGray
    }
    return Read-AgText -Prompt 'Name for the new availability group' -Default $default `
        -Validate { param($v) $v.Length -le 128 -and $v -notmatch '[\[\]]' -and $taken -notcontains $v } `
        -ValidationMessage 'Use 128 characters or fewer, no square brackets, and a name not already used in this cluster.'
}

function Read-AgListenerPlan {
    param(
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][psobject]$Cluster,
        [Parameter(Mandatory)][psobject[]]$Replicas,
        [bool]$IsContained,
        [int]$DefaultPort = 1433
    )

    $hint = if ($IsContained) {
        'A contained AG is only reachable as a contained environment through its listener — strongly recommended.'
    } else { 'Applications connect to the listener and follow the primary through failovers.' }
    $choice = Read-AgChoice -Title 'Create an availability group listener?' -DefaultIndex 0 -Hint $hint -Items @(
        'Yes — create the listener now'
        'No — I will create it later (the script prints the statement to use)'
    )
    if ($choice -like 'No*') { return [pscustomobject]@{ Create = $false; Name = $null; Port = $DefaultPort; Dhcp = $false; Addresses = @() } }

    #region Name
    $base = ($AgName -replace '[^A-Za-z0-9-]', '')
    if (-not $base) { $base = 'AG' }
    $suggest = if ($base.Length -le 11) { "$base-LSN" } else { $base.Substring(0, [math]::Min(15, $base.Length)) }
    $reserved = @($Cluster.ClusterName) + @($Cluster.Nodes | ForEach-Object { $_.Name })
    $name = $null
    while (-not $name) {
        $v = Read-AgText -Prompt 'Listener network name (becomes a computer object in Active Directory)' -Default $suggest `
                -Validate { param($x) Test-AgNetbiosName $x } `
                -ValidationMessage 'Use 1-15 letters, digits or hyphens (a NetBIOS name), not all digits.'
        if ($reserved -contains $v) { Write-Host "  '$v' is the cluster's or a node's own name." -ForegroundColor Yellow; continue }
        $resolved = @(Resolve-AgDnsName -Name $v)
        if ($resolved.Count -gt 0) {
            Write-Host "  '$v' already resolves in DNS to $($resolved -join ', ')." -ForegroundColor Yellow
            if (-not (Read-AgYesNo -Question 'Use it anyway (for example a stale record you are replacing)?' -DefaultYes $false)) { continue }
        }
        $name = $v
    }
    #endregion

    #region Port
    $portItems = @('1433')
    if ($DefaultPort -ne 1433) { $portItems = @("$DefaultPort (the instances' own port)", '1433') }
    $portItems += 'Another port'
    $p = Read-AgChoice -Title 'Listener TCP port' -Items $portItems -DefaultIndex 0 `
            -Hint 'Using the same port as the instances means clients need no port in the connection string when it is 1433.'
    $port = if ($p -eq 'Another port') {
        [int](Read-AgText -Prompt 'Port' -Validate { param($x) $x -match '^\d+$' -and [int]$x -ge 1 -and [int]$x -le 65535 } -ValidationMessage 'Enter 1-65535.')
    } else { [int](($p -split ' ')[0]) }
    #endregion

    #region Addresses
    $nodes   = @($Replicas | ForEach-Object { $_.PhysicalNode })
    $subnets = @(Get-AgListenerSubnet -Cluster $Cluster -NodeNames $nodes)
    $dhcp    = $false
    $addresses = New-Object System.Collections.Generic.List[psobject]

    if ($subnets.Count -eq 0) {
        Write-Host '  No public IPv4 cluster network was found for the replicas'' nodes; the listener will use DHCP.' -ForegroundColor Yellow
        $dhcp = $true
    } else {
        if ($subnets.Count -gt 1) {
            Write-Host ''
            Write-Host "MULTI-SUBNET availability group: the replicas span $($subnets.Count) subnets." -ForegroundColor Yellow
            Write-Host '  The listener needs one static IP address in EACH subnet. Only the address in the' -ForegroundColor DarkGray
            Write-Host '  current primary''s subnet is online at any time; WSFC switches it on failover.' -ForegroundColor DarkGray
            Write-Host '  Clients should connect with MultiSubnetFailover=True.' -ForegroundColor DarkGray
        } else {
            $mode = Read-AgChoice -Title 'Listener IP address' -DefaultIndex 0 -Items @(
                'Static IP address (recommended)'
                'DHCP'
            ) -Hint "Subnet $($subnets[0].SubnetIp)/$($subnets[0].PrefixLength) ($($subnets[0].Nodes -join ', '))"
            $dhcp = ($mode -eq 'DHCP')
        }

        if (-not $dhcp) {
            foreach ($s in $subnets) {
                $ip = $null
                while (-not $ip) {
                    $v = Read-AgText -Prompt "Static IP for subnet $($s.SubnetIp)/$($s.PrefixLength) (nodes: $($s.Nodes -join ', '))" `
                        -Validate { param($x) Test-AgIpInSubnet -Address $x -SubnetIp $s.SubnetIp -SubnetMask $s.SubnetMask } `
                        -ValidationMessage "Enter a host address inside $($s.SubnetIp) / $($s.SubnetMask)."
                    if (@($addresses | Where-Object { $_.IpAddress -eq $v }).Count -gt 0) { Write-Host '  Already used above.' -ForegroundColor Yellow; continue }
                    Write-Host "  Checking whether anything answers on $v ..." -ForegroundColor DarkGray
                    if (Test-AgIpInUse -Address $v) {
                        Write-Host "  $v answers a ping — it is in use. A listener on it will not come online." -ForegroundColor Yellow
                        if (-not (Read-AgYesNo -Question 'Use it anyway?' -DefaultYes $false)) { continue }
                    }
                    $ip = $v
                }
                $addresses.Add([pscustomobject]@{ IpAddress = $ip; SubnetMask = $s.SubnetMask; SubnetIp = $s.SubnetIp })
            }
        }
    }
    #endregion

    [pscustomobject]@{
        Create    = $true
        Name      = $name
        Port      = $port
        Dhcp      = $dhcp
        DhcpSubnet= if ($dhcp -and $subnets.Count -eq 1) { [pscustomobject]@{ SubnetIp = $subnets[0].SubnetIp; SubnetMask = $subnets[0].SubnetMask } } else { $null }
        Addresses = @($addresses.ToArray())
    }
}

function Read-AgAdvancedOptions {
    param(
        [Parameter(Mandatory)][int]$MinMajorVersion,
        [bool]$IsBasic
    )
    $o = [pscustomobject]@{
        FailureConditionLevel     = 3
        HealthCheckTimeout        = 30000
        DbFailover                = $true
        DtcSupport                = 'NONE'
        RequiredSyncedSecondaries = 0
        SessionTimeout            = 10
        UseFqdn                   = $true
    }

    Write-Host ''
    Write-Host 'Remaining availability group settings — the recommended values are:' -ForegroundColor Cyan
    Write-Host '   Failure condition level        3  (fail over on critical server errors)' -ForegroundColor DarkGray
    Write-Host '   Health check timeout           30000 ms' -ForegroundColor DarkGray
    Write-Host '   Database-level health (DB_FAILOVER)  ON — a database going offline triggers failover' -ForegroundColor DarkGray
    Write-Host '   DTC support                    NONE' -ForegroundColor DarkGray
    if ($MinMajorVersion -ge 14) {
        Write-Host '   Required synchronized secondaries to commit  0' -ForegroundColor DarkGray
    }
    Write-Host '   Session timeout                10 s' -ForegroundColor DarkGray
    Write-Host '   Endpoint URLs                  fully-qualified host names' -ForegroundColor DarkGray

    if (Read-AgYesNo -Question 'Use the recommended values?' -DefaultYes $true) { return $o }

    $o.FailureConditionLevel = [int](Read-AgChoice -Title 'FAILURE_CONDITION_LEVEL' -DefaultIndex 2 -Items @(1,2,3,4,5) `
        -Hint '1 = service down only ... 5 = also on any qualified failure condition. 3 is the default.')
    $o.HealthCheckTimeout = [int](Read-AgChoice -Title 'HEALTH_CHECK_TIMEOUT (ms)' -DefaultIndex 1 -Items @(15000, 30000, 60000, 90000))
    $o.DbFailover = ((Read-AgChoice -Title 'DB_FAILOVER (database-level health detection)' -DefaultIndex 0 -Items @('ON','OFF')) -eq 'ON')
    if (-not $IsBasic -and $MinMajorVersion -ge 13) {
        $o.DtcSupport = Read-AgChoice -Title 'DTC_SUPPORT' -DefaultIndex 0 -Items @('NONE','PER_DB') `
            -Hint 'PER_DB only if the applications run distributed (MSDTC) transactions against these databases.'
    }
    if (-not $IsBasic -and $MinMajorVersion -ge 14) {
        $o.RequiredSyncedSecondaries = [int](Read-AgChoice -Title 'REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT' -DefaultIndex 0 -Items @(0,1,2) `
            -Hint 'Non-zero blocks commits on the primary when too few synchronous secondaries are connected.')
    }
    $o.SessionTimeout = [int](Read-AgChoice -Title 'SESSION_TIMEOUT (seconds)' -DefaultIndex 0 -Items @(10, 15, 20, 30))
    $o.UseFqdn = ((Read-AgChoice -Title 'Endpoint URL host names' -DefaultIndex 0 -Items @(
        'Fully-qualified (node.domain.com) — recommended'
        'Short names (node) — only where DNS suffix search is guaranteed')) -like 'Fully*')
    return $o
}

#endregion

#region ── Shared: databases, prerequisites, seeding ─────────────────────────

function Read-AgDatabaseSelection {
    <#
    .OUTPUTS
        The chosen candidate objects, unrolled (nothing when none). Collect with @(...).
    #>
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [string[]]$Secondaries = @(),
        [Parameter(Mandatory)][hashtable]$InstanceInfo,
        [switch]$AllowNone,
        [int]$Max = 0
    )

    Write-Host ''
    Write-Host "Discovering databases on $PrimaryInstance and checking them against every replica..." -ForegroundColor DarkGray
    $candidates = @(Get-AgCandidateDatabases -Instance $PrimaryInstance -Secondaries $Secondaries -InstanceInfo $InstanceInfo)

    $ineligible = @($candidates | Where-Object { -not $_.IsEligible })
    if ($ineligible.Count -gt 0) {
        Write-Host ''
        Write-Host 'These databases cannot be added and are not offered:' -ForegroundColor Yellow
        foreach ($d in $ineligible) { Write-Host ("   {0,-32} {1}" -f $d.DatabaseName, $d.IneligibleWhy) -ForegroundColor DarkGray }
    }

    $eligible = @($candidates | Where-Object { $_.IsEligible })
    if ($eligible.Count -eq 0) {
        if ($AllowNone) {
            Write-Host '  No user database on the primary can be added; the availability group will be created empty.' -ForegroundColor Yellow
            return
        }
        throw "No database on '$PrimaryInstance' can be added to an availability group (see the reasons above)."
    }

    $width = [math]::Max(16, [math]::Min(40, (@($eligible | ForEach-Object { $_.DatabaseName.Length }) | Measure-Object -Maximum).Maximum + 2))
    $default = if ($Max -eq 1) { '1' } else { 'all' }
    $hint = 'Anything marked "needs" can be fixed for you — you will be asked next.'
    if ($Max -eq 1) { $hint = 'A Basic availability group holds exactly one database. ' + $hint }
    $picked = @(Read-AgSelection -Title 'Which databases should be in the availability group?' -Items $eligible -AllowNone:$AllowNone -Max $Max -Default $default -Hint $hint -Display {
        param($d) Format-AgCandidateLine -Candidate $d -NameWidth $width
    })
    return $picked
}

function Read-AgBackupDirectory {
    <#
    .SYNOPSIS
        A backup directory, chosen from what the instance already uses, or typed.
    .PARAMETER RequireUnc
        The location must be a UNC path every replica can reach (manual seeding).
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Title,
        [switch]$RequireUnc
    )
    $items = New-Object System.Collections.Generic.List[string]
    $default = Get-AgDefaultBackupPath -Instance $Instance
    $recent  = @(Get-AgRecentBackupDirectories -Instance $Instance)
    foreach ($d in (@($default) + $recent)) {
        if (-not $d) { continue }
        if ($RequireUnc -and $d -notmatch '^\\\\[^\\]+\\[^\\]+') { continue }
        if (-not $items.Contains($d)) { $items.Add($d) }
    }
    $typed = 'Enter a different path'
    $labels = @($items | ForEach-Object {
        if ($_ -eq $default) { "$_   (instance default backup directory)" } else { "$_   (used for recent backups)" }
    }) + @($typed)

    $pick = Read-AgChoice -Title $Title -Items $labels -DefaultIndex 0
    if ($pick -ne $typed) { return (($pick -split '   \(')[0]).TrimEnd('\') }

    if ($RequireUnc) {
        return (Read-AgText -Prompt 'UNC path (e.g. \\fileserver\SQLBackups)' `
            -Validate { param($v) $v -match '^\\\\[^\\]+\\[^\\]+' } -ValidationMessage 'Enter a UNC path such as \\fileserver\SQLBackups.').TrimEnd('\')
    }
    return (Read-AgText -Prompt 'Backup directory (local to the server, or a UNC path)' `
        -Validate { param($v) $v -match '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)' } -ValidationMessage 'Enter a path such as E:\Backup or \\fileserver\SQLBackups.').TrimEnd('\')
}

function Read-AgRepairDecisions {
    <#
    .SYNOPSIS
        For every selected database that is not ready, asks whether to fix it. A database the
        operator declines to fix is dropped from the selection — it cannot join as it is.
    .OUTPUTS
        { Databases = candidates kept; Repairs = per-database actions; BackupDirectory;
          DropLeftover = "db|replica" pairs }
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Selected,
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$SeedingMode
    )

    $keep = New-Object System.Collections.Generic.List[psobject]
    foreach ($d in $Selected) { $keep.Add($d) }

    #region Recovery model
    $needRecovery = @($keep | Where-Object { $_.NeedsFullRecovery })
    $fixRecovery = $false
    if ($needRecovery.Count -gt 0) {
        Write-Host ''
        Write-Host 'Availability groups require the FULL recovery model. Not in FULL today:' -ForegroundColor Yellow
        $needRecovery | ForEach-Object { Write-Host ("   {0,-32} {1}" -f $_.DatabaseName, $_.RecoveryModel) -ForegroundColor DarkGray }
        $fixRecovery = Read-AgYesNo -Question 'Switch these databases to FULL recovery?' -DefaultYes $true
        if (-not $fixRecovery) {
            Write-Host '  Leaving them out of this run.' -ForegroundColor DarkGray
            foreach ($d in $needRecovery) { [void]$keep.Remove($d) }
        }
    }
    #endregion

    #region AUTO_CLOSE
    $needAutoClose = @($keep | Where-Object { $_.NeedsAutoCloseOff })
    $fixAutoClose = $false
    if ($needAutoClose.Count -gt 0) {
        Write-Host ''
        Write-Host 'AUTO_CLOSE is ON for:' -ForegroundColor Yellow
        $needAutoClose | ForEach-Object { Write-Host "   $($_.DatabaseName)" -ForegroundColor DarkGray }
        Write-Host '  A database that closes itself cannot keep a secondary synchronized.' -ForegroundColor DarkGray
        $fixAutoClose = Read-AgYesNo -Question 'Turn AUTO_CLOSE OFF for these?' -DefaultYes $true
        if (-not $fixAutoClose) { foreach ($d in $needAutoClose) { [void]$keep.Remove($d) } }
    }
    #endregion

    #region Full backup / log chain
    $needBackup = @($keep | Where-Object { $_.NeedsFullBackup })
    $backupDir = $null
    $takeBackup = $false
    if ($needBackup.Count -gt 0) {
        Write-Host ''
        Write-Host 'A database joins an availability group only after a full backup has started its log chain.' -ForegroundColor Yellow
        Write-Host 'No usable full backup yet (or the recovery model is changing, which needs a fresh one):' -ForegroundColor Yellow
        $needBackup | ForEach-Object {
            $last = if ($_.LastFullBackup) { "last full backup $($_.LastFullBackup.ToString('yyyy-MM-dd HH:mm')) does not start the current chain" } else { 'never backed up' }
            Write-Host ("   {0,-32} {1,10}  {2}" -f $_.DatabaseName, (Format-AgBytes $_.SizeBytes), $last) -ForegroundColor DarkGray
        }

        if ($SeedingMode -eq 'MANUAL') {
            Write-Host '  Manual seeding takes a full backup of each database to the seeding share, and that' -ForegroundColor DarkGray
            Write-Host '  backup starts the log chain — nothing extra is needed.' -ForegroundColor DarkGray
        } else {
            $takeBackup = Read-AgYesNo -Question 'Take a full backup of these databases now?' -DefaultYes $true
            if ($takeBackup) {
                $backupDir = Read-AgBackupDirectory -Instance $PrimaryInstance -Title 'Where should the full backups go?'
            } else {
                Write-Host '  Leaving them out of this run.' -ForegroundColor DarkGray
                foreach ($d in $needBackup) { [void]$keep.Remove($d) }
            }
        }
    }
    #endregion

    #region Leftover copies on secondaries
    $drop = New-Object System.Collections.Generic.List[string]
    $withLeftovers = @($keep | Where-Object { $_.LeftoverCopies.Count -gt 0 })
    if ($withLeftovers.Count -gt 0) {
        Write-Host ''
        Write-Host 'Copies of these databases already sit on secondary replicas (not ONLINE, not in an AG):' -ForegroundColor Yellow
        foreach ($d in $withLeftovers) {
            foreach ($c in $d.LeftoverCopies) { Write-Host ("   {0,-32} on {1} ({2})" -f $d.DatabaseName, $c.Replica, $c.StateDesc) -ForegroundColor DarkGray }
        }
        if ($SeedingMode -eq 'AUTOMATIC') {
            Write-Host '  Automatic seeding cannot seed onto an existing copy; it has to be dropped first.' -ForegroundColor DarkGray
            if (Read-AgYesNo -Question 'Drop these leftover copies so the databases can be seeded?' -DefaultYes $true) {
                foreach ($d in $withLeftovers) { foreach ($c in $d.LeftoverCopies) { $drop.Add("$($d.DatabaseName)|$($c.Replica)") } }
            } else {
                foreach ($d in $withLeftovers) { [void]$keep.Remove($d) }
            }
        } else {
            Write-Host '  Manual seeding checks each copy against the new backup: one already restored from it is' -ForegroundColor DarkGray
            Write-Host '  reused, anything else stops the run rather than being overwritten.' -ForegroundColor DarkGray
            if (Read-AgYesNo -Question 'Drop these leftover copies first and restore fresh ones?' -DefaultYes $true) {
                foreach ($d in $withLeftovers) { foreach ($c in $d.LeftoverCopies) { $drop.Add("$($d.DatabaseName)|$($c.Replica)") } }
            }
        }
    }
    #endregion

    $repairs = @($keep | Where-Object { $_.Needs.Count -gt 0 } | ForEach-Object {
        [pscustomobject]@{
            DatabaseName    = $_.DatabaseName
            SetFullRecovery = ($fixRecovery -and $_.NeedsFullRecovery)
            SetAutoCloseOff = ($fixAutoClose -and $_.NeedsAutoCloseOff)
            TakeFullBackup  = ($takeBackup -and $_.NeedsFullBackup)
        }
    })

    [pscustomobject]@{
        Databases       = @($keep.ToArray())
        Repairs         = $repairs
        BackupDirectory = $backupDir
        DropLeftover    = @($drop.ToArray())
    }
}

function Read-AgSeedingMode {
    param(
        [string]$Default = 'AUTOMATIC',
        [bool]$IsContained,
        [int]$MinMajorVersion,
        [bool]$IsCreate = $true
    )
    $items = @(
        'AUTOMATIC seeding — SQL Server streams each database to the secondaries. No backup share needed.'
        'MANUAL seeding — back up to a share, restore on each secondary, then join. Best for very large databases or slow links.'
    )
    $def = if ($Default -eq 'MANUAL') { 1 } else { 0 }
    $hint = 'Automatic seeding needs the same drive letters and folders on every replica (they are created when missing).'
    $pick = Read-AgChoice -Title 'How should the databases be synchronized to the secondaries?' -Items $items -DefaultIndex $def -Hint $hint
    $mode = if ($pick -like 'AUTOMATIC*') { 'AUTOMATIC' } else { 'MANUAL' }
    if ($mode -eq 'MANUAL' -and $IsContained -and $IsCreate) {
        Write-Host '  Contained AG: its own master and msdb are always seeded automatically; your databases' -ForegroundColor DarkGray
        Write-Host '  are then restored from backup and joined once the AG exists.' -ForegroundColor DarkGray
    }
    return $mode
}

function Read-AgSeedingDetail {
    <#
    .SYNOPSIS
        Fills in the seeding settings on the plan: concurrency and compression for automatic;
        share, stripes, log interval, the log backup job's future and the file layout for manual.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [int]$MaxConcurrentSeeds = 3
    )

    if ($Plan.SeedingMode -eq 'AUTOMATIC') {
        $Plan.MaxConcurrentSeeds = $MaxConcurrentSeeds
        if ($Plan.Databases.Count -gt 1) {
            $Plan.MaxConcurrentSeeds = [int](Read-AgChoice -Title 'How many databases may seed at the same time?' -Items @(1, 2, 3, 5, 10) `
                -DefaultIndex ([math]::Max(0, [array]::IndexOf(@(1,2,3,5,10), $MaxConcurrentSeeds))) `
                -Hint 'Databases are added to the AG through a sliding window of this size, so the endpoint is never flooded.')
        }
        $Plan.SeedCompression = Read-AgYesNo -Question 'Compress the seeding stream (trace flag 9567)? Uses CPU on the primary, saves network.' -DefaultYes $true
        return
    }

    #region Share(s)
    $first = Read-AgBackupDirectory -Instance $Plan.PrimaryReplica -RequireUnc `
                -Title 'Backup share for seeding (every replica''s SQL Server service account needs read/write)'
    $roots = @($first)
    while (Read-AgYesNo -Question 'Stripe the full backups across another share as well (another file-server node)?' -DefaultYes $false) {
        $more = Read-AgText -Prompt 'Additional UNC path' -Validate { param($v) $v -match '^\\\\[^\\]+\\[^\\]+' } -ValidationMessage 'Enter a UNC path.'
        $roots += $more.TrimEnd('\')
    }
    $Plan.ShareRoots = @($roots | Select-Object -Unique)
    $Plan.ShareRoot  = $Plan.ShareRoots[0]
    if ($Plan.ShareRoots.Count -gt 1) {
        $Plan.StripeCount = $Plan.ShareRoots.Count
        Write-Host "  Each full backup is striped one file per share; log backups go to $($Plan.ShareRoot)." -ForegroundColor DarkGray
    } else {
        $Plan.StripeCount = [int](Read-AgChoice -Title 'How many files should each FULL backup be striped across?' -Items @(1, 2, 4, 8, 16) -DefaultIndex 2 `
            -Hint 'More stripes usually means a faster backup and restore for large databases.')
    }
    #endregion

    $Plan.TLogIntervalMinutes = [int](Read-AgChoice -Title 'How often should transaction logs be backed up while seeding runs?' `
                                    -Items @(5, 10, 15, 30) -DefaultIndex 2 `
                                    -Hint 'A log backup job on every replica keeps the log chain on the share unbroken until each database joins.')

    $keep = Read-AgChoice -Title 'When seeding finishes, what should happen to that log backup job?' -DefaultIndex 0 -Items @(
        'KEEP it — it carries on backing up these databases'' logs to the share (choose this if nothing else does)'
        'REMOVE it — my regular backup maintenance takes over'
    )
    $Plan.KeepLogBackupJob = ($keep -like 'KEEP*')

    #region File layout on the secondaries
    $layout = New-AgFileLayoutPlan -SourceInstance $Plan.PrimaryReplica -Databases @($Plan.Databases) `
                -RestoreTargets @($Plan.SecondaryReplicas)
    $Plan.FileLayoutMode = $layout.Mode
    $Plan.FileLayout     = @($layout.Entries)
    #endregion
}

function Read-AgContainedLoginDecision {
    param([Parameter(Mandatory)][psobject]$Plan)
    if (-not $Plan.IsContained -or $Plan.Databases.Count -eq 0) { return }

    $logins = @(Get-AgLoginsForDatabases -Instance $Plan.PrimaryReplica -Databases @($Plan.Databases))
    if ($logins.Count -eq 0) { return }

    Write-Host ''
    Write-Host 'Contained AG logins' -ForegroundColor Yellow
    Write-Host '  Connections through the listener authenticate against the contained AG''s own master.' -ForegroundColor DarkGray
    Write-Host '  Only sysadmin logins are copied there automatically. Users in these databases map to:' -ForegroundColor DarkGray
    $logins | ForEach-Object {
        $kind = switch ($_.LoginType) { 'S' { 'SQL login' } 'U' { 'Windows user' } 'G' { 'Windows group' } default { $_.LoginType } }
        Write-Host ("   {0,-36} {1}" -f $_.LoginName, $kind) -ForegroundColor DarkGray
    }
    if (Read-AgYesNo -Question 'Create these logins inside the contained AG (same SID and password)?' -DefaultYes $true) {
        $Plan.ContainedLogins = @($logins)
    }
}

#endregion

#region ── CREATE ────────────────────────────────────────────────────────────

function New-AgCreatePlan {
    param([int]$MaxConcurrentSeeds = 3)

    Write-AgBanner 'BUILD THE PLAN'
    Write-Host 'Everything is asked now. Once the plan is confirmed the run is unattended.' -ForegroundColor DarkGray
    Write-Host 'Press ENTER to take the default shown in [brackets] or marked with *.' -ForegroundColor DarkGray

    $instanceInfo = @{}

    #region Primary and cluster
    $primaryInfo = Select-AgSeedInstance -Prompt 'SQL Server instance that holds the databases today — it becomes the PRIMARY (SERVER or SERVER\INSTANCE)'
    $instanceInfo[$primaryInfo.ServerName] = $primaryInfo

    $cluster = Get-AgClusterInfo -Instance $primaryInfo.ServerName
    if (-not $cluster) {
        throw "'$($primaryInfo.ServerName)' is not running on a Windows Server Failover Cluster node. Build the WSFC (and enable Always On) before creating an availability group."
    }
    Write-AgLog ("  Cluster '{0}': {1} node(s), quorum {2} ({3})" -f $cluster.ClusterName, $cluster.Nodes.Count, $cluster.QuorumType, $cluster.QuorumState) INFO
    if ($cluster.QuorumState -notlike 'NORMAL*') {
        Write-Host "  The cluster reports quorum state '$($cluster.QuorumState)'. Fix quorum before relying on automatic failover." -ForegroundColor Yellow
    }
    #endregion

    $secondaryInfos = @(Read-AgReplicaSet -PrimaryInfo $primaryInfo -Cluster $cluster -InstanceInfo $instanceInfo)
    $allInfos       = @($primaryInfo) + $secondaryInfos
    $minMajor       = ($allInfos | Measure-Object -Property MajorVersion -Minimum).Minimum

    $agName = Read-AgName -Instance $primaryInfo.ServerName -ClusterName $cluster.ClusterName
    $plan   = New-AgPlanObject -Operation 'CREATE' -AgName $agName
    $plan.ClusterName     = $cluster.ClusterName
    $plan.MinMajorVersion = $minMajor

    #region Kind of AG
    $isBasic = (@($allInfos | Where-Object { $_.IsStandard }).Count -gt 0)
    if ($isBasic) {
        Write-Host ''
        Write-Host 'Standard Edition detected — this will be a BASIC availability group:' -ForegroundColor Yellow
        Write-Host '  two replicas, one database, no readable secondaries, backups on the primary only.' -ForegroundColor DarkGray
        if ($secondaryInfos.Count -gt 1) { throw 'A Basic availability group supports exactly one secondary replica. Re-run and choose one.' }
    } elseif ($minMajor -ge 16) {
        $kind = Read-AgChoice -Title 'What kind of availability group?' -DefaultIndex 0 -Items @(
            'STANDARD availability group'
            'CONTAINED availability group — logins, users, permissions and Agent jobs travel with the AG (its own master and msdb)'
        )
        if ($kind -like 'CONTAINED*') {
            $plan.IsContained = $true
            $sysDbs = Get-AgContainedSystemDatabaseNames -AgName $agName
            $found  = @($sysDbs | Where-Object { Get-AgDatabaseState -Instance $primaryInfo.ServerName -DatabaseName $_ })
            if ($found.Count -gt 0) {
                Write-Host ''
                Write-Host "  $($found -join ' and ') already exist on $($primaryInfo.ServerName), from an earlier contained AG of this name." -ForegroundColor Yellow
                $plan.ReuseSystemDatabases = Read-AgYesNo -Question 'Reuse them (keeps that AG''s logins and jobs)? No drops and recreates them.' -DefaultYes $true
            }
        }
    } else {
        Write-Host '  (Contained availability groups need SQL Server 2022 or later on every replica.)' -ForegroundColor DarkGray
    }
    $plan.IsBasic = $isBasic
    #endregion

    #region Replicas, roles, endpoints
    $replicas = @(@(New-AgReplicaSetting -InstanceInfo $primaryInfo -IsPrimary $true) +
                  @($secondaryInfos | ForEach-Object { New-AgReplicaSetting -InstanceInfo $_ -IsPrimary $false }))
    $limit = Get-AgReplicaLimit -MajorVersion $minMajor -IsBasic $isBasic
    if ($replicas.Count -gt $limit.MaxReplicas) { throw "At most $($limit.MaxReplicas) replicas are supported (chosen: $($replicas.Count))." }
    Read-AgReplicaRoles -Replicas $replicas -Limit $limit

    if (-not $isBasic -and $secondaryInfos.Count -gt 0) {
        $read = Read-AgChoice -Title 'Should the SECONDARY replicas accept read connections?' -DefaultIndex 0 -Items @(
            'NO — secondaries are for failover only'
            'READ-INTENT ONLY — connections that say ApplicationIntent=ReadOnly'
            'YES — any connection may read'
        ) -Hint 'Readable secondaries need Enterprise Edition licensing on those replicas.'
        $conn = switch -Wildcard ($read) { 'NO*' { 'NO' } 'READ-INTENT*' { 'READ_ONLY' } default { 'ALL' } }
        foreach ($r in $replicas) { $r.SecondaryConnections = $conn }
    }

    $backupPref = 'PRIMARY'
    if (-not $isBasic -and $secondaryInfos.Count -gt 0) {
        $bp = Read-AgChoice -Title 'Where should backups preferably run? (honoured by sys.fn_hadr_backup_is_preferred_replica)' -DefaultIndex 0 -Items @(
            'SECONDARY — prefer a secondary, fall back to the primary'
            'SECONDARY_ONLY — never on the primary'
            'PRIMARY — always on the primary'
            'NONE — any replica'
        )
        $backupPref = ($bp -split ' ')[0]
    }

    $opts = Read-AgAdvancedOptions -MinMajorVersion $minMajor -IsBasic $isBasic
    $opts | Add-Member -NotePropertyName AutomatedBackupPreference -NotePropertyValue $backupPref
    foreach ($r in $replicas) { $r.SessionTimeout = $opts.SessionTimeout }
    Set-AgEndpointPlan -Replicas $replicas -UseFqdn $opts.UseFqdn

    $plan.AgOptions         = $opts
    $plan.Replicas          = $replicas
    $plan.PrimaryReplica    = $primaryInfo.ServerName
    $plan.SecondaryReplicas = @($secondaryInfos | ForEach-Object { $_.ServerName })
    $plan.ReplicaNames      = @($replicas | ForEach-Object { $_.Name })
    #endregion

    #region Listener
    $plan.Listener = Read-AgListenerPlan -AgName $agName -Cluster $cluster -Replicas $replicas -IsContained $plan.IsContained -DefaultPort $primaryInfo.TcpPort
    if ($plan.Listener.Create -and @($replicas | Where-Object { $_.SecondaryConnections -ne 'NO' }).Count -gt 0) {
        $plan.ConfigureReadOnlyRouting = Read-AgYesNo -Question 'Configure read-only routing, so ApplicationIntent=ReadOnly connections to the listener land on a readable secondary?' -DefaultYes $true
    }
    #endregion

    #region Databases
    $selected = @(Read-AgDatabaseSelection -PrimaryInstance $plan.PrimaryReplica -Secondaries $plan.SecondaryReplicas `
                    -InstanceInfo $instanceInfo -AllowNone -Max $(if ($isBasic) { 1 } else { 0 }))

    if ($selected.Count -gt 0 -and $plan.SecondaryReplicas.Count -gt 0) {
        $plan.SeedingMode = Read-AgSeedingMode -IsContained $plan.IsContained -MinMajorVersion $minMajor
    }
    $repair = Read-AgRepairDecisions -Selected $selected -PrimaryInstance $plan.PrimaryReplica -SeedingMode $plan.SeedingMode
    $plan.Databases             = @($repair.Databases | ForEach-Object { $_.DatabaseName })
    $plan.Repairs               = @($repair.Repairs)
    $plan.RepairBackupDirectory = $repair.BackupDirectory
    $plan.DropLeftoverCopies    = @($repair.DropLeftover)

    if ($plan.Databases.Count -gt 0 -and $plan.SecondaryReplicas.Count -gt 0) {
        Read-AgSeedingDetail -Plan $plan -MaxConcurrentSeeds $MaxConcurrentSeeds
    }
    Read-AgContainedLoginDecision -Plan $plan
    #endregion

    $plan.Progress = @($plan.Databases | ForEach-Object { New-AgProgressRecord -DatabaseName $_ })
    return $plan
}

#endregion

#region ── ADD ───────────────────────────────────────────────────────────────

function Select-AgExistingAg {
    <#
    .SYNOPSIS
        Connects to any replica, picks the AG by number, and re-anchors on its primary.
    .OUTPUTS
        { Topology; InstanceInfo (hashtable) }
    #>
    param(
        [string]$Instance,
        [string]$AgName,
        [string]$Purpose = 'add databases to'
    )
    $info = if ($Instance) {
        if (-not (Test-AgConnection -Instance $Instance)) { throw "Cannot connect to '$Instance'." }
        Get-AgInstanceInfo -Instance $Instance
    } else {
        Select-AgSeedInstance -Prompt 'ANY replica of the availability group (SERVER or SERVER\INSTANCE)'
    }

    $ags = @(Get-AgLocalAvailabilityGroups -Instance $info.ServerName)
    if ($ags.Count -eq 0) { throw "No availability groups have a replica on '$($info.ServerName)'." }
    $ag = if ($AgName) {
        $m = @($ags | Where-Object { $_.AgName -eq $AgName })
        if ($m.Count -eq 0) { throw "Availability group '$AgName' has no replica on '$($info.ServerName)'. Found: $(($ags | ForEach-Object { $_.AgName }) -join ', ')." }
        $m[0]
    } else {
        Read-AgChoice -Title "Which availability group do you want to $($Purpose)?" -Items $ags -Display {
            param($a)
            $kind = if ($a.IsContained) { 'contained, ' } elseif ($a.IsBasic) { 'basic, ' } else { '' }
            '{0}  ({1}{2} replicas, {3} database(s), this node is {4})' -f $a.AgName, $kind, $a.ReplicaCount, $a.DatabaseCount, $a.LocalRole
        }
    }

    $topo = Get-AgTopology -Instance $info.ServerName -AgName $ag.AgName
    if ($topo.PrimaryReplica -ne $info.ServerName) {
        Write-AgLog "  The primary replica of [$($ag.AgName)] is $($topo.PrimaryReplica) — using it for all primary-side work." INFO
    }

    $instanceInfo = @{}
    foreach ($r in $topo.Replicas) {
        $name = $r.ReplicaServerName
        if (-not (Test-AgConnection -Instance $name)) { throw "Cannot connect to replica '$name'. Every replica of the availability group must be reachable." }
        $instanceInfo[$name] = Get-AgInstanceInfo -Instance $name
    }
    [pscustomobject]@{ Topology = $topo; InstanceInfo = $instanceInfo }
}

function New-AgAddPlan {
    param(
        [int]$MaxConcurrentSeeds = 3,
        [string]$Instance,
        [string]$AgName
    )

    Write-AgBanner 'BUILD THE PLAN'
    Write-Host 'Everything is asked now. Once the plan is confirmed the run is unattended.' -ForegroundColor DarkGray

    $sel  = Select-AgExistingAg -Instance $Instance -AgName $AgName
    $topo = $sel.Topology
    $instanceInfo = $sel.InstanceInfo

    $plan = New-AgPlanObject -Operation 'ADD' -AgName $topo.AgName
    $plan.PrimaryReplica    = $topo.PrimaryReplica
    $plan.SecondaryReplicas = @($topo.SecondaryReplicas)
    $plan.ReplicaNames      = @($topo.Replicas | ForEach-Object { $_.ReplicaServerName })
    $plan.IsContained       = $topo.IsContained
    $plan.IsBasic           = $topo.IsBasic
    $plan.MinMajorVersion   = ($instanceInfo.Values | Measure-Object -Property MajorVersion -Minimum).Minimum
    $plan.OriginalSeedingModes = @($topo.Replicas | ForEach-Object { [pscustomobject]@{ Replica = $_.ReplicaServerName; SeedingMode = $_.SeedingMode } })
    $cluster = Get-AgClusterInfo -Instance $plan.PrimaryReplica
    if ($cluster) { $plan.ClusterName = $cluster.ClusterName }

    Write-Host ''
    Write-Host "[$($topo.AgName)]  primary $($plan.PrimaryReplica); secondaries $(if ($plan.SecondaryReplicas.Count) { $plan.SecondaryReplicas -join ', ' } else { 'none' })" -ForegroundColor White
    $topo.Replicas | Format-Table ReplicaServerName, Role, AvailabilityMode, FailoverMode, SeedingMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    $notConnected = @($topo.Replicas | Where-Object { $_.Role -ne 'PRIMARY' -and $_.ConnectedState -ne 'CONNECTED' })
    if ($notConnected.Count -gt 0) {
        throw "Secondary replica(s) $(($notConnected | ForEach-Object { $_.ReplicaServerName }) -join ', ') are not CONNECTED. Fix the availability group's health before adding databases."
    }

    if ($topo.IsBasic) {
        $count = Get-AgScalar -Instance $plan.PrimaryReplica -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON ag.group_id = adc.group_id WHERE ag.name = $(ConvertTo-AgQuotedString $topo.AgName)"
        if ([int]$count -ge 1) { throw "[$($topo.AgName)] is a Basic availability group and already holds its one database. Create another Basic AG with Initialize-AG.ps1." }
    }

    $dags = @(Get-AgDistributedParent -Instance $plan.PrimaryReplica -AgName $topo.AgName)
    if ($dags.Count -gt 0) {
        Write-Host "  [$($topo.AgName)] is a member of distributed AG(s) $($dags -join ', '). A database added to the global primary AG also seeds across the DAG." -ForegroundColor Yellow
    }

    $selected = @(Read-AgDatabaseSelection -PrimaryInstance $plan.PrimaryReplica -Secondaries $plan.SecondaryReplicas `
                    -InstanceInfo $instanceInfo -Max $(if ($topo.IsBasic) { 1 } else { 0 }))

    # Offer the AG's own seeding mode first: what it already does is usually what is wanted.
    $currentModes = @($topo.Replicas | Where-Object { $_.Role -ne 'PRIMARY' } | ForEach-Object { $_.SeedingMode } | Sort-Object -Unique)
    $defaultMode  = if ($currentModes.Count -eq 1 -and $currentModes[0] -eq 'MANUAL') { 'MANUAL' } else { 'AUTOMATIC' }
    if ($plan.SecondaryReplicas.Count -gt 0) {
        $plan.SeedingMode = Read-AgSeedingMode -Default $defaultMode -IsContained $plan.IsContained -MinMajorVersion $plan.MinMajorVersion -IsCreate $false
    }

    $repair = Read-AgRepairDecisions -Selected $selected -PrimaryInstance $plan.PrimaryReplica -SeedingMode $plan.SeedingMode
    if ($repair.Databases.Count -eq 0) { throw 'Every selected database was left out, so there is nothing to add.' }
    $plan.Databases             = @($repair.Databases | ForEach-Object { $_.DatabaseName })
    $plan.Repairs               = @($repair.Repairs)
    $plan.RepairBackupDirectory = $repair.BackupDirectory
    $plan.DropLeftoverCopies    = @($repair.DropLeftover)

    if ($plan.SecondaryReplicas.Count -gt 0) { Read-AgSeedingDetail -Plan $plan -MaxConcurrentSeeds $MaxConcurrentSeeds }
    Read-AgContainedLoginDecision -Plan $plan

    $plan.Progress = @($plan.Databases | ForEach-Object { New-AgProgressRecord -DatabaseName $_ })
    return $plan
}

#endregion

#region ── Summary ───────────────────────────────────────────────────────────

function Show-AgPlanSummary {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-AgBanner 'PLAN'

    $verb = if ($Plan.Operation -eq 'CREATE') { 'Create availability group' } else { 'Add databases to availability group' }
    $kind = @()
    if ($Plan.IsContained) { $kind += 'CONTAINED' + $(if ($Plan.ReuseSystemDatabases) { ', reusing its system databases' } else { '' }) }
    if ($Plan.IsBasic)     { $kind += 'BASIC' }
    Write-Host "$verb [$($Plan.AgName)]$(if ($kind) { '  (' + ($kind -join '; ') + ')' })" -ForegroundColor White
    if ($Plan.ClusterName) { Write-Host "  Cluster             : $($Plan.ClusterName)" }
    Write-Host "  Primary             : $($Plan.PrimaryReplica)"

    if ($Plan.Operation -eq 'CREATE') {
        Write-Host ''
        Write-Host 'Replicas' -ForegroundColor White
        foreach ($r in $Plan.Replicas) {
            $ep = if ($r.CreateEndpoint) { "endpoint CREATE [$($r.EndpointName)] :$($r.EndpointPort)" }
                  elseif ($r.StartEndpoint) { "endpoint START [$($r.EndpointName)]" }
                  else { "endpoint [$($r.EndpointName)] :$($r.EndpointPort)" }
            Write-Host ("  {0,-22} {1,-20} {2,-10} read:{3,-10} {4}" -f $r.Name, $r.AvailabilityMode, $r.FailoverMode, $r.SecondaryConnections, $ep)
            Write-Host ("  {0,-22} {1}" -f '', $r.EndpointUrl) -ForegroundColor DarkGray
        }
        $o = $Plan.AgOptions
        Write-Host ''
        Write-Host 'Options' -ForegroundColor White
        Write-Host "  Backup preference   : $($o.AutomatedBackupPreference)"
        Write-Host "  Failure condition   : $($o.FailureConditionLevel)   health check $($o.HealthCheckTimeout) ms   DB_FAILOVER $(if ($o.DbFailover) { 'ON' } else { 'OFF' })"
        Write-Host "  DTC support         : $($o.DtcSupport)   required synced secondaries $($o.RequiredSyncedSecondaries)   session timeout $($o.SessionTimeout) s"

        Write-Host ''
        if ($Plan.Listener -and $Plan.Listener.Create) {
            $ips = if ($Plan.Listener.Dhcp) { 'DHCP' } else { ($Plan.Listener.Addresses | ForEach-Object { "$($_.IpAddress)/$($_.SubnetMask)" }) -join ', ' }
            Write-Host "Listener            : $($Plan.Listener.Name), port $($Plan.Listener.Port), $ips" -ForegroundColor White
            if ($Plan.Listener.Addresses.Count -gt 1) { Write-Host '                      multi-subnet — clients should use MultiSubnetFailover=True' -ForegroundColor DarkGray }
            if ($Plan.ConfigureReadOnlyRouting) { Write-Host '                      read-only routing will be configured' -ForegroundColor DarkGray }
        } else {
            Write-Host 'Listener            : not now (the statement to create one is printed at the end)' -ForegroundColor White
        }
    }

    Write-Host ''
    Write-Host "Databases ($($Plan.Databases.Count))" -ForegroundColor White
    if ($Plan.Databases.Count -eq 0) { Write-Host '  none — the availability group is created empty' -ForegroundColor DarkGray }
    foreach ($d in $Plan.Databases) {
        $r = @($Plan.Repairs | Where-Object { $_.DatabaseName -eq $d })
        $fix = @()
        if ($r.Count -gt 0) {
            if ($r[0].SetFullRecovery) { $fix += 'set FULL recovery' }
            if ($r[0].SetAutoCloseOff) { $fix += 'AUTO_CLOSE OFF' }
            if ($r[0].TakeFullBackup)  { $fix += 'full backup' }
        }
        $drops = @($Plan.DropLeftoverCopies | Where-Object { $_ -like "$d|*" } | ForEach-Object { ($_ -split '\|', 2)[1] })
        if ($drops.Count -gt 0) { $fix += "drop leftover copy on $($drops -join ', ')" }
        Write-Host ("  - {0}{1}" -f $d, $(if ($fix) { '   (' + ($fix -join ', ') + ')' } else { '' }))
    }
    if ($Plan.RepairBackupDirectory) { Write-Host "  Prerequisite backups to: $($Plan.RepairBackupDirectory)" -ForegroundColor DarkGray }

    if ($Plan.Databases.Count -gt 0 -and $Plan.SecondaryReplicas.Count -gt 0) {
        Write-Host ''
        Write-Host "Seeding             : $($Plan.SeedingMode)" -ForegroundColor White
        if ($Plan.SeedingMode -eq 'AUTOMATIC') {
            Write-Host "  At most $($Plan.MaxConcurrentSeeds) database(s) at a time; stream compression $(if ($Plan.SeedCompression) { 'ON' } else { 'OFF' })"
        } else {
            if ($Plan.ShareRoots.Count -gt 1) {
                Write-Host "  Backup shares       : $($Plan.ShareRoots -join ', ') (one stripe each)"
            } else {
                Write-Host "  Backup share        : $($Plan.ShareRoot)   ($($Plan.StripeCount) stripe(s))"
            }
            Write-Host "  Log backups         : every $($Plan.TLogIntervalMinutes) min; job afterwards: $(if ($Plan.KeepLogBackupJob) { 'KEEP' } else { 'REMOVE' })"
            Show-AgFileLayoutSummary -Plan $Plan
        }
    }
    if ($Plan.ContainedLogins.Count -gt 0) {
        Write-Host ''
        Write-Host "Contained AG logins : $(($Plan.ContainedLogins | ForEach-Object { $_.LoginName }) -join ', ')" -ForegroundColor White
    }
    Write-Host ''
}

#endregion
