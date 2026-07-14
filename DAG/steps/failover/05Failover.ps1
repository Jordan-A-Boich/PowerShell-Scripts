#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 5: move the primary role to the forwarder.

.DESCRIPTION
    Three statements, in an order that is not negotiable:

      1. ALTER AVAILABILITY GROUP <dag> SET (ROLE = SECONDARY)              on the SOURCE primary
      2. ALTER AVAILABILITY GROUP <dag> FORCE_FAILOVER_ALLOW_DATA_LOSS      on the TARGET primary
      3. (Step 6) back to asynchronous commit

    Both statements name the DISTRIBUTED group. Which side each one acts on is decided by
    which replica it runs against, not by what it names — naming the member AG in statement 1
    fails with Msg 19512.

    Statement 1 is what makes statement 2 safe. Demoting the source stops it accepting
    writes, so the log it has hardened is final — and because Step 4 proved the forwarder
    has hardened all of it, the forced failover has nothing left to lose. Skip statement 1
    and the source can still be committing transactions at the moment the role moves, and
    those transactions are gone.

    Between statements 1 and 2 the distributed availability group has NO primary at all and
    the databases are offline on both sides. That window is short, but if the script dies
    inside it the DAG stays there until somebody finishes the job. Get-DagFailoverStage
    recognises that state, and re-running resumes from it rather than starting over.
#>

Set-StrictMode -Version Latest

function Invoke-DagFailover {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [int]$TimeoutSeconds = 600,
        [switch]$Force
    )

    Write-DagBanner 'STEP 5 of 6 — FAILOVER'

    $stage = Get-DagFailoverStage -Context $Context
    Write-DagLog "Current stage: $stage" INFO

    if ($stage -eq 'Complete') {
        Write-DagLog "[$($Context.TargetAgName)] already holds the PRIMARY role — the failover has already happened." SUCCESS
        return $true
    }
    if ($stage -eq 'Split') {
        throw @"
Both member availability groups claim the PRIMARY role of [$($Context.DagName)].

This is a split state. Failing over again cannot fix it and may make it worse. Decide which
side is authoritative, demote the other with:

    ALTER AVAILABILITY GROUP [<the losing member AG>] SET (ROLE = SECONDARY);

then run this script again.
"@
    }

    if ($stage -eq 'Demoted') {
        Write-Host ''
        Write-DagLog "[$($Context.SourceAgName)] has already been demoted, but no member holds the primary role." WARN
        Write-DagLog 'A previous run stopped between the demotion and the failover. The databases are offline' WARN
        Write-DagLog 'on both sides until the failover completes. Resuming it now.' WARN
        Write-Host ''
    }

    #region Final gate — re-read everything immediately before the point of no return
    <#
        Step 4's rollup was true when it was printed. The operator has been reading it and
        thinking, and a busy database does not stop while they do. Nothing here is trusted
        from a moment ago.

        Skipped when resuming from 'Demoted': the source is already refusing writes, so its
        log cannot advance, and the DAG legitimately reports no primary — which the
        readiness check would (correctly, but uselessly) treat as a blocker.
    #>
    if ($stage -eq 'NotStarted') {
        Write-DagLog 'Re-checking synchronization immediately before the failover...' INFO
        $readiness = Get-DagFailoverReadiness -Context $Context

        if (-not $readiness.IsGo) {
            if (-not $Force) {
                Write-Host ''
                $readiness.Blockers | ForEach-Object { Write-DagLog "  - $_" ERROR }
                throw @"

The distributed availability group is no longer ready to fail over.

Something changed between the readiness rollup and now. Nothing has been altered — the
source availability group still holds the primary role and is still accepting writes.

Run the script again to re-assess.
"@
            }
            Write-DagLog 'Readiness re-check failed, but -Force was supplied. Proceeding — THIS WILL LOSE DATA.' WARN
        } else {
            Write-DagLog 'Confirmed: still SYNCHRONIZED, LSNs still match.' SUCCESS
        }
    }
    #endregion

    #region 1. Demote the source
    Set-DagAgRoleSecondary -Context $Context
    #endregion

    #region 2. Force the failover
    Invoke-DagForceFailover -Context $Context
    #endregion

    #region 3. Confirm the role actually moved
    $ok = Wait-DagCondition -Activity "[$($Context.TargetAgName)] taking the PRIMARY role" `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds 5 `
        -Condition { Test-DagFailoverComplete -Context $Context } `
        -ProgressMessage {
            $s = @(Get-DagDistributedAgState -Instance $Context.TargetPrimary -DagName $Context.DagName)
            ($s | ForEach-Object { "$($_.MemberAg)=$($_.Role)" }) -join ' '
        }

    if (-not $ok) {
        throw @"
The failover statement was accepted on '$($Context.TargetPrimary)' but [$($Context.TargetAgName)]
has not taken the PRIMARY role within $TimeoutSeconds seconds.

The distributed availability group currently has no primary and the databases are offline on
both sides. Do not run anything else against it yet — read the SQL Server error log on
'$($Context.TargetPrimary)' first.

Re-running this script is safe: it will detect that the source is already demoted and resume
from the failover.
"@
    }
    #endregion

    Write-DagLog "[$($Context.TargetAgName)] now holds the PRIMARY role of [$($Context.DagName)]." SUCCESS
    return $true
}
