#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — backup and restore engine for manual seeding.

.DESCRIPTION
    Designed for multi-terabyte databases, where a re-run must never mean
    "start the 9-hour full backup again". Every decision is driven by LSNs read
    from the backup media and from the target's restore history, so the tool can
    resume from whatever state an interrupted run left behind.

    Restore decisions are deliberately "attempt and classify": we ask SQL Server to apply
    a log and interpret its own error NUMBER —
        4319  a previous restore was interrupted -> the FULL never finished
        3117  no files are ready to rollforward  -> nothing usable was restored
        4326  the log ends too early             -> already applied, skip it
        4305  the log starts too late            -> a genuine gap, stop and report
        3154  different backup family            -> not this database's chain
    This is authoritative in a way that comparing our own bookkeeping never is, and it
    is the only thing that can tell a completed restore apart from one that was killed in
    its tail phase — the two are indistinguishable in sys.databases and in msdb.

    Numbers, not message text: message text is localized, and a classifier that fails to
    match falls through to "I cannot tell", which for a multi-terabyte database has
    historically meant restoring it all over again.
#>

Set-StrictMode -Version Latest

#region ── Reading backup media ──────────────────────────────────────────────

function Get-DagDiskClause {
    param([Parameter(Mandatory)][string[]]$Files)
    ($Files | ForEach-Object { "DISK = $(ConvertTo-DagQuotedString $_)" }) -join ', '
}

function Get-DagBackupHeader {
    <#
    .SYNOPSIS
        RESTORE HEADERONLY for a (possibly striped) backup set.
    .DESCRIPTION
        Columns are read by NAME, never by ordinal: RESTORE HEADERONLY has gained
        columns in most releases, so ordinal access breaks across versions.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Files
    )

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'read backup header' -QueryTimeout 600 `
        -Query "RESTORE HEADERONLY FROM $(Get-DagDiskClause $Files)"
    if (-not $rows) { return $null }

    # A media set may hold several backup sets; the newest is the one we care about.
    $r = $rows | Sort-Object { [datetime]$_.BackupFinishDate } | Select-Object -Last 1

    [pscustomobject]@{
        Files                = $Files
        DatabaseName         = [string]$r.DatabaseName
        BackupTypeCode       = [int]$r.BackupType          # 1 = full, 2 = log, 5 = differential
        BackupTypeName       = switch ([int]$r.BackupType) { 1 { 'FULL' } 2 { 'LOG' } 5 { 'DIFF' } default { "TYPE$($r.BackupType)" } }
        IsCopyOnly           = ([int]$r.IsCopyOnly -eq 1)
        FirstLSN             = [decimal]$r.FirstLSN
        LastLSN              = [decimal]$r.LastLSN
        CheckpointLSN        = [decimal]$r.CheckpointLSN
        DatabaseBackupLSN    = [decimal]$r.DatabaseBackupLSN
        BackupFinishDate     = [datetime]$r.BackupFinishDate
        RecoveryForkID       = [string]$r.RecoveryForkID
        # Constant across the lifetime of one database lineage. A database dropped and
        # recreated under the same name gets a new FamilyGUID, which is the only reliable
        # way to tell its backups apart from the previous incarnation's.
        FamilyGUID           = [string]$r.FamilyGUID
        BackupSetGUID        = [string]$r.BackupSetGUID
        SoftwareVersionMajor = [int]$r.SoftwareVersionMajor
        CompressedSizeBytes  = [long]$r.CompressedBackupSize
    }
}

function Get-DagBackupFileList {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Files
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'read backup file list' -QueryTimeout 600 `
        -Query "RESTORE FILELISTONLY FROM $(Get-DagDiskClause $Files)"
    foreach ($r in $rows) {
        [pscustomobject]@{
            LogicalName  = [string]$r.LogicalName
            PhysicalName = [string]$r.PhysicalName
            Type         = [string]$r.Type       # D = data, L = log, S = FILESTREAM/memory-optimized
        }
    }
}

#endregion

#region ── Target-side restore state ─────────────────────────────────────────

function Get-DagLastRestoredLsn {
    <#
    .SYNOPSIS
        Highest last_lsn restored into $DatabaseName on $Instance, or $null if unknown.

    .DESCRIPTION
        Read from the target's own msdb restore history. This can CONFIRM that a restore
        happened; it can never DENY it. Two reasons, and both of them have produced
        endless re-restores of multi-terabyte databases in the wild:

          * A row appears only when a restore COMMITS. A large RESTORE spends a long time
            after percent_complete reaches 100 — zeroing the log file, then recovering —
            and for that entire window the history is silent even though the restore is
            healthy and running.
          * Restore history is purged by routine maintenance (sp_delete_backuphistory is
            in every maintenance solution), so it can go silent about a restore that
            completed perfectly well hours earlier.

        Callers must therefore treat $null as "unknown", never as "not restored".
        Test-DagFullBackupApplied is what actually decides.

    .PARAMETER FamilyGuid
        When supplied, only history belonging to this backup family counts. A database
        dropped and recreated under the same name leaves behind history whose LSNs are
        meaningless — and potentially higher — for the current lineage.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string]$FamilyGuid
    )

    $familyClause = if ($FamilyGuid) { "  AND bs.family_guid = $(ConvertTo-DagQuotedString $FamilyGuid)" } else { '' }

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'read restore history' -Query @"
SELECT MAX(bs.last_lsn) AS LastLsn
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset      AS bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = $(ConvertTo-DagQuotedString $DatabaseName)
$familyClause
"@
    if (-not $rows -or $rows[0].LastLsn -is [System.DBNull]) { return $null }
    return [decimal]$rows[0].LastLsn
}

function Get-DagDatabaseFamilyGuid {
    <#
    .SYNOPSIS
        Backup family of the database as it currently sits on $Instance, or $null.
    .DESCRIPTION
        sys.database_recovery_status is one of the few catalog views that remains readable
        while a database is RESTORING, which is exactly the state we need to interrogate.
        A family that does not match the backup we are about to restore means the copy on
        the target descends from a different lineage entirely.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    try {
        return Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(drs.family_guid AS nvarchar(64)) AS v
FROM sys.database_recovery_status AS drs
JOIN sys.databases AS d ON d.database_id = drs.database_id
WHERE d.name = $(ConvertTo-DagQuotedString $DatabaseName)
"@
    } catch {
        return $null
    }
}

# Where the restored files land is a decision the operator makes in the interview, not one
# this engine improvises. Get-DagRestoreMoveClause lives in DagFileLayout.ps1.

#endregion

#region ── Taking backups ────────────────────────────────────────────────────

function New-DagFullBackup {
    <#
    .SYNOPSIS
        Non-copy-only, compressed, checksummed FULL backup striped across N files.
    .OUTPUTS
        string[] — the stripe paths written.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Directory,
        [int]$StripeCount = 4
    )

    New-DagRemoteDirectory -Instance $Instance -Path $Directory

    $token = Get-DagSafeFileToken $DatabaseName
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $files = 1..$StripeCount | ForEach-Object {
        Join-DagPath -Path $Directory -ChildPath @('{0}_FULL_{1}_{2:00}of{3:00}.bak' -f $token, $stamp, $_, $StripeCount)
    }

    # MAXTRANSFERSIZE above 64 KB is what makes COMPRESSION legal on TDE databases and
    # materially improves throughput to a UNC target for large databases.
    $sql = @"
BACKUP DATABASE $(ConvertTo-DagQuotedName $DatabaseName)
TO $(Get-DagDiskClause $files)
WITH FORMAT, INIT, COMPRESSION, CHECKSUM, STATS = 5,
     MAXTRANSFERSIZE = 4194304,
     DESCRIPTION = N'Initialize-DAG seed full backup';
"@
    Invoke-DagLongOp -Instance $Instance -Query $sql -Activity "FULL backup of [$DatabaseName] on $Instance ($StripeCount stripes)"
    return @($files)
}

function New-DagLogBackup {
    <#
    .SYNOPSIS
        Compressed transaction log backup to a single timestamped file.
    .OUTPUTS
        string — the file written.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Directory,
        [string]$Suffix = ''
    )

    New-DagRemoteDirectory -Instance $Instance -Path $Directory

    $token = Get-DagSafeFileToken $DatabaseName
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss_fff')
    $name  = if ($Suffix) { '{0}_LOG_{1}_{2}.trn' -f $token, $stamp, $Suffix } else { '{0}_LOG_{1}.trn' -f $token, $stamp }
    $file  = Join-DagPath -Path $Directory -ChildPath @($name)

    $sql = @"
BACKUP LOG $(ConvertTo-DagQuotedName $DatabaseName)
TO DISK = $(ConvertTo-DagQuotedString $file)
WITH COMPRESSION, CHECKSUM, STATS = 10,
     DESCRIPTION = N'Initialize-DAG seed log backup';
"@
    Invoke-DagLongOp -Instance $Instance -Query $sql -Activity "LOG backup of [$DatabaseName] on $Instance"
    return $file
}

#endregion

#region ── Restoring ─────────────────────────────────────────────────────────

function Test-DagFullBackupApplied {
    <#
    .SYNOPSIS
        Is the FULL backup described by $Header already applied to [$DatabaseName] on $Instance?

    .OUTPUTS
        $true   the FULL is applied; the database is ready to take log backups
        $false  it is not; a FULL restore is required
        $null   it cannot be determined from the evidence available

    .DESCRIPTION
        The question this answers is the one that decides whether we spend another nine
        hours, so it is answered by SQL Server rather than by our own bookkeeping.

        The decisive test is to attempt a RESTORE LOG from this backup's own chain and
        read the error number. SQL Server's response distinguishes the two states that no
        catalog view distinguishes — "the FULL landed" and "the FULL did not finish" —
        because the engine is the only thing that knows whether it has files ready to
        roll forward:

            4319  a previous restore was interrupted and did not complete processing on
                  file X -> the FULL did not complete. This is the one that matters. A
                  restore killed in its tail phase — after percent_complete reached 100,
                  while it was still zeroing the log — leaves exactly this, and the
                  database sits in RESTORING looking for all the world like a good copy.
            3117  no files are ready to rollforward -> nothing usable was restored at all
            4326  log too early to apply            -> the FULL landed; we are past this log
            4305  log too recent to apply           -> the FULL landed; the chain has a gap
            3154  different backup family           -> not this database's chain at all
            success                                 -> the FULL landed (and we applied a log)

        This is the same "attempt and classify" idiom Restore-DagLogChain already relies
        on, and it is authoritative in a way that reading restore history never is.
        Applying a log as a side effect is harmless: it is WITH NORECOVERY, it belongs to
        the chain, and it is work the very next step would do anyway.

    .PARAMETER ProbeLogFiles
        Log backups from this database's chain, oldest first. Without at least one the
        decisive test cannot run, and the answer is $null rather than a guess.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][psobject]$Header,
        [string[]]$ProbeLogFiles = @()
    )

    # Fast path: history can confirm, and confirmation is all we take from it.
    $lsn = Get-DagLastRestoredLsn -Instance $Instance -DatabaseName $DatabaseName -FamilyGuid $Header.FamilyGUID
    if ($null -ne $lsn -and $lsn -ge $Header.LastLSN) {
        Write-DagLog "  [$Instance] restore history: [$DatabaseName] is at LSN $lsn (>= $($Header.LastLSN)) — FULL is applied" DEBUG
        return $true
    }

    # A copy from another lineage is not this backup, whatever state it is in.
    $family = Get-DagDatabaseFamilyGuid -Instance $Instance -DatabaseName $DatabaseName
    if ($family -and $Header.FamilyGUID -and $family -ne $Header.FamilyGUID) {
        Write-DagLog "  [$Instance] [$DatabaseName] belongs to a different backup family than this FULL — it is not this backup" INFO
        return $false
    }

    foreach ($f in $ProbeLogFiles) {
        $leaf = Split-Path $f -Leaf
        try {
            Invoke-DagLongOp -Instance $Instance -Activity "probing [$DatabaseName] on $Instance with $leaf" -Query @"
RESTORE LOG $(ConvertTo-DagQuotedName $DatabaseName)
FROM DISK = $(ConvertTo-DagQuotedString $f)
WITH NORECOVERY, STATS = 25;
"@
            Write-DagLog "  [$Instance] $leaf applied — the FULL is present underneath it" DEBUG
            return $true
        } catch {
            $nums = @(Get-DagSqlErrorNumber -ErrorRecord $_)
            $first = $_.Exception.Message.Split("`n")[0]

            if ($nums -contains 4319 -or $nums -contains 3117) {
                Write-DagLog "  [$Instance] SQL Server reports the restore of [$DatabaseName] was interrupted and did not complete — the FULL must be restored." INFO
                Write-DagLog "    $first" DEBUG
                return $false
            }
            if ($nums -contains 4326) {
                Write-DagLog "  [$Instance] $leaf is too early to apply — the FULL is applied and we are past it" DEBUG
                return $true
            }
            if ($nums -contains 4305) {
                Write-DagLog "  [$Instance] $leaf is too recent to apply — the FULL is applied, but the log chain has a gap" DEBUG
                return $true
            }
            # Not part of this chain at all. Try the next candidate.
            if ($nums -contains 3154) { continue }

            Write-DagLog "  [$Instance] probe with $leaf was inconclusive (SQL error $($nums -join ', ')): $first" DEBUG
        }
    }

    return $null
}

function Restore-DagFullBackup {
    <#
    .SYNOPSIS
        Restores a striped FULL backup WITH NORECOVERY onto one replica, idempotently.

    .DESCRIPTION
        Re-restoring a multi-terabyte FULL is the most expensive and most destructive
        thing this tool can do, so it is never what happens when a check comes back
        uncertain. Three rules, in order:

          1. A database that is ONLINE on the target is somebody else's data. Refuse.
          2. Whether the FULL is already applied is decided by Test-DagFullBackupApplied,
             which asks the engine. When even that cannot answer, the run stops and says
             so — it does not restore on a guess.
          3. A FULL we recorded as COMPLETED on this replica, which SQL Server now says
             is not applied, is not a restore to retry. Something is undoing it, and
             reissuing it is precisely the endless loop this guard exists to break.

        Nothing here ever emits WITH REPLACE. REPLACE is what turns SQL Server's own
        refusal to overwrite a database into silent destruction of a nearly-finished
        restore, and it is the single flag that converts a stall into an infinite loop.

    .PARAMETER Plan
        Carries the operator's chosen file layout, and enables the restore receipt and the
        loop breaker in rule 3.

    .PARAMETER ProbeLogFiles
        Log backups from this chain, oldest first, used to prove the state of the FULL.

    .PARAMETER Force
        Restore even when the state is unprovable or a completed receipt exists. This is
        the operator asserting that the copy on the target is unusable.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [Parameter(Mandatory)][psobject]$Header,
        [psobject]$Plan,
        [string[]]$ProbeLogFiles = @(),
        [switch]$Force
    )

    if ($Header.SoftwareVersionMajor -gt $InstanceInfo.MajorVersion) {
        throw ("Backup of [{0}] was taken on SQL major version {1} but '{2}' is major version {3}. " -f `
                $DatabaseName, $Header.SoftwareVersionMajor, $Instance, $InstanceInfo.MajorVersion) +
              'A database cannot be restored onto an older version of SQL Server.'
    }

    $state = Get-DagDatabaseState -Instance $Instance -DatabaseName $DatabaseName

    if ($state -and $state.StateDesc -eq 'ONLINE') {
        throw ("Database [{0}] already exists and is ONLINE on '{1}'. " -f $DatabaseName, $Instance) +
              'Refusing to overwrite it. Drop or rename it, then re-run.'
    }

    $rec = if ($Plan) { Get-DagProgress -Plan $Plan -DatabaseName $DatabaseName } else { $null }

    #region The database is already there — decide what it is before touching it
    if ($state) {
        $applied = Test-DagFullBackupApplied -Instance $Instance -DatabaseName $DatabaseName `
                        -Header $Header -ProbeLogFiles $ProbeLogFiles

        if ($applied -eq $true) {
            Write-DagLog "  [$Instance] FULL already applied to [$DatabaseName] — skipping" SUCCESS
            if ($rec) {
                $done = Get-DagRestoreReceipt -Record $rec -Replica $Instance -BackupSetGuid $Header.BackupSetGUID
                if (-not $done) {
                    $done = New-DagRestoreReceipt -Replica $Instance -BackupSetGuid $Header.BackupSetGUID -LastLsn ([string]$Header.LastLSN)
                }
                if (-not $done.CompletedUtc) {
                    $done.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    Set-DagRestoreReceipt -Plan $Plan -Record $rec -Receipt $done
                }
            }
            return
        }

        if ($null -eq $applied -and -not $Force) {
            throw @"
Cannot determine whether the FULL backup of [$DatabaseName] has already been restored to '$Instance'.

The database is present there in $($state.StateDesc) state, but:
  * its restore history holds no record of this backup set, and
  * no log backup from this chain was available to prove the state of the restore.

Restoring the FULL again would overwrite it and, at $(Format-DagBytes $Header.CompressedSizeBytes) compressed,
could take hours — so this script will not do it on a guess.

Let the log backup job produce at least one log for this chain and re-run: that is enough
for SQL Server to tell us definitively whether the FULL is applied. If you are certain the
copy on '$Instance' is unusable, re-run with -Force to restore it again.
"@
        }

        if ($null -eq $applied) {
            Write-DagLog "  [$Instance] state of [$DatabaseName] is unprovable, but -Force was supplied — restoring anyway." WARN
        }
    }
    #endregion

    #region Loop breaker
    if ($rec) {
        $prior = Get-DagRestoreReceipt -Record $rec -Replica $Instance -BackupSetGuid $Header.BackupSetGUID
        if ($prior -and $prior.CompletedUtc -and -not $Force) {
            throw @"
Refusing to restore the same FULL backup of [$DatabaseName] to '$Instance' a second time.

This exact backup set was restored there and recorded as completed at $($prior.CompletedUtc),
yet SQL Server now reports that it is not applied. Restoring it again is what turns this
into an endless loop, so the run stops here instead.

Something is undoing the restore between attempts. In order of likelihood:
  * The restore is being rolled back. A killed session or a dropped connection aborts a
    RESTORE, and on a large database both the rollback and the tail of the restore run
    long after percent_complete reaches 100 — so an aborted restore can look finished.
  * Another process is dropping or restoring [$DatabaseName] on '$Instance'.
  * Automatic seeding is also trying to seed this database and is removing the copy.
    Confirm SEEDING_MODE is MANUAL on every replica of both availability groups.

Read the SQL Server error log on '$Instance' before re-running; it will name the cause.
Re-run with -Force to restore it again anyway.
"@
        }
        if ($prior -and $prior.StartedUtc -and -not $prior.CompletedUtc) {
            Write-DagLog "  [$Instance] a previous restore of this FULL was interrupted at $($prior.StartedUtc) — restoring again." INFO
        }
    }
    #endregion

    $moves = @(Get-DagRestoreMoveClause -Instance $Instance -Files $Files -DatabaseName $DatabaseName `
                -InstanceInfo $InstanceInfo -Plan $Plan)

    # Written before the restore starts, so an interruption is distinguishable afterwards
    # from a completion. Nothing else can tell those two apart.
    $receipt = $null
    if ($rec) {
        $receipt = New-DagRestoreReceipt -Replica $Instance -BackupSetGuid $Header.BackupSetGUID -LastLsn ([string]$Header.LastLSN)
        Set-DagRestoreReceipt -Plan $Plan -Record $rec -Receipt $receipt
    }

    $sql = @"
RESTORE DATABASE $(ConvertTo-DagQuotedName $DatabaseName)
FROM $(Get-DagDiskClause $Files)
WITH NORECOVERY, STATS = 5,
     $($moves -join ",`r`n     ");
"@
    Invoke-DagLongOp -Instance $Instance -Query $sql -Activity "RESTORE FULL [$DatabaseName] -> $Instance (NORECOVERY)"

    if ($receipt) {
        $receipt.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Set-DagRestoreReceipt -Plan $Plan -Record $rec -Receipt $receipt
    }
}

function Restore-DagLogChain {
    <#
    .SYNOPSIS
        Applies every log backup in $LogDirectory that the target still needs,
        in LSN order, WITH NORECOVERY.

    .OUTPUTS
        int — the number of log backups actually applied.

    .DESCRIPTION
        Ordering comes from each backup's FirstLSN (read from the media), never from
        the file name — a clock skew or a rename must not be able to corrupt the chain.
        SQL Server's own 4326/4305 responses are the final authority on what applies.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$HeaderReadInstance,
        [datetime]$NotBefore = [datetime]::MinValue,
        [string]$FamilyGuid
    )

    $files = @(Get-DagRemoteFile -Instance $Instance -Path $LogDirectory -Pattern '*.trn')
    if ($files.Count -eq 0) {
        Write-DagLog "  [$Instance] no log backups found in $LogDirectory" INFO
        return 0
    }

    # Cheap pre-filter: a log written before the full backup finished can never apply.
    $candidates = @($files | Where-Object {
        (-not $_.LastWriteTime) -or ($_.LastWriteTime -ge $NotBefore.AddHours(-1))
    })

    # A hint only. When msdb history is missing (cleared, or restored elsewhere) every log
    # is attempted and SQL Server's 4326 responses do the classifying. The last log may
    # then be re-applied, which is a no-op: it cannot move the recovery point past its own
    # LastLSN, so correctness never depends on this value being present or accurate.
    $known = Get-DagLastRestoredLsn -Instance $Instance -DatabaseName $DatabaseName -FamilyGuid $FamilyGuid
    Write-DagLog "  [$Instance] [$DatabaseName] evaluating $($candidates.Count) log backup(s); current restored LSN: $(if ($null -ne $known) { $known } else { 'unknown' })" INFO

    # Read headers once, then order by FirstLSN.
    $headers = New-Object System.Collections.Generic.List[psobject]
    foreach ($f in $candidates) {
        try {
            $h = Get-DagBackupHeader -Instance $HeaderReadInstance -Files @($f.FullPath)
        } catch {
            Write-DagLog "  Skipping unreadable backup file '$($f.FullPath)': $($_.Exception.Message.Split("`n")[0])" WARN
            continue
        }
        if (-not $h) { continue }
        if ($h.BackupTypeCode -ne 2) { continue }                       # logs only
        if ($h.DatabaseName -ne $DatabaseName) { continue }             # someone else's logs sharing the folder

        # A database dropped and recreated under the same name leaves behind log backups
        # that pass the name check but belong to a different lineage. Restoring one fails
        # with error 3154 ("holds a backup of a database other than the existing ..."), so
        # match on the backup family instead of trusting the name.
        if ($FamilyGuid -and $h.FamilyGUID -and $h.FamilyGUID -ne $FamilyGuid) {
            Write-DagLog "  Ignoring '$($f.Name)': belongs to a previous incarnation of [$DatabaseName]" DEBUG
            continue
        }

        if ($null -ne $known -and $h.LastLSN -le $known) { continue }   # already applied
        $headers.Add($h)
    }

    if ($headers.Count -eq 0) {
        Write-DagLog "  [$Instance] [$DatabaseName] log chain already current — nothing to apply" SUCCESS
        return 0
    }

    $ordered = @($headers | Sort-Object FirstLSN)
    $applied = 0

    foreach ($h in $ordered) {
        $sql = @"
RESTORE LOG $(ConvertTo-DagQuotedName $DatabaseName)
FROM DISK = $(ConvertTo-DagQuotedString $h.Files[0])
WITH NORECOVERY, STATS = 25;
"@
        try {
            Invoke-DagLongOp -Instance $Instance -Query $sql -Activity "RESTORE LOG [$DatabaseName] -> $Instance ($(Split-Path $h.Files[0] -Leaf))"
            $applied++
        } catch {
            $nums = @(Get-DagSqlErrorNumber -ErrorRecord $_)
            $msg  = $_.Exception.Message
            $leaf = Split-Path $h.Files[0] -Leaf

            # 4326: this log ends before the database's current point — already applied.
            if ($nums -contains 4326) {
                Write-DagLog "  [$Instance] log $leaf already applied — skipping" DEBUG
                continue
            }
            # 3154: same database name, different lineage. Backstop for when no FamilyGUID
            # was supplied; the file is simply not part of this chain.
            if ($nums -contains 3154) {
                Write-DagLog "  [$Instance] ignoring ${leaf}: belongs to a different incarnation of [$DatabaseName]" WARN
                continue
            }
            # 4319 / 3117: the FULL underneath this chain never finished. Applying logs on
            # top of it is not the problem to solve, and the message SQL Server gives here
            # is opaque unless you already know what it means — so say it plainly.
            if ($nums -contains 4319 -or $nums -contains 3117) {
                throw ("Cannot restore logs onto [{0}] on '{1}': the FULL restore underneath them never completed.`r`n" -f $DatabaseName, $Instance) +
                      ($msg.Split("`n")[0] + "`r`n") +
                      'A restore that is interrupted after percent_complete reaches 100 — while it is still ' +
                      'zeroing the transaction log — leaves the database in RESTORING looking like a good copy. ' +
                      'It is not one. Re-run: the FULL will be restored again, which is correct here.'
            }
            # 4305: this log starts after the database's current point — a real gap.
            if ($nums -contains 4305) {
                throw ("Log chain gap restoring [{0}] on '{1}': {2}`r`n" -f $DatabaseName, $Instance, $msg.Split("`n")[0]) +
                      'A log backup is missing from the share. This usually means another job ' +
                      'is taking transaction log backups of this database to a different location. ' +
                      'Locate the missing log backup, or restart the seed with a fresh FULL backup.'
            }
            throw
        }
    }

    Write-DagLog "  [$Instance] [$DatabaseName] applied $applied log backup(s)" SUCCESS
    return $applied
}

#endregion
