#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — health rollup and seeding progress.

.DESCRIPTION
    Interpreting distributed AG health requires knowing whether the two member AGs run
    the same major version of SQL Server. When the forwarder is a HIGHER version than
    the global primary (the upgrade/migration case), the forwarder's databases sit in
    RESTORING / SYNCHRONIZING and the distributed AG reports as less than fully healthy
    for as long as the global primary remains on the older version. That is the designed
    behaviour, and it resolves when the DAG is failed over to the new version. This
    module labels that state EXPECTED rather than crying wolf about it.
#>

Set-StrictMode -Version Latest

function Get-DagSeedingProgress {
    <#
    .SYNOPSIS
        Automatic seeding operations recorded on an instance.

    .DESCRIPTION
        Seeding rows are filed under the MEMBER availability group, never under the
        distributed AG's own name — a distributed-AG seed appears on the global primary
        as an operation belonging to the global primary AG, whose remote peer is the
        forwarder AG. Filtering by the DAG name therefore matches nothing. Pass -AgName
        to scope to a member AG, or omit it to see every operation on the instance.

        sys.dm_hadr_automatic_seeding identifies the database by ag_db_id and the peer by
        ag_remote_replica_id; there is no database_id or machine-name column to read.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$AgName
    )
    $filter = if ($AgName) { "WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)" } else { '' }

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'seeding progress' -Query @"
SELECT ag.name                                                    AS AgName,
       ISNULL(adc.database_name, '')                              AS DatabaseName,
       ISNULL(ar.replica_server_name, '')                         AS RemoteReplica,
       CAST(seed.current_state AS nvarchar(64))                   AS CurrentState,
       ISNULL(CAST(seed.failure_state_desc AS nvarchar(256)), '') AS FailureState,
       seed.start_time                                            AS StartTime,
       seed.completion_time                                       AS CompletionTime
FROM sys.dm_hadr_automatic_seeding AS seed
JOIN sys.availability_groups AS ag ON ag.group_id = seed.ag_id
LEFT JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = seed.ag_db_id
LEFT JOIN sys.availability_replicas AS ar ON ar.replica_id = seed.ag_remote_replica_id
$filter
ORDER BY seed.start_time DESC
"@
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        [pscustomobject]@{
            AgName        = $r.AgName
            DatabaseName  = $r.DatabaseName
            RemoteReplica = $r.RemoteReplica
            CurrentState  = $r.CurrentState
            FailureState  = $r.FailureState
            StartTime     = $r.StartTime
            CompletionTime= $r.CompletionTime
        }
    }
}

function Get-DagPhysicalSeedingStats {
    param([Parameter(Mandatory)][string]$Instance)
    try {
        $rows = Invoke-DagSql -Instance $Instance -Activity 'physical seeding stats' -Query @'
SELECT local_database_name                    AS DatabaseName,
       ISNULL(remote_machine_name, '')        AS RemoteMachine,
       role_desc                              AS RoleDesc,
       internal_state_desc                    AS StateDesc,
       transferred_size_bytes                 AS TransferredBytes,
       database_size_bytes                    AS TotalBytes,
       transfer_rate_bytes_per_second         AS RateBytesPerSec
FROM sys.dm_hadr_physical_seeding_stats
'@
    } catch { return @() }
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        $total = [long]$r.TotalBytes
        $done  = [long]$r.TransferredBytes
        [pscustomobject]@{
            DatabaseName  = $r.DatabaseName
            RemoteMachine = $r.RemoteMachine
            RoleDesc      = $r.RoleDesc
            StateDesc     = $r.StateDesc
            Percent       = if ($total -gt 0) { [math]::Round(100.0 * $done / $total, 1) } else { 0 }
            Transferred   = Format-DagBytes $done
            Total         = Format-DagBytes $total
            Rate          = "$(Format-DagBytes ([double]$r.RateBytesPerSec))/s"
        }
    }
}

function Get-DagReplicaHealth {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$AgName
    )
    $filter = if ($AgName) { "WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)" } else { '' }
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'replica health' -Query @"
SELECT ag.name                                          AS AgName,
       ag.is_distributed                                AS IsDistributed,
       ar.replica_server_name                           AS ReplicaServerName,
       ar.availability_mode_desc                        AS AvailabilityMode,
       ar.seeding_mode_desc                             AS SeedingMode,
       ISNULL(ars.role_desc,'UNKNOWN')                  AS Role,
       ISNULL(ars.connected_state_desc,'-')             AS ConnectedState,
       ISNULL(ars.operational_state_desc,'-')           AS OperationalState,
       ISNULL(ars.synchronization_health_desc,'UNKNOWN')AS SyncHealth
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
$filter
ORDER BY ag.is_distributed, ag.name, ar.replica_server_name
"@
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        [pscustomobject]@{
            AgName           = $r.AgName
            IsDistributed    = ([int]$r.IsDistributed -eq 1)
            ReplicaServerName= $r.ReplicaServerName
            AvailabilityMode = $r.AvailabilityMode
            SeedingMode      = $r.SeedingMode
            Role             = $r.Role
            ConnectedState   = $r.ConnectedState
            OperationalState = $r.OperationalState
            SyncHealth       = $r.SyncHealth
        }
    }
}

function Get-DagDatabaseHealth {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string[]]$Databases
    )
    $filter = ''
    if ($Databases -and $Databases.Count -gt 0) {
        $list = ($Databases | ForEach-Object { ConvertTo-DagQuotedString $_ }) -join ', '
        $filter = "AND DB_NAME(drs.database_id) IN ($list)"
    }

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'database health' -Query @"
SELECT ag.name                                    AS AgName,
       ag.is_distributed                          AS IsDistributed,
       ISNULL(DB_NAME(drs.database_id), '?')      AS DatabaseName,
       ISNULL(ar.replica_server_name, '?')        AS ReplicaServerName,
       drs.synchronization_state_desc             AS SyncState,
       drs.synchronization_health_desc            AS SyncHealth,
       drs.database_state_desc                    AS DatabaseState,
       drs.is_suspended                           AS IsSuspended,
       ISNULL(drs.suspend_reason_desc,'')         AS SuspendReason,
       drs.end_of_log_lsn                         AS EndOfLogLsn
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
LEFT JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
WHERE 1 = 1 $filter
ORDER BY ag.name, DatabaseName, ReplicaServerName
"@
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        [pscustomobject]@{
            AgName           = $r.AgName
            IsDistributed    = ([int]$r.IsDistributed -eq 1)
            DatabaseName     = $r.DatabaseName
            ReplicaServerName= $r.ReplicaServerName
            SyncState        = $r.SyncState
            SyncHealth       = $r.SyncHealth
            DatabaseState    = $r.DatabaseState
            IsSuspended      = ([int]$r.IsSuspended -eq 1)
            SuspendReason    = $r.SuspendReason
            EndOfLogLsn      = $r.EndOfLogLsn
        }
    }
}

function Show-DagHealthRollup {
    <#
    .SYNOPSIS
        Prints the end-of-run health summary and returns $true when everything is
        either healthy or in a state that is expected for this topology.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan
    )

    Write-DagBanner 'HEALTH ROLLUP'

    $gp = $Plan.GlobalPrimaryReplica
    $fp = $Plan.ForwarderPrimaryReplica
    $crossVersion = $Plan.ForwarderMajorVersion -gt $Plan.GlobalMajorVersion

    #region distributed AG membership
    Write-Host ''
    Write-Host "Distributed availability group: $($Plan.DagName)" -ForegroundColor White
    $dagState = @(Get-DagDistributedAgState -Instance $gp -DagName $Plan.DagName)
    if ($dagState.Count -eq 0) {
        Write-DagLog "The distributed availability group '$($Plan.DagName)' was not found on $gp." ERROR
        return $false
    }
    $dagState | Format-Table MemberAg, Role, AvailabilityMode, SeedingMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host
    #endregion

    #region replicas of each member AG
    foreach ($pair in @(@{ i = $gp; ag = $Plan.GlobalAgName; label = 'GLOBAL PRIMARY' },
                        @{ i = $fp; ag = $Plan.ForwarderAgName; label = 'FORWARDER' })) {
        Write-Host "$($pair.label) AG '$($pair.ag)' replicas (as seen from $($pair.i)):" -ForegroundColor White
        Get-DagReplicaHealth -Instance $pair.i -AgName $pair.ag |
            Format-Table ReplicaServerName, Role, AvailabilityMode, SeedingMode, ConnectedState, SyncHealth -AutoSize |
            Out-String -Width 200 | Write-Host
    }
    #endregion

    #region databases
    $problems = New-Object System.Collections.Generic.List[string]
    $expected = New-Object System.Collections.Generic.List[string]

    Write-Host "Databases on the GLOBAL PRIMARY side ($gp):" -ForegroundColor White
    $gpDbs = Get-DagDatabaseHealth -Instance $gp -Databases $Plan.Databases
    $gpDbs | Format-Table AgName, DatabaseName, ReplicaServerName, SyncState, SyncHealth, DatabaseState -AutoSize |
        Out-String -Width 200 | Write-Host

    Write-Host "Databases on the FORWARDER side ($fp):" -ForegroundColor White
    $fpDbs = Get-DagDatabaseHealth -Instance $fp -Databases $Plan.Databases
    $fpDbs | Format-Table AgName, DatabaseName, ReplicaServerName, SyncState, SyncHealth, DatabaseState -AutoSize |
        Out-String -Width 200 | Write-Host

    # A cross-version forwarder holds its databases un-upgraded and therefore not online.
    # SQL Server reports that as RECOVERING (or RESTORING on some builds), and the forwarder
    # primary cannot seed a database it cannot bring online, so its own secondaries stay
    # empty until the DAG is failed over. Both are designed behaviour, not faults.
    $notOnlineStates = @('RESTORING','RECOVERING','NOT_SYNCHRONIZING')

    foreach ($db in $Plan.Databases) {
        $onGp = @($gpDbs | Where-Object { $_.DatabaseName -eq $db })
        if ($onGp.Count -eq 0) { $problems.Add("[$db] is not present in any availability group on the global primary."); continue }

        $onFp = @($fpDbs | Where-Object { $_.DatabaseName -eq $db })
        if ($onFp.Count -eq 0) { $problems.Add("[$db] has not arrived on the forwarder AG."); continue }

        foreach ($r in $onFp) {
            if ($r.IsSuspended) { $problems.Add("[$db] on $($r.ReplicaServerName) is SUSPENDED ($($r.SuspendReason)).") ; continue }

            $notOnline = ($r.DatabaseState -in $notOnlineStates) -or ($r.SyncState -eq 'NOT SYNCHRONIZING')
            if ($notOnline -and $crossVersion) {
                # An empty database_state means the replica has no copy of the database yet.
                $shown = if ([string]::IsNullOrWhiteSpace($r.DatabaseState)) { 'not present' } else { $r.DatabaseState }
                $expected.Add("[$db] on $($r.ReplicaServerName): $shown / $($r.SyncState)")
            } elseif ($r.SyncState -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
                $problems.Add("[$db] on $($r.ReplicaServerName) is $($r.SyncState) / $($r.DatabaseState).")
            }
        }

        # Forwarder secondaries with no row at all: absent, not unhealthy, when cross-version.
        foreach ($sec in $Plan.ForwarderSecondaries) {
            if (@($onFp | Where-Object { $_.ReplicaServerName -eq $sec }).Count -gt 0) { continue }
            if ($crossVersion) {
                $expected.Add("[$db] not yet present on forwarder secondary $sec (seeds after failover)")
            } else {
                $problems.Add("[$db] has not arrived on forwarder secondary $sec.")
            }
        }
    }
    #endregion

    #region verdict
    Write-Host ''
    if ($crossVersion) {
        Write-Host 'Cross-version distributed availability group detected.' -ForegroundColor Yellow
        Write-Host ("  Global primary AG '{0}' runs {1}." -f $Plan.GlobalAgName, (Get-DagSqlVersionName $Plan.GlobalMajorVersion)) -ForegroundColor DarkGray
        Write-Host ("  Forwarder AG '{0}' runs {1}." -f $Plan.ForwarderAgName, (Get-DagSqlVersionName $Plan.ForwarderMajorVersion)) -ForegroundColor DarkGray
        Write-Host '  Until the distributed AG is failed over to the higher version, the forwarder''s' -ForegroundColor DarkGray
        Write-Host '  databases stay in a Recovering / Synchronizing state and are not readable, and the' -ForegroundColor DarkGray
        Write-Host '  forwarder''s own secondary replicas cannot be seeded from them. Both are expected and' -ForegroundColor DarkGray
        Write-Host '  resolve at failover. Data continues to flow in the meantime.' -ForegroundColor DarkGray
    }

    if ($expected.Count -gt 0) {
        Write-Host ''
        Write-Host 'Expected cross-version states (not a fault):' -ForegroundColor Yellow
        $expected | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
    }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-DagLog 'Health rollup: no problems detected.' SUCCESS
        return $true
    }

    Write-DagLog "Health rollup found $($problems.Count) problem(s):" ERROR
    $problems | ForEach-Object { Write-DagLog "  - $_" ERROR }
    return $false
    #endregion
}
