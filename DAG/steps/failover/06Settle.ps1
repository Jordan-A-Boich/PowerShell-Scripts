#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 6: back to asynchronous commit, then prove the new shape is healthy.

.DESCRIPTION
    The roles have swapped, so everything in this step works from a context re-derived from
    the servers. Reusing the pre-failover context here would settle the wrong side: its
    "source primary" is now the forwarder.

    Asynchronous commit is the steady state for a distributed availability group. Leaving it
    synchronous after a failover would keep every commit on the NEW primary waiting for the
    OLD one — which, after a cross-version failover, is a replica that can no longer apply
    the log at all. That does not merely cost latency; it makes the new primary's commit
    path depend on a replica that will never acknowledge.

    THE ROLLUP WAITS BEFORE IT JUDGES. A failover does not finish the moment the role moves.
    The old primary has to notice it is now a forwarder and re-establish the distributed AG
    link; the new primary's own secondaries reconnect to a replica that has just changed
    role; the per-database rows in sys.dm_hadr_database_replica_states are rebuilt and read
    NOT SYNCHRONIZING with a hardened LSN of 0 until they are. All of that is normal and
    clears itself within seconds to a couple of minutes. Reading the DMVs the instant the
    failover statement returns therefore reports a pile of failures that are simply the
    system still coming up — which is worse than useless, because it teaches the operator
    that this rollup cries wolf. So Step 6 polls until the new shape is actually settled
    (or a bounded timeout expires) and only then decides what to call a problem.
#>

Set-StrictMode -Version Latest

function Wait-DagDatabasesOnline {
    <#
    .SYNOPSIS
        Waits for the databases to come ONLINE on the new primary.
    .DESCRIPTION
        After a cross-version failover the databases are physically upgraded as they come
        up, so this is where that time is spent. Before the failover they sat in RECOVERING
        on the forwarder and were not readable; ONLINE here is the proof that the failover
        did the thing it was for.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Databases,
        [int]$TimeoutSeconds = 1800
    )

    return Wait-DagCondition -Activity "databases coming ONLINE on the new primary $Instance" `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds 10 `
        -Condition {
            foreach ($db in $Databases) {
                $s = Get-DagDatabaseState -Instance $Instance -DatabaseName $db
                if (-not $s -or $s.StateDesc -ne 'ONLINE') { return $false }
            }
            return $true
        } `
        -ProgressMessage {
            $notYet = foreach ($db in $Databases) {
                $s = Get-DagDatabaseState -Instance $Instance -DatabaseName $db
                $state = if ($s) { $s.StateDesc } else { 'absent' }
                if ($state -ne 'ONLINE') { "$db=$state" }
            }
            if ($notYet) { ($notYet -join ' ') } else { $null }
        }
}

function Test-DagForwarderIsOlder {
    <#
    .SYNOPSIS
        Is the NEW forwarder on an older major version than the new primary?
    .DESCRIPTION
        The upgrade end state. Such a forwarder cannot apply log from databases that have
        just been upgraded, so it never reports healthy and never synchronizes again. Waiting
        for it to settle would burn the whole timeout on something that is finished, and
        calling it a fault would be wrong. Every settle check exempts the forwarder when this
        is true; the rollup lists those states as expected instead.
    #>
    param([Parameter(Mandatory)][psobject]$Context)
    return ($Context.TargetMajorVersion -lt $Context.SourceMajorVersion)
}

function Get-DagPostFailoverState {
    <#
    .SYNOPSIS
        One snapshot of the post-failover shape, plus what about it is not settled yet.

    .OUTPUTS
        pscustomobject:
            DagState  — member rows of the distributed AG, as seen from the new primary
            Replicas  — replica rows of the new primary's own member AG
            Sync      — per-database synchronization of the new forwarder
            Pending   — [string[]] plain-language list of what has not settled
            IsSettled — [bool] Pending is empty

    .DESCRIPTION
        Anything transient after a failover belongs in Pending: a DMV that cannot be read
        yet, a link that has not reconnected, a database row that has not been rebuilt.
        A query failure is deliberately treated as "not settled" rather than an error —
        immediately after a forced failover the DMVs on a replica that is still recovering
        can refuse to answer, and that is exactly the condition this wait exists for.
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $pending    = New-Object System.Collections.Generic.List[string]
    $oldIsLower = Test-DagForwarderIsOlder -Context $Context
    $dagState   = @()
    $replicas   = @()
    $sync       = @()

    try {
        $dagState = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
        $replicas = @(Get-DagReplicaHealth -Instance $Context.SourcePrimary -AgName $Context.SourceAgName)
        $sync     = @(Get-DagSyncStatus -Context $Context)
    } catch {
        $pending.Add("$($Context.SourcePrimary) is not answering yet ($($_.Exception.Message.Split("`n")[0].Trim()))")
        return [pscustomobject]@{
            DagState = $dagState; Replicas = $replicas; Sync = $sync
            Pending  = @($pending); IsSettled = $false; ForwarderIsOlder = $oldIsLower
        }
    }

    #region The two member AGs of the distributed group
    if ($dagState.Count -eq 0) {
        $pending.Add("[$($Context.DagName)] is not reporting its members yet")
    }
    foreach ($m in $dagState) {
        # The new forwarder in an upgrade is a dead end by design — never wait on it.
        if ($oldIsLower -and $m.MemberAg -eq $Context.TargetAgName) { continue }
        if ($m.ConnectedState -ne 'CONNECTED') {
            $pending.Add("member AG '$($m.MemberAg)' is $($m.ConnectedState)")
        } elseif ($m.SyncHealth -ne 'HEALTHY') {
            $pending.Add("member AG '$($m.MemberAg)' health is $($m.SyncHealth)")
        }
    }
    #endregion

    #region The new primary's own availability group
    # Its secondaries were talking to a replica that has just changed role; they reconnect
    # on their own. Rows whose role is not yet known are still being rebuilt.
    foreach ($r in $replicas) {
        if ($r.Role -eq 'PRIMARY') { continue }
        if ($r.ConnectedState -ne 'CONNECTED') {
            $pending.Add("$($r.ReplicaServerName) is $($r.ConnectedState)")
        } elseif ($r.SyncHealth -ne 'HEALTHY') {
            $pending.Add("$($r.ReplicaServerName) health is $($r.SyncHealth)")
        }
    }
    #endregion

    #region Log flow to the new forwarder
    if (-not $oldIsLower) {
        if ($sync.Count -eq 0) {
            $pending.Add("no per-database rows for [$($Context.DagName)] yet")
        }
        foreach ($d in $sync) {
            # Suspension is deliberately NOT waited on: data movement that has been suspended
            # stays suspended until somebody resumes it, so polling for it would spend the
            # whole timeout to learn what the first read already said. The rollup reports it
            # as a real problem with the statement that fixes it.
            if ($d.IsSuspended) { continue }
            if ($d.SyncState -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
                $pending.Add("$($d.DatabaseName) is $($d.SyncState)")
            }
        }
    }
    #endregion

    return [pscustomobject]@{
        DagState         = $dagState
        Replicas         = $replicas
        Sync             = $sync
        Pending          = @($pending)
        IsSettled        = ($pending.Count -eq 0)
        ForwarderIsOlder = $oldIsLower
    }
}

function Wait-DagPostFailoverSettled {
    <#
    .SYNOPSIS
        Polls until the post-failover shape stops changing, or the timeout expires.
    .OUTPUTS
        pscustomobject with Settled [bool], State (the last snapshot) and TimeoutSeconds.
    .DESCRIPTION
        A timeout is not a failure verdict — it only means the rollup that follows is being
        printed against a shape that is still moving, and the rollup says so.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$TimeoutSeconds = 180,
        [int]$PollSeconds = 5
    )

    # A hashtable, not a plain variable: the poll scriptblocks below need to hand the
    # snapshot they took back to this scope, and mutating a captured object is the one way
    # to do that which does not depend on how the scriptblock is dot-sourced or invoked.
    $box = @{ State = $null }

    if ($TimeoutSeconds -le 0) {
        $box.State = Get-DagPostFailoverState -Context $Context
        Write-DagLog 'Settle wait disabled (timeout 0) — reporting the state as it is right now.' WARN
        return [pscustomobject]@{ Settled = $box.State.IsSettled; State = $box.State; TimeoutSeconds = 0 }
    }

    $describe = {
        param($items)
        $shown = @($items | Select-Object -First 6)
        $extra = $items.Count - $shown.Count
        ($shown -join '; ') + $(if ($extra -gt 0) { " (+$extra more)" } else { '' })
    }

    $settled = Wait-DagCondition -Activity "[$($Context.DagName)] settling into its new shape" `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds `
        -Condition {
            $box.State = Get-DagPostFailoverState -Context $Context
            return $box.State.IsSettled
        } `
        -ProgressMessage {
            if ($box.State -and -not $box.State.IsSettled) { & $describe $box.State.Pending } else { $null }
        }

    if (-not $box.State) { $box.State = Get-DagPostFailoverState -Context $Context }

    if (-not $settled) {
        Write-DagLog "Still not settled after ${TimeoutSeconds}s: $(& $describe $box.State.Pending)" WARN
        Write-DagLog 'The rollup below is a snapshot of a shape that is still moving. Re-read it in a minute' INFO
        Write-DagLog 'before treating anything in it as a fault.' INFO
    }

    return [pscustomobject]@{ Settled = $settled; State = $box.State; TimeoutSeconds = $TimeoutSeconds }
}

function Show-DagPostFailoverRollup {
    <#
    .SYNOPSIS
        Health and synchronization of the distributed AG in its new shape.
    .PARAMETER Settled
        $false when the settle wait timed out. Nothing below is judged differently — the
        checks are the same — but the verdict says the shape was still moving when it was
        read, which is the difference between "this is broken" and "this had not finished".
    .OUTPUTS
        [bool] — $true when nothing is wrong that is not expected for this topology.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [bool]$Settled = $true,
        [int]$SettleTimeoutSeconds = 0
    )

    # Three buckets, because "wrong" is not one thing here:
    #   $problems  — states that do not fix themselves (a suspended database, a database that
    #                is not online, a mode that did not take). Always reported as errors.
    #   $transient — states a distributed AG passes through while it reconnects. Reported as
    #                errors only if they are STILL present after the settle wait succeeded;
    #                if the wait timed out they are reported as unfinished, not as faults.
    #   $expected  — the cross-version end state, which is neither.
    $problems  = New-Object System.Collections.Generic.List[string]
    $transient = New-Object System.Collections.Generic.List[string]
    $expected  = New-Object System.Collections.Generic.List[string]
    $oldIsLower = Test-DagForwarderIsOlder -Context $Context

    Write-Host ''
    Write-Host "Distributed availability group [$($Context.DagName)] after failover:" -ForegroundColor White
    $dagState = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
    $dagState | Format-Table MemberAg, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    foreach ($m in $dagState) {
        if ($m.AvailabilityMode -ne 'ASYNCHRONOUS_COMMIT') {
            $problems.Add("Member AG '$($m.MemberAg)' is still $($m.AvailabilityMode).")
        }

        # The link between the two clusters. It drops while the old primary works out that it
        # is now a forwarder, and comes back on its own — which is why this is only read
        # after the settle wait.
        $isNewForwarder = ($m.MemberAg -eq $Context.TargetAgName)
        if ($m.ConnectedState -ne 'CONNECTED' -or $m.SyncHealth -ne 'HEALTHY') {
            $desc = "member AG '$($m.MemberAg)' is $($m.ConnectedState) / $($m.SyncHealth)"
            if ($isNewForwarder -and $oldIsLower) {
                $expected.Add("$desc — expected: it runs $(Get-DagSqlVersionName $Context.TargetMajorVersion) and can no longer follow the upgraded primary.")
            } else {
                $transient.Add("The distributed availability group link to $desc.")
            }
        }
    }

    #region The new primary's own AG
    Write-Host "NEW PRIMARY availability group '$($Context.SourceAgName)' (as seen from $($Context.SourcePrimary)):" -ForegroundColor White
    $replicas = @(Get-DagReplicaHealth -Instance $Context.SourcePrimary -AgName $Context.SourceAgName)
    $replicas | Format-Table ReplicaServerName, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    # A secondary of the new primary was, until a moment ago, following a replica that has
    # just changed role. It reconnects by itself; if it has not by now, it is worth naming.
    foreach ($r in $replicas) {
        if ($r.Role -eq 'PRIMARY') { continue }
        if ($r.ConnectedState -ne 'CONNECTED' -or $r.SyncHealth -ne 'HEALTHY') {
            $transient.Add("Replica $($r.ReplicaServerName) of the new primary AG is $($r.ConnectedState) / $($r.SyncHealth).")
        }
    }
    #endregion

    #region Databases on the new primary
    Write-Host "Databases on the new primary ($($Context.SourcePrimary)):" -ForegroundColor White
    foreach ($db in $Context.Databases) {
        $s = Get-DagDatabaseState -Instance $Context.SourcePrimary -DatabaseName $db
        $state = if ($s) { $s.StateDesc } else { 'ABSENT' }
        $col = if ($state -eq 'ONLINE') { 'Green' } else { 'Red' }
        Write-Host ("  {0,-30} {1}" -f $db, $state) -ForegroundColor $col
        if ($state -ne 'ONLINE') {
            $problems.Add("[$db] is $state on the new primary '$($Context.SourcePrimary)' — it should be ONLINE after a failover.")
        }
    }
    Write-Host ''
    #endregion

    #region Synchronization back to the new forwarder
    <#
        After a cross-version failover the new forwarder is the OLDER version, and it cannot
        apply log records from databases that have just been upgraded. It will report NOT
        SYNCHRONIZING and it is never coming back. That is the documented end state of a
        distributed AG used for an upgrade — not a fault to chase — and calling it a problem
        here would teach the operator to ignore this rollup.

        Everything else here is read only after the settle wait, because immediately after a
        failover these same rows read NOT SYNCHRONIZING with a hardened LSN of 0 while they
        are being rebuilt, and that is not a fault either.
    #>
    Write-Host "Synchronization to the new forwarder ($($Context.TargetAgName)):" -ForegroundColor White
    $sync = @(Get-DagSyncStatus -Context $Context)
    if ($sync.Count -eq 0) {
        Write-Host '  (no rows — the new forwarder is not receiving log)' -ForegroundColor DarkGray
        if (-not $oldIsLower) {
            $transient.Add("[$($Context.DagName)] reports no per-database rows for the new forwarder — no log is flowing to '$($Context.TargetAgName)'.")
        }
    }
    $suspended = $false
    foreach ($d in $sync) {
        $healthySync = ($d.SyncState -in @('SYNCHRONIZED','SYNCHRONIZING')) -and -not $d.IsSuspended
        $col   = if ($healthySync) { 'Green' } else { 'Yellow' }
        $shown = if ($d.IsSuspended) { 'SUSPENDED' } else { $d.SyncState }
        Write-Host ("  {0,-30} {1,-18} hardened {2}" -f $d.DatabaseName, $shown, $d.DagHardenedLsn) -ForegroundColor $col
        if ($healthySync) { continue }

        if ($oldIsLower) {
            $expected.Add("[$($d.DatabaseName)] is $shown on '$($Context.TargetAgName)' — expected: it runs $(Get-DagSqlVersionName $Context.TargetMajorVersion) and cannot apply log from databases now upgraded to $(Get-DagSqlVersionName $Context.SourceMajorVersion).")
        } elseif ($d.IsSuspended) {
            $suspended = $true
            $problems.Add("[$($d.DatabaseName)] data movement is SUSPENDED$(if ($d.SuspendReason) { " ($($d.SuspendReason))" }) — it will not catch up until it is resumed.")
        } else {
            $transient.Add("[$($d.DatabaseName)] is $($d.SyncState) to the new forwarder.")
        }
    }
    Write-Host ''

    # Suspension is the one state here that never clears on its own, so say what fixes it.
    if ($suspended) {
        Write-Host 'A suspended database does not resume by itself. On the forwarder primary' -ForegroundColor Yellow
        Write-Host ("({0}), for each suspended database:" -f $Context.TargetPrimary) -ForegroundColor Yellow
        Write-Host '    ALTER DATABASE [<name>] SET HADR RESUME;' -ForegroundColor Yellow
        Write-Host ''
    }
    #endregion

    if ($expected.Count -gt 0) {
        Write-Host 'Expected states for this topology (not faults):' -ForegroundColor Yellow
        $expected | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host ("  The upgrade is done. '{0}' has served its purpose and is now a dead end:" -f $Context.TargetAgName) -ForegroundColor Yellow
        Write-Host '  decommission it rather than trying to repair the synchronization.' -ForegroundColor Yellow
        Write-Host ''
    }

    if ($problems.Count -eq 0 -and $transient.Count -eq 0) {
        Write-DagLog 'Post-failover rollup: no problems detected.' SUCCESS
        return $true
    }

    # States that do not fix themselves are always errors, whether or not the shape settled.
    if ($problems.Count -gt 0) {
        Write-DagLog "Post-failover rollup found $($problems.Count) problem(s):" ERROR
        $problems | ForEach-Object { Write-DagLog "  - $_" ERROR }
    }

    if ($transient.Count -gt 0) {
        if ($Settled) {
            # The wait said the shape had settled and these are still here — that is a real
            # finding, not a snapshot taken too early.
            Write-DagLog "Post-failover rollup found $($transient.Count) further problem(s):" ERROR
            $transient | ForEach-Object { Write-DagLog "  - $_" ERROR }
        } else {
            # Reported as unfinished, not as broken. One of these is a reason to investigate;
            # the other is a reason to look again in a minute.
            Write-DagLog "$($transient.Count) item(s) had not finished reconnecting within ${SettleTimeoutSeconds}s:" WARN
            $transient | ForEach-Object { Write-DagLog "  - $_" WARN }
            Write-Host ''
            Write-DagLog 'The failover itself completed — the primary role moved and the databases are online.' INFO
            Write-DagLog 'These are states a distributed availability group passes through while it reconnects,' INFO
            Write-DagLog 'and they usually clear on their own. Read them again before chasing them:' INFO
            Write-DagLog "    SELECT * FROM sys.dm_hadr_database_replica_states  -- on $($Context.SourcePrimary)" INFO
        }
    }

    return $false
}

function Invoke-DagSettle {
    <#
    .OUTPUTS
        pscustomobject with Context (the NEW, post-failover shape) and Healthy [bool].
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$OnlineTimeoutSeconds = 1800,
        [int]$SettleTimeoutSeconds = 180
    )

    Write-DagBanner 'STEP 6 of 6 — SETTLE AND HEALTH ROLLUP'

    #region Re-derive the topology: the roles have swapped
    $all = @($Context.SourceReplicas) + @($Context.TargetReplicas)
    $new = New-DagFailoverContext -DagName $Context.DagName -CandidateInstances $all

    Write-DagLog "[$($new.SourceAgName)] now holds the PRIMARY role (primary replica $($new.SourcePrimary))." SUCCESS
    Write-DagLog "[$($new.TargetAgName)] is now the forwarder." INFO
    #endregion

    #region Databases online on the new primary
    Write-DagLog 'Waiting for the databases to come ONLINE on the new primary...' INFO
    if (-not (Wait-DagDatabasesOnline -Instance $new.SourcePrimary -Databases $new.Databases -TimeoutSeconds $OnlineTimeoutSeconds)) {
        Write-DagLog "Not every database reached ONLINE on '$($new.SourcePrimary)' within $OnlineTimeoutSeconds seconds." WARN
        Write-DagLog 'A cross-version failover upgrades the database files as they come up, which on a large' INFO
        Write-DagLog 'database takes time. Check the SQL Server error log for upgrade progress before assuming' INFO
        Write-DagLog 'it has failed.' INFO
    } else {
        Write-DagLog 'All databases are ONLINE on the new primary.' SUCCESS
    }
    #endregion

    #region Back to asynchronous commit
    Write-DagLog 'Returning the distributed availability group to ASYNCHRONOUS_COMMIT...' INFO
    Set-DagDistributedAgMode -Context $new -Mode 'ASYNCHRONOUS_COMMIT'

    if (-not (Test-DagModeApplied -Context $new -Mode 'ASYNCHRONOUS_COMMIT' -Instances @($new.SourcePrimary))) {
        Write-DagLog 'The new primary does not report ASYNCHRONOUS_COMMIT on both members. Check it by hand.' WARN
    } else {
        Write-DagLog 'Both member availability groups confirm ASYNCHRONOUS_COMMIT.' SUCCESS
    }
    #endregion

    #region Let the new shape settle before judging it
    <#
        Everything from here on is a verdict, and a verdict read too early is wrong. The
        link between the clusters, the new primary's own secondaries and the per-database
        rows all take seconds to a couple of minutes to catch up with the role change.
    #>
    Write-DagLog 'Waiting for the new shape to settle before the health rollup...' INFO
    $settle = Wait-DagPostFailoverSettled -Context $new -TimeoutSeconds $SettleTimeoutSeconds
    if ($settle.Settled -and $settle.TimeoutSeconds -gt 0) {
        Write-DagLog 'The distributed availability group has settled into its new shape.' SUCCESS
    }
    #endregion

    $healthy = Show-DagPostFailoverRollup -Context $new -Settled $settle.Settled -SettleTimeoutSeconds $settle.TimeoutSeconds

    return [pscustomobject]@{ Context = $new; Healthy = $healthy; Settled = $settle.Settled }
}
