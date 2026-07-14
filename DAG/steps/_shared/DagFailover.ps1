#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — the SQL layer: live role discovery, synchronization state, readiness,
    and the three statements that actually move the primary role between clusters.

.DESCRIPTION
    Everything here re-derives the topology from the servers. Nothing trusts a saved plan's
    idea of which side is the global primary, because a failover swaps exactly that, and a
    tool that fails over "the side the file says is primary" will happily fail over the
    wrong way round the second time it is run.

    Three facts about distributed availability groups drive the design, and each one was
    established by reading the DMVs on a live DAG rather than from first principles:

      1. A distributed AG owns NO databases of its own — sys.availability_databases_cluster
         has zero rows for the distributed group. The database list must come from the
         member AG that currently holds the primary role.

      2. Only the side holding the primary role sees the whole DAG. Query the forwarder and
         the remote member's role, connected_state and health all come back NULL. Readiness
         is therefore always assessed from the global primary.

      3. The forwarder's progress is the DAG row's last_hardened_lsn, and the value to
         compare it against is the source primary's OWN last_hardened_lsn — not its
         end_of_log_lsn, which in this DMV can legitimately sit BEHIND last_hardened_lsn on
         the primary. Comparing against end_of_log_lsn reports a mismatch on a perfectly
         healthy DAG and would block every failover.
#>

Set-StrictMode -Version Latest

#region ── Live topology ─────────────────────────────────────────────────────

function Get-DagMemberRoleOnInstance {
    <#
    .SYNOPSIS
        The DAG role of the member availability group that lives ON this instance.
    .OUTPUTS
        pscustomobject with MemberAg / DagRole / AvailabilityMode, or $null when this
        instance hosts no member of the named distributed AG.
    .DESCRIPTION
        The member AGs of a distributed AG appear as its "replicas", so a member AG's name
        sits in availability_replicas.replica_server_name. Joining that back to the local
        non-distributed availability groups yields exactly the member this instance hosts.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName
    )

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'local member role' -Query @"
SELECT lag.name                                    AS MemberAg,
       ISNULL(dars.role_desc, 'UNKNOWN')           AS DagRole,
       dar.availability_mode_desc                  AS AvailabilityMode,
       ISNULL(dars.connected_state_desc, 'UNKNOWN')AS ConnectedState
FROM sys.availability_groups AS dag
JOIN sys.availability_replicas AS dar ON dar.group_id = dag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS dars ON dars.replica_id = dar.replica_id
JOIN sys.availability_groups AS lag
     ON lag.name = dar.replica_server_name AND lag.is_distributed = 0
WHERE dag.name = $(ConvertTo-DagQuotedString $DagName) AND dag.is_distributed = 1
"@
    if ($rows.Count -eq 0) { return $null }
    [pscustomobject]@{
        MemberAg         = [string]$rows[0].MemberAg
        DagRole          = [string]$rows[0].DagRole
        AvailabilityMode = [string]$rows[0].AvailabilityMode
        ConnectedState   = [string]$rows[0].ConnectedState
    }
}

function Get-DagDistributedAgNames {
    param([Parameter(Mandatory)][string]$Instance)
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'distributed AG discovery' `
        -Query 'SELECT name AS n FROM sys.availability_groups WHERE is_distributed = 1 ORDER BY name'
    if ($rows.Count -eq 0) { return @() }
    return @($rows | ForEach-Object { [string]$_.n })
}

function Get-DagAgDatabase {
    <#
    .SYNOPSIS
        The databases belonging to a member availability group.
    .DESCRIPTION
        Read from the member AG, never from the distributed AG: the distributed group has
        no database list of its own.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'AG database list' -Query @"
SELECT adc.database_name AS n
FROM sys.availability_databases_cluster AS adc
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)
ORDER BY adc.database_name
"@
    if ($rows.Count -eq 0) { return @() }
    return @($rows | ForEach-Object { [string]$_.n })
}

function Get-DagMemberInventory {
    <#
    .SYNOPSIS
        The two member availability groups of a distributed AG, with the DAG role each one
        reports and the instances we reached it through. Decides nothing.

    .DESCRIPTION
        Split out from New-DagFailoverContext so that the caller can look at a distributed
        AG which has NO primary at all and decide what to do, rather than being handed an
        exception. That state is not a corruption — it is what an interrupted failover
        leaves behind, and it is recoverable.
    #>
    param(
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string[]]$CandidateInstances
    )

    $seen = @{}

    foreach ($i in $CandidateInstances) {
        if (-not (Test-DagConnection -Instance $i)) {
            Write-DagLog "  [$i] not reachable — skipping during discovery." WARN
            continue
        }
        $m = Get-DagMemberRoleOnInstance -Instance $i -DagName $DagName
        if (-not $m) {
            Write-DagLog "  [$i] hosts no member of [$DagName] — skipping." DEBUG
            continue
        }
        if (-not $seen.ContainsKey($m.MemberAg)) {
            $seen[$m.MemberAg] = [pscustomobject]@{
                MemberAg  = $m.MemberAg
                DagRole   = $m.DagRole
                Mode      = $m.AvailabilityMode
                Instances = New-Object System.Collections.Generic.List[string]
            }
        }
        # A member's DAG role is only visible from the side that hosts it — the far side
        # reports NULL for the remote member. Never let an UNKNOWN overwrite a real role.
        if ($m.DagRole -ne 'UNKNOWN') { $seen[$m.MemberAg].DagRole = $m.DagRole }
        $seen[$m.MemberAg].Instances.Add($i)
    }

    # Sorted: a hashtable's enumeration order is not defined, and this list is presented to
    # the operator as a numbered menu when they have to choose which side takes the primary
    # role. A menu whose numbering changes between runs is a menu that gets mis-clicked.
    $members = @($seen.Values | Sort-Object MemberAg)
    if ($members.Count -lt 2) {
        throw @"
Could not see both member availability groups of [$DagName] from the instances supplied:
    $($CandidateInstances -join ', ')

Found: $(if ($members.Count -eq 0) { '<none>' } else { ($members | ForEach-Object { "$($_.MemberAg) ($($_.DagRole))" }) -join ', ' })

Supply at least one reachable instance from EACH side of the distributed availability group.
"@
    }

    $primaries = @($members | Where-Object { $_.DagRole -eq 'PRIMARY' })
    if ($primaries.Count -gt 1) {
        throw @"
Both member availability groups of [$DagName] claim the PRIMARY role.

$(($members | ForEach-Object { "  $($_.MemberAg): $($_.DagRole)" }) -join "`r`n")

This is a split state. It cannot be resolved by failing over again, and doing so may make it
worse. Decide which side is authoritative, then on the primary replica of the LOSING member
availability group run:

    ALTER AVAILABILITY GROUP [$DagName] SET (ROLE = SECONDARY);

Note that it names the DISTRIBUTED group, not the member AG — which side is demoted is
decided by where you run it, not by what it names.
"@
    }

    return @($members)
}

function New-DagFailoverContext {
    <#
    .SYNOPSIS
        Resolves the live shape of a distributed AG: which member is failing over to which,
        and the primary replica, replicas and version of each side.

    .PARAMETER TargetAgName
        The member availability group that should END UP with the primary role.

        Required only when the DAG currently has NO primary — the state left behind when the
        demotion ran but the failover did not. In that state both members report SECONDARY
        from their own side and NULL for the remote one, so nothing in the DMVs records which
        of them was demoted. Guessing would be a coin flip on a live system, so the caller
        must say. Both answers are legitimate: promoting the forwarder completes the failover,
        promoting the original primary abandons it.

    .DESCRIPTION
        $CandidateInstances is any set of instances that between them host both member AGs.
        A saved plan is used only as a source of instance NAMES — which side is primary is
        always read from the servers, because that is exactly what a failover changes.
    #>
    param(
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string[]]$CandidateInstances,
        [string]$TargetAgName,
        [psobject[]]$Inventory
    )

    $members = if ($Inventory) { @($Inventory) } else { @(Get-DagMemberInventory -DagName $DagName -CandidateInstances $CandidateInstances) }

    $primaries  = @($members | Where-Object { $_.DagRole -eq 'PRIMARY' })
    $noPrimary  = ($primaries.Count -eq 0)

    if ($noPrimary) {
        if (-not $TargetAgName) {
            throw @"
[$DagName] has no member availability group in the PRIMARY role, and no -TargetAgName was
supplied to say which one should take it.

$(($members | ForEach-Object { "  $($_.MemberAg): $($_.DagRole)" }) -join "`r`n")
"@
        }
        $targetMember = @($members | Where-Object { $_.MemberAg -eq $TargetAgName })
        if ($targetMember.Count -ne 1) {
            throw "'$TargetAgName' is not a member availability group of [$DagName]. Members: $(($members | ForEach-Object { $_.MemberAg }) -join ', ')."
        }
        $targetMember = $targetMember[0]
        $sourceMember = @($members | Where-Object { $_.MemberAg -ne $TargetAgName })[0]
    } else {
        $sourceMember = $primaries[0]
        $targetMember = @($members | Where-Object { $_.MemberAg -ne $sourceMember.MemberAg })[0]
        if ($TargetAgName -and $TargetAgName -ne $targetMember.MemberAg) {
            throw "[$DagName] currently has '$($sourceMember.MemberAg)' as primary, so the failover target can only be '$($targetMember.MemberAg)', not '$TargetAgName'."
        }
    }

    $sourceTopo = Get-DagAgTopology -Instance $sourceMember.Instances[0] -AgName $sourceMember.MemberAg
    $targetTopo = Get-DagAgTopology -Instance $targetMember.Instances[0] -AgName $targetMember.MemberAg

    $sourceInfo = Get-DagInstanceInfo -Instance $sourceTopo.PrimaryReplica
    $targetInfo = Get-DagInstanceInfo -Instance $targetTopo.PrimaryReplica

    # The database list has to come from a member AG that actually holds them. In the
    # no-primary state the "source" is not serving, but its AG still owns the database list.
    $dbs = @(Get-DagAgDatabase -Instance $sourceTopo.PrimaryReplica -AgName $sourceMember.MemberAg)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-DagAgDatabase -Instance $targetTopo.PrimaryReplica -AgName $targetMember.MemberAg)
    }

    [pscustomobject]@{
        DagName            = $DagName
        SourceAgName       = $sourceMember.MemberAg
        SourcePrimary      = $sourceTopo.PrimaryReplica
        SourceReplicas     = @($sourceTopo.Replicas | ForEach-Object { $_.ReplicaServerName })
        SourceSecondaries  = @($sourceTopo.SecondaryReplicas)
        SourceMajorVersion = $sourceInfo.MajorVersion
        TargetAgName       = $targetMember.MemberAg
        TargetPrimary      = $targetTopo.PrimaryReplica
        TargetReplicas     = @($targetTopo.Replicas | ForEach-Object { $_.ReplicaServerName })
        TargetSecondaries  = @($targetTopo.SecondaryReplicas)
        TargetMajorVersion = $targetInfo.MajorVersion
        Databases          = $dbs
        IsCrossVersion     = ($sourceInfo.MajorVersion -ne $targetInfo.MajorVersion)
        IsUpgradeDirection = ($targetInfo.MajorVersion -gt $sourceInfo.MajorVersion)
        IsDowngrade        = ($targetInfo.MajorVersion -lt $sourceInfo.MajorVersion)
        # True when discovery found no primary at all: we are resuming an interrupted
        # failover, not starting one.
        IsResume           = $noPrimary
    }
}

#endregion

#region ── Availability mode ─────────────────────────────────────────────────

function Set-DagDistributedAgMode {
    <#
    .SYNOPSIS
        Sets AVAILABILITY_MODE on both members of a distributed AG.
    .DESCRIPTION
        MODIFY AVAILABILITY GROUP ON must be executed on BOTH sides. Running it only on the
        global primary leaves the forwarder still believing it is asynchronous, and the DAG
        never reaches SYNCHRONIZED — which, in a tool that gates failover on SYNCHRONIZED,
        looks like a hang with no cause.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][ValidateSet('SYNCHRONOUS_COMMIT','ASYNCHRONOUS_COMMIT')][string]$Mode,
        [string[]]$Instances
    )

    $sql = @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Context.DagName)
MODIFY
AVAILABILITY GROUP ON
    $(ConvertTo-DagQuotedString $Context.SourceAgName) WITH (AVAILABILITY_MODE = $Mode),
    $(ConvertTo-DagQuotedString $Context.TargetAgName) WITH (AVAILABILITY_MODE = $Mode);
"@

    $targets = if ($Instances) { $Instances } else { @($Context.SourcePrimary, $Context.TargetPrimary) }
    foreach ($i in $targets) {
        Invoke-DagSql -Instance $i -QueryTimeout 300 -Activity 'set distributed AG availability mode' -Query $sql | Out-Null
        Write-DagLog "  [$i] $($Context.DagName) -> $Mode on both member AGs" SUCCESS
    }
}

function Test-DagModeApplied {
    <#
    .SYNOPSIS
        Confirms both members report the given mode, as seen from every supplied instance.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Mode,
        [string[]]$Instances
    )
    $targets = if ($Instances) { $Instances } else { @($Context.SourcePrimary, $Context.TargetPrimary) }
    foreach ($i in $targets) {
        $state = @(Get-DagDistributedAgState -Instance $i -DagName $Context.DagName)
        foreach ($m in $state) {
            if ($m.AvailabilityMode -ne $Mode) {
                Write-DagLog "  [$i] member '$($m.MemberAg)' reports $($m.AvailabilityMode), expected $Mode" WARN
                return $false
            }
        }
    }
    return $true
}

#endregion

#region ── Synchronization state ─────────────────────────────────────────────

function Get-DagSyncStatus {
    <#
    .SYNOPSIS
        Per-database synchronization of the forwarder, read from the global primary.

    .OUTPUTS
        One row per database: sync state, suspension, queue depths, and the two LSNs whose
        equality is what "no data loss" actually means.

    .DESCRIPTION
        SourceHardenedLsn is the source primary's own last_hardened_lsn. DagHardenedLsn is
        how far the forwarder has hardened. When they are equal, every log record the
        primary has hardened is also hardened across the link.

        Deliberately NOT compared against the primary's end_of_log_lsn: that column can sit
        behind last_hardened_lsn on a primary, so an end-of-log comparison reports a
        mismatch on a healthy, fully synchronized DAG.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context
    )

    $rows = Invoke-DagSql -Instance $Context.SourcePrimary -Retry -Activity 'DAG sync status' -Query @"
SELECT dag.DatabaseName,
       dag.SyncState,
       dag.SyncHealth,
       dag.IsSuspended,
       dag.SuspendReason,
       dag.LogSendQueueKb,
       dag.RedoQueueKb,
       dag.DagHardenedLsn,
       loc.SourceHardenedLsn,
       loc.SourceEndOfLogLsn
FROM (
    SELECT drs.database_id                                AS dbid,
           ISNULL(DB_NAME(drs.database_id), '?')          AS DatabaseName,
           drs.synchronization_state_desc                 AS SyncState,
           drs.synchronization_health_desc                AS SyncHealth,
           CAST(drs.is_suspended AS int)                  AS IsSuspended,
           ISNULL(drs.suspend_reason_desc, '')            AS SuspendReason,
           ISNULL(drs.log_send_queue_size, 0)             AS LogSendQueueKb,
           ISNULL(drs.redo_queue_size, 0)                 AS RedoQueueKb,
           drs.last_hardened_lsn                          AS DagHardenedLsn
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
    WHERE ag.name = $(ConvertTo-DagQuotedString $Context.DagName) AND ag.is_distributed = 1
) AS dag
LEFT JOIN (
    SELECT drs.database_id            AS dbid,
           drs.last_hardened_lsn      AS SourceHardenedLsn,
           drs.end_of_log_lsn         AS SourceEndOfLogLsn
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
    WHERE ag.name = $(ConvertTo-DagQuotedString $Context.SourceAgName)
      AND ag.is_distributed = 0
      AND drs.is_local = 1
) AS loc ON loc.dbid = dag.dbid
ORDER BY dag.DatabaseName
"@

    if ($rows.Count -eq 0) { return @() }

    foreach ($r in $rows) {
        $dagLsn = if ($r.DagHardenedLsn -is [System.DBNull]) { $null } else { [decimal]$r.DagHardenedLsn }
        $srcLsn = if ($r.SourceHardenedLsn -is [System.DBNull]) { $null } else { [decimal]$r.SourceHardenedLsn }

        [pscustomobject]@{
            DatabaseName      = [string]$r.DatabaseName
            SyncState         = [string]$r.SyncState
            SyncHealth        = [string]$r.SyncHealth
            IsSuspended       = ([int]$r.IsSuspended -eq 1)
            SuspendReason     = [string]$r.SuspendReason
            LogSendQueueKb    = [long]$r.LogSendQueueKb
            RedoQueueKb       = [long]$r.RedoQueueKb
            DagHardenedLsn    = $dagLsn
            SourceHardenedLsn = $srcLsn
            SourceEndOfLogLsn = $(if ($r.SourceEndOfLogLsn -is [System.DBNull]) { $null } else { [decimal]$r.SourceEndOfLogLsn })
            LsnMatch          = ($null -ne $dagLsn -and $null -ne $srcLsn -and $dagLsn -eq $srcLsn)
            LsnDelta          = $(if ($null -ne $dagLsn -and $null -ne $srcLsn) { $srcLsn - $dagLsn } else { $null })
        }
    }
}

function Wait-DagSynchronized {
    <#
    .SYNOPSIS
        Waits for every database in the DAG to be SYNCHRONIZED with a matching hardened LSN.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$TimeoutSeconds = 900
    )

    return Wait-DagCondition -Activity "[$($Context.DagName)] reaching SYNCHRONIZED on every database" `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds 5 `
        -Condition {
            $s = @(Get-DagSyncStatus -Context $Context)
            if ($s.Count -eq 0) { return $false }
            $bad = @($s | Where-Object { $_.SyncState -ne 'SYNCHRONIZED' -or $_.IsSuspended -or -not $_.LsnMatch })
            return ($bad.Count -eq 0)
        } `
        -ProgressMessage {
            $s = @(Get-DagSyncStatus -Context $Context)
            $bad = @($s | Where-Object { $_.SyncState -ne 'SYNCHRONIZED' -or $_.IsSuspended -or -not $_.LsnMatch })
            if ($bad.Count -eq 0) { return $null }
            ($bad | ForEach-Object {
                if ($_.IsSuspended) { "$($_.DatabaseName)=SUSPENDED" }
                elseif ($_.SyncState -ne 'SYNCHRONIZED') { "$($_.DatabaseName)=$($_.SyncState)" }
                else { "$($_.DatabaseName)=LSN behind by $($_.LsnDelta)" }
            }) -join ' '
        }
}

#endregion

#region ── The failover statements ───────────────────────────────────────────

function Set-DagAgRoleSecondary {
    <#
    .SYNOPSIS
        Demotes the global primary availability group to secondary within the distributed AG.

    .DESCRIPTION
        The statement names the DISTRIBUTED availability group, not the member AG being
        demoted — which side gets demoted is decided by WHERE the statement runs (the global
        primary's replica), not by what it names. Naming the member AG instead is the obvious
        reading and it is wrong:

            Msg 19512: The requested operation only applies to distributed availability
                       group, and is not supported on the specified availability group.

        After this the source stops accepting writes, which is what makes the subsequent
        forced failover lossless: there is nothing left for the primary to accept that the
        forwarder has not already hardened.

        Idempotent — a member that is already SECONDARY is left alone.
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $state = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
    $me    = @($state | Where-Object { $_.MemberAg -eq $Context.SourceAgName })

    if ($me.Count -eq 1 -and $me[0].Role -eq 'SECONDARY') {
        Write-DagLog "  [$($Context.SourceAgName)] is already SECONDARY in [$($Context.DagName)] — skipping the demotion." SUCCESS
        return
    }

    Write-DagLog "  Demoting [$($Context.SourceAgName)] to SECONDARY on $($Context.SourcePrimary)..." INFO
    Invoke-DagSql -Instance $Context.SourcePrimary -QueryTimeout 300 -Activity 'demote global primary AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Context.DagName)
SET (ROLE = SECONDARY);
"@ | Out-Null
    Write-DagLog "  [$($Context.SourceAgName)] is now SECONDARY — the source has stopped accepting writes." SUCCESS
}

function Invoke-DagForceFailover {
    <#
    .SYNOPSIS
        Fails the distributed AG over to the forwarder.

    .DESCRIPTION
        FORCE_FAILOVER_ALLOW_DATA_LOSS is the ONLY failover command a distributed
        availability group accepts — there is no planned-failover form of the statement, and
        its name is a poor description of what it does here. Data loss is a property of the
        STATE the command runs against, not of the command:

          * run it against a SYNCHRONIZED DAG whose global primary has already been demoted
            with SET (ROLE = SECONDARY), and there is nothing to lose — every hardened log
            record is on both sides and the source is accepting no new ones,
          * run it against an ASYNCHRONOUS or lagging DAG and it will do exactly what it
            says, silently.

        Everything Failover-DAG.ps1 does before calling this exists to guarantee the first
        case. It is run on the forwarder AG's primary replica.
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    Write-DagLog "  Failing [$($Context.DagName)] over to [$($Context.TargetAgName)] on $($Context.TargetPrimary)..." INFO
    Invoke-DagSql -Instance $Context.TargetPrimary -QueryTimeout 600 -Activity 'force failover distributed AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Context.DagName)
FORCE_FAILOVER_ALLOW_DATA_LOSS;
"@ | Out-Null
    Write-DagLog "  Failover statement accepted on $($Context.TargetPrimary)." SUCCESS
}

function Test-DagFailoverComplete {
    <#
    .SYNOPSIS
        Has the target member AG taken the primary role in the distributed AG?
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $state = @(Get-DagDistributedAgState -Instance $Context.TargetPrimary -DagName $Context.DagName)
    $me    = @($state | Where-Object { $_.MemberAg -eq $Context.TargetAgName })
    return ($me.Count -eq 1 -and $me[0].Role -eq 'PRIMARY')
}

function Get-DagFailoverStage {
    <#
    .SYNOPSIS
        Where in the failover sequence this distributed AG currently sits.

    .OUTPUTS
        'NotStarted'  the source still holds the primary role
        'Demoted'     the source has been demoted but no member holds the primary role —
                      the failover statement did not run, or did not take
        'Complete'    the target holds the primary role
        'Split'       both members claim the primary role

    .DESCRIPTION
        This is what makes the script re-runnable. The window between the demotion and the
        forced failover is small but it is real, and a run interrupted inside it leaves a
        distributed AG with NO primary — every database offline on both sides. Recognising
        that state and finishing the job is the difference between a resumable tool and a
        3 a.m. incident.
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $roles = @{}
    foreach ($i in @($Context.SourcePrimary, $Context.TargetPrimary)) {
        if (-not (Test-DagConnection -Instance $i)) { continue }
        foreach ($m in @(Get-DagDistributedAgState -Instance $i -DagName $Context.DagName)) {
            # Only the side that holds a member can report that member's role; the remote
            # side reports UNKNOWN. Never let an UNKNOWN overwrite a role we already have.
            if ($m.Role -eq 'UNKNOWN') { continue }
            $roles[$m.MemberAg] = $m.Role
        }
    }

    $srcRole = if ($roles.ContainsKey($Context.SourceAgName)) { $roles[$Context.SourceAgName] } else { 'UNKNOWN' }
    $tgtRole = if ($roles.ContainsKey($Context.TargetAgName)) { $roles[$Context.TargetAgName] } else { 'UNKNOWN' }

    if ($srcRole -eq 'PRIMARY' -and $tgtRole -eq 'PRIMARY') { return 'Split' }
    if ($tgtRole -eq 'PRIMARY') { return 'Complete' }
    if ($srcRole -eq 'PRIMARY') { return 'NotStarted' }
    if ($srcRole -eq 'SECONDARY' -and $tgtRole -eq 'SECONDARY') { return 'Demoted' }
    return 'NotStarted'
}

#endregion
