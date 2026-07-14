#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 3: put the distributed AG into synchronous commit and wait for it
    to actually get there.

.DESCRIPTION
    This is the step that turns a forced failover into a lossless one. Under asynchronous
    commit the global primary acknowledges a commit without waiting for the forwarder, so
    there is always a tail of hardened-here-but-not-there log. Synchronous commit closes
    that gap and keeps it closed, which is the only state in which
    FORCE_FAILOVER_ALLOW_DATA_LOSS loses nothing.

    It is not free: while it is in effect, every commit on the global primary waits for the
    forwarder to harden the record, across whatever link separates the two clusters. That is
    a real latency cost on a production workload, it starts the moment this step runs, and
    it lasts until Step 6 puts the DAG back to asynchronous commit. The operator is told
    this and asked, rather than having it done to them.
#>

Set-StrictMode -Version Latest

function Invoke-DagSynchronize {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$TimeoutSeconds = 900,
        [switch]$NonInteractive
    )

    Write-DagBanner 'STEP 3 of 6 — SYNCHRONOUS COMMIT'

    $state = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
    $already = @($state | Where-Object { $_.AvailabilityMode -ne 'SYNCHRONOUS_COMMIT' }).Count -eq 0

    if ($already) {
        Write-DagLog "[$($Context.DagName)] is already SYNCHRONOUS_COMMIT on both member availability groups." SUCCESS
    } else {
        Write-Host ''
        Write-Host 'Switching the distributed availability group to synchronous commit.' -ForegroundColor White
        Write-Host ''
        Write-Host ("  From now until this script finishes, every commit on {0} waits for" -f $Context.SourcePrimary) -ForegroundColor DarkGray
        Write-Host ("  {0} to harden it. On a busy database that is a measurable increase in" -f $Context.TargetPrimary) -ForegroundColor DarkGray
        Write-Host '  commit latency. Step 6 puts it back to asynchronous commit.' -ForegroundColor DarkGray
        Write-Host ''

        if (-not $NonInteractive) {
            if (-not (Read-DagYesNo -Question 'Switch to synchronous commit now?' -DefaultYes $true)) {
                throw 'Declined at the synchronous commit step. Nothing has been changed.'
            }
        }

        Set-DagDistributedAgMode -Context $Context -Mode 'SYNCHRONOUS_COMMIT'
    }

    #region Confirm it took on BOTH sides
    # MODIFY is executed on each side separately, and a half-applied mode is the classic
    # cause of a DAG that never reaches SYNCHRONIZED for reasons nobody can see.
    if (-not (Test-DagModeApplied -Context $Context -Mode 'SYNCHRONOUS_COMMIT')) {
        throw @"
The distributed availability group did not report SYNCHRONOUS_COMMIT on both sides after
being set.

ALTER AVAILABILITY GROUP ... MODIFY AVAILABILITY GROUP ON must be applied on the primary
replica of BOTH member availability groups, and a mode that is set on only one side leaves
the DAG unable to reach SYNCHRONIZED with no visible reason why.

Check '$($Context.SourcePrimary)' and '$($Context.TargetPrimary)'.
"@
    }
    Write-DagLog 'Both member availability groups confirm SYNCHRONOUS_COMMIT.' SUCCESS
    #endregion

    #region Wait for the forwarder to catch up
    Write-DagLog 'Waiting for every database to reach SYNCHRONIZED with a matching hardened LSN...' INFO
    if (-not (Wait-DagSynchronized -Context $Context -TimeoutSeconds $TimeoutSeconds)) {
        Write-DagLog "The distributed availability group did not fully synchronize within $TimeoutSeconds seconds." WARN
        Write-DagLog 'Step 4 will show exactly which databases are behind and by how much.' INFO
        return $false
    }
    Write-DagLog 'Every database is SYNCHRONIZED and the forwarder has hardened everything the primary has.' SUCCESS
    return $true
    #endregion
}
