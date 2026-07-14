#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — where data and log files land when a database is restored.

.DESCRIPTION
    Manual seeding restores a backup taken on the global primary onto replicas that may
    have an entirely different drive layout. Which directories those files land in is a
    decision only the operator can make, so it is asked once, in the interview, and
    recorded in the plan:

      SOURCE         Reuse the file structure the database has today. The directories are
                     created on the target when they do not already exist.
      TARGETDEFAULT  Each target's own default data and log directory.
      CUSTOM         Directories — or the destination of every individual file — named by
                     the operator, per replica.

    Resolution happens at restore time against RESTORE FILELISTONLY rather than against
    the layout captured when the plan was built, so a file added to the database after
    planning still lands somewhere sensible instead of failing the restore.

    A plan written before this feature existed has no FileLayoutMode. Initialize-DAG.ps1
    asks for one before resuming rather than guessing, because the old behaviour — keep
    the source path when the directory happens to exist, silently relocate to the default
    when it does not — is precisely the ambiguity these modes exist to remove.
#>

Set-StrictMode -Version Latest

#region ── The target instance's own default directories ─────────────────────

function Get-DagDefaultPathText {
    <#
    .SYNOPSIS
        An instance default path rendered for display or as a prompt default, or '' when
        the instance does not report one. Never throws: this is used while asking, and a
        missing suggestion is not a reason to abandon the interview.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return '' }
    return ([string]$Value).TrimEnd('\')
}

function Get-DagInstanceDefaultPath {
    <#
    .SYNOPSIS
        The instance's default data or log directory — or a stop, when it has none.

    .DESCRIPTION
        SERVERPROPERTY('InstanceDefaultDataPath') is NULL on an instance where that default
        was never configured, and Invoke-Sqlcmd hands NULL back as [System.DBNull]. Cast to
        a string that is '', and the MOVE clause built from it reads MOVE ... TO '\MyDb.mdf'
        — a path with no drive, which SQL Server will restore somewhere nobody chose.

        Nothing downstream can tell that apart from a real answer, so it stops here instead.
    #>
    param(
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind
    )

    $raw  = if ($Kind -eq 'Data') { $InstanceInfo.DefaultDataPath } else { $InstanceInfo.DefaultLogPath }
    $path = Get-DagDefaultPathText $raw

    if (-not $path) {
        throw @"
'$($InstanceInfo.Instance)' reports no default $($Kind.ToLower()) file directory
(SERVERPROPERTY('InstanceDefault${Kind}Path') is NULL), so there is nowhere for this file
layout to put the restored files on that replica.

Re-run and name the directories yourself, or configure the instance's default
$($Kind.ToLower()) location.
"@
    }
    return $path
}

#endregion

#region ── Source-side discovery ─────────────────────────────────────────────

function Get-DagDatabaseFileLayout {
    <#
    .SYNOPSIS
        The files of one database as they exist on $Instance today.
    .DESCRIPTION
        FileType is normalised to the same single letters RESTORE FILELISTONLY uses
        (D data, L log, S FILESTREAM / full-text container) so that plan-time and
        restore-time resolution speak one language.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'database file layout' -Query @"
SELECT mf.name                        AS LogicalName,
       mf.physical_name               AS PhysicalName,
       mf.type_desc                   AS TypeDesc,
       CAST(mf.size AS bigint) * 8192 AS SizeBytes
FROM sys.master_files AS mf
JOIN sys.databases AS d ON d.database_id = mf.database_id
WHERE d.name = $(ConvertTo-DagQuotedString $DatabaseName)
ORDER BY CASE mf.type_desc WHEN 'ROWS' THEN 0 WHEN 'LOG' THEN 1 ELSE 2 END, mf.file_id
"@
    if (-not $rows) { throw "Database [$DatabaseName] has no files on '$Instance' — it does not exist there." }

    foreach ($r in $rows) {
        [pscustomobject]@{
            LogicalName  = [string]$r.LogicalName
            PhysicalName = [string]$r.PhysicalName
            FileType     = switch ([string]$r.TypeDesc) { 'ROWS' { 'D' } 'LOG' { 'L' } default { 'S' } }
            SizeBytes    = [long]$r.SizeBytes
        }
    }
}

function Get-DagRestoreTarget {
    <#
    .SYNOPSIS
        Every replica this run will RESTORE onto.
    .DESCRIPTION
        Always the forwarder replicas. The global secondaries join the list only when a
        selected database is not yet in the global primary AG, because manual seeding
        then has to restore it there too before it can be added.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Plan.ForwarderReplicas) { if (-not $targets.Contains($r)) { $targets.Add($r) } }

    $needsGlobal = $false
    foreach ($db in $Plan.Databases) {
        if (-not (Test-DagDatabaseInAg -Instance $Plan.GlobalPrimaryReplica -AgName $Plan.GlobalAgName -DatabaseName $db)) {
            $needsGlobal = $true
            break
        }
    }
    if ($needsGlobal) {
        foreach ($r in $Plan.GlobalSecondaries) { if (-not $targets.Contains($r)) { $targets.Add($r) } }
    }

    return @($targets.ToArray())
}

#endregion

#region ── Reading the choice ────────────────────────────────────────────────

function Read-DagDirectory {
    <#
    .SYNOPSIS
        Prompts for a directory, as the SQL Server SERVICE ACCOUNT will see it: a local
        path on the target (D:\SQLData) or a UNC path it can reach.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default
    )
    $value = Read-DagText -Prompt $Prompt -Default $Default `
        -Validate { param($v) $v -match '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)' } `
        -ValidationMessage 'Enter a rooted path as the target server sees it, such as D:\SQLData or \\fileserver\share.'
    return $value.TrimEnd('\')
}

function Get-DagDefaultFileTarget {
    <#
    .SYNOPSIS
        Where a file lands given a data directory and a log directory.
        A FILESTREAM / full-text entry is a CONTAINER (a directory), so it is named for
        the database and its logical file rather than keeping a file's leaf name.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][string]$PhysicalName,
        [Parameter(Mandatory)][string]$FileType,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    $base = if ($FileType -eq 'L') { $LogPath } else { $DataPath }
    if ($FileType -eq 'S') {
        return Join-DagPath -Path $base -ChildPath @("$(Get-DagSafeFileToken $DatabaseName)_$LogicalName")
    }
    return Join-DagPath -Path $base -ChildPath @([System.IO.Path]::GetFileName($PhysicalName))
}

function New-DagFileLayoutPlan {
    <#
    .SYNOPSIS
        The interview for the file layout. Returns { Mode; Entries }.
    .PARAMETER RestoreTargets
        The replicas that will be restored onto. CUSTOM prompts once per replica, because
        a lab and a production DR site rarely have the same drive letters.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceInstance,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string[]]$RestoreTargets
    )

    $sourceFiles = @{}
    foreach ($db in $Databases) {
        $sourceFiles[$db] = @(Get-DagDatabaseFileLayout -Instance $SourceInstance -DatabaseName $db)
    }

    $targetInfo = @{}
    foreach ($t in $RestoreTargets) {
        # Preflight says this properly, but preflight runs after the interview — and an
        # interview that dies here has thrown away every answer the operator just gave,
        # because the plan is not saved until it returns.
        if (-not (Test-DagConnection -Instance $t)) {
            throw "Cannot connect to replica '$t'. Every replica of both availability groups must be reachable."
        }
        $targetInfo[$t] = Get-DagInstanceInfo -Instance $t
    }

    Write-Host ''
    Write-Host "Database files as they are today on $SourceInstance" -ForegroundColor Cyan
    foreach ($db in $Databases) {
        foreach ($f in $sourceFiles[$db]) {
            Write-Host ('   {0,-24} {1,-24} {2}' -f $db, $f.LogicalName, $f.PhysicalName) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host 'Default directories on the replicas that will be restored onto' -ForegroundColor Cyan
    foreach ($t in $RestoreTargets) {
        $d = Get-DagDefaultPathText $targetInfo[$t].DefaultDataPath
        $l = Get-DagDefaultPathText $targetInfo[$t].DefaultLogPath
        if (-not $d) { $d = '(none reported)' }
        if (-not $l) { $l = '(none reported)' }
        Write-Host ('   {0,-24} data {1,-28} log {2}' -f $t, $d, $l) -ForegroundColor DarkGray
    }

    $choice = Read-DagChoice -Title 'Where should the data and log files land on those replicas?' -DefaultIndex 0 -Items @(
        'REUSE the layout above - the same directories, created on the target if they do not exist.'
        'TARGET DEFAULTS - each replica''s own default data and log directory.'
        'CHOOSE - name the directories, or the destination of every individual file, yourself.'
    )

    $mode = switch -Wildcard ($choice) {
        'REUSE*'  { 'SOURCE' }
        'TARGET*' { 'TARGETDEFAULT' }
        default   { 'CUSTOM' }
    }

    $entries = @()
    if ($mode -eq 'CUSTOM') {
        $entries = @(Read-DagCustomFileLayout -Databases $Databases -RestoreTargets $RestoreTargets `
                        -SourceFiles $sourceFiles -TargetInfo $targetInfo)
    }

    return [pscustomobject]@{
        Mode    = $mode
        Entries = @($entries)
    }
}

function Read-DagCustomFileLayout {
    <#
    .SYNOPSIS
        The CUSTOM branch: one entry per restore target, optionally with a destination
        recorded for every individual file.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string[]]$RestoreTargets,
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [Parameter(Mandatory)][hashtable]$TargetInfo
    )

    $fileCount = 0
    foreach ($db in $Databases) { $fileCount += @($SourceFiles[$db]).Count }

    $granularity = Read-DagChoice -Title 'How much of it do you want to specify?' -DefaultIndex 0 -Items @(
        'One data directory and one log directory, used on every replica.'
        'A data directory and a log directory PER replica.'
        ('The destination of EVERY file, per replica ({0} prompts).' -f ($fileCount * $RestoreTargets.Count))
    )

    # Even at the coarsest granularity every replica gets its own entry: the plan is the
    # thing the restore reads, and a per-replica entry keeps that lookup uniform.
    $sharedData = $null; $sharedLog = $null
    if ($granularity -like 'One data directory*') {
        $first = $RestoreTargets[0]
        Write-Host ''
        Write-Host 'These directories will be used on every replica being restored onto.' -ForegroundColor DarkGray
        $sharedData = Read-DagDirectory -Prompt 'Data file directory' -Default (Get-DagDefaultPathText $TargetInfo[$first].DefaultDataPath)
        $sharedLog  = Read-DagDirectory -Prompt 'Log file directory'  -Default (Get-DagDefaultPathText $TargetInfo[$first].DefaultLogPath)
    }

    $entries = New-Object System.Collections.Generic.List[psobject]

    foreach ($t in $RestoreTargets) {
        if ($sharedData) {
            $dataPath = $sharedData
            $logPath  = $sharedLog
        } else {
            Write-Host ''
            Write-Host "Directories on $t" -ForegroundColor Cyan
            $dataPath = Read-DagDirectory -Prompt "  Data file directory on $t" -Default (Get-DagDefaultPathText $TargetInfo[$t].DefaultDataPath)
            $logPath  = Read-DagDirectory -Prompt "  Log file directory on $t"  -Default (Get-DagDefaultPathText $TargetInfo[$t].DefaultLogPath)
        }

        $files = New-Object System.Collections.Generic.List[psobject]

        if ($granularity -like 'The destination of EVERY file*') {
            Write-Host ''
            Write-Host "Destination of each file on $t — ENTER accepts the suggested path." -ForegroundColor DarkGray
            foreach ($db in $Databases) {
                foreach ($f in @($SourceFiles[$db])) {
                    $suggest = Get-DagDefaultFileTarget -DatabaseName $db -LogicalName $f.LogicalName `
                                    -PhysicalName $f.PhysicalName -FileType $f.FileType `
                                    -DataPath $dataPath -LogPath $logPath
                    $kind = switch ($f.FileType) { 'D' { 'data' } 'L' { 'log' } default { 'container' } }
                    $target = Read-DagText -Prompt ("  [{0}] {1} ({2}, {3})" -f $db, $f.LogicalName, $kind, (Format-DagBytes $f.SizeBytes)) `
                                -Default $suggest `
                                -Validate { param($v) $v -match '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)' } `
                                -ValidationMessage 'Enter a rooted path as the target server sees it, such as D:\SQLData\MyDb.mdf.'
                    $files.Add([pscustomobject]@{
                        DatabaseName = $db
                        LogicalName  = $f.LogicalName
                        FileType     = $f.FileType
                        TargetPath   = $target
                    })
                }
            }
        }

        $entries.Add([pscustomobject]@{
            Replica  = $t
            DataPath = $dataPath
            LogPath  = $logPath
            Files    = @($files.ToArray())
        })
    }

    return @($entries.ToArray())
}

#endregion

#region ── Resolution ────────────────────────────────────────────────────────

function Get-DagFileLayoutMode {
    param([psobject]$Plan)
    if (-not $Plan) { return 'SOURCE' }
    if ($Plan.PSObject.Properties.Name -notcontains 'FileLayoutMode') { return 'SOURCE' }
    if (-not $Plan.FileLayoutMode) { return 'SOURCE' }
    return [string]$Plan.FileLayoutMode
}

function Get-DagFileLayoutEntry {
    <#
    .OUTPUTS
        The CUSTOM layout entry for one replica, or $null when none was recorded.
    #>
    param(
        [psobject]$Plan,
        [Parameter(Mandatory)][string]$Instance
    )
    if (-not $Plan) { return $null }
    if ($Plan.PSObject.Properties.Name -notcontains 'FileLayout') { return $null }
    $m = @($Plan.FileLayout | Where-Object { $_ -and $_.Replica -eq $Instance })
    if ($m.Count -gt 0) { return $m[0] }
    return $null
}

function Resolve-DagFileTarget {
    <#
    .SYNOPSIS
        The path one database file must be restored to on one replica.
    #>
    param(
        [psobject]$Plan,
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][string]$PhysicalName,
        [Parameter(Mandatory)][string]$FileType
    )

    $mode = Get-DagFileLayoutMode -Plan $Plan
    if ($mode -eq 'SOURCE') { return $PhysicalName }

    $entry = $null
    if ($mode -eq 'CUSTOM') {
        $entry = Get-DagFileLayoutEntry -Plan $Plan -Instance $Instance
        if ($entry) {
            # A file named individually wins outright. Anything else — including a file
            # added to the database after the plan was built — falls back to this
            # replica's chosen directories.
            $named = @($entry.Files | Where-Object { $_ -and $_.DatabaseName -eq $DatabaseName -and $_.LogicalName -eq $LogicalName })
            if ($named.Count -gt 0) { return [string]$named[0].TargetPath }
        } else {
            Write-DagLog "  [$Instance] the plan records no custom file layout for this replica — using its default data and log directories." WARN
        }
    }

    # The instance default is only consulted when nothing else answered, so an instance
    # that has no default only fails the runs that actually needed one.
    $dataPath = if ($entry -and $entry.DataPath) { [string]$entry.DataPath }
                else { Get-DagInstanceDefaultPath -InstanceInfo $InstanceInfo -Kind Data }
    $logPath  = if ($entry -and $entry.LogPath)  { [string]$entry.LogPath }
                else { Get-DagInstanceDefaultPath -InstanceInfo $InstanceInfo -Kind Log }

    return Get-DagDefaultFileTarget -DatabaseName $DatabaseName -LogicalName $LogicalName `
                -PhysicalName $PhysicalName -FileType $FileType -DataPath $dataPath -LogPath $logPath
}

function Get-DagTargetDirectory {
    <#
    .SYNOPSIS
        The directory that must exist before a file can be restored to $TargetPath.
    .DESCRIPTION
        The parent, for every file type. A data or log file needs the directory holding
        it; a FILESTREAM container is itself a directory, and RESTORE insists on creating
        it — so what has to be there beforehand is, again, its parent.
    #>
    param([Parameter(Mandatory)][string]$TargetPath)
    return [System.IO.Path]::GetDirectoryName($TargetPath.TrimEnd('\'))
}

function Get-DagRestoreMoveClause {
    <#
    .SYNOPSIS
        MOVE clauses relocating a backup's files onto one replica, per the plan's file
        layout, creating whatever directories that requires.

    .DESCRIPTION
        The file list is read from the backup media rather than from the plan, so the set
        of files is always the set the RESTORE will actually see. Directories are created
        before the clauses are handed back: RESTORE does not create them, and a missing
        directory is otherwise a failure hours into a large restore.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][psobject]$InstanceInfo,
        [psobject]$Plan
    )

    $fileList = @(Get-DagBackupFileList -Instance $Instance -Files $Files)
    $moves    = New-Object System.Collections.Generic.List[string]
    $dirs     = New-Object System.Collections.Generic.List[string]

    foreach ($f in $fileList) {
        $target = Resolve-DagFileTarget -Plan $Plan -Instance $Instance -InstanceInfo $InstanceInfo `
                    -DatabaseName $DatabaseName -LogicalName $f.LogicalName `
                    -PhysicalName $f.PhysicalName -FileType $f.Type

        $dir = Get-DagTargetDirectory -TargetPath $target
        if ($dir -and -not $dirs.Contains($dir)) { $dirs.Add($dir) }

        if ($target -ne $f.PhysicalName) {
            Write-DagLog "  [$Instance] MOVE '$($f.LogicalName)' -> $target" INFO
        } else {
            Write-DagLog "  [$Instance] '$($f.LogicalName)' keeps its current path: $target" DEBUG
        }
        $moves.Add("MOVE $(ConvertTo-DagQuotedString $f.LogicalName) TO $(ConvertTo-DagQuotedString $target)")
    }

    foreach ($d in $dirs) { New-DagRemoteDirectory -Instance $Instance -Path $d }

    return @($moves.ToArray())
}

#endregion

#region ── Validation and reporting ──────────────────────────────────────────

function Test-DagFileLayoutTarget {
    <#
    .SYNOPSIS
        Proves every directory the restores will need either exists on its replica or can
        be created there, before any data moves.

    .DESCRIPTION
        This is the check that makes REUSE safe. A source path of E:\SQLData on a target
        that has no E: drive is only discoverable by trying, and trying at restore time
        means finding out hours in. So it is tried here, with a message that names the
        alternatives.

        It also catches two files resolving to the SAME path on one replica — which the
        flattening modes make easy to do by accident, since two databases whose files live
        in different source directories can share a file NAME. SQL Server would refuse the
        second restore, but only after the full backup had been taken and shipped.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo
    )

    $mode    = Get-DagFileLayoutMode -Plan $Plan
    $targets = @(Get-DagRestoreTarget -Plan $Plan)
    if ($targets.Count -eq 0) { return }

    Write-DagLog "Validating file placement — $(Get-DagFileLayoutLabel $mode) — on: $($targets -join ', ')" INFO

    # The source layout does not vary by target, so it is read once per database rather
    # than once per database per replica.
    $sourceFiles = @{}
    foreach ($db in $Plan.Databases) {
        $sourceFiles[$db] = @(Get-DagDatabaseFileLayout -Instance $Plan.GlobalPrimaryReplica -DatabaseName $db)
    }

    foreach ($t in $targets) {
        $needed = New-Object System.Collections.Generic.List[string]
        $claims = @{}   # resolved path (case-insensitive) -> the file that claimed it

        foreach ($db in $Plan.Databases) {
            foreach ($f in $sourceFiles[$db]) {
                $target = Resolve-DagFileTarget -Plan $Plan -Instance $t -InstanceInfo $InstanceInfo[$t] `
                            -DatabaseName $db -LogicalName $f.LogicalName `
                            -PhysicalName $f.PhysicalName -FileType $f.FileType

                $key = $target.ToLowerInvariant()
                if ($claims.ContainsKey($key)) {
                    throw @"
Two database files would be restored to the same path on '$t':

  $target
    <- [$($claims[$key].Database)] $($claims[$key].LogicalName)   ($($claims[$key].Source))
    <- [$db] $($f.LogicalName)   ($($f.PhysicalName))

They collide because this file layout puts both in one directory and their file names are
identical, even though they are not in the same directory on $($Plan.GlobalPrimaryReplica).
SQL Server would restore the first and then refuse the second — after the full backup had
already been taken.

Re-run and give at least one of them a destination of its own.
"@
                }
                $claims[$key] = [pscustomobject]@{ Database = $db; LogicalName = $f.LogicalName; Source = $f.PhysicalName }

                $dir = Get-DagTargetDirectory -TargetPath $target
                if ($dir -and -not $needed.Contains($dir)) { $needed.Add($dir) }
            }
        }

        foreach ($dir in $needed) {
            $probe = Test-DagRemotePath -Instance $t -Path $dir
            if ($probe.IsDirectory) {
                Write-DagLog "  [$t] $dir exists." SUCCESS
                continue
            }

            try {
                New-DagRemoteDirectory -Instance $t -Path $dir
            } catch {
                throw @"
Replica '$t' cannot create the directory '$dir'.

  $($_.Exception.Message.Split("`n")[0])

The file layout you chose — $(Get-DagFileLayoutLabel $mode) — puts database files there, and
SQL Server cannot restore a file into a directory that does not exist. Usually the drive is
simply not present on '$t'.

Re-run and give '$t' somewhere it can actually write. Its own default data and log
directories always qualify.
"@
            }

            $probe = Test-DagRemotePath -Instance $t -Path $dir
            if (-not $probe.IsDirectory) {
                throw "Replica '$t' reported no error creating '$dir', but the directory still does not exist. Check the SQL Server service account's permissions on that path."
            }
            Write-DagLog "  [$t] created $dir" SUCCESS
        }
    }
}

function Get-DagFileLayoutLabel {
    param([string]$Mode)
    switch ($Mode) {
        'SOURCE'        { 'REUSE the source file structure' }
        'TARGETDEFAULT' { 'each target''s DEFAULT data and log directories' }
        'CUSTOM'        { 'CUSTOM directories' }
        default         { "unknown ($Mode)" }
    }
}

function Show-DagFileLayoutSummary {
    param([Parameter(Mandatory)][psobject]$Plan)

    $mode = Get-DagFileLayoutMode -Plan $Plan
    Write-Host "  Data / log files    : $(Get-DagFileLayoutLabel $mode)"

    if ($mode -ne 'CUSTOM') { return }

    foreach ($e in @($Plan.FileLayout)) {
        if (-not $e) { continue }
        Write-Host ("    {0,-22} data {1,-26} log {2}" -f $e.Replica, $e.DataPath, $e.LogPath)
        foreach ($f in @($e.Files)) {
            if (-not $f) { continue }
            Write-Host ("      {0}.{1} -> {2}" -f $f.DatabaseName, $f.LogicalName, $f.TargetPath) -ForegroundColor DarkGray
        }
    }
}

#endregion
