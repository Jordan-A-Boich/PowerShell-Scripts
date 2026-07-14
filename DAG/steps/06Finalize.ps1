#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 06: settle the distributed AG into asynchronous commit.

.DESCRIPTION
    Asynchronous commit is the right steady state for a distributed availability group:
    it decouples commit latency on the global primary from the link to the forwarder.
    Synchronous commit is something you switch on deliberately, immediately before a
    planned failover, so that the forwarder can catch up with no data loss.

    The distributed AG is created asynchronous, so on a clean run this step is a
    confirmation rather than a change. It exists because a re-run, a hand-edited DAG,
    or a half-finished earlier attempt can leave the two sides disagreeing.
#>

Set-StrictMode -Version Latest

function Invoke-DagFinalize {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-DagBanner 'STEP 6 of 7 — FINALIZE'

    $state = @(Get-DagDistributedAgState -Instance $Plan.GlobalPrimaryReplica -DagName $Plan.DagName)
    $needsChange = @($state | Where-Object { $_.AvailabilityMode -ne 'ASYNCHRONOUS_COMMIT' })

    if ($needsChange.Count -eq 0) {
        Write-DagLog 'Distributed availability group is already ASYNCHRONOUS_COMMIT on both member AGs.' SUCCESS
    } else {
        Write-DagLog 'Setting the distributed availability group to ASYNCHRONOUS_COMMIT on both sides...' INFO
        Set-DagMemberOptions -Plan $Plan -AvailabilityMode 'ASYNCHRONOUS_COMMIT'
    }

    # Re-read from both sides: MODIFY has to be applied on each, and a partial application
    # is exactly the kind of thing that silently bites later.
    foreach ($i in @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica)) {
        $s = @(Get-DagDistributedAgState -Instance $i -DagName $Plan.DagName)
        foreach ($m in $s) {
            if ($m.AvailabilityMode -ne 'ASYNCHRONOUS_COMMIT') {
                throw "On '$i', member AG '$($m.MemberAg)' still reports AVAILABILITY_MODE = $($m.AvailabilityMode)."
            }
        }
        Write-DagLog "  [$i] both member AGs confirmed ASYNCHRONOUS_COMMIT." SUCCESS
    }

    Write-DagLog 'Distributed availability group finalized.' SUCCESS
}
