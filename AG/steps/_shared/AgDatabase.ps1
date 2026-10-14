#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — which databases can join an availability group, what is stopping the rest,
    and the repairs this tool can make on the operator's behalf.

.DESCRIPTION
    Every user database is returned, eligible or not, so the interview can say WHY a database
    is missing from the menu instead of silently leaving it out. Problems fall into two kinds:

      Blockers   things only the operator should decide (the database is OFFLINE, READ_ONLY,
                 already in another AG, ONLINE under the same name on a secondary, encrypted
                 with a certificate a secondary does not have). The database is not offered.

      Fixable    prerequisites the tool can satisfy: FULL recovery, an established log chain
                 (a full backup), AUTO_CLOSE off. The database is offered, flagged with what
                 it needs, and the interview asks before changing anything.
#>

Set-StrictMode -Version Latest

function Get-AgCandidateDatabases {
    <#
    .PARAMETER Instance
        The (future) primary — where the databases live today.
    .PARAMETER Secondaries
        Replicas the databases will be copied to. Each is checked for a database of the same
        name, for the TDE certificate, and for FILESTREAM.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [string[]]$Secondaries = @(),
        [hashtable]$InstanceInfo = @{}
    )

    # The log chain is read from the database itself: sys.database_recovery_status reports a
    # NULL last_log_backup_lsn while a FULL-recovery database is still in pseudo-simple mode,
    # i.e. has never had the full backup that starts its chain. Backup history in msdb is
    # shown for information only — it is purged by maintenance and does not see backups
    # restored from elsewhere, so it can say nothing reliable about the chain.
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'database discovery' -Query @'
SELECT d.name                                    AS DatabaseName,
       d.recovery_model_desc                     AS RecoveryModel,
       d.state_desc                              AS StateDesc,
       CAST(d.is_read_only AS int)               AS IsReadOnly,
       CAST(d.is_auto_close_on AS int)           AS IsAutoClose,
       CAST(d.is_encrypted AS int)               AS IsEncrypted,
       CAST(CASE WHEN d.group_database_id IS NULL THEN 0 ELSE 1 END AS int) AS InAnAg,
       ISNULL(agname.name, '')                   AS CurrentAg,
       CAST(CASE WHEN drs.last_log_backup_lsn IS NULL THEN 0 ELSE 1 END AS int) AS HasLogChain,
       lastfull.FinishDate                       AS LastFullBackup,
       CAST(ISNULL(sz.SizeBytes, 0) AS bigint)   AS SizeBytes,
       CAST(ISNULL(fs.HasFilestream, 0) AS int)  AS HasFilestream,
       ISNULL(CONVERT(nvarchar(130), dek.encryptor_thumbprint, 1), '') AS TdeThumbprint,
       ISNULL(cert.name, '')                     AS TdeCertificate,
       d.containment_desc                        AS Containment
FROM sys.databases AS d
LEFT JOIN sys.database_recovery_status AS drs ON drs.database_id = d.database_id
OUTER APPLY (
    SELECT TOP 1 ag.name
    FROM sys.availability_databases_cluster AS adc
    JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
    WHERE adc.group_database_id = d.group_database_id
) AS agname
OUTER APPLY (
    SELECT MAX(b.backup_finish_date) AS FinishDate
    FROM msdb.dbo.backupset AS b
    WHERE b.database_name = d.name AND b.type = 'D'
) AS lastfull
OUTER APPLY (
    SELECT SUM(CAST(mf.size AS bigint)) * 8192 AS SizeBytes
    FROM sys.master_files AS mf WHERE mf.database_id = d.database_id
) AS sz
OUTER APPLY (
    SELECT TOP 1 1 AS HasFilestream
    FROM sys.master_files AS mf WHERE mf.database_id = d.database_id AND mf.type = 2
) AS fs
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = d.database_id
LEFT JOIN master.sys.certificates AS cert ON cert.thumbprint = dek.encryptor_thumbprint
WHERE d.database_id > 4
  AND d.source_database_id IS NULL            -- not a database snapshot
  AND d.name NOT IN (N'SSISDB', N'distribution')
ORDER BY d.name
'@
    if ($rows.Count -eq 0) { return @() }

    # Contained AG system databases (<AG>_master, <AG>_msdb) are user databases as far as
    # sys.databases is concerned, but belong to their AG and must never be offered.
    $containedSys = @()
    try {
        if (Get-AgColumnExists -Instance $Instance -View 'sys.availability_groups' -Column 'is_contained') {
            $cags = Invoke-AgSql -Instance $Instance -Retry -Activity 'contained AG names' `
                -Query 'SELECT name FROM sys.availability_groups WHERE is_contained = 1'
            $containedSys = @($cags | ForEach-Object { Get-AgContainedSystemDatabaseNames -AgName ([string]$_.name) })
        }
    } catch { }

    # A contained AG that was DROPPED leaves its <AG>_master and <AG>_msdb behind, ONLINE and
    # unattached, and nothing in the catalog marks them as system databases any more. A pair
    # of that shape is a contained AG's system databases waiting to be reused or dropped —
    # never something to seed as a user database.
    $names = @($rows | ForEach-Object { [string]$_.DatabaseName })
    $orphanSys = @{}
    foreach ($n in $names) {
        if ($n -match '^(.+)_master$' -and $names -contains "$($Matches[1])_msdb") {
            $orphanSys[$n] = $Matches[1]; $orphanSys["$($Matches[1])_msdb"] = $Matches[1]
        }
    }

    #region What each secondary already has
    $secState = @{}
    foreach ($s in $Secondaries) {
        $dbs = Invoke-AgSql -Instance $s -Retry -Activity 'secondary database scan' -Query @'
SELECT d.name AS DatabaseName, d.state_desc AS StateDesc,
       CAST(CASE WHEN d.group_database_id IS NULL THEN 0 ELSE 1 END AS int) AS InAnAg
FROM sys.databases AS d WHERE d.database_id > 4
'@
        $certs = Invoke-AgSql -Instance $s -Retry -Activity 'secondary certificate scan' `
            -Query 'SELECT CONVERT(nvarchar(130), thumbprint, 1) AS Thumbprint FROM master.sys.certificates'
        $secState[$s] = [pscustomobject]@{
            Databases   = @($dbs)
            Thumbprints = @($certs | ForEach-Object { [string]$_.Thumbprint })
        }
    }
    #endregion

    foreach ($r in $rows) {
        $name     = [string]$r.DatabaseName
        $blockers = New-Object System.Collections.Generic.List[string]
        $needs    = New-Object System.Collections.Generic.List[string]
        $leftover = New-Object System.Collections.Generic.List[psobject]

        if ($containedSys -contains $name) { continue }
        if ($orphanSys.ContainsKey($name)) {
            $blockers.Add("system database of the dropped contained AG [$($orphanSys[$name])] — reused when that AG is recreated with the same name")
        }

        if ($r.StateDesc -ne 'ONLINE')        { $blockers.Add("database is $($r.StateDesc), not ONLINE") }
        if ([int]$r.IsReadOnly -eq 1)         { $blockers.Add('database is READ_ONLY') }
        if ([int]$r.InAnAg -eq 1)             { $blockers.Add("already in availability group [$($r.CurrentAg)]") }

        $recovery = [string]$r.RecoveryModel
        if ($recovery -ne 'FULL')             { $needs.Add("$recovery -> FULL recovery") }
        if ([int]$r.HasLogChain -eq 0 -or $recovery -ne 'FULL') { $needs.Add('a full backup') }
        if ([int]$r.IsAutoClose -eq 1)        { $needs.Add('AUTO_CLOSE OFF') }

        $thumb = [string]$r.TdeThumbprint
        # Already in an AG: that one reason says everything, and its secondary copies are
        # that AG's own — checking them would only add noise.
        $checkSecondaries = if ([int]$r.InAnAg -eq 1) { @() } else { $Secondaries }
        foreach ($s in $checkSecondaries) {
            $copy = @($secState[$s].Databases | Where-Object { $_.DatabaseName -eq $name })
            if ($copy.Count -gt 0) {
                $c = $copy[0]
                if ([int]$c.InAnAg -eq 1) {
                    $blockers.Add("a copy on $s already belongs to an availability group")
                } elseif ($c.StateDesc -eq 'ONLINE') {
                    $blockers.Add("a different database of the same name is ONLINE on $s")
                } else {
                    $leftover.Add([pscustomobject]@{ Replica = $s; StateDesc = [string]$c.StateDesc })
                }
            }
            if ([int]$r.IsEncrypted -eq 1 -and $thumb -and ($secState[$s].Thumbprints -notcontains $thumb)) {
                $blockers.Add("TDE certificate [$($r.TdeCertificate)] is missing on $s (back it up with its private key and create it there)")
            }
            if ([int]$r.HasFilestream -eq 1 -and $InstanceInfo.ContainsKey($s) -and $InstanceInfo[$s].FilestreamLevel -eq 0) {
                $blockers.Add("uses FILESTREAM, which is not enabled on $s")
            }
        }

        [pscustomobject]@{
            DatabaseName    = $name
            RecoveryModel   = $recovery
            StateDesc       = [string]$r.StateDesc
            IsEncrypted     = ([int]$r.IsEncrypted -eq 1)
            TdeCertificate  = [string]$r.TdeCertificate
            HasLogChain     = ([int]$r.HasLogChain -eq 1)
            IsAutoClose     = ([int]$r.IsAutoClose -eq 1)
            LastFullBackup  = if ($r.LastFullBackup -is [System.DBNull]) { $null } else { [datetime]$r.LastFullBackup }
            SizeBytes       = [long]$r.SizeBytes
            Containment     = [string]$r.Containment
            NeedsFullRecovery = ($recovery -ne 'FULL')
            NeedsFullBackup   = ([int]$r.HasLogChain -eq 0 -or $recovery -ne 'FULL')
            NeedsAutoCloseOff = ([int]$r.IsAutoClose -eq 1)
            Needs           = @($needs.ToArray())
            LeftoverCopies  = @($leftover.ToArray())
            IsEligible      = ($blockers.Count -eq 0)
            IneligibleWhy   = ($blockers -join '; ')
        }
    }
}

function Format-AgCandidateLine {
    <#
    .SYNOPSIS
        One menu line per candidate: name, size, and what it still needs.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [int]$NameWidth = 32
    )
    $fmt   = '{0,-' + $NameWidth + '} {1,10}  {2}'
    $needs = if ($Candidate.Needs.Count -gt 0) { 'needs: ' + ($Candidate.Needs -join ', ') } else { 'ready' }
    if ($Candidate.LeftoverCopies.Count -gt 0) {
        $needs += '; leftover copy on ' + (($Candidate.LeftoverCopies | ForEach-Object { "$($_.Replica) ($($_.StateDesc))" }) -join ', ')
    }
    $fmt -f $Candidate.DatabaseName, (Format-AgBytes $Candidate.SizeBytes), $needs
}

#region ── Backup locations ──────────────────────────────────────────────────

function Get-AgDefaultBackupPath {
    <#
    .SYNOPSIS
        The instance's configured backup directory.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'default backup path' -Query @'
DECLARE @path nvarchar(512);
EXEC master.dbo.xp_instance_regread
     N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',
     N'BackupDirectory', @path OUTPUT;
SELECT @path AS v;
'@
    if (-not $rows -or $rows[0].v -is [System.DBNull] -or -not $rows[0].v) { return $null }
    return [string]$rows[0].v
}

function Get-AgRecentBackupDirectories {
    <#
    .SYNOPSIS
        Directories this instance has written disk backups to in the last 30 days, most used
        first — the operator's existing backup location is usually one of them.
    #>
    param([Parameter(Mandatory)][string]$Instance)
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'recent backup directories' -Query @'
SELECT TOP 5 LEFT(bmf.physical_device_name, LEN(bmf.physical_device_name) - CHARINDEX(N'\', REVERSE(bmf.physical_device_name))) AS Dir,
       COUNT(*) AS Uses
FROM msdb.dbo.backupmediafamily AS bmf
JOIN msdb.dbo.backupset AS bs ON bs.media_set_id = bmf.media_set_id
WHERE bmf.device_type = 2
  AND bs.backup_finish_date > DATEADD(DAY, -30, GETDATE())
  AND CHARINDEX(N'\', bmf.physical_device_name) > 0
  AND bmf.physical_device_name NOT LIKE N'%\_agprobe\%'
  AND bmf.physical_device_name NOT LIKE N'%\_dagprobe\%'
GROUP BY LEFT(bmf.physical_device_name, LEN(bmf.physical_device_name) - CHARINDEX(N'\', REVERSE(bmf.physical_device_name)))
ORDER BY COUNT(*) DESC
'@
    # The seeding layout <root>\<AG>\<Database>\FULL|LOG (this toolkit's and Initialize-DAG's)
    # is offered as the root it hangs off, not as one entry per database folder.
    $dirs = foreach ($r in $rows) {
        $d = [string]$r.Dir
        if ($d -match '^(.+)\\[^\\]+\\[^\\]+\\(FULL|LOG)$') { $d = $Matches[1] }
        $d
    }
    return @($dirs | Where-Object { $_ } | Select-Object -Unique)
}

#endregion

#region ── Repairs ───────────────────────────────────────────────────────────

function Test-AgLogChain {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $v = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(CASE WHEN drs.last_log_backup_lsn IS NULL THEN 0 ELSE 1 END AS int) AS v
FROM sys.database_recovery_status AS drs
JOIN sys.databases AS d ON d.database_id = drs.database_id
WHERE d.name = $(ConvertTo-AgQuotedString $DatabaseName)
"@
    return ([int]$v -eq 1)
}

function New-AgPrerequisiteBackup {
    <#
    .SYNOPSIS
        The full backup that takes a database out of pseudo-simple mode and starts its log
        chain. Not COPY_ONLY: a copy-only full deliberately leaves the chain alone.
    .OUTPUTS
        string — the backup file written.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Directory
    )
    New-AgRemoteDirectory -Instance $Instance -Path $Directory
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $file  = Join-AgPath -Path $Directory -ChildPath @('{0}_FULL_{1}.bak' -f (Get-AgSafeFileToken $DatabaseName), $stamp)
    Invoke-AgLongOp -Instance $Instance -Activity "FULL backup of [$DatabaseName] to $file" -Query @"
BACKUP DATABASE $(ConvertTo-AgQuotedName $DatabaseName)
TO DISK = $(ConvertTo-AgQuotedString $file)
WITH INIT, FORMAT, COMPRESSION, CHECKSUM, STATS = 10,
     DESCRIPTION = N'AG toolkit prerequisite full backup';
"@
    return $file
}

function Invoke-AgDatabaseRepair {
    <#
    .SYNOPSIS
        Applies the repairs the operator agreed to, for one database. Idempotent: every
        change re-reads the live setting first.
    .PARAMETER BackupDirectory
        Where the prerequisite full backup goes. $null means "do not take one" — manual
        seeding takes its own non-copy-only full, which starts the chain just the same.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [bool]$SetFullRecovery,
        [bool]$SetAutoCloseOff,
        [string]$BackupDirectory
    )

    $db = ConvertTo-AgQuotedName $DatabaseName
    $state = Invoke-AgSql -Instance $Instance -Retry -Activity 'repair check' -Query @"
SELECT recovery_model_desc AS RecoveryModel, CAST(is_auto_close_on AS int) AS IsAutoClose
FROM sys.databases WHERE name = $(ConvertTo-AgQuotedString $DatabaseName)
"@
    if ($state.Count -eq 0) { throw "Database [$DatabaseName] no longer exists on '$Instance'." }

    if ($SetFullRecovery -and $state[0].RecoveryModel -ne 'FULL') {
        Invoke-AgSql -Instance $Instance -QueryTimeout 120 -Activity 'set recovery FULL' `
            -Query "ALTER DATABASE $db SET RECOVERY FULL WITH NO_WAIT;" | Out-Null
        Write-AgLog "  [$DatabaseName] recovery model $($state[0].RecoveryModel) -> FULL" SUCCESS
    }
    if ($SetAutoCloseOff -and [int]$state[0].IsAutoClose -eq 1) {
        Invoke-AgSql -Instance $Instance -QueryTimeout 120 -Activity 'auto close off' `
            -Query "ALTER DATABASE $db SET AUTO_CLOSE OFF WITH NO_WAIT;" | Out-Null
        Write-AgLog "  [$DatabaseName] AUTO_CLOSE -> OFF" SUCCESS
    }
    if ($BackupDirectory) {
        if (Test-AgLogChain -Instance $Instance -DatabaseName $DatabaseName) {
            Write-AgLog "  [$DatabaseName] log chain already established — no prerequisite backup needed." SUCCESS
        } else {
            $file = New-AgPrerequisiteBackup -Instance $Instance -DatabaseName $DatabaseName -Directory $BackupDirectory
            if (-not (Test-AgLogChain -Instance $Instance -DatabaseName $DatabaseName)) {
                throw "[$DatabaseName] was backed up to '$file' but SQL Server still reports no log chain. Check that it is in FULL recovery."
            }
            Write-AgLog "  [$DatabaseName] full backup taken: $file" SUCCESS
        }
    }
}

#endregion

#region ── Leftover copies on secondaries ────────────────────────────────────

function Remove-AgDatabaseCopy {
    <#
    .SYNOPSIS
        Drops a non-ONLINE copy of a database on a replica (a RESTORING leftover of an earlier
        attempt, or a copy just removed from an AG).
    .DESCRIPTION
        Refuses an ONLINE database outright — that is somebody's data. A copy still joined to
        an AG is taken out with SET HADR OFF first, and the drop is retried briefly because the
        HADR worker can hold the database for a few seconds after it leaves the group.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $state = Get-AgDatabaseState -Instance $Instance -DatabaseName $DatabaseName
    if (-not $state) { return }
    if ($state.StateDesc -eq 'ONLINE' -and -not $state.IsJoinedToAg) {
        throw "Refusing to drop [$DatabaseName] on '$Instance': it is ONLINE and not part of an availability group."
    }
    $db = ConvertTo-AgQuotedName $DatabaseName
    if ($state.IsJoinedToAg) {
        try {
            Invoke-AgSql -Instance $Instance -QueryTimeout 120 -Activity 'set hadr off' -Query "ALTER DATABASE $db SET HADR OFF;" | Out-Null
        } catch {
            Write-AgLog "  [$Instance] SET HADR OFF on [$DatabaseName]: $($_.Exception.Message.Split("`n")[0])" DEBUG
        }
    }
    $ok = Wait-AgCondition -Activity "dropping [$DatabaseName] on $Instance" -TimeoutSeconds 120 -PollSeconds 5 -Condition {
        try {
            Invoke-AgSql -Instance $Instance -QueryTimeout 120 -Activity 'drop database copy' -Query "DROP DATABASE $db;" | Out-Null
        } catch {
            Write-AgLog "  [$Instance] drop [$DatabaseName] not yet possible: $($_.Exception.Message.Split("`n")[0])" DEBUG
        }
        return ($null -eq (Get-AgDatabaseState -Instance $Instance -DatabaseName $DatabaseName))
    }
    if (-not $ok) { throw "Could not drop [$DatabaseName] on '$Instance'. Check for sessions using it and drop it by hand." }
    Write-AgLog "  [$Instance] dropped [$DatabaseName]" SUCCESS
}

#endregion

#region ── Contained AG logins ───────────────────────────────────────────────

function Get-AgLoginsForDatabases {
    <#
    .SYNOPSIS
        Instance logins that users in the given databases map to (by SID), excluding the
        sysadmins — which a contained AG copies into its own master when it is created.
    .DESCRIPTION
        Once a database joins a contained AG, connections made through the AG's listener
        authenticate against the contained master. A login that exists only at the instance
        level stops working there, and the application's users find out first.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Databases
    )
    $all = New-Object System.Collections.Generic.List[psobject]
    foreach ($db in $Databases) {
        $rows = Invoke-AgSql -Instance $Instance -Database $db -Retry -Activity 'database user scan' -Query @'
SELECT sp.name AS LoginName, sp.type AS LoginType, CONVERT(nvarchar(200), sp.sid, 1) AS SidHex,
       sp.default_database_name AS DefaultDatabase,
       CONVERT(nvarchar(512), CAST(LOGINPROPERTY(sp.name, 'PasswordHash') AS varbinary(256)), 1) AS PasswordHashHex,
       CAST(sp.is_disabled AS int) AS IsDisabled
FROM sys.database_principals AS dp
JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE dp.type IN ('S','U','G')
  AND sp.type IN ('S','U','G')
  AND sp.name NOT LIKE N'##%'
  AND sp.name <> N'sa'
  AND ISNULL(IS_SRVROLEMEMBER('sysadmin', sp.name), 0) = 0
'@
        foreach ($r in $rows) { $all.Add($r) }
    }
    return @($all | Group-Object LoginName | ForEach-Object {
        $r = $_.Group[0]
        [pscustomobject]@{
            LoginName       = [string]$r.LoginName
            LoginType       = [string]$r.LoginType
            SidHex          = [string]$r.SidHex
            DefaultDatabase = [string]$r.DefaultDatabase
            PasswordHashHex = if ($r.PasswordHashHex -is [System.DBNull]) { $null } else { [string]$r.PasswordHashHex }
            IsDisabled      = ([int]$r.IsDisabled -eq 1)
        }
    })
}

function Copy-AgLoginToContainedAg {
    <#
    .SYNOPSIS
        Creates instance logins inside a contained AG's own master, keeping SID and password
        hash, so database users stay mapped and passwords keep working.
    .DESCRIPTION
        Runs on a connection whose database is the contained master. Connecting to a database
        that belongs to a contained AG puts the session in that AG's environment, which is how
        CREATE LOGIN lands in <AG>_master rather than in the instance's master. Each login is
        checked for first, so a re-run creates only what is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][psobject[]]$Logins
    )
    $cmaster = (Get-AgContainedSystemDatabaseNames -AgName $AgName)[0]
    foreach ($l in $Logins) {
        $exists = Get-AgScalar -Instance $Instance -Database $cmaster -Query `
            "SELECT CAST(COUNT(*) AS int) AS v FROM sys.server_principals WHERE name = $(ConvertTo-AgQuotedString $l.LoginName)"
        if ([int]$exists -gt 0) {
            Write-AgLog "  [$AgName] login '$($l.LoginName)' already exists in the contained AG." SUCCESS
            continue
        }
        $name = ConvertTo-AgQuotedName $l.LoginName
        $sql = if ($l.LoginType -eq 'S') {
            if (-not $l.PasswordHashHex) { Write-AgLog "  [$AgName] '$($l.LoginName)': no password hash readable — skipped." WARN; continue }
            "CREATE LOGIN $name WITH PASSWORD = $($l.PasswordHashHex) HASHED, SID = $($l.SidHex), CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;"
        } else {
            "CREATE LOGIN $name FROM WINDOWS;"
        }
        if ($l.IsDisabled) { $sql += " ALTER LOGIN $name DISABLE;" }
        Invoke-AgSql -Instance $Instance -Database $cmaster -QueryTimeout 60 -Activity 'copy login to contained AG' -Query $sql | Out-Null
        Write-AgLog "  [$AgName] created login '$($l.LoginName)' in the contained AG." SUCCESS
    }
}

#endregion
