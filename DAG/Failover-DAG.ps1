#Requires -Version 5.1
<#
.SYNOPSIS
    Failover-DAG — planned, lossless failover of a SQL Server distributed availability group.

.DESCRIPTION
    Prompt-driven, like Initialize-DAG.ps1. Answer a short interview, read the readiness
    rollup, and decide.

    What it does, in order:
      1. Works out which distributed AG to fail over and, from the servers, which member
         availability group currently holds the primary role.
      2. Refuses the failovers that must never be attempted — most importantly a forwarder
         on an OLDER version of SQL Server.
      3. Switches the distributed AG to synchronous commit and waits for the forwarder to
         harden everything the primary has.
      4. Prints a synchronization and LSN rollup, and gives a GO or NO-GO.
      5. On GO and on your confirmation: demotes the global primary, fails the DAG over, and
         confirms the role actually moved.
      6. Returns the DAG to asynchronous commit and prints a health rollup of the new shape.

    Why the failover is safe even though the only statement available is called
    FORCE_FAILOVER_ALLOW_DATA_LOSS:

        A distributed availability group has no planned-failover command. The forced one is
        all there is, and whether it loses data is a property of the state you run it in,
        not of the statement. Run it against a synchronized DAG whose primary has already
        been demoted and is accepting no writes, and there is nothing left to lose. Steps 3
        to 5 exist to guarantee exactly that state, and to stop if they cannot.

    Safe to re-run. Every step re-reads live server state first. In particular, a run
    interrupted between the demotion and the failover leaves the DAG with no primary at all;
    re-running detects that and finishes the job rather than starting over.

.PARAMETER Credential
    A SQL Server login to use for every replica connection. When omitted you are asked how
    to authenticate.

.PARAMETER SyncTimeoutMinutes
    How long to wait for the distributed AG to reach SYNCHRONIZED after switching to
    synchronous commit. Default 15.

.PARAMETER ReadinessOnly
    Do everything up to and including the readiness rollup, then stop. Changes nothing
    except the availability mode, which is set back to asynchronous commit before exiting.
    This is the dry run.

.PARAMETER Force
    Fail over even when the readiness check says NO-GO. THIS WILL LOSE DATA — it is the
    only path in this script that can. It exists for the case where the source is gone and
    losing the tail of the log is better than losing the service.

.EXAMPLE
    .\Failover-DAG.ps1

.EXAMPLE
    .\Failover-DAG.ps1 -ReadinessOnly

.EXAMPLE
    .\Failover-DAG.ps1 -Credential (Get-Credential labadmin)
#>

[CmdletBinding()]
param(
    [pscredential]$Credential,

    [ValidateRange(1, 720)]
    [int]$SyncTimeoutMinutes = 15,

    [switch]$ReadinessOnly,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot   = $PSScriptRoot
$SharedDir    = Join-Path $ScriptRoot 'steps\_shared'
$FailoverDir  = Join-Path $ScriptRoot 'steps\failover'
$StateDir     = Join-Path $ScriptRoot 'state'

#region ── Load modules and step files ───────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw @'
The SqlServer PowerShell module is required and was not found.

    Install-Module -Name SqlServer -Scope CurrentUser
'@
}
Import-Module SqlServer -DisableNameChecking -ErrorAction Stop

foreach ($file in @(
        'DagCommon.ps1'
        'DagSql.ps1'
        'DagPrompt.ps1'
        'DagDiscovery.ps1'
        'DagHealth.ps1'
        'DagFailover.ps1'
    )) {
    . (Join-Path $SharedDir $file)
}

foreach ($file in @(
        '01Context.ps1'
        '02Preflight.ps1'
        '03Synchronize.ps1'
        '04Readiness.ps1'
        '05Failover.ps1'
        '06Settle.ps1'
    )) {
    . (Join-Path $FailoverDir $file)
}

#endregion

#region ── Entry ─────────────────────────────────────────────────────────────

$revertToAsync = $null   # set once synchronous commit has been applied

try {
    Initialize-DagLog -LogDirectory (Join-Path $ScriptRoot 'logs') -NamePrefix 'Failover-DAG' | Out-Null

    Write-DagBanner 'FAIL OVER A DISTRIBUTED AVAILABILITY GROUP'
    Write-Host 'Moves the primary role of a distributed availability group to its forwarder.' -ForegroundColor DarkGray
    Write-Host 'Nothing is changed until you are shown a readiness rollup and confirm.' -ForegroundColor DarkGray

    if ($Credential) {
        Set-DagConnectionContext -Credential $Credential
        Write-DagLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-DagCredential
    }

    if ($Force) {
        Write-Host ''
        Write-DagLog '-Force was supplied. A NO-GO readiness result will NOT stop the failover.' WARN
        Write-DagLog 'This can lose committed transactions. It is only correct when the source is gone.' WARN
    }

    #region Steps 1-2: what are we failing over, and may we?
    $ctx = Invoke-DagFailoverContext -StateDirectory $StateDir
    Invoke-DagFailoverPreflight -Context $ctx

    $started = Get-Date

    #region Resume: an interrupted failover has no primary, so Steps 3 and 4 are moot
    <#
        With no primary there is nothing accepting writes, so there is nothing to synchronize
        and nothing for a readiness rollup to measure. The databases are offline on both sides
        and the only useful thing this script can do is finish what it started. It goes
        straight to Step 5.
    #>
    if ($ctx.IsResume) {
        if ($ReadinessOnly) {
            Write-Host ''
            Write-DagLog '-ReadinessOnly: this distributed availability group has no primary and its databases' WARN
            Write-DagLog 'are offline on both sides. There is nothing to assess — it needs to be finished.' WARN
            Write-DagLog "Re-run without -ReadinessOnly to promote [$($ctx.TargetAgName)]." INFO
            exit 1
        }

        Write-Host ''
        $prompt = "Promote [$($ctx.TargetAgName)] to PRIMARY and bring the databases back online?"
        if (-not (Read-DagYesNo -Question $prompt -DefaultYes $true)) {
            Write-DagLog 'Declined. The distributed availability group still has no primary and its databases' WARN
            Write-DagLog 'remain offline on both sides. Re-run when you are ready to finish.' WARN
            return
        }

        Invoke-DagFailover -Context $ctx -Force:$Force | Out-Null
        #endregion
    }
    else {
        # A dry run is never asked to confirm a failover it is not going to perform. It still
        # confirms the switch to synchronous commit in Step 3, because that one is a real
        # change to a production system whether or not a failover follows it.
        if ($ReadinessOnly) {
            Write-Host ''
            Write-DagLog '-ReadinessOnly: this is a dry run. Nothing will be failed over.' INFO
        } elseif (-not (Read-DagYesNo -Question "Fail [$($ctx.DagName)] over from [$($ctx.SourceAgName)] to [$($ctx.TargetAgName)]?" -DefaultYes $false)) {
            Write-DagLog 'Aborted by operator. Nothing has been changed.' WARN
            return
        }

        #region Step 3: synchronous commit
        Invoke-DagSynchronize -Context $ctx -TimeoutSeconds ($SyncTimeoutMinutes * 60) | Out-Null
        $revertToAsync = $ctx
        #endregion

        #region Step 4: readiness and the recommendation
        $readiness = Invoke-DagReadiness -Context $ctx

        if ($ReadinessOnly) {
            Write-Host ''
            Write-DagLog '-ReadinessOnly: stopping here. Returning the DAG to asynchronous commit...' INFO
            Set-DagDistributedAgMode -Context $ctx -Mode 'ASYNCHRONOUS_COMMIT'
            $revertToAsync = $null
            Write-DagLog 'Nothing was failed over. The distributed availability group is as you found it.' SUCCESS
            exit $(if ($readiness.IsGo) { 0 } else { 1 })
        }

        if (-not $readiness.IsGo -and -not $Force) {
            Write-DagLog 'Returning the DAG to asynchronous commit...' INFO
            Set-DagDistributedAgMode -Context $ctx -Mode 'ASYNCHRONOUS_COMMIT'
            $revertToAsync = $null
            Write-Host ''
            Write-DagLog 'NO-GO. Nothing was failed over.' ERROR
            Write-DagLog 'Clear the blockers above and run this script again.' INFO
            exit 1
        }
        #endregion

        #region Step 5: the point of no return
        Write-Host ''
        if (-not $readiness.IsGo) {
            Write-DagBanner 'PROCEEDING AGAINST A NO-GO — DATA WILL BE LOST'
            $typed = Read-DagText -Prompt "Type the word LOSE to fail over anyway and accept losing the transactions listed above"
            if ($typed -cne 'LOSE') {
                Write-DagLog 'Not confirmed. Returning the DAG to asynchronous commit...' WARN
                Set-DagDistributedAgMode -Context $ctx -Mode 'ASYNCHRONOUS_COMMIT'
                $revertToAsync = $null
                Write-DagLog 'Nothing was failed over.' SUCCESS
                return
            }
        } else {
            $prompt = "Proceed with the failover? [$($ctx.SourceAgName)] stops accepting writes and [$($ctx.TargetAgName)] takes over."
            if (-not (Read-DagYesNo -Question $prompt -DefaultYes $false)) {
                Write-DagLog 'Declined. Returning the DAG to asynchronous commit...' WARN
                Set-DagDistributedAgMode -Context $ctx -Mode 'ASYNCHRONOUS_COMMIT'
                $revertToAsync = $null
                Write-DagLog 'Nothing was failed over.' SUCCESS
                return
            }
        }

        Invoke-DagFailover -Context $ctx -Force:$Force | Out-Null
        $revertToAsync = $null   # Step 6 owns the mode from here; the roles have swapped
        #endregion
    }

    #region Step 6: settle
    $settled = Invoke-DagSettle -Context $ctx

    Write-DagBanner ('DONE in {0}' -f (Format-DagDuration ((Get-Date) - $started)))
    Write-Host ''
    Write-Host ("  [{0}] now holds the PRIMARY role." -f $settled.Context.SourceAgName) -ForegroundColor Green
    Write-Host ("  Write to it through the listener of '{0}' ({1})." -f $settled.Context.SourceAgName, $settled.Context.SourcePrimary) -ForegroundColor Green
    Write-Host ''

    if (-not $settled.Healthy) {
        Write-DagLog 'The failover completed, but the health rollup reported problems (see above).' WARN
        exit 1
    }
    Write-DagLog "Distributed availability group [$($ctx.DagName)] failed over successfully." SUCCESS
    #endregion
}
catch {
    Write-Host ''
    Write-DagLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-DagLog $_.ScriptStackTrace DEBUG }
    Write-Host ''

    # Synchronous commit was applied and the failover did not happen. Leaving it on would
    # quietly tax every commit on the primary for as long as nobody notices.
    if ($revertToAsync) {
        try {
            Write-DagLog 'Returning the distributed availability group to ASYNCHRONOUS_COMMIT...' INFO
            Set-DagDistributedAgMode -Context $revertToAsync -Mode 'ASYNCHRONOUS_COMMIT'
            Write-DagLog 'Done — the distributed availability group is as you found it.' SUCCESS
        } catch {
            Write-DagLog "Could not restore ASYNCHRONOUS_COMMIT: $($_.Exception.Message.Split("`n")[0])" ERROR
            Write-DagLog 'The distributed availability group is still in SYNCHRONOUS_COMMIT. Every commit on the' WARN
            Write-DagLog 'global primary is waiting for the forwarder. Set it back by hand:' WARN
            Write-DagLog "    ALTER AVAILABILITY GROUP [$($revertToAsync.DagName)] MODIFY AVAILABILITY GROUP ON" WARN
            Write-DagLog "        '$($revertToAsync.SourceAgName)' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT)," WARN
            Write-DagLog "        '$($revertToAsync.TargetAgName)' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);" WARN
        }
    }

    Write-Host ''
    Write-DagLog 'Failover-DAG.ps1 is safe to re-run: it re-reads live state and resumes.' INFO
    exit 1
}

#endregion
