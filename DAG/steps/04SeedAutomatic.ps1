#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 05a: automatic seeding.

.DESCRIPTION
    With the distributed AG created SEEDING_MODE = AUTOMATIC and the forwarder holding
    GRANT CREATE ANY DATABASE, SQL Server streams each database across the endpoints on
    its own. This step watches, reports progress, and decides when the seed is finished.

    Two behaviours of the seeding DMV are handled explicitly.

    First, sys.dm_hadr_automatic_seeding is an append-only history, and a distributed-AG
    seed routinely records transient FAILED attempts (for example "Transport Replica")
    immediately before the attempt that succeeds. Treating any FAILED row as fatal would
    abort a seed that is about to work. A database is therefore only considered failed
    when it has a non-benign failure AND no successful attempt at all.

    Second, on the primary replica of the forwarder AG the DMV can report FAILED with
    "Seeding Check Message Timeout" even though seeding succeeded, which is why arrival
    on the target — not the DMV — is the signal this step actually waits on.
#>

Set-StrictMode -Version Latest

# Documented false alarm: reported on the forwarder primary even when seeding worked.
$script:DagBenignSeedingFailures = @('Seeding Check Message Timeout')

function Test-DagDatabaseArrivedOnForwarder {
    <#
    .SYNOPSIS
        Has the database arrived and started moving data on the given forwarder replica?
    .DESCRIPTION
        In a cross-version DAG the database sits in RECOVERING on the forwarder and is not
        readable, so database_state is useless as a completion signal. The synchronization
        state is what tells us the log stream is flowing.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'forwarder arrival check' -Query @"
SELECT drs.synchronization_state_desc AS SyncState
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)
  AND DB_NAME(drs.database_id) = $(ConvertTo-DagQuotedString $DatabaseName)
  AND drs.is_local = 1
"@
    return ($rows.Count -gt 0 -and $rows[0].SyncState -in @('SYNCHRONIZED','SYNCHRONIZING'))
}

function Get-DagSeedingFailure {
    <#
    .SYNOPSIS
        A genuine, unrecovered seeding failure for one database, or $null.

    .DESCRIPTION
        Read from the global primary, scoped to seeding operations of the global primary AG
        whose remote peer is the forwarder AG — that is the distributed-AG seed. A failure
        only counts when the same database has no COMPLETED attempt against that peer.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $rows = @(Get-DagSeedingProgress -Instance $Plan.GlobalPrimaryReplica -AgName $Plan.GlobalAgName |
                Where-Object { $_.DatabaseName -eq $DatabaseName -and $_.RemoteReplica -eq $Plan.ForwarderAgName })

    if ($rows.Count -eq 0) { return $null }
    if (@($rows | Where-Object { $_.CurrentState -eq 'COMPLETED' }).Count -gt 0) { return $null }

    $failed = @($rows | Where-Object {
        $_.CurrentState -eq 'FAILED' -and
        $_.FailureState -and
        $script:DagBenignSeedingFailures -notcontains $_.FailureState
    })
    if ($failed.Count -eq 0) { return $null }
    return $failed[0]
}

function Show-DagSeedingProgressLine {
    param([Parameter(Mandatory)][psobject]$Plan)

    $stats = @(Get-DagPhysicalSeedingStats -Instance $Plan.GlobalPrimaryReplica)
    foreach ($s in $stats) {
        Write-DagLog ("  seeding [{0}] -> {1}: {2}% of {3} at {4}" -f $s.DatabaseName, $s.RemoteMachine, $s.Percent, $s.Total, $s.Rate) INFO
    }
}

function Invoke-DagSeedAutomatic {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [int]$TimeoutHours = 24
    )

    Write-DagBanner 'STEP 5 of 7 — AUTOMATIC SEEDING'

    Write-DagLog "SQL Server is seeding $($Plan.Databases.Count) database(s) across the distributed availability group." INFO
    Write-DagLog 'No further action is required; this step waits for the stream to finish.' INFO

    if ($Plan.IsCrossVersion) {
        Write-Host ''
        Write-DagLog 'Cross-version seed: databases land on the forwarder in a Recovering / Synchronizing state.' WARN
        Write-DagLog "That is expected and resolves when the distributed AG is failed over to $(Get-DagSqlVersionName $Plan.ForwarderMajorVersion)." WARN
    }

    $timeoutSeconds = $TimeoutHours * 3600
    $deferredSecondaries = New-Object System.Collections.Generic.List[string]

    foreach ($db in $Plan.Databases) {
        Write-Host ''
        Write-DagLog "Waiting for [$db] to seed to the forwarder..." STEP

        $arrived = Wait-DagCondition -Activity "[$db] seeding to $($Plan.ForwarderPrimaryReplica)" `
            -TimeoutSeconds $timeoutSeconds -PollSeconds 20 `
            -Condition {
                # Arrival is checked first: a database that has landed is done, whatever
                # transient failures the DMV recorded on the way there.
                if (Test-DagDatabaseArrivedOnForwarder -Instance $Plan.ForwarderPrimaryReplica -AgName $Plan.ForwarderAgName -DatabaseName $db) {
                    return $true
                }
                $fail = Get-DagSeedingFailure -Plan $Plan -DatabaseName $db
                if ($fail) {
                    throw "Automatic seeding of [$db] to '$($Plan.ForwarderAgName)' failed: $($fail.FailureState)"
                }
                return $false
            } `
            -ProgressMessage { Show-DagSeedingProgressLine -Plan $Plan; $null }

        if (-not $arrived) {
            throw @"
[$db] did not finish seeding to '$($Plan.ForwarderPrimaryReplica)' within $TimeoutHours hour(s).

Check on the global primary:
    SELECT * FROM sys.dm_hadr_automatic_seeding;
    SELECT * FROM sys.dm_hadr_physical_seeding_stats;

Re-running Initialize-DAG.ps1 is safe and will resume waiting.
"@
        }
        Write-DagLog "[$db] arrived on $($Plan.ForwarderPrimaryReplica)." SUCCESS

        #region Forwarder secondaries
        <#
            The forwarder primary reseeds to its own secondaries through the forwarder AG,
            but it can only do so while its copy of the database is ONLINE. In a
            cross-version distributed AG the forwarder's databases stay in RECOVERING until
            the DAG is failed over and the databases are upgraded, so seeding onward fails
            with "Async Task Failure" and the secondaries stay empty. That is the product
            behaving as designed, not a fault, and it resolves at failover.

            Choose manual seeding if the forwarder secondaries must hold the databases
            before failover: restoring backups onto them works regardless of version.
        #>
        $fpState  = Get-DagDatabaseState -Instance $Plan.ForwarderPrimaryReplica -DatabaseName $db
        $fwSeconds = @($Plan.ForwarderSecondaries)
        $onlineOnForwarder = ($fpState -and $fpState.StateDesc -eq 'ONLINE')

        if (-not $onlineOnForwarder -and $fwSeconds.Count -gt 0) {
            $state = if ($fpState) { $fpState.StateDesc } else { 'absent' }
            Write-DagLog "[$db] is $state on $($Plan.ForwarderPrimaryReplica); its secondaries cannot be seeded until the DAG is failed over." WARN
            foreach ($sec in $fwSeconds) { $deferredSecondaries.Add("$db -> $sec") }
        } else {
            foreach ($sec in $fwSeconds) {
                $ok = Wait-DagCondition -Activity "[$db] seeding to $sec" -TimeoutSeconds $timeoutSeconds -PollSeconds 20 `
                    -Condition { Test-DagDatabaseArrivedOnForwarder -Instance $sec -AgName $Plan.ForwarderAgName -DatabaseName $db }
                if (-not $ok) {
                    throw "[$db] did not finish seeding to forwarder secondary '$sec' within $TimeoutHours hour(s)."
                }
                Write-DagLog "[$db] arrived on $sec." SUCCESS
            }
        }
        #endregion

        $rec = Get-DagProgress -Plan $Plan -DatabaseName $db
        $rec.JoinedOn  = @($Plan.ForwarderPrimaryReplica)
        $rec.Completed = $true
        Set-DagProgress -Plan $Plan -Record $rec
    }

    Write-Host ''
    Write-DagLog 'Automatic seeding complete for every selected database.' SUCCESS

    if ($deferredSecondaries.Count -gt 0) {
        Write-Host ''
        Write-DagLog 'The following forwarder secondary copies are deferred until the distributed AG is failed over:' WARN
        $deferredSecondaries | ForEach-Object { Write-DagLog "  - $_" WARN }
        Write-DagLog 'The forwarder primary cannot seed a database it cannot bring online. After failover the' INFO
        Write-DagLog 'databases are upgraded, come online, and seed to the secondaries automatically.' INFO
        Write-DagLog 'If the secondaries must be populated beforehand, re-run with MANUAL seeding instead.' INFO
    }
}
