#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 2: the conditions under which a failover must not even be attempted.

.DESCRIPTION
    Separate from the readiness rollup in Step 4 on purpose. Preflight is about things that
    can never become true by waiting — a missing permission, an unreachable replica, a
    forwarder running an OLDER version of SQL Server. Readiness is about things that are
    expected to become true once synchronous commit has had a moment to work.
#>

Set-StrictMode -Version Latest

function Invoke-DagFailoverPreflight {
    param([Parameter(Mandatory)][psobject]$Context)

    Write-DagBanner 'STEP 2 of 6 — PREFLIGHT'

    $fatal = New-Object System.Collections.Generic.List[string]

    #region Reachability and permission on both primaries
    foreach ($pair in @(@{ i = $Context.SourcePrimary; label = 'source' },
                        @{ i = $Context.TargetPrimary; label = 'target' })) {
        if (-not (Test-DagConnection -Instance $pair.i)) {
            $fatal.Add("Cannot connect to the $($pair.label) primary replica '$($pair.i)'.")
            continue
        }
        $info = Get-DagInstanceInfo -Instance $pair.i
        if (-not $info.IsSysadmin) {
            $fatal.Add("The account used is not a sysadmin on '$($pair.i)'. Failing a distributed availability group over requires it.")
        }
        if (-not $info.IsHadrEnabled) {
            $fatal.Add("AlwaysOn availability groups are not enabled on '$($pair.i)'.")
        }
        Write-DagLog "  [$($pair.i)] reachable, sysadmin, HADR enabled ($($info.ProductVersion))" SUCCESS
    }
    #endregion

    #region The distributed AG must exist on both sides
    foreach ($i in @($Context.SourcePrimary, $Context.TargetPrimary)) {
        if (-not (Test-DagConnection -Instance $i)) { continue }
        if (-not (Test-DagIsDistributed -Instance $i -DagName $Context.DagName)) {
            $fatal.Add("Distributed availability group '$($Context.DagName)' does not exist on '$i'.")
        }
    }
    #endregion

    #region Version direction — the one that can never be waited out
    <#
        A distributed AG can carry databases UP a version (the migration case) but never
        DOWN. Failing over to an older major version would hand the forwarder databases it
        cannot open and log records it cannot redo. SQL Server will not stop you setting
        this up, and the damage is discovered after the primary role has already moved.

        Not applied when resuming a failover that was interrupted before it completed. There,
        no database has been upgraded — the upgrade happens as they come ONLINE on a new
        primary, and no primary exists — so each side's databases are still at its own
        version and promoting either one is safe. Applying the rule here would refuse to let
        the operator put the primary role BACK where it came from, which is the one thing
        they are most likely to want.
    #>
    if ($Context.IsDowngrade -and -not $Context.IsResume) {
        $fatal.Add(@"
The forwarder runs an OLDER version of SQL Server than the global primary.

    $($Context.SourceAgName) : $(Get-DagSqlVersionName $Context.SourceMajorVersion)  (primary now)
    $($Context.TargetAgName) : $(Get-DagSqlVersionName $Context.TargetMajorVersion)  (forwarder)

A database cannot be moved to an older version of SQL Server. Failing over would give
'$($Context.TargetPrimary)' databases it cannot open. This is not something a wait or a
re-run can fix, and it is refused.

If you have already failed this distributed availability group over once, this is what a
second run looks like: the failover you are asking for is the one that has already happened,
in reverse. There is no way back.
"@)
    }
    #endregion

    #region Databases
    if ($Context.Databases.Count -eq 0) {
        $fatal.Add("Member availability group '$($Context.SourceAgName)' contains no databases. There is nothing to fail over.")
    }
    #endregion

    #region Connected state of the two members
    <#
        A DAG with no primary has no link, because there is no primary for the peer to
        connect TO: both members report themselves DISCONNECTED. That is a consequence of the
        interrupted failover, not a cause of it, and it resolves the moment a member takes the
        primary role.

        So this check is skipped entirely on a resume. Requiring CONNECTED there would refuse
        to recover from the one state that most needs recovering — the databases are offline
        on both sides — and it would refuse forever, because the link cannot come back until
        the failover this check is blocking has completed. A deadlock dressed up as a safety
        check.

        The forced failover does not need the peer anyway. That is what makes it forced.
    #>
    if ($Context.IsResume) {
        Write-DagLog '  Skipping the connected-state check: a distributed AG with no primary has no link, by definition.' INFO
    } else {
        $state = @(Get-DagDistributedAgState -Instance $Context.SourcePrimary -DagName $Context.DagName)
        foreach ($m in $state) {
            if ($m.ConnectedState -ne 'CONNECTED') {
                $fatal.Add("Member availability group '$($m.MemberAg)' is $($m.ConnectedState), not CONNECTED. The two clusters cannot see each other, so the forwarder cannot be brought up to date.")
            }
        }
    }
    #endregion

    if ($fatal.Count -gt 0) {
        Write-Host ''
        throw ("Preflight failed:`r`n`r`n" + (($fatal | ForEach-Object { "  * $_" }) -join "`r`n`r`n"))
    }

    Write-DagLog 'Preflight passed.' SUCCESS

    #region The one-way warning — not fatal, but the operator must say it out loud
    if ($Context.IsUpgradeDirection) {
        Write-Host ''
        Write-DagBanner 'THIS FAILOVER CANNOT BE UNDONE'
        Write-Host ''
        Write-Host ("  {0} runs {1}." -f $Context.SourceAgName, (Get-DagSqlVersionName $Context.SourceMajorVersion)) -ForegroundColor Yellow
        Write-Host ("  {0} runs {1}." -f $Context.TargetAgName, (Get-DagSqlVersionName $Context.TargetMajorVersion)) -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Failing over will bring the databases online on the higher version, which UPGRADES' -ForegroundColor Yellow
        Write-Host '  their physical files. From that moment the older side can no longer apply their log,' -ForegroundColor Yellow
        Write-Host '  and this distributed availability group cannot be failed back. The old primary becomes' -ForegroundColor Yellow
        Write-Host '  a dead end that you decommission, not a standby you can return to.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Make sure you have a backup you are willing to go back to.' -ForegroundColor Yellow
        Write-Host ''
    }
    #endregion
}
