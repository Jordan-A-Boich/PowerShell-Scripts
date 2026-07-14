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

function Show-DagPostFailoverRollup {
    <#
    .SYNOPSIS
        Health and synchronization of the distributed AG in its new shape.
    .OUTPUTS
        [bool] — $true when nothing is wrong that is not expected for this topology.
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $problems = New-Object System.Collections.Generic.List[string]
    $expected = New-Object System.Collections.Generic.List[string]

    Write-Host ''
    Write-Host "Distributed availability group [$($Context.DagName)] after failover:" -ForegroundColor White
    $dagState = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
    $dagState | Format-Table MemberAg, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    foreach ($m in $dagState) {
        if ($m.AvailabilityMode -ne 'ASYNCHRONOUS_COMMIT') {
            $problems.Add("Member AG '$($m.MemberAg)' is still $($m.AvailabilityMode).")
        }
    }

    #region The new primary's own AG
    Write-Host "NEW PRIMARY availability group '$($Context.SourceAgName)' (as seen from $($Context.SourcePrimary)):" -ForegroundColor White
    @(Get-DagReplicaHealth -Instance $Context.SourcePrimary -AgName $Context.SourceAgName) |
        Format-Table ReplicaServerName, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host
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
    #>
    $oldIsLower = ($Context.TargetMajorVersion -lt $Context.SourceMajorVersion)

    Write-Host "Synchronization to the new forwarder ($($Context.TargetAgName)):" -ForegroundColor White
    $sync = @(Get-DagSyncStatus -Context $Context)
    if ($sync.Count -eq 0) {
        Write-Host '  (no rows — the new forwarder is not receiving log)' -ForegroundColor DarkGray
    }
    foreach ($d in $sync) {
        $col = if ($d.SyncState -in @('SYNCHRONIZED','SYNCHRONIZING')) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-30} {1,-18} hardened {2}" -f $d.DatabaseName, $d.SyncState, $d.DagHardenedLsn) -ForegroundColor $col
        if ($d.SyncState -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
            if ($oldIsLower) {
                $expected.Add("[$($d.DatabaseName)] is $($d.SyncState) on '$($Context.TargetAgName)' — expected: it runs $(Get-DagSqlVersionName $Context.TargetMajorVersion) and cannot apply log from databases now upgraded to $(Get-DagSqlVersionName $Context.SourceMajorVersion).")
            } else {
                $problems.Add("[$($d.DatabaseName)] is $($d.SyncState) to the new forwarder.")
            }
        }
    }
    Write-Host ''
    #endregion

    if ($expected.Count -gt 0) {
        Write-Host 'Expected states for this topology (not faults):' -ForegroundColor Yellow
        $expected | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host ("  The upgrade is done. '{0}' has served its purpose and is now a dead end:" -f $Context.TargetAgName) -ForegroundColor Yellow
        Write-Host '  decommission it rather than trying to repair the synchronization.' -ForegroundColor Yellow
        Write-Host ''
    }

    if ($problems.Count -eq 0) {
        Write-DagLog 'Post-failover rollup: no problems detected.' SUCCESS
        return $true
    }
    Write-DagLog "Post-failover rollup found $($problems.Count) problem(s):" ERROR
    $problems | ForEach-Object { Write-DagLog "  - $_" ERROR }
    return $false
}

function Invoke-DagSettle {
    <#
    .OUTPUTS
        pscustomobject with Context (the NEW, post-failover shape) and Healthy [bool].
    #>
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$OnlineTimeoutSeconds = 1800
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

    $healthy = Show-DagPostFailoverRollup -Context $new

    return [pscustomobject]@{ Context = $new; Healthy = $healthy }
}
