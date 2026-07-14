#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 4: the synchronization and LSN rollup, and the go / no-go call.

.DESCRIPTION
    A blocker is a condition under which FORCE_FAILOVER_ALLOW_DATA_LOSS would do what its
    name threatens. A warning is something the operator should know but which does not by
    itself put data at risk.

    The recommendation is computed from the blockers, not from a feeling. If there are none,
    this is a GO and the failover is lossless. If there is even one, it is a NO-GO, and
    -Force is the only way past it — which is the right shape, because every blocker here is
    a way of saying "the forwarder does not have all your data yet".
#>

Set-StrictMode -Version Latest

function Get-DagFailoverReadiness {
    <#
    .OUTPUTS
        pscustomobject with IsGo / Blockers[] / Warnings[] / Databases[]
    #>
    param([Parameter(Mandatory)][psobject]$Context)

    $blockers = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    #region The distributed AG itself
    $dagState = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
    if ($dagState.Count -eq 0) {
        $blockers.Add("Distributed availability group '$($Context.DagName)' cannot be read from $($Context.SourcePrimary).")
    }
    foreach ($m in $dagState) {
        if ($m.AvailabilityMode -ne 'SYNCHRONOUS_COMMIT') {
            $blockers.Add("Member AG '$($m.MemberAg)' is $($m.AvailabilityMode). A forced failover from asynchronous commit loses every transaction the forwarder has not yet hardened.")
        }
        if ($m.ConnectedState -ne 'CONNECTED') {
            $blockers.Add("Member AG '$($m.MemberAg)' is $($m.ConnectedState). The forwarder cannot be caught up while the link is down.")
        }
        if ($m.SyncHealth -eq 'NOT_HEALTHY') {
            $blockers.Add("Member AG '$($m.MemberAg)' reports synchronization health NOT_HEALTHY.")
        }
    }
    #endregion

    #region Per-database synchronization and LSN match
    $dbs = @(Get-DagSyncStatus -Context $Context)

    $missing = @($Context.Databases | Where-Object { $n = $_; -not (@($dbs | Where-Object { $_.DatabaseName -eq $n })) })
    foreach ($m in $missing) {
        $blockers.Add("[$m] is in '$($Context.SourceAgName)' but has no row in the distributed availability group — it has never reached the forwarder.")
    }

    foreach ($d in $dbs) {
        if ($d.IsSuspended) {
            $blockers.Add("[$($d.DatabaseName)] data movement is SUSPENDED$(if ($d.SuspendReason) { " ($($d.SuspendReason))" }). The forwarder is not receiving log for it.")
            continue
        }
        if ($d.SyncState -ne 'SYNCHRONIZED') {
            $blockers.Add("[$($d.DatabaseName)] is $($d.SyncState), not SYNCHRONIZED.")
            continue
        }
        if (-not $d.LsnMatch) {
            $behind = if ($null -ne $d.LsnDelta) { $d.LsnDelta } else { 'an unknown amount' }
            $blockers.Add("[$($d.DatabaseName)] is SYNCHRONIZED but the forwarder's hardened LSN is behind the primary's by $behind.")
            continue
        }
        if ($d.RedoQueueKb -gt 0) {
            $warnings.Add("[$($d.DatabaseName)] has $($d.RedoQueueKb) KB still to redo on the forwarder. No data is at risk — it is hardened — but the database will take longer to come online after failover.")
        }
    }
    #endregion

    #region Seeding still running
    $seeding = @(Get-DagSeedingProgress -Instance $Context.SourcePrimary -AgName $Context.SourceAgName |
                    Where-Object { $_.RemoteReplica -eq $Context.TargetAgName -and $_.CurrentState -notin @('COMPLETED','FAILED') })
    foreach ($s in $seeding) {
        $blockers.Add("[$($s.DatabaseName)] is still being seeded to the forwarder ($($s.CurrentState)). Let it finish.")
    }
    #endregion

    #region The member AGs' own internal health
    <#
        A DAG failover does not need the source AG's local secondaries to be healthy, so
        these are warnings. They matter anyway: the source AG is about to become the
        forwarder, and a secondary that is already unhealthy there will still be unhealthy
        afterwards — just harder to notice.
    #>
    foreach ($pair in @(@{ i = $Context.SourcePrimary; ag = $Context.SourceAgName; side = 'source' },
                        @{ i = $Context.TargetPrimary; ag = $Context.TargetAgName; side = 'target' })) {
        foreach ($r in @(Get-DagReplicaHealth -Instance $pair.i -AgName $pair.ag)) {
            if ($r.Role -eq 'PRIMARY') { continue }
            if ($r.ConnectedState -eq 'DISCONNECTED') {
                $warnings.Add("Replica '$($r.ReplicaServerName)' of the $($pair.side) AG '$($pair.ag)' is DISCONNECTED.")
            } elseif ($r.SyncHealth -eq 'NOT_HEALTHY') {
                $warnings.Add("Replica '$($r.ReplicaServerName)' of the $($pair.side) AG '$($pair.ag)' reports NOT_HEALTHY.")
            }
        }
    }
    #endregion

    #region Cross-version notes
    if ($Context.IsUpgradeDirection) {
        $warnings.Add("Cross-version failover to $(Get-DagSqlVersionName $Context.TargetMajorVersion): the databases will be upgraded and this distributed availability group cannot be failed back.")
        foreach ($sec in $Context.TargetSecondaries) {
            $warnings.Add("Forwarder secondary '$sec' holds no copy of the databases yet. It seeds from the new primary after failover; that is expected, not a fault.")
        }
    }
    #endregion

    [pscustomobject]@{
        IsGo      = ($blockers.Count -eq 0)
        Blockers  = @($blockers)
        Warnings  = @($warnings)
        Databases = $dbs
    }
}

function Show-DagReadiness {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Readiness
    )

    Write-Host ''
    Write-Host "Distributed availability group [$($Context.DagName)]:" -ForegroundColor White
    @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName) |
        Format-Table MemberAg, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    # Right-alignment in the -f operator is a bare positive width ({3,10}). '{3,>10}' is not
    # a format specifier — it throws "Expected an ASCII digit" and takes the rollup with it.
    Write-Host 'Database synchronization and LSN match:' -ForegroundColor White
    Write-Host ("  {0,-28} {1,-16} {2,-7} {3,10} {4,10}  {5}" -f 'DATABASE','SYNC STATE','LSN','SEND Q KB','REDO Q KB','HARDENED LSN (forwarder / primary)') -ForegroundColor DarkGray
    foreach ($d in $Readiness.Databases) {
        $lsnTag = if ($d.LsnMatch) { 'OK' } else { 'BEHIND' }
        $colour = if ($d.LsnMatch -and $d.SyncState -eq 'SYNCHRONIZED' -and -not $d.IsSuspended) { 'Green' } else { 'Red' }
        $state  = if ($d.IsSuspended) { 'SUSPENDED' } else { $d.SyncState }
        Write-Host ("  {0,-28} {1,-16} {2,-7} {3,10} {4,10}  {5} / {6}" -f `
            $d.DatabaseName, $state, $lsnTag, $d.LogSendQueueKb, $d.RedoQueueKb, $d.DagHardenedLsn, $d.SourceHardenedLsn) -ForegroundColor $colour
    }
    Write-Host ''

    if ($Readiness.Warnings.Count -gt 0) {
        Write-Host 'Warnings:' -ForegroundColor Yellow
        $Readiness.Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host ''
    }

    if ($Readiness.Blockers.Count -gt 0) {
        Write-Host 'Blockers:' -ForegroundColor Red
        $Readiness.Blockers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        Write-Host ''
    }

    Write-DagBanner $(if ($Readiness.IsGo) { 'RECOMMENDATION: GO' } else { 'RECOMMENDATION: NO-GO' })

    if ($Readiness.IsGo) {
        Write-Host ''
        Write-Host '  Every database is SYNCHRONIZED and the forwarder has hardened every log record the' -ForegroundColor Green
        Write-Host '  primary has. Failing over now loses nothing.' -ForegroundColor Green
        Write-Host ''
        Write-Host ("  {0} will stop accepting writes and {1} will take over." -f $Context.SourceAgName, $Context.TargetAgName) -ForegroundColor DarkGray
        Write-Host ''
    } else {
        Write-Host ''
        Write-Host '  Do not fail over. The forwarder does not have all of the data.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  FORCE_FAILOVER_ALLOW_DATA_LOSS is the only failover a distributed availability group' -ForegroundColor Red
        Write-Host '  accepts, and in this state it would do exactly what it says. Clear the blockers above' -ForegroundColor Red
        Write-Host '  and run this script again.' -ForegroundColor Red
        Write-Host ''
    }
}

function Invoke-DagReadiness {
    param([Parameter(Mandatory)][psobject]$Context)

    Write-DagBanner 'STEP 4 of 6 — READINESS'

    $readiness = Get-DagFailoverReadiness -Context $Context
    Show-DagReadiness -Context $Context -Readiness $readiness
    return $readiness
}
