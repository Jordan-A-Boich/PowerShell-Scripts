#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 05b: manual seeding via a backup share.

.DESCRIPTION
    Per database, in order:

      1. A 15-minute transaction log backup job runs on the global primary AG (installed
         once, before any full backup, so the log chain is continuous from the start).
      2. Non-copy-only, compressed, checksummed FULL backup striped across N files.
      3. Restore that FULL to the forwarder primary and every forwarder secondary,
         WITH NORECOVERY, relocating files onto each target's own drive layout.
      4. Restore every log backup accumulated so far, WITH NORECOVERY.
      5. Disable the log backup job and WAIT for any in-flight backup to finish — a log
         backup that fires during the final catch-up would take log records the forwarder
         can then never obtain.
      6. Take the final log backup and restore it.
      7. Join the database to the forwarder AG on the primary, then on each secondary.
      8. Re-enable the log backup job and move to the next database.

    Every step re-reads live state first, so an interrupted run resumes rather than
    repeating a multi-terabyte full backup.
#>

Set-StrictMode -Version Latest

function Get-DagRecoveryForkGuid {
    <#
    .SYNOPSIS
        Current recovery fork of a database, or $null when it cannot be determined.
        A changed fork means the database was restored or reverted since our last full
        backup, which invalidates that backup for seeding.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    try {
        $v = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(drs.recovery_fork_guid AS nvarchar(64)) AS v
FROM sys.database_recovery_status AS drs
JOIN sys.databases AS d ON d.database_id = drs.database_id
WHERE d.name = $(ConvertTo-DagQuotedString $DatabaseName)
"@
        return $v
    } catch {
        return $null
    }
}

function Test-DagFullBackupReusable {
    <#
    .SYNOPSIS
        Can a FULL backup recorded by a previous run still be used to seed this database?
    .DESCRIPTION
        Reusing a completed multi-terabyte full backup is the single biggest win on a
        resume, but only when every stripe is still present, the media reads back, and
        it belongs to the current recovery fork of the source database.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string[]]$Files
    )

    if (-not $Files -or $Files.Count -eq 0) { return $null }

    foreach ($f in $Files) {
        $probe = Test-DagRemotePath -Instance $Instance -Path $f
        if (-not $probe.FileExists) {
            Write-DagLog "  [$DatabaseName] recorded FULL backup stripe missing ($f) — a new full backup is required." INFO
            return $null
        }
    }

    try {
        $header = Get-DagBackupHeader -Instance $Instance -Files $Files
    } catch {
        Write-DagLog "  [$DatabaseName] recorded FULL backup is unreadable — a new full backup is required." WARN
        return $null
    }

    if (-not $header -or $header.BackupTypeCode -ne 1 -or $header.DatabaseName -ne $DatabaseName) {
        Write-DagLog "  [$DatabaseName] recorded backup is not a FULL backup of this database — taking a new one." WARN
        return $null
    }

    $fork = Get-DagRecoveryForkGuid -Instance $Instance -DatabaseName $DatabaseName
    if ($fork -and $header.RecoveryForkID -and ($fork -ne $header.RecoveryForkID)) {
        Write-DagLog "  [$DatabaseName] recovery fork changed since the recorded full backup — taking a new one." WARN
        return $null
    }

    Write-DagLog "  [$DatabaseName] reusing FULL backup from $($header.BackupFinishDate) ($(Format-DagBytes $header.CompressedSizeBytes) compressed, $($Files.Count) stripes)." SUCCESS
    return $header
}

function Test-DagDatabaseFullyJoined {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    foreach ($r in (@($Plan.ForwarderPrimaryReplica) + @($Plan.ForwarderSecondaries))) {
        if (-not (Test-DagDatabaseJoinedOnReplica -Instance $r -AgName $Plan.ForwarderAgName -DatabaseName $DatabaseName)) {
            return $false
        }
    }
    return $true
}

function Join-DagDatabaseToForwarder {
    <#
    .SYNOPSIS
        ALTER DATABASE ... SET HADR AVAILABILITY GROUP on the forwarder primary, then
        on each forwarder secondary. Idempotent per replica.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    foreach ($r in (@($Plan.ForwarderPrimaryReplica) + @($Plan.ForwarderSecondaries))) {
        if (Test-DagDatabaseJoinedOnReplica -Instance $r -AgName $Plan.ForwarderAgName -DatabaseName $DatabaseName) {
            Write-DagLog "  [$r] [$DatabaseName] already joined to [$($Plan.ForwarderAgName)]" SUCCESS
            continue
        }
        Invoke-DagSql -Instance $r -QueryTimeout 600 -Activity 'join database to forwarder AG' -Query @"
ALTER DATABASE $(ConvertTo-DagQuotedName $DatabaseName)
SET HADR AVAILABILITY GROUP = $(ConvertTo-DagQuotedName $Plan.ForwarderAgName);
"@ | Out-Null
        Write-DagLog "  [$r] [$DatabaseName] joined to [$($Plan.ForwarderAgName)]" SUCCESS
    }
}

function Invoke-DagSeedManual {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo
    )

    Write-DagBanner 'STEP 5 of 7 — MANUAL SEEDING'

    $gp          = $Plan.GlobalPrimaryReplica
    $fwReplicas  = @($Plan.ForwarderPrimaryReplica) + @($Plan.ForwarderSecondaries)

    #region Install the log backup job on every replica of the global primary AG
    Write-DagLog "Installing the $($Plan.TLogIntervalMinutes)-minute transaction log backup job..." INFO
    foreach ($r in $Plan.GlobalReplicas) {
        Install-DagTLogJob -Instance $r -DagName $Plan.DagName -GlobalAgName $Plan.GlobalAgName `
            -ShareRoot $Plan.ShareRoot -Databases $Plan.Databases -IntervalMinutes $Plan.TLogIntervalMinutes
    }
    #endregion

    foreach ($db in $Plan.Databases) {
        Write-Host ''
        Write-DagBanner "SEEDING [$db]"
        $dbStart = Get-Date

        if (Test-DagDatabaseFullyJoined -Plan $Plan -DatabaseName $db) {
            Write-DagLog "[$db] is already joined to [$($Plan.ForwarderAgName)] on every forwarder replica — nothing to do." SUCCESS
            $rec = Get-DagProgress -Plan $Plan -DatabaseName $db
            $rec.Completed = $true
            Set-DagProgress -Plan $Plan -Record $rec
            continue
        }

        $rec     = Get-DagProgress -Plan $Plan -DatabaseName $db
        $fullDir = Get-DagFullDirectory -ShareRoot $Plan.ShareRoot -DagName $Plan.DagName -DatabaseName $db
        $logDir  = Get-DagLogDirectory  -ShareRoot $Plan.ShareRoot -DagName $Plan.DagName -DatabaseName $db

        New-DagRemoteDirectory -Instance $gp -Path $fullDir
        New-DagRemoteDirectory -Instance $gp -Path $logDir

        #region 1. FULL backup (or reuse one from an interrupted run)
        $header = Test-DagFullBackupReusable -Instance $gp -DatabaseName $db -Files @($rec.FullBackupFiles)
        if (-not $header) {
            $files  = @(New-DagFullBackup -Instance $gp -DatabaseName $db -Directory $fullDir -StripeCount $Plan.StripeCount)
            $header = Get-DagBackupHeader -Instance $gp -Files $files

            $rec.FullBackupFiles   = @($files)
            $rec.FullBackupUtc     = (Get-Date).ToUniversalTime().ToString('o')
            $rec.FullCheckpointLsn = [string]$header.CheckpointLSN
            Set-DagProgress -Plan $Plan -Record $rec
        }
        $fullFiles = @($rec.FullBackupFiles)
        #endregion

        #region 2. Restore the FULL onto every forwarder replica
        foreach ($r in $fwReplicas) {
            Restore-DagFullBackup -Instance $r -DatabaseName $db -Files $fullFiles `
                -InstanceInfo $InstanceInfo[$r] -Header $header
            if ($rec.RestoredOn -notcontains $r) {
                $rec.RestoredOn = @($rec.RestoredOn) + $r
                Set-DagProgress -Plan $Plan -Record $rec
            }
        }
        #endregion

        #region 3. Catch up with every log backup taken so far
        foreach ($r in $fwReplicas) {
            Restore-DagLogChain -Instance $r -DatabaseName $db -LogDirectory $logDir `
                -HeaderReadInstance $r -NotBefore $header.BackupFinishDate -FamilyGuid $header.FamilyGUID | Out-Null
        }
        #endregion

        #region 4. Quiesce the log backup job, take the final log, restore it, join
        Write-DagLog "[$db] entering the final catch-up window." STEP
        Suspend-DagTLogJob -Instances $Plan.GlobalReplicas -DagName $Plan.DagName

        try {
            New-DagLogBackup -Instance $gp -DatabaseName $db -Directory $logDir -Suffix 'final' | Out-Null

            foreach ($r in $fwReplicas) {
                Restore-DagLogChain -Instance $r -DatabaseName $db -LogDirectory $logDir `
                    -HeaderReadInstance $r -NotBefore $header.BackupFinishDate -FamilyGuid $header.FamilyGUID | Out-Null
            }

            Join-DagDatabaseToForwarder -Plan $Plan -DatabaseName $db
        } finally {
            # The job must come back even if the join failed, otherwise the log on the
            # global primary grows unbounded while the operator investigates.
            Resume-DagTLogJob -Instances $Plan.GlobalReplicas -DagName $Plan.DagName
        }
        #endregion

        #region 5. Confirm the database is moving data on the forwarder
        foreach ($r in $fwReplicas) {
            $ok = Wait-DagCondition -Activity "[$db] synchronizing on $r" -TimeoutSeconds 900 -PollSeconds 10 `
                -Condition { Test-DagDatabaseArrivedOnForwarder -Instance $r -AgName $Plan.ForwarderAgName -DatabaseName $db }
            if (-not $ok) {
                throw "[$db] joined [$($Plan.ForwarderAgName)] on '$r' but never reached a synchronizing state. Check the SQL Server error log on '$r'."
            }
        }

        $rec.JoinedOn  = @($fwReplicas)
        $rec.Completed = $true
        Set-DagProgress -Plan $Plan -Record $rec

        Write-DagLog ("[{0}] seeded in {1}." -f $db, (Format-DagDuration ((Get-Date) - $dbStart))) SUCCESS
        #endregion
    }

    Write-Host ''
    Write-DagLog 'Manual seeding complete for every selected database.' SUCCESS
    Write-DagLog "The log backup job '$(Get-DagTLogJobName -DagName $Plan.DagName)' is still enabled on the global primary AG." INFO
    Write-DagLog 'Leave it in place until your normal log backup maintenance covers these databases,' INFO
    Write-DagLog "then remove it with:  .\Initialize-DAG.ps1 -RemoveLogBackupJob" INFO
}
