#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — health rollup and seeding progress.

.DESCRIPTION
    The rollup WAITS before it judges. An availability group that has just been created, or
    has just had databases joined, spends a short while with replicas reconnecting and
    per-database rows reading NOT SYNCHRONIZING while redo catches up. Read a second after
    the last change, all of that looks like a wall of faults that is gone by the time anyone
    looks again. So the rollup polls until the group has settled (or a window expires), and
    only then decides what to call a problem. States that never clear on their own — a
    suspended database, a disconnected replica past the window — are always problems.
#>

Set-StrictMode -Version Latest

function Get-AgSeedingProgress {
    <#
    .SYNOPSIS
        Automatic seeding operations recorded on an instance, optionally for one AG.
    .DESCRIPTION
        sys.dm_hadr_automatic_seeding identifies the database by ag_db_id and the peer by
        ag_remote_replica_id; there is no database_id or machine-name column to read.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string]$AgName
    )
    $filter = if ($AgName) { "WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)" } else { '' }

    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'seeding progress' -Query @"
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

function Get-AgPhysicalSeedingStats {
    param([Parameter(Mandatory)][string]$Instance)
    try {
        $rows = Invoke-AgSql -Instance $Instance -Activity 'physical seeding stats' -Query @'
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
            DatabaseName  = [string]$r.DatabaseName
            RemoteMachine = [string]$r.RemoteMachine
            RoleDesc      = [string]$r.RoleDesc
            StateDesc     = [string]$r.StateDesc
            Percent       = if ($total -gt 0) { [math]::Round(100.0 * $done / $total, 1) } else { 0 }
            Transferred   = Format-AgBytes $done
            Total         = Format-AgBytes $total
            Rate          = "$(Format-AgBytes ([double]$r.RateBytesPerSec))/s"
        }
    }
}

function Get-AgReplicaHealth {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'replica health' -Query @"
SELECT ar.replica_server_name                           AS Replica,
       ISNULL(ars.role_desc,'UNKNOWN')                  AS Role,
       ar.availability_mode_desc                        AS AvailabilityMode,
       ar.failover_mode_desc                            AS FailoverMode,
       ar.seeding_mode_desc                             AS SeedingMode,
       ar.secondary_role_allow_connections_desc         AS Readable,
       ISNULL(ars.connected_state_desc,'-')             AS ConnectedState,
       ISNULL(ars.synchronization_health_desc,'UNKNOWN')AS SyncHealth
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)
ORDER BY CASE WHEN ars.role_desc = 'PRIMARY' THEN 0 ELSE 1 END, ar.replica_server_name
"@
    return @($rows | ForEach-Object {
        [pscustomobject]@{
            Replica          = [string]$_.Replica
            Role             = [string]$_.Role
            AvailabilityMode = [string]$_.AvailabilityMode
            FailoverMode     = [string]$_.FailoverMode
            SeedingMode      = [string]$_.SeedingMode
            Readable         = [string]$_.Readable
            ConnectedState   = [string]$_.ConnectedState
            SyncHealth       = [string]$_.SyncHealth
        }
    })
}

function Get-AgDatabaseHealth {
    <#
    .SYNOPSIS
        One row per (database, replica) for an AG, read on the primary — which is the only
        replica that sees every secondary's rows.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [string[]]$Databases
    )
    $filter = ''
    if ($Databases -and $Databases.Count -gt 0) {
        $list = ($Databases | ForEach-Object { ConvertTo-AgQuotedString $_ }) -join ', '
        $filter = "AND adc.database_name IN ($list)"
    }

    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'database health' -Query @"
SELECT adc.database_name                          AS DatabaseName,
       ar.replica_server_name                     AS Replica,
       ar.availability_mode_desc                  AS AvailabilityMode,
       ISNULL(drs.synchronization_state_desc, 'NOT JOINED') AS SyncState,
       ISNULL(drs.synchronization_health_desc, '-')         AS SyncHealth,
       ISNULL(drs.database_state_desc, '')        AS DatabaseState,
       CAST(ISNULL(drs.is_suspended, 0) AS int)   AS IsSuspended,
       ISNULL(drs.suspend_reason_desc,'')         AS SuspendReason,
       ISNULL(drs.log_send_queue_size, 0)         AS LogSendQueueKB,
       ISNULL(drs.redo_queue_size, 0)             AS RedoQueueKB,
       CAST(ISNULL(drs.is_primary_replica, 0) AS int) AS IsPrimary
FROM sys.availability_groups AS ag
JOIN sys.availability_databases_cluster AS adc ON adc.group_id = ag.group_id
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs
       ON drs.group_database_id = adc.group_database_id AND drs.replica_id = ar.replica_id
WHERE ag.name = $(ConvertTo-AgQuotedString $AgName) $filter
ORDER BY adc.database_name, IsPrimary DESC, ar.replica_server_name
"@
    return @($rows | ForEach-Object {
        [pscustomobject]@{
            DatabaseName     = [string]$_.DatabaseName
            Replica          = [string]$_.Replica
            AvailabilityMode = [string]$_.AvailabilityMode
            SyncState        = [string]$_.SyncState
            SyncHealth       = [string]$_.SyncHealth
            DatabaseState    = [string]$_.DatabaseState
            IsSuspended      = ([int]$_.IsSuspended -eq 1)
            SuspendReason    = [string]$_.SuspendReason
            LogSendQueueKB   = [long]$_.LogSendQueueKB
            RedoQueueKB      = [long]$_.RedoQueueKB
            IsPrimary        = ([int]$_.IsPrimary -eq 1)
        }
    })
}

function Get-AgHealthFinding {
    <#
    .SYNOPSIS
        Evaluates one snapshot. Returns Problems (never clear on their own), Pending (normally
        clear within moments: reconnecting, catching up) and the rows read.
    #>
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$AgName,
        [string[]]$Databases,
        [string[]]$ExpectedNotJoined = @()
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $pending  = New-Object System.Collections.Generic.List[string]

    $replicas = @(Get-AgReplicaHealth -Instance $PrimaryInstance -AgName $AgName)
    $dbs      = @(Get-AgDatabaseHealth -Instance $PrimaryInstance -AgName $AgName -Databases $Databases)

    $prim = @($replicas | Where-Object { $_.Role -eq 'PRIMARY' })
    if ($prim.Count -ne 1) { $problems.Add("The AG has $($prim.Count) PRIMARY replica(s) as seen from $PrimaryInstance.") }

    foreach ($r in $replicas | Where-Object { $_.Role -ne 'PRIMARY' }) {
        if ($r.ConnectedState -ne 'CONNECTED') { $pending.Add("Replica $($r.Replica) is $($r.ConnectedState).") }
    }
    # Replica-level health is the roll-up of its databases' health, so with no databases in
    # the AG it always reads NOT_HEALTHY and says nothing. With databases it matters.
    if ($dbs.Count -gt 0) {
        foreach ($r in $replicas | Where-Object { $_.SyncHealth -ne 'HEALTHY' }) {
            $pending.Add("Replica $($r.Replica) reports synchronization health $($r.SyncHealth).")
        }
    }

    foreach ($d in $dbs) {
        if ($d.IsSuspended) {
            $problems.Add("[$($d.DatabaseName)] on $($d.Replica) is SUSPENDED ($($d.SuspendReason)). Resume: ALTER DATABASE [$($d.DatabaseName)] SET HADR RESUME;  (run on $($d.Replica))")
            continue
        }
        if ($d.IsPrimary) {
            if ($d.DatabaseState -and $d.DatabaseState -ne 'ONLINE') { $problems.Add("[$($d.DatabaseName)] is $($d.DatabaseState) on the primary $($d.Replica).") }
            continue
        }
        # Taken out of this one secondary on purpose: the primary still lists the replica's
        # row (NOT SYNCHRONIZING, or NOT JOINED), and that is exactly what was asked for.
        if (@($ExpectedNotJoined) -contains "$($d.DatabaseName)|$($d.Replica)") { continue }
        $want = if ($d.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT') { @('SYNCHRONIZED') } else { @('SYNCHRONIZING','SYNCHRONIZED') }
        if ($d.SyncState -eq 'NOT JOINED') {
            $pending.Add("[$($d.DatabaseName)] is not joined on $($d.Replica).")
        } elseif ($want -notcontains $d.SyncState) {
            $pending.Add("[$($d.DatabaseName)] on $($d.Replica) is $($d.SyncState) (expected $($want -join ' or ')).")
        }
    }

    [pscustomobject]@{ Problems = $problems; Pending = $pending; Replicas = $replicas; Databases = $dbs }
}

function Show-AgHealthRollup {
    <#
    .SYNOPSIS
        Prints the end-of-run health summary and returns $true when nothing is wrong.
    .PARAMETER Databases
        Limit the database section to these. Omit for every database in the AG.
    .PARAMETER SettleSeconds
        How long to wait for reconnecting replicas and catching-up databases before
        reporting them. Default 180.
    #>
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$AgName,
        [string[]]$Databases,
        [int]$SettleSeconds = 180,
        # "database|replica" pairs that are deliberately not joined (removed from one secondary).
        [string[]]$ExpectedNotJoined = @()
    )

    Write-AgBanner "HEALTH ROLLUP — [$AgName]"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $f  = Get-AgHealthFinding -PrimaryInstance $PrimaryInstance -AgName $AgName -Databases $Databases -ExpectedNotJoined $ExpectedNotJoined
    if ($f.Pending.Count -gt 0 -and $f.Problems.Count -eq 0) {
        Write-AgLog "Waiting up to $SettleSeconds s for $($f.Pending.Count) item(s) to settle before judging..." INFO
        while ($f.Pending.Count -gt 0 -and $f.Problems.Count -eq 0 -and $sw.Elapsed.TotalSeconds -lt $SettleSeconds) {
            Start-Sleep -Seconds 5
            $f = Get-AgHealthFinding -PrimaryInstance $PrimaryInstance -AgName $AgName -Databases $Databases -ExpectedNotJoined $ExpectedNotJoined
        }
    }

    Write-Host ''
    Write-Host "Replicas (as seen from $PrimaryInstance):" -ForegroundColor White
    $f.Replicas | Format-Table Replica, Role, AvailabilityMode, FailoverMode, SeedingMode, Readable, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 220 | Write-Host

    if ($f.Databases.Count -gt 0) {
        Write-Host 'Databases:' -ForegroundColor White
        $f.Databases | Format-Table DatabaseName, Replica, SyncState, SyncHealth, DatabaseState, LogSendQueueKB, RedoQueueKB, IsSuspended -AutoSize |
            Out-String -Width 220 | Write-Host
    } else {
        Write-Host 'Databases: none in the availability group yet (which is why the replicas read NOT_HEALTHY — normal until one is added).' -ForegroundColor DarkGray
    }

    #region Listener
    $topo = Get-AgTopology -Instance $PrimaryInstance -AgName $AgName -AllowNoPrimary
    if ($topo.Listeners.Count -eq 0) {
        Write-Host 'Listener: none. Applications have to connect to the primary replica by name.' -ForegroundColor Yellow
    } else {
        foreach ($l in $topo.Listeners) {
            $ips = ($l.Addresses | ForEach-Object { "$($_.IpAddress) ($($_.State))" }) -join ', '
            if (-not $ips) { $ips = 'DHCP' }
            Write-Host ("Listener: {0},{1}  ->  {2}" -f $l.DnsName, $l.Port, $ips) -ForegroundColor White
            if ($l.Addresses.Count -gt 0 -and @($l.Addresses | Where-Object { $_.State -eq 'ONLINE' }).Count -eq 0) {
                $f.Problems.Add("Listener $($l.DnsName) has no ONLINE IP address.")
            }
            if ($l.Addresses.Count -gt 1) {
                Write-Host '  Multi-subnet listener: only the address in the primary''s subnet is ONLINE, which is normal.' -ForegroundColor DarkGray
                Write-Host '  Clients should connect with MultiSubnetFailover=True.' -ForegroundColor DarkGray
            }
        }
    }
    #endregion

    if (@($ExpectedNotJoined).Count -gt 0) {
        Write-Host ("Deliberately not joined (removed from that replica only): {0}" -f (($ExpectedNotJoined | ForEach-Object { $_ -replace '\|', ' on ' }) -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host ''
    foreach ($p in $f.Pending) {
        $f.Problems.Add("$p  (still not settled after $SettleSeconds s)")
    }
    if ($f.Problems.Count -eq 0) {
        Write-AgLog 'Health rollup: no problems detected.' SUCCESS
        return $true
    }
    Write-AgLog "Health rollup found $($f.Problems.Count) problem(s):" ERROR
    $f.Problems | ForEach-Object { Write-AgLog "  - $_" ERROR }
    return $false
}
