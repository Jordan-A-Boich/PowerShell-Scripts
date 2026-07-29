#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 05a: automatic seeding, concurrency-governed and self-healing.

.DESCRIPTION
    A database begins seeding across the distributed AG the moment it becomes a member of
    the global primary AG — that membership is the only per-database lever SQL Server gives
    for automatic seeding (SUSPEND does not hold it back; the seed streams regardless).
    Streaming many databases across the cross-cluster endpoint at once provokes transient
    "Transport Replica" seeding failures and, intermittently, outright cancellation — the
    stalled databases then sit un-seeded until something restarts them.

    This step keeps at most MaxConcurrentSeeds databases streaming to the forwarder at a
    time and drives every database home. It faces two situations, and handles both in one
    concurrency-governed loop:

      * Databases NOT yet in the global primary AG (the tool is adding them) are ADMITTED
        through the window — added to the global primary AG only when a slot is free. This
        is proactive: the contention never happens, because the databases are never all
        eligible at once. The instant one lands on the forwarder, the next is admitted.

      * Databases ALREADY in the global primary AG when the distributed AG was created (the
        common field case: the global AG is live and seeded before the DAG is built) all
        start seeding the moment the DAG connects — there is no non-destructive way to hold
        them back. When the endpoint is saturated the surplus fail transiently and are
        cancelled. This step SELF-HEALS them: it watches how many are actively streaming,
        and whenever that drops below the cap while databases remain unlanded, it re-triggers
        seeding (a harmless re-issue of SEEDING_MODE = AUTOMATIC on both member AGs, which
        restarts the cancelled seeds without disturbing the ones in flight). It repeats until
        every database has reached the forwarder.

    Compression of the seeding stream (trace flag 9567) is turned on globally on each member
    AG's primary before the loop opens; it reduces the bytes on the wire and, with the
    concurrency governor, is what keeps the cross-cluster endpoint out of trouble.

    Completion is judged by ARRIVAL on the forwarder — the database reaching SYNCHRONIZING /
    SYNCHRONIZED there — not by the seeding DMV, because on the forwarder primary the DMV can
    report FAILED with "Seeding Check Message Timeout" even when the seed actually worked, and
    it records transient "Transport Replica" failures on the way to a seed that succeeds.
    Neither is treated as fatal; the loop simply keeps going until arrival or the timeout.
#>

Set-StrictMode -Version Latest

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

function Get-DagForwarderListenerHost {
    # The host portion of a listener URL: TCP://NAME.DOMAIN:PORT -> NAME.DOMAIN.
    param([Parameter(Mandatory)][string]$ListenerUrl)
    if ($ListenerUrl -match '//([^:/]+)') { return $Matches[1] }
    return $ListenerUrl
}

function Get-DagActivelySeedingDatabases {
    <#
    .SYNOPSIS
        Databases currently STREAMING to the forwarder — the real occupancy of the seeding
        endpoint, used to decide whether a slot is free.
    .DESCRIPTION
        sys.dm_hadr_physical_seeding_stats identifies the peer by its listener URL in
        remote_machine_name, and lingers on a completed seed with internal_state 'Success'.
        Active means a non-terminal state to the forwarder listener; a database whose seed
        was cancelled has no such row and so does not count against the cap — which is exactly
        what lets the loop restart it.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$ForwarderListenerUrl
    )
    $hostPart = Get-DagForwarderListenerHost -ListenerUrl $ForwarderListenerUrl
    try {
        $rows = Invoke-DagSql -Instance $Instance -Activity 'active seeds' -Query @"
SELECT local_database_name AS db, ISNULL(internal_state_desc, '') AS st
FROM sys.dm_hadr_physical_seeding_stats
WHERE remote_machine_name LIKE $(ConvertTo-DagQuotedString "%$hostPart%")
"@
    } catch { return @() }
    if (-not $rows) { return @() }
    return @($rows | Where-Object { $_.st -notmatch 'Success|Fail|Error|Cancel' } | ForEach-Object { $_.db } | Select-Object -Unique)
}

function Enable-DagAutoSeedCompression {
    <#
    .SYNOPSIS
        Turns on trace flag 9567 globally on each member AG's primary replica.
    .DESCRIPTION
        9567 compresses the automatic-seeding data stream. It is a session/instance runtime
        flag set with DBCC TRACEON (…, -1); it is not persisted across a restart, which is
        the right lifetime here — it only needs to be on while this seed runs. Enabled on the
        SENDING side of each seed: the global primary streams across the DAG, and the
        forwarder primary streams onward to its own secondaries.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $primaries = @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica) | Select-Object -Unique
    foreach ($inst in $primaries) {
        try {
            Invoke-DagSql -Instance $inst -Activity 'enable trace flag 9567' -Query 'DBCC TRACEON (9567, -1) WITH NO_INFOMSGS;' | Out-Null
            Write-DagLog "  [$inst] trace flag 9567 ON globally — automatic-seeding stream compression." SUCCESS
        } catch {
            Write-DagLog "  [$inst] could not enable trace flag 9567 (seeding will proceed uncompressed): $($_.Exception.Message.Split([char]10)[0])" WARN
        }
    }
}

function Invoke-DagReseedNudge {
    <#
    .SYNOPSIS
        Re-triggers automatic seeding for every global-AG database not yet on the forwarder,
        by re-issuing SEEDING_MODE = AUTOMATIC on both member AGs.
    .DESCRIPTION
        This is how a cancelled distributed-AG seed is restarted — SQL Server does not retry
        one on its own once it has exhausted its attempts. Re-issuing the seeding mode is
        verified safe against seeds already in flight: it restarts the stalled ones without
        disturbing the ones that are streaming. Like all distributed-AG option changes it must
        run on BOTH member primaries to take effect.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $sql = @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.DagName)
MODIFY
AVAILABILITY GROUP ON
    $(ConvertTo-DagQuotedString $Plan.GlobalAgName) WITH
    (
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC
    ),
    $(ConvertTo-DagQuotedString $Plan.ForwarderAgName) WITH
    (
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC
    );
"@
    foreach ($inst in @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica)) {
        Invoke-DagSql -Instance $inst -QueryTimeout 120 -Activity 're-trigger seeding' -Query $sql | Out-Null
    }
}

function Add-DagDatabaseToGlobalAgAuto {
    <#
    .SYNOPSIS
        Admits one database to the global primary AG for automatic seeding — the act that
        releases it to seed across the distributed AG. Non-blocking: it returns as soon as
        the ADD is issued; the caller's loop watches for arrival on the forwarder.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $gp = $Plan.GlobalPrimaryReplica

    if (Test-DagDatabaseInAg -Instance $gp -AgName $Plan.GlobalAgName -DatabaseName $DatabaseName) {
        return   # already a member (pre-existing or resumed) — it is already seeding.
    }

    # A database must have a full backup before it can join an AG; without one it behaves as
    # if it were in SIMPLE recovery and the ADD is refused.
    $hasFull = Get-DagScalar -Instance $gp -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM msdb.dbo.backupset
WHERE database_name = $(ConvertTo-DagQuotedString $DatabaseName) AND type = 'D' AND is_copy_only = 0
"@
    if ([int]$hasFull -eq 0) {
        $dir  = Get-DagDefaultBackupPath -Instance $gp
        $file = Join-DagPath -Path $dir -ChildPath @("$(Get-DagSafeFileToken $DatabaseName)_InitialFull.bak")
        Write-DagLog "  [$DatabaseName] has never been backed up; taking an initial full backup to $file" INFO
        Invoke-DagLongOp -Instance $gp -Activity "initial FULL backup of [$DatabaseName]" -Query @"
BACKUP DATABASE $(ConvertTo-DagQuotedName $DatabaseName) TO DISK = $(ConvertTo-DagQuotedString $file)
WITH INIT, COMPRESSION, CHECKSUM, FORMAT, DESCRIPTION = N'Initialize-DAG initial full backup';
"@
    }

    Invoke-DagSql -Instance $gp -QueryTimeout 300 -Activity 'add database to AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.GlobalAgName)
ADD DATABASE $(ConvertTo-DagQuotedName $DatabaseName);
"@ | Out-Null
}

function Get-DagSeedProgressStatus {
    <#
    .SYNOPSIS
        Renders live per-database seeding progress: a Write-Progress bar for each database
        actively streaming to the forwarder, plus a compact one-line status the caller logs
        when it changes.
    .OUTPUTS
        [string] the compact status line (empty when nothing is streaming).
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InFlight,
        [Parameter(Mandatory)][hashtable]$IdOf,
        [int]$PendingCount,
        [int]$DoneCount,
        [int]$Total
    )

    $hostPart = Get-DagForwarderListenerHost -ListenerUrl $Plan.ForwarderListenerUrl
    $stats = @(Get-DagPhysicalSeedingStats -Instance $Plan.GlobalPrimaryReplica |
                Where-Object { $_.RemoteMachine -like "*$hostPart*" })

    $parentPct = if ($Total -gt 0) { [int]([math]::Round(100.0 * $DoneCount / $Total)) } else { 0 }
    Write-Progress -Id 0 -Activity "Automatic seeding across [$($Plan.DagName)]" `
        -Status ("{0}/{1} done · {2} seeding · {3} waiting" -f $DoneCount, $Total, $InFlight.Count, $PendingCount) `
        -PercentComplete $parentPct

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($db in $InFlight) {
        $row = @($stats | Where-Object { $_.DatabaseName -eq $db })
        if ($row.Count -gt 0) {
            $r = $row[0]
            Write-Progress -Id $IdOf[$db] -ParentId 0 -Activity "[$db] -> forwarder" `
                -Status ("{0} / {1} @ {2}" -f $r.Transferred, $r.Total, $r.Rate) -PercentComplete ([int]$r.Percent)
            $parts.Add(("{0} {1}% ({2}/{3})" -f $db, [int]$r.Percent, $r.Transferred, $r.Total))
        } else {
            Write-Progress -Id $IdOf[$db] -ParentId 0 -Activity "[$db]" -Status 'starting…' -PercentComplete 0
            $parts.Add(("{0} starting" -f $db))
        }
    }
    return ($parts -join '  |  ')
}

function Complete-DagForwarderSecondaries {
    <#
    .SYNOPSIS
        After a database has arrived on the forwarder PRIMARY, ensure it reaches the
        forwarder's own secondary replicas — or record it as deferred when it cannot yet.
    .DESCRIPTION
        The forwarder primary reseeds to its own secondaries through the forwarder AG, but
        only while its copy is ONLINE. In a cross-version DAG the forwarder's databases stay
        in RECOVERING until the DAG is failed over and upgraded, so seeding onward cannot
        happen and the secondaries stay empty. That is by design and resolves at failover.
    .OUTPUTS
        [string[]] "db -> secondary" entries that were deferred (empty when none).
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName,
        [int]$TimeoutSeconds
    )

    $fp        = $Plan.ForwarderPrimaryReplica
    $fwSeconds = @($Plan.ForwarderSecondaries)
    if ($fwSeconds.Count -eq 0) { return @() }

    $fpState = Get-DagDatabaseState -Instance $fp -DatabaseName $DatabaseName
    $onlineOnForwarder = ($fpState -and $fpState.StateDesc -eq 'ONLINE')

    if (-not $onlineOnForwarder) {
        $state = if ($fpState) { $fpState.StateDesc } else { 'absent' }
        Write-DagLog "[$DatabaseName] is $state on $fp; its secondaries cannot be seeded until the DAG is failed over." WARN
        return @($fwSeconds | ForEach-Object { "$DatabaseName -> $_" })
    }

    foreach ($sec in $fwSeconds) {
        $ok = Wait-DagCondition -Activity "[$DatabaseName] seeding to $sec" -TimeoutSeconds $TimeoutSeconds -PollSeconds 20 `
            -Condition { Test-DagDatabaseArrivedOnForwarder -Instance $sec -AgName $Plan.ForwarderAgName -DatabaseName $DatabaseName }
        if (-not $ok) { throw "[$DatabaseName] did not finish seeding to forwarder secondary '$sec' within the timeout." }
        Write-DagLog "[$DatabaseName] arrived on $sec." SUCCESS
    }
    return @()
}

function Invoke-DagSeedAutomatic {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [int]$TimeoutHours = 24
    )

    Write-DagBanner 'STEP 5 of 7 — AUTOMATIC SEEDING'

    $gp        = $Plan.GlobalPrimaryReplica
    $fp        = $Plan.ForwarderPrimaryReplica
    $maxConc   = [math]::Max(1, [int]$Plan.MaxConcurrentSeeds)
    $timeoutSeconds       = $TimeoutHours * 3600
    $pollSeconds          = 8
    $nudgeCooldownSeconds = 25    # do not re-trigger seeding more often than this
    $stallSeconds         = 900   # nothing arriving AND nothing streaming for this long => genuinely stuck
    $graceSeconds         = 30    # count a just-admitted db as active until the DMV catches up

    Enable-DagAutoSeedCompression -Plan $Plan

    Write-DagLog "Seeding $($Plan.Databases.Count) database(s) across the distributed AG, at most $maxConc streaming at once." INFO
    Write-DagLog 'Databases not yet in the global AG are admitted a slot at a time; databases already seeding are watched and, if the endpoint stalls them, re-triggered as slots free.' INFO

    if ($Plan.IsCrossVersion) {
        Write-Host ''
        Write-DagLog 'Cross-version seed: databases land on the forwarder in a Recovering / Synchronizing state.' WARN
        Write-DagLog "That is expected and resolves when the distributed AG is failed over to $(Get-DagSqlVersionName $Plan.ForwarderMajorVersion)." WARN
    }

    #region Classify
    $selected  = @($Plan.Databases)
    $arrived   = New-Object 'System.Collections.Generic.HashSet[string]'
    $member    = New-Object 'System.Collections.Generic.HashSet[string]'
    $firstSeen = @{}
    $idOf      = @{}
    $justAdmitted = @{}

    $i = 0
    foreach ($db in $selected) {
        $i++; $idOf[$db] = $i; $firstSeen[$db] = Get-Date
        if (Test-DagDatabaseInAg -Instance $gp -AgName $Plan.GlobalAgName -DatabaseName $db) { [void]$member.Add($db) }
        if (Test-DagDatabaseArrivedOnForwarder -Instance $fp -AgName $Plan.ForwarderAgName -DatabaseName $db) {
            [void]$arrived.Add($db)
            Write-DagLog "[$db] is already on the forwarder — nothing to seed." SUCCESS
        }
    }
    $preMembers = @($selected | Where-Object { $member.Contains($_) -and -not $arrived.Contains($_) })
    if ($preMembers.Count -gt 0) {
        Write-DagLog "$($preMembers.Count) database(s) were already in [$($Plan.GlobalAgName)] before the DAG and began seeding at creation; they will be self-healed if the endpoint stalls them: $($preMembers -join ', ')" INFO
    }
    #endregion

    #region Concurrency-governed seed-and-heal loop
    $deferredSecondaries = New-Object System.Collections.Generic.List[string]
    $lastStatus  = ''
    $lastNudge   = [datetime]::MinValue
    $lastForward = Get-Date          # last time anything arrived or was actively streaming
    Write-Host ''

    while ($arrived.Count -lt $selected.Count) {

        #region arrivals
        $notArrived = @($selected | Where-Object { -not $arrived.Contains($_) })
        foreach ($db in $notArrived) {
            if (Test-DagDatabaseArrivedOnForwarder -Instance $fp -AgName $Plan.ForwarderAgName -DatabaseName $db) {
                [void]$arrived.Add($db)
                $justAdmitted.Remove($db)
                Write-Progress -Id $idOf[$db] -Activity "[$db]" -Completed
                Write-DagLog "[$db] arrived on $fp ($($arrived.Count)/$($selected.Count) complete)." SUCCESS
            }
        }
        if ($arrived.Count -ge $selected.Count) { break }
        $notArrived = @($selected | Where-Object { -not $arrived.Contains($_) })
        #endregion

        #region occupancy of the seeding endpoint
        $activeNow = Get-DagActivelySeedingDatabases -Instance $gp -ForwarderListenerUrl $Plan.ForwarderListenerUrl
        $graceNow  = @($justAdmitted.Keys | Where-Object { ((Get-Date) - $justAdmitted[$_]).TotalSeconds -lt $graceSeconds })
        $active    = @(@($activeNow) + @($graceNow) | Where-Object { -not $arrived.Contains($_) } | Select-Object -Unique)
        if ($active.Count -gt 0) { $lastForward = Get-Date }
        $freeSlots = $maxConc - $active.Count
        #endregion

        #region fill free slots — admit non-members first (proactive), then heal stalled members (reactive)
        if ($freeSlots -gt 0) {
            $nonMembers = @($notArrived | Where-Object { -not $member.Contains($_) -and $active -notcontains $_ })
            foreach ($db in $nonMembers) {
                if ($freeSlots -le 0) { break }
                Add-DagDatabaseToGlobalAgAuto -Plan $Plan -DatabaseName $db
                [void]$member.Add($db); $justAdmitted[$db] = Get-Date
                $active = @(@($active) + $db); $freeSlots--
                Write-DagLog ("[$db] admitted to [$($Plan.GlobalAgName)] — $($maxConc - $freeSlots)/$maxConc streaming.") STEP
            }

            $stalledMembers = @($notArrived | Where-Object { $member.Contains($_) -and $active -notcontains $_ })
            if ($freeSlots -gt 0 -and $stalledMembers.Count -gt 0 -and ((Get-Date) - $lastNudge).TotalSeconds -ge $nudgeCooldownSeconds) {
                Invoke-DagReseedNudge -Plan $Plan
                $lastNudge = Get-Date
                Write-DagLog ("Re-triggered seeding ($($active.Count)/$maxConc streaming) for $($stalledMembers.Count) stalled database(s): $($stalledMembers -join ', ')") STEP
            }
        }
        #endregion

        #region give-up guards
        if (((Get-Date) - $lastForward).TotalSeconds -gt $stallSeconds) {
            $stuck = @($selected | Where-Object { -not $arrived.Contains($_) })
            throw @"
Seeding made no progress for $([int]($stallSeconds/60)) minutes: nothing is streaming to the forwarder and $($stuck.Count) database(s) have not arrived: $($stuck -join ', ').

Inspect on the global primary ($gp):
    SELECT * FROM sys.dm_hadr_automatic_seeding;
    SELECT * FROM sys.dm_hadr_physical_seeding_stats;
and the SQL Server error log on $gp and $fp. Re-running Initialize-DAG.ps1 is safe and resumes.
"@
        }
        foreach ($db in $notArrived) {
            if (((Get-Date) - $firstSeen[$db]).TotalSeconds -gt $timeoutSeconds) {
                throw "[$db] did not finish seeding to '$fp' within $TimeoutHours hour(s). Re-running Initialize-DAG.ps1 is safe and resumes."
            }
        }
        #endregion

        $inFlight = @($notArrived | Where-Object { $active -contains $_ })
        $status = Get-DagSeedProgressStatus -Plan $Plan -InFlight $inFlight -IdOf $idOf `
                    -PendingCount ($notArrived.Count - $inFlight.Count) -DoneCount $arrived.Count -Total $selected.Count
        if ($status -and $status -ne $lastStatus) { Write-DagLog "  seeding: $status" INFO; $lastStatus = $status }

        Start-Sleep -Seconds $pollSeconds
    }
    Write-Progress -Id 0 -Activity 'Automatic seeding' -Completed
    Write-DagLog "All $($selected.Count) database(s) have reached the forwarder primary $fp." SUCCESS
    #endregion

    #region Onward to the forwarder secondaries, then record completion
    Write-Host ''
    foreach ($db in $selected) {
        foreach ($d in (Complete-DagForwarderSecondaries -Plan $Plan -DatabaseName $db -TimeoutSeconds $timeoutSeconds)) {
            $deferredSecondaries.Add($d)
        }
        $rec = Get-DagProgress -Plan $Plan -DatabaseName $db
        $rec.JoinedOn  = @($Plan.ForwarderPrimaryReplica)
        $rec.Completed = $true
        Set-DagProgress -Plan $Plan -Record $rec
    }
    #endregion

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
