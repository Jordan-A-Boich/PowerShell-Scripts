#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — backup and restore engine for manual seeding.

.DESCRIPTION
    Designed for multi-terabyte databases, where a re-run must never mean
    "start the 9-hour full backup again". Every decision is driven by LSNs read
    from the backup media and from the target's restore history, so the tool can
    resume from whatever state an interrupted run left behind.

    Log-chain restore is deliberately "attempt and classify": we ask SQL Server to
    apply each log and interpret its own errors —
        4326  the log ends too early  -> already applied, skip it
        4305  the log starts too late -> a genuine gap, stop and report
    This is authoritative in a way that comparing our own bookkeeping never is.
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
        Read from the target's own msdb restore history. Treated as a hint that lets us
        skip work quickly; correctness never depends on it, because the restore loop
        also classifies SQL Server's own 4326/4305 responses.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'read restore history' -Query @"
SELECT TOP 1 bs.last_lsn AS LastLsn
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset      AS bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = $(ConvertTo-DagQuotedString $DatabaseName)
ORDER BY rh.restore_history_id DESC
"@
    if (-not $rows -or $rows[0].LastLsn -is [System.DBNull]) { return $null }
    return [decimal]$rows[0].LastLsn
}

function Get-DagRestoreMoveClause {
    <#
    .SYNOPSIS
        Builds MOVE clauses relocating a backup's files onto the target's layout.
    .DESCRIPTION
        A file keeps its original path when that directory already exists on the target
        (the common same-layout case). Otherwise it moves to the target instance's
        default data/log directory. This is what lets the same backup restore onto
        replicas whose drive letters differ.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$DefaultDataPath,
        [Parameter(Mandatory)][string]$DefaultLogPath
    )

    $fileList = Get-DagBackupFileList -Instance $Instance -Files $Files
    $moves    = New-Object System.Collections.Generic.List[string]
    $dirCache = @{}

    foreach ($f in $fileList) {
        $srcDir  = [System.IO.Path]::GetDirectoryName($f.PhysicalName)
        $srcLeaf = [System.IO.Path]::GetFileName($f.PhysicalName)

        if (-not $dirCache.ContainsKey($srcDir)) {
            $probe = Test-DagRemotePath -Instance $Instance -Path $srcDir
            $dirCache[$srcDir] = $probe.IsDirectory
        }

        if ($dirCache[$srcDir]) {
            $target = $f.PhysicalName
        } else {
            $baseDir = if ($f.Type -eq 'L') { $DefaultLogPath } else { $DefaultDataPath }
            # FILESTREAM / memory-optimized containers are directories, not files.
            $target  = if ($f.Type -eq 'S') { Join-DagPath -Path $baseDir.TrimEnd('\') -ChildPath @("$(Get-DagSafeFileToken $DatabaseName)_$($f.LogicalName)") }
                       else                 { Join-DagPath -Path $baseDir.TrimEnd('\') -ChildPath @($srcLeaf) }
            Write-DagLog "  [$Instance] MOVE '$($f.LogicalName)' -> $target (source directory '$srcDir' not present)" DEBUG
        }

        $moves.Add("MOVE $(ConvertTo-DagQuotedString $f.LogicalName) TO $(ConvertTo-DagQuotedString $target)")
    }

    return @($moves.ToArray())
}

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

function Restore-DagFullBackup {
    <#
    .SYNOPSIS
        Restores a striped FULL backup WITH NORECOVERY onto one replica, idempotently.
    .DESCRIPTION
        Skips the restore when the target has already advanced to or past the backup's
        LastLSN — the resume path for an interrupted multi-TB seed. Refuses to touch a
        database that is ONLINE on the target, because that is somebody else's data.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [Parameter(Mandatory)][psobject]$Header
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

    if ($state -and $state.StateDesc -eq 'RESTORING') {
        $lsn = Get-DagLastRestoredLsn -Instance $Instance -DatabaseName $DatabaseName
        if ($null -ne $lsn -and $lsn -ge $Header.LastLSN) {
            Write-DagLog "  [$Instance] FULL already applied to [$DatabaseName] (restored LSN $lsn >= backup LSN $($Header.LastLSN)) — skipping" SUCCESS
            return
        }
    }

    $moves = @(Get-DagRestoreMoveClause -Instance $Instance -Files $Files -DatabaseName $DatabaseName `
                -DefaultDataPath $InstanceInfo.DefaultDataPath -DefaultLogPath $InstanceInfo.DefaultLogPath)

    $sql = @"
RESTORE DATABASE $(ConvertTo-DagQuotedName $DatabaseName)
FROM $(Get-DagDiskClause $Files)
WITH NORECOVERY, STATS = 5,
     $($moves -join ",`r`n     ");
"@
    Invoke-DagLongOp -Instance $Instance -Query $sql -Activity "RESTORE FULL [$DatabaseName] -> $Instance (NORECOVERY)"
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
    $known = Get-DagLastRestoredLsn -Instance $Instance -DatabaseName $DatabaseName
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
            $msg = $_.Exception.Message

            # 4326: this log ends before the database's current point — already applied.
            if ($msg -match 'too early to apply' -or $msg -match '\b4326\b') {
                Write-DagLog "  [$Instance] log $(Split-Path $h.Files[0] -Leaf) already applied — skipping" DEBUG
                continue
            }
            # 3154: same database name, different lineage. Backstop for when no FamilyGUID
            # was supplied; the file is simply not part of this chain.
            if ($msg -match 'holds a backup of a database other than') {
                Write-DagLog "  [$Instance] ignoring $(Split-Path $h.Files[0] -Leaf): belongs to a different incarnation of [$DatabaseName]" WARN
                continue
            }
            # 4305: this log starts after the database's current point — a real gap.
            if ($msg -match 'too recent to apply' -or $msg -match '\b4305\b') {
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
