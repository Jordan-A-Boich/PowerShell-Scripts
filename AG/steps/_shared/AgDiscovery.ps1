#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — auto-discovery of instance, endpoint, availability group and replica state.

    The scripts ask the operator for as little as possible: one instance name, typed once.
    Everything reachable from it — the cluster, its nodes, the SQL Server instances on them,
    their availability groups and databases — is discovered here and offered as a number.
#>

Set-StrictMode -Version Latest

#region ── Instance-level facts ──────────────────────────────────────────────

function Get-AgInstanceInfo {
    param([Parameter(Mandatory)][string]$Instance)

    $row = Invoke-AgSql -Instance $Instance -Retry -Activity 'instance discovery' -Query @'
DECLARE @dnsDomain nvarchar(256);
BEGIN TRY
    EXEC master.dbo.xp_regread
         N'HKEY_LOCAL_MACHINE', N'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters',
         N'Domain', @dnsDomain OUTPUT;
END TRY
BEGIN CATCH
    SET @dnsDomain = NULL;
END CATCH

SELECT
    CAST(SERVERPROPERTY('ServerName')           AS nvarchar(256)) AS ServerName,
    CAST(SERVERPROPERTY('MachineName')          AS nvarchar(256)) AS MachineName,
    CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(256)) AS PhysicalNode,
    CAST(SERVERPROPERTY('InstanceName')         AS nvarchar(256)) AS InstanceName,
    CAST(SERVERPROPERTY('ProductVersion')       AS nvarchar(64))  AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel')         AS nvarchar(64))  AS ProductLevel,
    CAST(SERVERPROPERTY('Edition')              AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('EngineEdition')        AS int)           AS EngineEdition,
    CAST(SERVERPROPERTY('ProductMajorVersion')  AS int)           AS MajorVersion,
    CAST(SERVERPROPERTY('IsHadrEnabled')        AS int)           AS IsHadrEnabled,
    CAST(SERVERPROPERTY('IsClustered')          AS int)           AS IsClustered,
    CAST(IS_SRVROLEMEMBER('sysadmin')           AS int)           AS IsSysadmin,
    CAST(DEFAULT_DOMAIN()                       AS nvarchar(256)) AS NetbiosDomain,
    CAST(@dnsDomain                             AS nvarchar(256)) AS DnsDomain,
    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS DefaultDataPath,
    CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(512)) AS DefaultLogPath,
    CAST(SERVERPROPERTY('IsFullTextInstalled')  AS int)           AS IsFullTextInstalled,
    (SELECT TOP 1 CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'filestream access level') AS FilestreamLevel,
    (SELECT TOP 1 local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID AND local_tcp_port IS NOT NULL) AS SessionTcpPort,
    (SELECT TOP 1 port FROM sys.dm_tcp_listener_states WHERE type_desc = N'TSQL' AND state_desc = N'ONLINE' AND ip_address IN (N'::', N'0.0.0.0') ORDER BY port) AS ListenerTcpPort
'@

    if ($row.Count -eq 0) { throw "Could not read instance properties from '$Instance'." }
    $r = $row[0]

    $agent = Invoke-AgSql -Instance $Instance -Retry -Activity 'agent status' -Query @'
SELECT TOP 1 status_desc AS StatusDesc
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%'
'@

    $dns   = if ($r.DnsDomain -is [System.DBNull]) { $null } else { [string]$r.DnsDomain }
    $mach  = [string]$r.MachineName
    $port  = if ($r.ListenerTcpPort -isnot [System.DBNull]) { [int]$r.ListenerTcpPort }
             elseif ($r.SessionTcpPort -isnot [System.DBNull]) { [int]$r.SessionTcpPort }
             else { 1433 }

    [pscustomobject]@{
        Instance        = $Instance
        ServerName      = [string]$r.ServerName
        MachineName     = $mach
        PhysicalNode    = [string]$r.PhysicalNode
        InstanceName    = if ($r.InstanceName -is [System.DBNull]) { $null } else { [string]$r.InstanceName }
        ProductVersion  = [string]$r.ProductVersion
        ProductLevel    = [string]$r.ProductLevel
        Edition         = [string]$r.Edition
        # EngineEdition 2 = Standard. Standard Edition can only host BASIC availability groups.
        IsStandard      = ([int]$r.EngineEdition -eq 2)
        MajorVersion    = [int]$r.MajorVersion
        IsHadrEnabled   = ([int]$r.IsHadrEnabled -eq 1)
        IsClustered     = ([int]$r.IsClustered -eq 1)
        IsSysadmin      = ([int]$r.IsSysadmin -eq 1)
        NetbiosDomain   = [string]$r.NetbiosDomain
        DnsDomain       = $dns
        HostFqdn        = if ($dns) { "$mach.$dns" } else { $mach }
        TcpPort         = $port
        DefaultDataPath = [string]$r.DefaultDataPath
        DefaultLogPath  = [string]$r.DefaultLogPath
        FilestreamLevel = if ($r.FilestreamLevel -is [System.DBNull]) { 0 } else { [int]$r.FilestreamLevel }
        AgentStatus     = if ($agent.Count -gt 0) { [string]$agent[0].StatusDesc } else { 'Unknown' }
    }
}

function Get-AgSqlVersionName {
    param([Parameter(Mandatory)][int]$MajorVersion)
    switch ($MajorVersion) {
        11 { 'SQL Server 2012' }  12 { 'SQL Server 2014' }
        13 { 'SQL Server 2016' }  14 { 'SQL Server 2017' }
        15 { 'SQL Server 2019' }  16 { 'SQL Server 2022' }
        17 { 'SQL Server 2025' }
        default { "SQL Server (major version $MajorVersion)" }
    }
}

function Get-AgReplicaLimit {
    <#
    .SYNOPSIS
        How many replicas may be synchronous-commit, and how many may fail over automatically,
        for the OLDEST SQL Server version in the availability group (the primary counts).
    .DESCRIPTION
        SQL Server 2016 and 2017 allow three synchronous replicas, all three able to fail over
        automatically. SQL Server 2019 raised both to five. A Basic availability group has
        exactly two replicas, so the limit is two whatever the version.
    #>
    param(
        [Parameter(Mandatory)][int]$MajorVersion,
        [bool]$IsBasic = $false
    )
    if ($IsBasic) { return [pscustomobject]@{ MaxReplicas = 2; MaxSync = 2; MaxAutoFailover = 2 } }
    if ($MajorVersion -ge 15) { return [pscustomobject]@{ MaxReplicas = 9; MaxSync = 5; MaxAutoFailover = 5 } }
    return [pscustomobject]@{ MaxReplicas = 9; MaxSync = 3; MaxAutoFailover = 3 }
}

#endregion

#region ── Endpoints ─────────────────────────────────────────────────────────

function Get-AgEndpointInfo {
    <#
    .OUTPUTS
        The database mirroring endpoint on $Instance, or $null when it has none.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $row = Invoke-AgSql -Instance $Instance -Retry -Activity 'endpoint discovery' -Query @'
SELECT TOP 1
    e.name                        AS EndpointName,
    e.state_desc                  AS StateDesc,
    te.port                       AS Port,
    dme.role_desc                 AS RoleDesc,
    dme.connection_auth_desc      AS AuthDesc,
    dme.encryption_algorithm_desc AS EncryptionDesc,
    dme.is_encryption_enabled     AS IsEncrypted,
    SUSER_NAME(e.principal_id)    AS OwnerName
FROM sys.database_mirroring_endpoints AS dme
JOIN sys.endpoints     AS e  ON e.endpoint_id  = dme.endpoint_id
LEFT JOIN sys.tcp_endpoints AS te ON te.endpoint_id = e.endpoint_id
'@
    if ($row.Count -eq 0) { return $null }

    [pscustomobject]@{
        Instance       = $Instance
        EndpointName   = [string]$row[0].EndpointName
        StateDesc      = [string]$row[0].StateDesc
        Port           = [int]$row[0].Port
        RoleDesc       = [string]$row[0].RoleDesc
        AuthDesc       = [string]$row[0].AuthDesc
        EncryptionDesc = [string]$row[0].EncryptionDesc
        IsEncrypted    = ([int]$row[0].IsEncrypted -eq 1)
        OwnerName      = if ($row[0].OwnerName -is [System.DBNull]) { $null } else { [string]$row[0].OwnerName }
    }
}

#endregion

#region ── Availability groups ───────────────────────────────────────────────

function Get-AgColumnExists {
    <#
    .SYNOPSIS
        Does a catalog view carry a column on this build? sys.availability_groups gained
        is_contained in 2022 and basic_features in 2016; selecting a missing one is a
        compile error, so optional columns are checked first.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$View,
        [Parameter(Mandatory)][string]$Column
    )
    $v = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v FROM sys.all_columns
WHERE object_id = OBJECT_ID($(ConvertTo-AgQuotedString $View)) AND name = $(ConvertTo-AgQuotedString $Column)
"@
    return ([int]$v -gt 0)
}

function Get-AgLocalAvailabilityGroups {
    <#
    .SYNOPSIS
        Non-distributed AGs on this instance that have a local replica.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $contained = if (Get-AgColumnExists -Instance $Instance -View 'sys.availability_groups' -Column 'is_contained') { 'CAST(ag.is_contained AS int)' } else { '0' }
    $basic     = if (Get-AgColumnExists -Instance $Instance -View 'sys.availability_groups' -Column 'basic_features') { 'CAST(ag.basic_features AS int)' } else { '0' }

    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'AG discovery' -Query @"
SELECT ag.name          AS AgName,
       ag.group_id      AS GroupId,
       ars.role_desc    AS LocalRole,
       $contained       AS IsContained,
       $basic           AS IsBasic,
       (SELECT COUNT(*) FROM sys.availability_replicas r WHERE r.group_id = ag.group_id) AS ReplicaCount,
       (SELECT COUNT(*) FROM sys.availability_databases_cluster d WHERE d.group_id = ag.group_id) AS DatabaseCount
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars
     ON ars.replica_id = ar.replica_id AND ars.is_local = 1
WHERE ag.is_distributed = 0
ORDER BY ag.name
"@
    if (-not $rows) { return @() }

    foreach ($r in $rows) {
        [pscustomobject]@{
            AgName        = [string]$r.AgName
            GroupId       = [guid]$r.GroupId
            LocalRole     = [string]$r.LocalRole
            IsContained   = ([int]$r.IsContained -eq 1)
            IsBasic       = ([int]$r.IsBasic -eq 1)
            ReplicaCount  = [int]$r.ReplicaCount
            DatabaseCount = [int]$r.DatabaseCount
        }
    }
}

function Test-AgExists {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $v = Get-AgScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.availability_groups WHERE name = $(ConvertTo-AgQuotedString $AgName)"
    return ([int]$v -gt 0)
}

function Get-AgTopology {
    <#
    .SYNOPSIS
        Full picture of one availability group: replicas, their modes and roles, listeners,
        and the instance currently holding the primary role.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [switch]$AllowNoPrimary,
        [switch]$NoRedirect
    )

    $agLit = ConvertTo-AgQuotedString $AgName
    $contained = if (Get-AgColumnExists -Instance $Instance -View 'sys.availability_groups' -Column 'is_contained') { 'CAST(ag.is_contained AS int)' } else { '0' }
    $basic     = if (Get-AgColumnExists -Instance $Instance -View 'sys.availability_groups' -Column 'basic_features') { 'CAST(ag.basic_features AS int)' } else { '0' }

    $agRow = Invoke-AgSql -Instance $Instance -Retry -Activity 'AG options' -Query @"
SELECT ag.name AS AgName, $contained AS IsContained, $basic AS IsBasic,
       ag.automated_backup_preference_desc AS BackupPreference,
       ag.failure_condition_level AS FailureConditionLevel,
       ag.health_check_timeout AS HealthCheckTimeout
FROM sys.availability_groups AS ag WHERE ag.name = $agLit
"@
    if ($agRow.Count -eq 0) { throw "Availability group '$AgName' was not found on '$Instance'." }

    $replicas = Invoke-AgSql -Instance $Instance -Retry -Activity 'replica discovery' -Query @"
SELECT ar.replica_server_name       AS ReplicaServerName,
       ar.endpoint_url              AS EndpointUrl,
       ar.availability_mode_desc    AS AvailabilityMode,
       ar.failover_mode_desc        AS FailoverMode,
       ar.seeding_mode_desc         AS SeedingMode,
       ar.secondary_role_allow_connections_desc AS SecondaryConnections,
       ar.backup_priority           AS BackupPriority,
       ISNULL(ar.read_only_routing_url, '')             AS ReadOnlyRoutingUrl,
       ISNULL(ars.role_desc, 'UNKNOWN')                 AS Role,
       ISNULL(ars.connected_state_desc, 'UNKNOWN')      AS ConnectedState,
       ISNULL(ars.synchronization_health_desc,'UNKNOWN')AS SyncHealth,
       ISNULL(ars.operational_state_desc, 'UNKNOWN')    AS OperationalState,
       ISNULL(ars.is_local, 0)                          AS IsLocal
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ag.name = $agLit
ORDER BY ar.replica_server_name
"@

    $listeners = Invoke-AgSql -Instance $Instance -Retry -Activity 'listener discovery' -Query @"
SELECT l.dns_name AS DnsName, l.port AS Port,
       ISNULL(ip.ip_address, '') AS IpAddress, ISNULL(ip.ip_subnet_mask, '') AS SubnetMask,
       ISNULL(ip.state_desc, '') AS IpState, CAST(l.is_conformant AS int) AS IsConformant
FROM sys.availability_group_listeners AS l
JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id
WHERE ag.name = $agLit
"@

    $replicaObjs = @(foreach ($r in $replicas) {
        [pscustomobject]@{
            ReplicaServerName    = [string]$r.ReplicaServerName
            EndpointUrl          = [string]$r.EndpointUrl
            AvailabilityMode     = [string]$r.AvailabilityMode
            FailoverMode         = [string]$r.FailoverMode
            SeedingMode          = [string]$r.SeedingMode
            SecondaryConnections = [string]$r.SecondaryConnections
            BackupPriority       = [int]$r.BackupPriority
            ReadOnlyRoutingUrl   = [string]$r.ReadOnlyRoutingUrl
            Role                 = [string]$r.Role
            ConnectedState       = [string]$r.ConnectedState
            SyncHealth           = [string]$r.SyncHealth
            OperationalState     = [string]$r.OperationalState
            IsLocal              = ([int]$r.IsLocal -eq 1)
        }
    })

    $primary = @($replicaObjs | Where-Object { $_.Role -eq 'PRIMARY' })

    # A secondary only sees its own row in sys.dm_hadr_availability_replica_states, so read
    # from one, no replica reports PRIMARY. The AG-level state does name the primary, and the
    # primary is the only replica with the full picture — so re-read the topology there.
    if ($primary.Count -eq 0 -and -not $NoRedirect) {
        $named = Get-AgScalar -Instance $Instance -Query @"
SELECT TOP 1 ags.primary_replica AS v
FROM sys.dm_hadr_availability_group_states AS ags
JOIN sys.availability_groups AS ag ON ag.group_id = ags.group_id
WHERE ag.name = $agLit
"@
        if ($named -and $named -ne $Instance -and (Test-AgConnection -Instance $named)) {
            return Get-AgTopology -Instance $named -AgName $AgName -AllowNoPrimary:$AllowNoPrimary -NoRedirect
        }
    }

    if ($primary.Count -ne 1 -and -not $AllowNoPrimary) {
        throw "Availability group '$AgName' does not currently have exactly one PRIMARY replica (found $($primary.Count)). Resolve the AG's health first."
    }

    # One row per listener, with every IP address it carries.
    $listenerObjs = @()
    if ($listeners) {
        $listenerObjs = @($listeners | Group-Object DnsName | ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                DnsName      = [string]$first.DnsName
                Port         = [int]$first.Port
                IsConformant = ([int]$first.IsConformant -eq 1)
                Addresses    = @($_.Group | Where-Object { $_.IpAddress } | ForEach-Object {
                    [pscustomobject]@{ IpAddress = [string]$_.IpAddress; SubnetMask = [string]$_.SubnetMask; State = [string]$_.IpState }
                })
            }
        })
    }

    [pscustomobject]@{
        AgName            = $AgName
        IsContained       = ([int]$agRow[0].IsContained -eq 1)
        IsBasic           = ([int]$agRow[0].IsBasic -eq 1)
        BackupPreference  = [string]$agRow[0].BackupPreference
        Replicas          = $replicaObjs
        Listeners         = @($listenerObjs)
        PrimaryReplica    = if ($primary.Count -eq 1) { $primary[0].ReplicaServerName } else { $null }
        SecondaryReplicas = @($replicaObjs | Where-Object { $_.Role -ne 'PRIMARY' } | ForEach-Object { $_.ReplicaServerName })
        DiscoveredFrom    = $Instance
    }
}

function Get-AgDistributedParent {
    <#
    .SYNOPSIS
        Distributed availability groups this AG is a member of, as seen from $Instance.
        Removing a database from a DAG's global primary AG also removes it from the forwarder,
        which is worth saying before it happens.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'DAG membership' -Query @"
SELECT DISTINCT dag.name AS DagName
FROM sys.availability_groups AS dag
JOIN sys.availability_replicas AS ar ON ar.group_id = dag.group_id
WHERE dag.is_distributed = 1 AND ar.replica_server_name = $(ConvertTo-AgQuotedString $AgName)
"@
    return @($rows | ForEach-Object { [string]$_.DagName })
}

#endregion

#region ── Databases ─────────────────────────────────────────────────────────

function Test-AgDatabaseInAg {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $v = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_databases_cluster AS adc
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)
  AND adc.database_name = $(ConvertTo-AgQuotedString $DatabaseName)
"@
    return ([int]$v -gt 0)
}

function Get-AgDatabaseState {
    <#
    .SYNOPSIS
        State of one database on one instance. Returns $null when it does not exist.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'database state' -Query @"
SELECT d.name                AS DatabaseName,
       d.state_desc          AS StateDesc,
       d.recovery_model_desc AS RecoveryModel,
       CAST(CASE WHEN d.group_database_id IS NULL THEN 0 ELSE 1 END AS int) AS IsJoinedToAg
FROM sys.databases AS d
WHERE d.name = $(ConvertTo-AgQuotedString $DatabaseName)
"@
    if (-not $rows) { return $null }
    [pscustomobject]@{
        DatabaseName = [string]$rows[0].DatabaseName
        StateDesc    = [string]$rows[0].StateDesc
        RecoveryModel= [string]$rows[0].RecoveryModel
        IsJoinedToAg = ([int]$rows[0].IsJoinedToAg -eq 1)
    }
}

function Test-AgDatabaseJoinedOnReplica {
    <#
    .SYNOPSIS
        Is the database an active member of the named AG *on this replica*?
        (sys.databases.group_database_id is set once the local copy has joined.)
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $v = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.databases AS d
JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = d.group_database_id
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE d.name = $(ConvertTo-AgQuotedString $DatabaseName)
  AND ag.name = $(ConvertTo-AgQuotedString $AgName)
"@
    return ([int]$v -gt 0)
}

function Test-AgDatabaseSynchronizing {
    <#
    .SYNOPSIS
        Has the database joined and started moving data on the given replica?
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'arrival check' -Query @"
SELECT drs.synchronization_state_desc AS SyncState
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)
  AND DB_NAME(drs.database_id) = $(ConvertTo-AgQuotedString $DatabaseName)
  AND drs.is_local = 1
"@
    return ($rows.Count -gt 0 -and $rows[0].SyncState -in @('SYNCHRONIZED','SYNCHRONIZING'))
}

function Get-AgContainedSystemDatabaseNames {
    <#
    .SYNOPSIS
        The contained master and msdb a contained AG owns: <AgName>_master, <AgName>_msdb.
    #>
    param([Parameter(Mandatory)][string]$AgName)
    return @("${AgName}_master", "${AgName}_msdb")
}

#endregion
