#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 06b: manual seeding via a backup share.

.DESCRIPTION
    Per database, in order:

      1. A transaction log backup job runs on every replica (installed once, before any full
         backup, so the log chain on the share is continuous from the start).
      2. Non-copy-only, compressed, checksummed FULL backup striped across N files.
      3. Restore that FULL onto every secondary WITH NORECOVERY, putting the data and log
         files where the operator chose.
      4. Restore every log backup accumulated so far, WITH NORECOVERY.
      5. Disable the log backup job and WAIT for any in-flight backup to finish — a log
         backup that fires during the final catch-up would take log records the secondaries
         could then never obtain.
      6. Take the final log backup and restore it on every secondary.
      7. ALTER AVAILABILITY GROUP ... ADD DATABASE on the primary, then
         ALTER DATABASE ... SET HADR AVAILABILITY GROUP on each secondary.
      8. Re-enable the log backup job and move to the next database.

    Every step re-reads live state first, so an interrupted run resumes rather than repeating
    a multi-terabyte full backup.
#>

Set-StrictMode -Version Latest

function Get-AgRecoveryForkGuid {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    try {
        return Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(drs.recovery_fork_guid AS nvarchar(64)) AS v
FROM sys.database_recovery_status AS drs
JOIN sys.databases AS d ON d.database_id = drs.database_id
WHERE d.name = $(ConvertTo-AgQuotedString $DatabaseName)
"@
    } catch { return $null }
}

function Test-AgFullBackupReusable {
    <#
    .SYNOPSIS
        Can a FULL backup recorded by a previous run still be used to seed this database?
        Only when every stripe is still present, the media reads back, and it belongs to the
        current recovery fork of the source database.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string[]]$Files
    )
    if (-not $Files -or $Files.Count -eq 0) { return $null }
    foreach ($f in $Files) {
        if (-not (Test-AgRemotePath -Instance $Instance -Path $f).FileExists) {
            Write-AgLog "  [$DatabaseName] recorded FULL backup stripe missing ($f) — a new full backup is required." INFO
            return $null
        }
    }
    try { $header = Get-AgBackupHeader -Instance $Instance -Files $Files }
    catch { Write-AgLog "  [$DatabaseName] recorded FULL backup is unreadable — taking a new one." WARN; return $null }

    if (-not $header -or $header.BackupTypeCode -ne 1 -or $header.DatabaseName -ne $DatabaseName) {
        Write-AgLog "  [$DatabaseName] recorded backup is not a FULL backup of this database — taking a new one." WARN
        return $null
    }
    $fork = Get-AgRecoveryForkGuid -Instance $Instance -DatabaseName $DatabaseName
    if ($fork -and $header.RecoveryForkID -and ($fork -ne $header.RecoveryForkID)) {
        Write-AgLog "  [$DatabaseName] recovery fork changed since the recorded full backup — taking a new one." WARN
        return $null
    }
    Write-AgLog "  [$DatabaseName] reusing FULL backup from $($header.BackupFinishDate) ($(Format-AgBytes $header.CompressedSizeBytes) compressed, $($Files.Count) stripes)." SUCCESS
    return $header
}

function Get-AgProbeLogFile {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$LogDirectory,
        [int]$Limit = 5
    )
    $files = @(Get-AgRemoteFile -Instance $Instance -Path $LogDirectory -Pattern '*.trn')
    if ($files.Count -eq 0) { return @() }
    return @($files | Sort-Object LastWriteTime | Select-Object -First $Limit | ForEach-Object { $_.FullPath })
}

function Test-AgDatabaseFullyJoined {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    if (-not (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $DatabaseName)) { return $false }
    foreach ($s in $Plan.SecondaryReplicas) {
        if (-not (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Plan.AgName -DatabaseName $DatabaseName)) { return $false }
    }
    return $true
}

function Join-AgDatabase {
    <#
    .SYNOPSIS
        ADD DATABASE on the primary, then SET HADR AVAILABILITY GROUP on each secondary.
        Idempotent per replica.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $ag = ConvertTo-AgQuotedName $Plan.AgName
    $db = ConvertTo-AgQuotedName $DatabaseName

    if (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $DatabaseName) {
        Write-AgLog "  [$($Plan.PrimaryReplica)] [$DatabaseName] already in [$($Plan.AgName)]" SUCCESS
    } else {
        Invoke-AgSql -Instance $Plan.PrimaryReplica -QueryTimeout 300 -Activity 'add database to AG' `
            -Query "ALTER AVAILABILITY GROUP $ag ADD DATABASE $db;" | Out-Null
        Write-AgLog "  [$($Plan.PrimaryReplica)] [$DatabaseName] added to [$($Plan.AgName)]" SUCCESS
    }

    foreach ($s in $Plan.SecondaryReplicas) {
        if (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Plan.AgName -DatabaseName $DatabaseName) {
            Write-AgLog "  [$s] [$DatabaseName] already joined" SUCCESS
            continue
        }
        # The secondary learns of the new AG database through the cluster a moment after the
        # ADD; joining before then fails with 35250-family errors that clear on their own.
        Invoke-AgWithRetry -Activity "join [$DatabaseName] on $s" -MaxAttempts 6 -DelaySeconds 5 -ScriptBlock {
            try {
                Invoke-AgSql -Instance $s -QueryTimeout 600 -Activity 'join database' `
                    -Query "ALTER DATABASE $db SET HADR AVAILABILITY GROUP = $ag;" | Out-Null
            } catch {
                $nums = @(Get-AgSqlErrorNumber -ErrorRecord $_)
                if ($nums -contains 35250 -or $nums -contains 35242 -or $nums -contains 41145) { throw "Timeout expired (transient: $($_.Exception.Message.Split("`n")[0]))" }
                throw
            }
        }
        Write-AgLog "  [$s] [$DatabaseName] joined to [$($Plan.AgName)]" SUCCESS
    }
}

function Invoke-AgSeedManual {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo,
        [int]$TimeoutHours = 24,
        [switch]$Force
    )

    Write-AgBanner 'MANUAL SEEDING'

    $p = $Plan.PrimaryReplica

    # Automatic seeding must not race the restores for these databases.
    Set-AgReplicaSeedingMode -PrimaryInstance $p -AgName $Plan.AgName -Replicas $Plan.SecondaryReplicas -Mode 'MANUAL'

    Write-AgLog "Installing the $($Plan.TLogIntervalMinutes)-minute transaction log backup job on every replica..." INFO
    foreach ($r in $Plan.ReplicaNames) {
        Install-AgTLogJob -Instance $r -AgName $Plan.AgName -ShareRoot $Plan.ShareRoot `
            -Databases $Plan.Databases -IntervalMinutes $Plan.TLogIntervalMinutes
    }

    foreach ($db in $Plan.Databases) {
        Write-AgBanner "SEEDING [$db]"
        $dbStart = Get-Date

        if (Test-AgDatabaseFullyJoined -Plan $Plan -DatabaseName $db) {
            Write-AgLog "[$db] is already joined on every replica — nothing to do." SUCCESS
            $rec = Get-AgProgress -Plan $Plan -DatabaseName $db
            $rec.Completed = $true
            Set-AgProgress -Plan $Plan -Record $rec
            continue
        }

        $rec      = Get-AgProgress -Plan $Plan -DatabaseName $db
        $shares   = @(Get-AgPlanShareRoots -Plan $Plan)
        $fullDirs = @(Get-AgFullDirectoryList -ShareRoots $shares -AgName $Plan.AgName -DatabaseName $db)
        $logDir   = Get-AgLogDirectory -ShareRoot $shares[0] -AgName $Plan.AgName -DatabaseName $db
        foreach ($d in $fullDirs) { New-AgRemoteDirectory -Instance $p -Path $d }
        New-AgRemoteDirectory -Instance $p -Path $logDir

        #region 1. FULL backup (or reuse one from an interrupted run)
        $header = Test-AgFullBackupReusable -Instance $p -DatabaseName $db -Files @($rec.FullBackupFiles)
        if (-not $header) {
            $files  = @(New-AgFullBackup -Instance $p -DatabaseName $db -Directories $fullDirs -StripeCount $Plan.StripeCount)
            $header = Get-AgBackupHeader -Instance $p -Files $files
            $rec.FullBackupFiles   = @($files)
            $rec.FullBackupUtc     = (Get-Date).ToUniversalTime().ToString('o')
            $rec.FullCheckpointLsn = [string]$header.CheckpointLSN
            Set-AgProgress -Plan $Plan -Record $rec
        }
        $fullFiles = @($rec.FullBackupFiles)
        #endregion

        #region 2. Restore the FULL onto every secondary
        foreach ($s in $Plan.SecondaryReplicas) {
            if (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Plan.AgName -DatabaseName $db) { continue }
            $probeLogs = @(Get-AgProbeLogFile -Instance $s -LogDirectory $logDir)
            Restore-AgFullBackup -Instance $s -DatabaseName $db -Files $fullFiles `
                -InstanceInfo $InstanceInfo[$s] -Header $header -Plan $Plan -ProbeLogFiles $probeLogs -Force:$Force
            $rec = Get-AgProgress -Plan $Plan -DatabaseName $db
            if ($rec.RestoredOn -notcontains $s) { $rec.RestoredOn = @($rec.RestoredOn) + $s; Set-AgProgress -Plan $Plan -Record $rec }
        }
        #endregion

        #region 3. Catch up with every log backup taken so far
        foreach ($s in $Plan.SecondaryReplicas) {
            if (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Plan.AgName -DatabaseName $db) { continue }
            Restore-AgLogChain -Instance $s -DatabaseName $db -LogDirectory $logDir -HeaderReadInstance $s `
                -NotBefore $header.BackupFinishDate -FamilyGuid $header.FamilyGUID | Out-Null
        }
        #endregion

        #region 4. Quiesce the job, final log, restore, join
        Write-AgLog "[$db] entering the final catch-up window." STEP
        Suspend-AgTLogJob -Instances $Plan.ReplicaNames -AgName $Plan.AgName
        try {
            New-AgLogBackup -Instance $p -DatabaseName $db -Directory $logDir -Suffix 'final' | Out-Null
            foreach ($s in $Plan.SecondaryReplicas) {
                if (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Plan.AgName -DatabaseName $db) { continue }
                Restore-AgLogChain -Instance $s -DatabaseName $db -LogDirectory $logDir -HeaderReadInstance $s `
                    -NotBefore $header.BackupFinishDate -FamilyGuid $header.FamilyGUID | Out-Null
            }
            Join-AgDatabase -Plan $Plan -DatabaseName $db
        } finally {
            # The job must come back even if the join failed, or the primary's log grows
            # unbounded while the operator investigates.
            Resume-AgTLogJob -Instances $Plan.ReplicaNames -AgName $Plan.AgName
        }
        #endregion

        #region 5. Confirm data is moving
        foreach ($s in $Plan.SecondaryReplicas) {
            $ok = Wait-AgCondition -Activity "[$db] synchronizing on $s" -TimeoutSeconds ($TimeoutHours * 3600) -PollSeconds 5 `
                -Condition { Test-AgDatabaseSynchronizing -Instance $s -AgName $Plan.AgName -DatabaseName $db }
            if (-not $ok) { throw "[$db] joined on '$s' but never reached a synchronizing state within $TimeoutHours hour(s). Check the SQL Server error log on '$s'." }
        }
        $rec = Get-AgProgress -Plan $Plan -DatabaseName $db
        $rec.JoinedOn  = @($Plan.SecondaryReplicas)
        $rec.Completed = $true
        Set-AgProgress -Plan $Plan -Record $rec
        Write-AgLog ("[{0}] seeded in {1}." -f $db, (Format-AgDuration ((Get-Date) - $dbStart))) SUCCESS
        #endregion
    }

    Write-AgLog 'Manual seeding complete for every selected database.' SUCCESS
}
