#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — auto-discovery of instance, AG, replica, listener and database state.

    The script asks the user for as little as possible; everything reachable from a
    single seed instance is discovered here and presented as a numbered choice.
#>

Set-StrictMode -Version Latest

#region ── Instance-level facts ──────────────────────────────────────────────

function Get-DagInstanceInfo {
    param([Parameter(Mandatory)][string]$Instance)

    $row = Invoke-DagSql -Instance $Instance -Retry -Activity 'instance discovery' -Query @'
SELECT
    CAST(SERVERPROPERTY('ServerName')           AS nvarchar(256)) AS ServerName,
    CAST(SERVERPROPERTY('MachineName')          AS nvarchar(256)) AS MachineName,
    CAST(SERVERPROPERTY('ProductVersion')       AS nvarchar(64))  AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel')         AS nvarchar(64))  AS ProductLevel,
    CAST(SERVERPROPERTY('Edition')              AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('ProductMajorVersion')  AS int)           AS MajorVersion,
    CAST(SERVERPROPERTY('IsHadrEnabled')        AS int)           AS IsHadrEnabled,
    CAST(IS_SRVROLEMEMBER('sysadmin')           AS int)           AS IsSysadmin,
    CAST(DEFAULT_DOMAIN()                       AS nvarchar(256)) AS NetbiosDomain,
    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS DefaultDataPath,
    CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(512)) AS DefaultLogPath
'@

    if ($row.Count -eq 0) { throw "Could not read instance properties from '$Instance'." }

    $agent = Invoke-DagSql -Instance $Instance -Retry -Activity 'agent status' -Query @'
SELECT TOP 1 status_desc AS StatusDesc
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%'
'@

    [pscustomobject]@{
        Instance        = $Instance
        ServerName      = $row[0].ServerName
        MachineName     = $row[0].MachineName
        ProductVersion  = $row[0].ProductVersion
        ProductLevel    = $row[0].ProductLevel
        Edition         = $row[0].Edition
        MajorVersion    = [int]$row[0].MajorVersion
        IsHadrEnabled   = ([int]$row[0].IsHadrEnabled -eq 1)
        IsSysadmin      = ([int]$row[0].IsSysadmin -eq 1)
        NetbiosDomain   = $row[0].NetbiosDomain
        DefaultDataPath = $row[0].DefaultDataPath
        DefaultLogPath  = $row[0].DefaultLogPath
        AgentStatus     = if ($agent.Count -gt 0) { [string]$agent[0].StatusDesc } else { 'Unknown' }
    }
}

function Get-DagSqlVersionName {
    param([Parameter(Mandatory)][int]$MajorVersion)
    switch ($MajorVersion) {
        11 { 'SQL Server 2012' }  12 { 'SQL Server 2014' }
        13 { 'SQL Server 2016' }  14 { 'SQL Server 2017' }
        15 { 'SQL Server 2019' }  16 { 'SQL Server 2022' }
        17 { 'SQL Server 2025' }
        default { "SQL Server (major version $MajorVersion)" }
    }
}

#endregion

#region ── Endpoints ─────────────────────────────────────────────────────────

function Get-DagEndpointInfo {
    param([Parameter(Mandatory)][string]$Instance)

    $row = Invoke-DagSql -Instance $Instance -Retry -Activity 'endpoint discovery' -Query @'
SELECT TOP 1
    e.name                        AS EndpointName,
    e.state_desc                  AS StateDesc,
    te.port                       AS Port,
    dme.role_desc                 AS RoleDesc,
    dme.connection_auth_desc      AS AuthDesc,
    dme.encryption_algorithm_desc AS EncryptionDesc,
    dme.is_encryption_enabled     AS IsEncrypted
FROM sys.database_mirroring_endpoints AS dme
JOIN sys.endpoints     AS e  ON e.endpoint_id  = dme.endpoint_id
LEFT JOIN sys.tcp_endpoints AS te ON te.endpoint_id = e.endpoint_id
'@
    if ($row.Count -eq 0) { return $null }

    [pscustomobject]@{
        Instance       = $Instance
        EndpointName   = $row[0].EndpointName
        StateDesc      = $row[0].StateDesc
        Port           = [int]$row[0].Port
        RoleDesc       = $row[0].RoleDesc
        AuthDesc       = $row[0].AuthDesc
        EncryptionDesc = $row[0].EncryptionDesc
        IsEncrypted    = ([int]$row[0].IsEncrypted -eq 1)
    }
}

#endregion

#region ── Availability groups ───────────────────────────────────────────────

function Get-DagLocalAvailabilityGroups {
    <#
    .SYNOPSIS
        Non-distributed AGs on this instance that have a local replica.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'AG discovery' -Query @'
SELECT ag.name          AS AgName,
       ag.group_id      AS GroupId,
       ars.role_desc    AS LocalRole,
       (SELECT COUNT(*) FROM sys.availability_replicas r WHERE r.group_id = ag.group_id) AS ReplicaCount,
       (SELECT COUNT(*) FROM sys.availability_databases_cluster d WHERE d.group_id = ag.group_id) AS DatabaseCount
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars
     ON ars.replica_id = ar.replica_id AND ars.is_local = 1
WHERE ag.is_distributed = 0
ORDER BY ag.name
'@
    if (-not $rows) { return @() }

    foreach ($r in $rows) {
        [pscustomobject]@{
            AgName        = $r.AgName
            GroupId       = [guid]$r.GroupId
            LocalRole     = $r.LocalRole
            ReplicaCount  = [int]$r.ReplicaCount
            DatabaseCount = [int]$r.DatabaseCount
        }
    }
}

function Get-DagAgTopology {
    <#
    .SYNOPSIS
        Full picture of one availability group: replicas, roles, seeding modes,
        listeners, and the instance currently holding the primary role.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )

    $agLit = ConvertTo-DagQuotedString $AgName

    $replicas = Invoke-DagSql -Instance $Instance -Retry -Activity 'replica discovery' -Query @"
SELECT ar.replica_server_name       AS ReplicaServerName,
       ar.endpoint_url              AS EndpointUrl,
       ar.availability_mode_desc    AS AvailabilityMode,
       ar.failover_mode_desc        AS FailoverMode,
       ar.seeding_mode_desc         AS SeedingMode,
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
    if (-not $replicas) { throw "Availability group '$AgName' was not found on '$Instance'." }

    $listeners = Invoke-DagSql -Instance $Instance -Retry -Activity 'listener discovery' -Query @"
SELECT l.dns_name AS DnsName, l.port AS Port
FROM sys.availability_group_listeners AS l
JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
WHERE ag.name = $agLit
"@

    $replicaObjs = foreach ($r in $replicas) {
        [pscustomobject]@{
            ReplicaServerName = $r.ReplicaServerName
            EndpointUrl       = $r.EndpointUrl
            AvailabilityMode  = $r.AvailabilityMode
            FailoverMode      = $r.FailoverMode
            SeedingMode       = $r.SeedingMode
            Role              = $r.Role
            ConnectedState    = $r.ConnectedState
            SyncHealth        = $r.SyncHealth
            OperationalState  = $r.OperationalState
            IsLocal           = ([int]$r.IsLocal -eq 1)
        }
    }

    $primary = @($replicaObjs | Where-Object { $_.Role -eq 'PRIMARY' })
    if ($primary.Count -ne 1) {
        throw "Availability group '$AgName' does not currently have exactly one PRIMARY replica (found $($primary.Count)). Resolve the AG's health before configuring a distributed AG."
    }

    $listenerObjs = @()
    if ($listeners) {
        $listenerObjs = foreach ($l in $listeners) {
            [pscustomobject]@{ DnsName = $l.DnsName; Port = [int]$l.Port }
        }
    }

    [pscustomobject]@{
        AgName            = $AgName
        Replicas          = $replicaObjs
        Listeners         = @($listenerObjs)
        PrimaryReplica    = $primary[0].ReplicaServerName
        SecondaryReplicas = @($replicaObjs | Where-Object { $_.Role -ne 'PRIMARY' } | ForEach-Object { $_.ReplicaServerName })
        DiscoveredFrom    = $Instance
    }
}

function Test-DagIsDistributed {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName
    )
    $v = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_groups
WHERE name = $(ConvertTo-DagQuotedString $DagName) AND is_distributed = 1
"@
    return ([int]$v -gt 0)
}

function Get-DagDistributedAgState {
    <#
    .SYNOPSIS
        Per-member-AG state of a distributed AG as seen from one instance.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'DAG state' -Query @"
SELECT ar.replica_server_name       AS MemberAg,
       ar.availability_mode_desc    AS AvailabilityMode,
       ar.seeding_mode_desc         AS SeedingMode,
       ar.failover_mode_desc        AS FailoverMode,
       ar.endpoint_url              AS ListenerUrl,
       ISNULL(ars.role_desc,'UNKNOWN')                   AS Role,
       ISNULL(ars.connected_state_desc,'UNKNOWN')        AS ConnectedState,
       ISNULL(ars.synchronization_health_desc,'UNKNOWN') AS SyncHealth
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ag.name = $(ConvertTo-DagQuotedString $DagName) AND ag.is_distributed = 1
"@
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        [pscustomobject]@{
            MemberAg         = $r.MemberAg
            AvailabilityMode = $r.AvailabilityMode
            SeedingMode      = $r.SeedingMode
            FailoverMode     = $r.FailoverMode
            ListenerUrl      = $r.ListenerUrl
            Role             = $r.Role
            ConnectedState   = $r.ConnectedState
            SyncHealth       = $r.SyncHealth
        }
    }
}

#endregion

#region ── Databases ─────────────────────────────────────────────────────────

function Get-DagCandidateDatabases {
    <#
    .SYNOPSIS
        User databases on the global primary, annotated with everything needed to
        decide whether they can participate in the distributed AG.

    .DESCRIPTION
        Returns every user database, including ineligible ones, so the plan can
        explain *why* something was skipped instead of silently omitting it.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'database discovery' -Query @"
SELECT d.name                                    AS DatabaseName,
       d.recovery_model_desc                     AS RecoveryModel,
       d.state_desc                              AS StateDesc,
       d.is_read_only                            AS IsReadOnly,
       d.is_auto_close_on                        AS IsAutoClose,
       d.is_encrypted                            AS IsEncrypted,
       CAST(CASE WHEN adc.group_id IS NULL THEN 0 ELSE 1 END AS int) AS InThisAg,
       CAST(CASE WHEN d.group_database_id IS NOT NULL AND adc.group_id IS NULL
                 THEN 1 ELSE 0 END AS int)       AS InAnotherAg,
       CAST(ISNULL(bs.HasFullBackup, 0) AS int)  AS HasFullBackup,
       CAST(ISNULL(sz.SizeBytes, 0) AS bigint)   AS SizeBytes
FROM sys.databases AS d
LEFT JOIN (
    SELECT adc.database_name, adc.group_id
    FROM sys.availability_databases_cluster AS adc
    JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
    WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)
) AS adc ON adc.database_name = d.name
OUTER APPLY (
    SELECT TOP 1 1 AS HasFullBackup
    FROM msdb.dbo.backupset AS b
    WHERE b.database_name = d.name AND b.type = 'D' AND b.is_copy_only = 0
) AS bs
OUTER APPLY (
    SELECT SUM(CAST(mf.size AS bigint)) * 8192 AS SizeBytes
    FROM sys.master_files AS mf
    WHERE mf.database_id = d.database_id
) AS sz
WHERE d.database_id > 4 AND d.source_database_id IS NULL
ORDER BY d.name
"@
    if (-not $rows) { return @() }

    foreach ($r in $rows) {
        $reasons = New-Object System.Collections.Generic.List[string]

        if ($r.StateDesc -ne 'ONLINE')            { $reasons.Add("database is $($r.StateDesc), not ONLINE") }
        if ($r.RecoveryModel -eq 'SIMPLE')        { $reasons.Add('SIMPLE recovery model (availability groups require FULL)') }
        if ([int]$r.IsReadOnly -eq 1)             { $reasons.Add('database is READ_ONLY') }
        if ([int]$r.IsAutoClose -eq 1)            { $reasons.Add('AUTO_CLOSE is enabled') }
        if ([int]$r.InAnotherAg -eq 1)            { $reasons.Add('already belongs to a different availability group') }

        [pscustomobject]@{
            DatabaseName   = $r.DatabaseName
            RecoveryModel  = $r.RecoveryModel
            StateDesc      = $r.StateDesc
            IsEncrypted    = ([int]$r.IsEncrypted -eq 1)
            InThisAg       = ([int]$r.InThisAg -eq 1)
            HasFullBackup  = ([int]$r.HasFullBackup -eq 1)
            SizeBytes      = [long]$r.SizeBytes
            IsEligible     = ($reasons.Count -eq 0)
            IneligibleWhy  = ($reasons -join '; ')
        }
    }
}

function Test-DagDatabaseInAg {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $v = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_databases_cluster AS adc
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)
  AND adc.database_name = $(ConvertTo-DagQuotedString $DatabaseName)
"@
    return ([int]$v -gt 0)
}

function Get-DagDatabaseState {
    <#
    .SYNOPSIS
        State of one database on one instance. Returns $null when it does not exist.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'database state' -Query @"
SELECT d.name                AS DatabaseName,
       d.state_desc          AS StateDesc,
       d.recovery_model_desc AS RecoveryModel,
       CAST(CASE WHEN d.group_database_id IS NULL THEN 0 ELSE 1 END AS int) AS IsJoinedToAg
FROM sys.databases AS d
WHERE d.name = $(ConvertTo-DagQuotedString $DatabaseName)
"@
    if (-not $rows) { return $null }
    [pscustomobject]@{
        DatabaseName = $rows[0].DatabaseName
        StateDesc    = $rows[0].StateDesc
        RecoveryModel= $rows[0].RecoveryModel
        IsJoinedToAg = ([int]$rows[0].IsJoinedToAg -eq 1)
    }
}

function Test-DagDatabaseJoinedOnReplica {
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
    $v = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.databases AS d
JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = d.group_database_id
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE d.name = $(ConvertTo-DagQuotedString $DatabaseName)
  AND ag.name = $(ConvertTo-DagQuotedString $AgName)
"@
    return ([int]$v -gt 0)
}

#endregion
