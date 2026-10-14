#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 06a: automatic seeding, concurrency-governed and self-healing.

.DESCRIPTION
    A database starts seeding to the secondaries the moment it is added to the availability
    group — membership is the only per-database lever SQL Server offers. Adding thirty
    databases at once starts thirty streams over the endpoint, and the surplus fail or stall.
    So this step keeps at most MaxConcurrentSeeds databases streaming at a time:

      * a database NOT yet in the AG is admitted (ALTER AVAILABILITY GROUP ... ADD DATABASE)
        only when a slot is free; the instant one lands, the next is admitted;
      * a database already in the AG that has not arrived on a secondary and is not streaming
        (a seed that failed, or was cancelled) is restarted by re-issuing SEEDING_MODE =
        AUTOMATIC for that secondary — harmless to seeds already in flight.

    Completion is judged by ARRIVAL — the database SYNCHRONIZING or SYNCHRONIZED on every
    secondary — not by the seeding DMV, which records transient failures on the way to seeds
    that succeed. Re-running is safe: databases already in the AG and synchronized are skipped.
#>

Set-StrictMode -Version Latest

function Get-AgActivelySeedingDatabases {
    <#
    .SYNOPSIS
        Databases currently streaming FROM the primary — the real occupancy of the endpoint.
    .DESCRIPTION
        sys.dm_hadr_physical_seeding_stats lingers on a finished seed with internal_state
        'Success'; only non-terminal rows count as active.
    #>
    param([Parameter(Mandatory)][string]$Instance)
    try {
        $rows = Invoke-AgSql -Instance $Instance -Activity 'active seeds' -Query @'
SELECT local_database_name AS db, ISNULL(internal_state_desc, '') AS st, ISNULL(role_desc, '') AS role
FROM sys.dm_hadr_physical_seeding_stats
'@
    } catch { return @() }
    return @($rows | Where-Object { $_.role -ne 'Destination' -and $_.st -notmatch 'Success|Fail|Error|Cancel' } |
             ForEach-Object { [string]$_.db } | Select-Object -Unique)
}

function Test-AgTraceFlagOn {
    param([Parameter(Mandatory)][string]$Instance, [Parameter(Mandatory)][int]$Flag)
    try {
        $rows = Invoke-AgSql -Instance $Instance -Activity 'trace status' -Query "DBCC TRACESTATUS ($Flag, -1) WITH NO_INFOMSGS;"
        return ($rows.Count -gt 0 -and [int]$rows[0].Global -eq 1)
    } catch { return $false }
}

function Get-AgDatabaseArrival {
    <#
    .OUTPUTS
        The secondaries on which the database has NOT yet arrived.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    return @($Plan.SecondaryReplicas | Where-Object {
        -not (Test-AgDatabaseSynchronizing -Instance $_ -AgName $Plan.AgName -DatabaseName $DatabaseName)
    })
}

function Invoke-AgSeedAutomatic {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [int]$TimeoutHours = 24
    )

    Write-AgBanner 'AUTOMATIC SEEDING'

    $p       = $Plan.PrimaryReplica
    $maxConc = [math]::Max(1, [int]$Plan.MaxConcurrentSeeds)
    $timeoutSeconds       = $TimeoutHours * 3600
    $pollSeconds          = 5
    $nudgeCooldownSeconds = 25
    $stallSeconds         = 900
    $graceSeconds         = 30

    #region Seeding stream compression
    $tfWasOn = $false; $tfTurnedOn = $false
    if ($Plan.SeedCompression) {
        $tfWasOn = Test-AgTraceFlagOn -Instance $p -Flag 9567
        if (-not $tfWasOn) {
            try {
                Invoke-AgSql -Instance $p -Activity 'trace flag 9567' -Query 'DBCC TRACEON (9567, -1) WITH NO_INFOMSGS;' | Out-Null
                $tfTurnedOn = $true
                Write-AgLog "  [$p] trace flag 9567 ON — the seeding stream is compressed." SUCCESS
            } catch {
                Write-AgLog "  [$p] could not enable trace flag 9567 (seeding proceeds uncompressed): $($_.Exception.Message.Split("`n")[0])" WARN
            }
        }
    }
    #endregion

    try {
        foreach ($s in $Plan.SecondaryReplicas) { Grant-AgCreateAnyDatabase -Instance $s -AgName $Plan.AgName }
        Set-AgReplicaSeedingMode -PrimaryInstance $p -AgName $Plan.AgName -Replicas $Plan.SecondaryReplicas -Mode 'AUTOMATIC'

        $selected  = @($Plan.Databases)
        $arrived   = New-Object 'System.Collections.Generic.HashSet[string]'
        $member    = New-Object 'System.Collections.Generic.HashSet[string]'
        $firstSeen = @{}; $idOf = @{}; $justAdmitted = @{}
        $i = 0
        foreach ($db in $selected) {
            $i++; $idOf[$db] = $i; $firstSeen[$db] = Get-Date
            if (Test-AgDatabaseInAg -Instance $p -AgName $Plan.AgName -DatabaseName $db) { [void]$member.Add($db) }
            if ($member.Contains($db) -and @(Get-AgDatabaseArrival -Plan $Plan -DatabaseName $db).Count -eq 0) {
                [void]$arrived.Add($db)
                Write-AgLog "[$db] is already synchronizing on every secondary — nothing to seed." SUCCESS
            }
        }

        Write-AgLog "Seeding $($selected.Count - $arrived.Count) database(s), at most $maxConc at a time." INFO
        $lastStatus = ''; $lastNudge = [datetime]::MinValue; $lastForward = Get-Date

        while ($arrived.Count -lt $selected.Count) {
            #region arrivals
            foreach ($db in @($selected | Where-Object { -not $arrived.Contains($_) -and $member.Contains($_) })) {
                if (@(Get-AgDatabaseArrival -Plan $Plan -DatabaseName $db).Count -eq 0) {
                    [void]$arrived.Add($db); $justAdmitted.Remove($db); $lastForward = Get-Date
                    Write-Progress -Id $idOf[$db] -Activity "[$db]" -Completed
                    Write-AgLog "[$db] is synchronizing on every secondary ($($arrived.Count)/$($selected.Count))." SUCCESS
                    $rec = Get-AgProgress -Plan $Plan -DatabaseName $db
                    if ($rec) { $rec.JoinedOn = @($Plan.SecondaryReplicas); $rec.Completed = $true; Set-AgProgress -Plan $Plan -Record $rec }
                }
            }
            if ($arrived.Count -ge $selected.Count) { break }
            $notArrived = @($selected | Where-Object { -not $arrived.Contains($_) })
            #endregion

            #region occupancy
            $activeNow = @(Get-AgActivelySeedingDatabases -Instance $p)
            $graceNow  = @($justAdmitted.Keys | Where-Object { ((Get-Date) - $justAdmitted[$_]).TotalSeconds -lt $graceSeconds })
            $active    = @(@($activeNow) + @($graceNow) | Where-Object { $notArrived -contains $_ } | Select-Object -Unique)
            if ($active.Count -gt 0) { $lastForward = Get-Date }
            $freeSlots = $maxConc - $active.Count
            #endregion

            #region admit, then heal
            if ($freeSlots -gt 0) {
                foreach ($db in @($notArrived | Where-Object { -not $member.Contains($_) })) {
                    if ($freeSlots -le 0) { break }
                    Invoke-AgSql -Instance $p -QueryTimeout 300 -Activity 'add database to AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $Plan.AgName) ADD DATABASE $(ConvertTo-AgQuotedName $db);
"@ | Out-Null
                    [void]$member.Add($db); $justAdmitted[$db] = Get-Date; $firstSeen[$db] = Get-Date
                    $active = @(@($active) + $db); $freeSlots--
                    Write-AgLog "[$db] added to [$($Plan.AgName)] — $($maxConc - $freeSlots)/$maxConc seeding." STEP
                }

                $stalled = @($notArrived | Where-Object { $member.Contains($_) -and $active -notcontains $_ })
                if ($freeSlots -gt 0 -and $stalled.Count -gt 0 -and ((Get-Date) - $lastNudge).TotalSeconds -ge $nudgeCooldownSeconds) {
                    $missingOn = @($stalled | ForEach-Object { Get-AgDatabaseArrival -Plan $Plan -DatabaseName $_ } | Sort-Object -Unique)
                    foreach ($s in $missingOn) {
                        Invoke-AgSql -Instance $p -QueryTimeout 120 -Activity 're-trigger seeding' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $Plan.AgName) MODIFY REPLICA ON $(ConvertTo-AgQuotedString $s) WITH (SEEDING_MODE = AUTOMATIC);
"@ | Out-Null
                    }
                    $lastNudge = Get-Date
                    Write-AgLog "Re-triggered seeding to $($missingOn -join ', ') for: $($stalled -join ', ')" DEBUG
                }
            }
            #endregion

            #region give-up guards
            if (((Get-Date) - $lastForward).TotalSeconds -gt $stallSeconds) {
                $failed = @(Get-AgSeedingProgress -Instance $p -AgName $Plan.AgName | Where-Object { $_.FailureState } | Select-Object -First 5)
                $why = if ($failed.Count) { ($failed | ForEach-Object { "  $($_.DatabaseName) -> $($_.RemoteReplica): $($_.CurrentState) $($_.FailureState)" }) -join "`r`n" } else { '  (no failure recorded)' }
                throw @"
Automatic seeding made no progress for $([int]($stallSeconds / 60)) minutes. Not yet on every secondary: $($notArrived -join ', ').

Most recent seeding failures recorded on ${p}:
$why

The usual causes are a missing directory or no free space on a secondary, or a secondary that
lacks CREATE ANY DATABASE. Read the SQL Server error log on the secondaries. Re-running is safe.
"@
            }
            foreach ($db in $notArrived) {
                if (((Get-Date) - $firstSeen[$db]).TotalSeconds -gt $timeoutSeconds) {
                    throw "[$db] did not finish seeding within $TimeoutHours hour(s). Re-running is safe and resumes."
                }
            }
            #endregion

            #region progress
            $stats = @(Get-AgPhysicalSeedingStats -Instance $p | Where-Object { $_.RoleDesc -ne 'Destination' })
            $parts = foreach ($db in $active) {
                $row = @($stats | Where-Object { $_.DatabaseName -eq $db } | Select-Object -First 1)
                if ($row.Count -gt 0) {
                    Write-Progress -Id $idOf[$db] -ParentId 0 -Activity "[$db]" -Status ("{0} / {1} @ {2}" -f $row[0].Transferred, $row[0].Total, $row[0].Rate) -PercentComplete ([int][math]::Min(100, $row[0].Percent))
                    '{0} {1}%' -f $db, [int]$row[0].Percent
                } else { "$db starting" }
            }
            Write-Progress -Id 0 -Activity "Automatic seeding into [$($Plan.AgName)]" `
                -Status ("{0}/{1} done, {2} seeding" -f $arrived.Count, $selected.Count, $active.Count) `
                -PercentComplete ([int](100.0 * $arrived.Count / [math]::Max(1, $selected.Count)))
            $status = ($parts -join '  |  ')
            if ($status -and $status -ne $lastStatus) { Write-AgLog "  seeding: $status" INFO; $lastStatus = $status }
            #endregion

            Start-Sleep -Seconds $pollSeconds
        }
        Write-Progress -Id 0 -Activity 'Automatic seeding' -Completed
        Write-AgLog "All $($selected.Count) database(s) are synchronizing on every secondary." SUCCESS
    } finally {
        if ($tfTurnedOn) {
            try {
                Invoke-AgSql -Instance $p -Activity 'trace flag 9567 off' -Query 'DBCC TRACEOFF (9567, -1) WITH NO_INFOMSGS;' | Out-Null
                Write-AgLog "  [$p] trace flag 9567 OFF again (it was off before this run)." DEBUG
            } catch { }
        }
    }
}
