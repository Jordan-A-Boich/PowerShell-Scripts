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
      CUSTOM         Directories chosen by the operator, at whichever precision the job
                     needs — see below.

    CUSTOM is the interesting one, because consolidating a sprawling source layout onto a
    tidier target is the usual reason to run this at all. It has two independent axes:

      PRECISION   ALL          one data directory and one log directory for everything
                  DATABASE     a data directory and a log directory per database
                  FILE         a directory per individual file

      REPLICA     shared       the same answers on every replica being restored onto
                  per-replica  answered separately for each one

    So a target AG with D:\Data, E:\Data and H:\Data for data and L:\Log and M:\Log for
    logs can send Database1's files to D:\Data + L:\Log and Database2's to H:\Data +
    M:\Log (DATABASE precision), or scatter one database's three data files across all
    three data locations (FILE precision).

    Directories are never typed blind. Each prompt is a numbered menu built from what the
    target replica actually has — the directories its databases already use, its instance
    defaults, folders that already exist on its volumes, and the volume roots themselves,
    each with free space — plus the option to type a path that does not exist yet.

    Resolution happens at restore time against RESTORE FILELISTONLY rather than against
    the layout captured when the plan was built, so a file added to the database after
    planning still lands somewhere sensible instead of failing the restore. The fallback
    chain is deliberate and total:

        a destination recorded for this exact file
          -> the directories recorded for its database
            -> the directories recorded for its replica
              -> the replica's instance defaults

    A plan written before this feature existed has no FileLayoutMode. Initialize-DAG.ps1
    asks for one before resuming rather than guessing, because the old behaviour — keep
    the source path when the directory happens to exist, silently relocate to the default
    when it does not — is precisely the ambiguity these modes exist to remove.
#>

Set-StrictMode -Version Latest

#region ── Optional-property access ──────────────────────────────────────────

function Get-DagOptionalProperty {
    <#
    .SYNOPSIS
        A property that may not be there, or $null.
    .DESCRIPTION
        Plan entries are round-tripped through JSON, and a plan written by an older
        version simply has no 'Databases' or 'TargetDirectory' member. Under
        Set-StrictMode -Version Latest, reading a property that does not exist is a
        terminating error rather than $null — so every optional read goes through here.
    #>
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $InputObject.$Name
}

#endregion

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

#region ── What a replica actually has: the path catalog ─────────────────────

<#
    A forwarder AG is required to be empty, so the directories its *databases* use are
    only ever the system databases' — which means discovery cannot stop there. The
    catalog therefore reports four kinds of candidate, in descending order of evidence:

      default  the instance's configured default for this kind of file
      inuse    a directory this instance already keeps this kind of file in
      folder   a directory that exists on one of its volumes but holds no database files
      volume   a volume root, for composing somewhere new

    'folder' is what finds a pre-created E:\Data on a forwarder that has never held a
    database. Free space comes along for the ride, because "which of these five
    directories" is usually really "which of these has room".
#>

$script:DagCatalogNoiseFolder = @(
    'windows', 'program files', 'program files (x86)', 'programdata', 'users'
    'system volume information', 'recovery', 'perflogs', 'documents and settings'
    'msocache', 'config.msi', 'inetpub', 'intel', 'amd', 'nvidia', 'drivers'
    'windows.old', 'onedrivetemp', 'boot', 'efi', 'temp', 'tmp', 'clusterstorage'
)

function Get-DagVolumeFreeSpace {
    <#
    .OUTPUTS
        Hashtable: upper-case drive letter -> free bytes. Empty when it cannot be read —
        free space decorates the menu, it never gates it.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $map = @{}
    try {
        # xp_fixeddrives' second column is literally named 'MB free'. Landing it in a
        # temp table with names of our own choosing beats quoting that everywhere.
        $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'volume free space' -QueryTimeout 60 -Query @'
CREATE TABLE #dagdrives (drive nvarchar(10), mbfree bigint);
INSERT INTO #dagdrives EXEC master.dbo.xp_fixeddrives;
SELECT drive AS Drive, mbfree AS MbFree FROM #dagdrives;
DROP TABLE #dagdrives;
'@
        foreach ($r in $rows) {
            $letter = ([string]$r.Drive).Trim().TrimEnd(':').ToUpperInvariant()
            if ($letter) { $map[$letter] = [long]$r.MbFree * 1MB }
        }
    } catch {
        Write-DagLog "  [$Instance] could not read volume free space (harmless): $($_.Exception.Message.Split("`n")[0])" DEBUG
    }
    return $map
}

function Get-DagVolumeFolder {
    <#
    .SYNOPSIS
        Top-level directories on one volume, minus the operating system's own.
    .DESCRIPTION
        One level only. Deeper walks on a populated volume cost real time and bury the
        handful of directories an operator would ever nominate, and the convention this
        is here to find — E:\Data, L:\Log — lives at the top.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Root,
        [int]$Limit = 12
    )

    $out = New-Object System.Collections.Generic.List[string]
    try {
        $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'enumerate folders' -QueryTimeout 120 `
            -Query "EXEC master.dbo.xp_dirtree $(ConvertTo-DagQuotedString $Root), 1, 0"
        foreach ($r in $rows) {
            $name = [string]$r.subdirectory
            if (-not $name) { continue }
            if ($script:DagCatalogNoiseFolder -contains $name.ToLowerInvariant()) { continue }
            if ($name.StartsWith('$')) { continue }
            $out.Add((Join-DagPath -Path $Root -ChildPath @($name)))
            if ($out.Count -ge $Limit) { break }
        }
    } catch {
        Write-DagLog "  [$Instance] could not enumerate folders on $Root (harmless): $($_.Exception.Message.Split("`n")[0])" DEBUG
    }
    return @($out.ToArray())
}

function Get-DagInstancePathCatalog {
    <#
    .SYNOPSIS
        Every directory on $Instance worth offering as a data or log destination.
    .OUTPUTS
        { Instance; InstanceInfo; DataPaths; LogPaths; FreeSpace } — each path list holds
        { Path; Origin; FileCount; FreeBytes; IsDefault }, best evidence first.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [psobject]$InstanceInfo
    )

    $info = $InstanceInfo
    if (-not $info) { $info = Get-DagInstanceInfo -Instance $Instance }
    $free = Get-DagVolumeFreeSpace -Instance $Instance

    # Directories this instance already keeps USER database files in, and how many are in
    # each. System databases are excluded deliberately: they put the SQL Server
    # installation directory and the tempdb location at the top of the list on every
    # instance, and neither is anywhere an operator would restore a user database.
    $inUse = @{ Data = @{}; Log = @{} }
    try {
        $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'existing file directories' -Query @'
SELECT mf.type_desc AS TypeDesc, mf.physical_name AS PhysicalName
FROM sys.master_files AS mf
WHERE mf.database_id > 4
'@
        foreach ($r in $rows) {
            $dir = [System.IO.Path]::GetDirectoryName(([string]$r.PhysicalName))
            if (-not $dir) { continue }
            $dir  = $dir.TrimEnd('\')
            $kind = if ([string]$r.TypeDesc -eq 'LOG') { 'Log' } else { 'Data' }
            $key  = $dir.ToLowerInvariant()
            if ($inUse[$kind].ContainsKey($key)) {
                $inUse[$kind][$key].FileCount++
            } else {
                $inUse[$kind][$key] = [pscustomobject]@{ Path = $dir; FileCount = 1 }
            }
        }
    } catch {
        Write-DagLog "  [$Instance] could not read existing file directories (harmless): $($_.Exception.Message.Split("`n")[0])" DEBUG
    }

    # Folders and volume roots, discovered once and offered for both kinds of file.
    $volumes = @($free.Keys | Sort-Object)
    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($v in $volumes) {
        foreach ($f in (Get-DagVolumeFolder -Instance $Instance -Root ('{0}:\' -f $v))) { $folders.Add($f) }
    }

    $defaults = @{
        Data = (Get-DagDefaultPathText $info.DefaultDataPath)
        Log  = (Get-DagDefaultPathText $info.DefaultLogPath)
    }

    $result = @{}
    foreach ($kind in 'Data', 'Log') {
        $seen  = @{}
        $items = New-Object System.Collections.Generic.List[psobject]

        # Order is the whole point: the directory this instance already uses for this kind
        # of file is the most likely right answer, and a bare volume root the least.
        $ordered = New-Object System.Collections.Generic.List[psobject]
        $ordered.Add([pscustomobject]@{ Path = $defaults[$kind]; Origin = 'default'; FileCount = 0 })
        foreach ($u in ($inUse[$kind].Values | Sort-Object -Property FileCount -Descending)) {
            $ordered.Add([pscustomobject]@{ Path = $u.Path; Origin = 'inuse'; FileCount = $u.FileCount })
        }
        foreach ($f in $folders) { $ordered.Add([pscustomobject]@{ Path = $f; Origin = 'folder'; FileCount = 0 }) }
        foreach ($v in $volumes) { $ordered.Add([pscustomobject]@{ Path = ('{0}:\' -f $v); Origin = 'volume'; FileCount = 0 }) }

        foreach ($cand in $ordered) {
            if (-not $cand.Path) { continue }
            $p = ([string]$cand.Path).TrimEnd('\')
            # A volume root trims to 'D:', which is not a directory any file can live in.
            if ($p -match '^[A-Za-z]:$') { $p = $p + '\' }
            $key = $p.ToLowerInvariant()

            if ($seen.ContainsKey($key)) {
                # Already offered with stronger evidence; only enrich what is there.
                if ($cand.Origin -eq 'default') { $seen[$key].IsDefault = $true }
                if ($cand.FileCount -gt $seen[$key].FileCount) { $seen[$key].FileCount = $cand.FileCount }
                continue
            }

            $bytes = $null
            if ($p -match '^([A-Za-z]):' -and $free.ContainsKey($Matches[1].ToUpperInvariant())) {
                $bytes = $free[$Matches[1].ToUpperInvariant()]
            }
            $entry = [pscustomobject]@{
                Path      = $p
                Origin    = $cand.Origin
                FileCount = [int]$cand.FileCount
                FreeBytes = $bytes
                IsDefault = ($cand.Origin -eq 'default')
            }
            $seen[$key] = $entry
            $items.Add($entry)
        }

        $result[$kind] = @($items.ToArray())
    }

    return [pscustomobject]@{
        Instance     = $Instance
        InstanceInfo = $info
        DataPaths    = $result['Data']
        LogPaths     = $result['Log']
        FreeSpace    = $free
    }
}

function Get-DagFreeSpaceText {
    param([AllowNull()]$FreeBytes)
    if ($null -eq $FreeBytes) { return 'free space unknown' }
    return ('{0} free' -f (Format-DagBytes $FreeBytes))
}

function Get-DagPathColumnWidth {
    <#
    .SYNOPSIS
        A column width that fits the paths actually being shown.
    .DESCRIPTION
        A fixed width either wastes half the line on short paths like D:\Data or is
        overrun by a real one, which pushes every annotation out of alignment and makes
        the list harder to read than no alignment at all. Capped, because one pathological
        path should not reflow the whole table.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Paths,
        [int]$Minimum = 18,
        [int]$Maximum = 46
    )
    $w = $Minimum
    foreach ($p in $Paths) {
        if ($p -and $p.Length -gt $w) { $w = $p.Length }
    }
    if ($w -gt $Maximum) { $w = $Maximum }
    return $w
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

function Get-DagFileKindLabel {
    param([Parameter(Mandatory)][string]$FileType)
    switch ($FileType) { 'D' { 'data' } 'L' { 'log' } default { 'container' } }
}

#endregion

#region ── Reading a directory: the numbered menu ────────────────────────────

$script:DagRootedPathPattern = '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)'

function Read-DagDirectory {
    <#
    .SYNOPSIS
        Prompts for a directory as free text, as the SQL Server SERVICE ACCOUNT will see
        it: a local path on the target (D:\SQLData) or a UNC path it can reach.
    .DESCRIPTION
        Kept for the cases a menu cannot cover — a directory that does not exist yet on a
        volume the instance cannot enumerate. Read-DagPathChoice is what the interview
        normally uses, and it falls through to this.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default
    )
    $value = Read-DagText -Prompt $Prompt -Default $Default `
        -Validate { param($v) $v -match $script:DagRootedPathPattern } `
        -ValidationMessage 'Enter a rooted path as the target server sees it, such as D:\SQLData or \\fileserver\share.'
    return $value.TrimEnd('\')
}

function Read-DagPathChoice {
    <#
    .SYNOPSIS
        Picks a directory on one replica from that replica's path catalog, by number.

    .DESCRIPTION
        Every candidate is annotated with where it came from and how much room is left on
        its volume, because the question an operator is really answering is "which of
        these has space and is meant for this kind of file". The last entry is always an
        escape hatch to type a path the instance has no knowledge of yet — preflight
        creates it, or fails naming the alternatives.

    .PARAMETER KeepPath
        Offered as "keep its current directory" when the file being placed has a source
        directory worth keeping. Makes partial relocation — move most, leave some — a
        single keystroke.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind,
        [string]$Default,
        [string]$KeepPath
    )

    $candidates = if ($Kind -eq 'Data') { @($Catalog.DataPaths) } else { @($Catalog.LogPaths) }

    $shown = New-Object System.Collections.Generic.List[string]
    if ($KeepPath) { $shown.Add($KeepPath.TrimEnd('\')) }
    foreach ($c in $candidates) { $shown.Add($c.Path) }
    $fmt = '{0,-' + (Get-DagPathColumnWidth -Paths @($shown.ToArray())) + '}  {1}'

    $items = New-Object System.Collections.Generic.List[psobject]
    $defaultIndex = -1

    if ($KeepPath) {
        $items.Add([pscustomobject]@{
            Path  = $KeepPath.TrimEnd('\')
            Label = ($fmt -f $KeepPath.TrimEnd('\'), 'keep the directory it has today')
        })
    }

    foreach ($c in $candidates) {
        if ($KeepPath -and $c.Path.TrimEnd('\').ToLowerInvariant() -eq $KeepPath.TrimEnd('\').ToLowerInvariant()) { continue }

        $notes = New-Object System.Collections.Generic.List[string]
        switch ($c.Origin) {
            'default' { $notes.Add(('default {0} location' -f $Kind.ToLower())) }
            'inuse'   { $notes.Add(('holds {0} database file(s)' -f $c.FileCount)) }
            'folder'  { $notes.Add('existing folder, empty') }
            'volume'  { $notes.Add('volume root') }
        }
        if ($c.IsDefault -and $c.Origin -ne 'default') { $notes.Add(('default {0} location' -f $Kind.ToLower())) }
        $notes.Add((Get-DagFreeSpaceText $c.FreeBytes))

        if ($Default -and $c.Path.TrimEnd('\').ToLowerInvariant() -eq $Default.TrimEnd('\').ToLowerInvariant()) {
            $defaultIndex = $items.Count
        }
        $items.Add([pscustomobject]@{
            Path  = $c.Path
            Label = ($fmt -f $c.Path, ($notes -join ' · '))
        })
    }

    if ($defaultIndex -lt 0 -and $items.Count -gt 0) { $defaultIndex = 0 }

    $typeItem = [pscustomobject]@{ Path = $null; Label = 'Type a different path (it does not have to exist yet)' }
    $items.Add($typeItem)

    $chosen = Read-DagChoice -Title $Prompt -Items @($items.ToArray()) -DefaultIndex $defaultIndex `
                -Display { param($i) $i.Label }

    if ($null -eq $chosen.Path) {
        return (Read-DagDirectory -Prompt ('  Directory on {0}' -f $Catalog.Instance) -Default $Default)
    }
    return $chosen.Path.TrimEnd('\')
}

#endregion

#region ── Composing a destination ───────────────────────────────────────────

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

#endregion

#region ── The interview ─────────────────────────────────────────────────────

function New-DagFileLayoutPlan {
    <#
    .SYNOPSIS
        The interview for the file layout. Returns { Mode; Entries }.
    .PARAMETER RestoreTargets
        The replicas that will be restored onto.
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

    Write-Host ''
    Write-Host 'Reading the drive layout of each replica being restored onto...' -ForegroundColor DarkGray
    $catalogs = @{}
    foreach ($t in $RestoreTargets) {
        # Preflight says this properly, but preflight runs after the interview — and an
        # interview that dies here has thrown away every answer the operator just gave,
        # because the plan is not saved until it returns.
        if (-not (Test-DagConnection -Instance $t)) {
            throw "Cannot connect to replica '$t'. Every replica of both availability groups must be reachable."
        }
        $catalogs[$t] = Get-DagInstancePathCatalog -Instance $t
    }

    Show-DagSourceLayout -SourceInstance $SourceInstance -Databases $Databases -SourceFiles $sourceFiles
    Show-DagTargetLayout -RestoreTargets $RestoreTargets -Catalogs $catalogs

    while ($true) {
        $choice = Read-DagChoice -DefaultIndex 0 `
            -Title 'Where should the data and log files land on the replicas being restored onto?' -Items @(
                'REUSE the layout above — every file keeps the directory it has on the source. Missing directories are created on the target.'
                'TARGET DEFAULTS — every data file to each target''s default data directory, every log file to its default log directory.'
                'CHOOSE where they land — pick directories from what each target actually has, for everything at once, per database, or per file.'
            )

        $mode = switch -Wildcard ($choice) {
            'REUSE*'  { 'SOURCE' }
            'TARGET*' { 'TARGETDEFAULT' }
            default   { 'CUSTOM' }
        }

        $entries = @()
        if ($mode -eq 'CUSTOM') {
            $entries = @(Read-DagCustomFileLayout -Databases $Databases -RestoreTargets $RestoreTargets `
                            -SourceFiles $sourceFiles -Catalogs $catalogs)
        }

        # Nobody can hold a four-way fallback chain in their head. Show the operator the
        # destination of every file that this answer actually produces, and let them go
        # round again — the whole decision costs nothing until the plan is confirmed.
        $placements = @(Get-DagFileLayoutPlacement -Mode $mode -Entries $entries -SourceFiles $sourceFiles `
                            -Databases $Databases -RestoreTargets $RestoreTargets -Catalogs $catalogs)
        Show-DagFileLayoutPlacement -Placements $placements -Mode $mode -Catalogs $catalogs

        if (Read-DagYesNo -Question 'Is that where you want the files to land?' -DefaultYes $true) {
            return [pscustomobject]@{
                Mode    = $mode
                Entries = @($entries)
            }
        }
        Write-Host ''
        Write-Host 'Starting the file placement question again.' -ForegroundColor DarkGray
    }
}

function Show-DagSourceLayout {
    <#
    .SYNOPSIS
        The source layout, grouped by database, with the directories called out.
    .DESCRIPTION
        The old flat list of every file on one line each is unreadable past a few
        databases, and it is the per-database grouping that makes a sprawling layout
        legible — which is the thing the operator is about to decide what to do with.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceInstance,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][hashtable]$SourceFiles
    )

    Write-Host ''
    Write-Host "Database files as they are today on $SourceInstance" -ForegroundColor Cyan
    foreach ($db in $Databases) {
        $files = @($SourceFiles[$db])
        $total = 0; foreach ($f in $files) { $total += $f.SizeBytes }
        Write-Host ('  {0}  ({1} file(s), {2})' -f $db, $files.Count, (Format-DagBytes $total)) -ForegroundColor White
        foreach ($f in $files) {
            Write-Host ('      {0,-28} {1,-10} {2,10}  {3}' -f `
                $f.LogicalName, (Get-DagFileKindLabel $f.FileType), (Format-DagBytes $f.SizeBytes), $f.PhysicalName) -ForegroundColor DarkGray
        }
    }

    $dirs = @{}
    foreach ($db in $Databases) {
        foreach ($f in @($SourceFiles[$db])) {
            $d = [System.IO.Path]::GetDirectoryName($f.PhysicalName)
            if ($d) { $dirs[$d.TrimEnd('\').ToLowerInvariant()] = $d.TrimEnd('\') }
        }
    }
    Write-Host ('  {0} distinct source directory(ies): {1}' -f $dirs.Count, (($dirs.Values | Sort-Object) -join ', ')) -ForegroundColor DarkGray
}

function Show-DagTargetLayout {
    <#
    .SYNOPSIS
        What each restore target has to offer, so the operator sees the menu before being
        asked to choose from it.
    #>
    param(
        [Parameter(Mandatory)][string[]]$RestoreTargets,
        [Parameter(Mandatory)][hashtable]$Catalogs
    )

    Write-Host ''
    Write-Host 'Where those files could go on the replicas being restored onto' -ForegroundColor Cyan
    foreach ($t in $RestoreTargets) {
        $cat = $Catalogs[$t]
        Write-Host "  $t" -ForegroundColor White

        # Data and log candidates are the same directories in a different order — any
        # directory can hold either kind of file — so the overview lists each one once and
        # says what it is instead of printing the set twice. Volume roots are offered when
        # choosing but are noise here: a root is never where anybody keeps database files.
        $byPath = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($kind in 'Data', 'Log') {
            $list = if ($kind -eq 'Data') { @($cat.DataPaths) } else { @($cat.LogPaths) }
            foreach ($p in $list) {
                if ($p.Origin -eq 'volume') { continue }
                $key = $p.Path.ToLowerInvariant()
                if (-not $byPath.Contains($key)) {
                    $byPath.Add($key, [pscustomobject]@{
                        Path = $p.Path; FreeBytes = $p.FreeBytes; FileCount = $p.FileCount
                        Origin = $p.Origin; IsDataDefault = $false; IsLogDefault = $false
                    })
                }
                if ($p.IsDefault) {
                    if ($kind -eq 'Data') { $byPath[$key].IsDataDefault = $true } else { $byPath[$key].IsLogDefault = $true }
                }
                if ($p.FileCount -gt $byPath[$key].FileCount) { $byPath[$key].FileCount = $p.FileCount }
            }
        }

        if ($byPath.Count -eq 0) {
            Write-Host '      (no candidate directories reported)' -ForegroundColor DarkGray
            continue
        }

        $entries = @($byPath.Values)
        $w = Get-DagPathColumnWidth -Paths @($entries | ForEach-Object { $_.Path })
        foreach ($e in $entries) {
            $tags = New-Object System.Collections.Generic.List[string]
            if ($e.IsDataDefault) { $tags.Add('default data') }
            if ($e.IsLogDefault)  { $tags.Add('default log') }
            if ($e.FileCount -gt 0) { $tags.Add(('{0} database file(s)' -f $e.FileCount)) }
            if ($tags.Count -eq 0) { $tags.Add('empty') }
            Write-Host (('      {0,-' + $w + '}  {1,-26} {2}') -f `
                $e.Path, ($tags -join ', '), (Get-DagFreeSpaceText $e.FreeBytes)) -ForegroundColor DarkGray
        }
    }
}

function Read-DagCustomFileLayout {
    <#
    .SYNOPSIS
        The CUSTOM branch: one entry per restore target, carrying directories at whatever
        precision the operator asked for.
    .DESCRIPTION
        Precision and the replica axis are asked separately because they are independent:
        a two-replica forwarder with identical drive letters wants per-database precision
        answered once, not twice.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string[]]$RestoreTargets,
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [Parameter(Mandatory)][hashtable]$Catalogs
    )

    $fileCount = 0
    foreach ($db in $Databases) { $fileCount += @($SourceFiles[$db]).Count }
    $dbCount = $Databases.Count
    $rCount  = $RestoreTargets.Count

    #region Precision
    $precisionItems = @(
        [pscustomobject]@{
            Key   = 'ALL'
            Label = ('ALL DATABASES TOGETHER — one data directory and one log directory for every file.' + "`n" +
                     ('        {0} question(s) per replica.' -f 2))
        }
        [pscustomobject]@{
            Key   = 'DATABASE'
            Label = ('PER DATABASE — a data directory and a log directory for each database. All of a' + "`n" +
                     '        database''s data files go to one place, all of its log files to another.' + "`n" +
                     ('        {0} question(s) per replica, for {1} database(s).' -f (2 * $dbCount), $dbCount))
        }
        [pscustomobject]@{
            Key   = 'FILE'
            Label = ('PER FILE — a directory for each individual data and log file, so one database''s' + "`n" +
                     '        data files can be split across several locations.' + "`n" +
                     ('        {0} question(s) per replica, for {1} file(s).' -f $fileCount, $fileCount))
        }
    )
    $precision = (Read-DagChoice -DefaultIndex 0 -Items $precisionItems -Display { param($i) $i.Label } `
                    -Title 'How precisely do you want to place the files?').Key
    #endregion

    #region Replica axis
    $perReplica = $false
    if ($rCount -gt 1) {
        $same = Read-DagChoice -DefaultIndex 0 -Title ('Those answers will be used on {0} replicas: {1}' -f $rCount, ($RestoreTargets -join ', ')) -Items @(
            'The SAME directories on every replica — they have the same drive layout.'
            'DIFFERENT directories per replica — ask me separately for each one.'
        )
        $perReplica = ($same -notlike 'The SAME*')
    }
    #endregion

    $entries = New-Object System.Collections.Generic.List[psobject]
    $template = $null   # answers from the first replica, reused when they are shared

    foreach ($t in $RestoreTargets) {
        if ($template -and -not $perReplica) {
            # Shared answers: every replica still gets its own entry, because the restore
            # looks the layout up by replica and a uniform lookup is one less special case.
            $entries.Add((Copy-DagFileLayoutEntry -Entry $template -Replica $t))
            continue
        }

        if ($perReplica -or $rCount -eq 1) {
            Write-Host ''
            Write-Host "Directories on $t" -ForegroundColor Cyan
        } else {
            Write-Host ''
            Write-Host "Directories — used on every replica ($($RestoreTargets -join ', '))" -ForegroundColor Cyan
        }

        $entry = Read-DagFileLayoutEntry -Replica $t -Precision $precision -Databases $Databases `
                    -SourceFiles $SourceFiles -Catalog $Catalogs[$t]
        $entries.Add($entry)
        if (-not $template) { $template = $entry }
    }

    return @($entries.ToArray())
}

function Read-DagFileLayoutEntry {
    <#
    .SYNOPSIS
        One replica's worth of answers at the chosen precision.
    .DESCRIPTION
        The replica-level DataPath / LogPath is always filled in, even at FILE precision.
        It is the fallback for a file that joins the database after the plan was built, and
        having it means no resolution ever has to reach for an instance default it might
        not have.
    #>
    param(
        [Parameter(Mandatory)][string]$Replica,
        [Parameter(Mandatory)][ValidateSet('ALL','DATABASE','FILE')][string]$Precision,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [Parameter(Mandatory)][psobject]$Catalog
    )

    $defData = Get-DagDefaultPathText $Catalog.InstanceInfo.DefaultDataPath
    $defLog  = Get-DagDefaultPathText $Catalog.InstanceInfo.DefaultLogPath

    $dataPath = $null
    $logPath  = $null
    $dbEntries   = New-Object System.Collections.Generic.List[psobject]
    $fileEntries = New-Object System.Collections.Generic.List[psobject]

    if ($Precision -eq 'ALL') {
        $dataPath = Read-DagPathChoice -Prompt '  Data file directory — for every data file' -Catalog $Catalog -Kind Data -Default $defData
        $logPath  = Read-DagPathChoice -Prompt '  Log file directory — for every log file'   -Catalog $Catalog -Kind Log  -Default $defLog
    }
    elseif ($Precision -eq 'DATABASE') {
        foreach ($db in $Databases) {
            $files = @($SourceFiles[$db])
            $dataSize = 0; $logSize = 0
            foreach ($f in $files) {
                if ($f.FileType -eq 'L') { $logSize += $f.SizeBytes } else { $dataSize += $f.SizeBytes }
            }
            $dataFiles = @($files | Where-Object { $_.FileType -ne 'L' }).Count
            $logFiles  = @($files | Where-Object { $_.FileType -eq 'L' }).Count

            Write-Host ''
            Write-Host ('  [{0}]' -f $db) -ForegroundColor White
            $d = Read-DagPathChoice -Catalog $Catalog -Kind Data -Default $defData `
                    -Prompt ('  Data directory for [{0}] — {1} file(s), {2}' -f $db, $dataFiles, (Format-DagBytes $dataSize))
            $l = Read-DagPathChoice -Catalog $Catalog -Kind Log -Default $defLog `
                    -Prompt ('  Log directory for [{0}] — {1} file(s), {2}' -f $db, $logFiles, (Format-DagBytes $logSize))

            $dbEntries.Add([pscustomobject]@{ DatabaseName = $db; DataPath = $d; LogPath = $l })
            if (-not $dataPath) { $dataPath = $d }
            if (-not $logPath)  { $logPath  = $l }
        }
    }
    else {
        Write-Host ''
        Write-Host '  A directory is asked for each file; the file keeps its own name.' -ForegroundColor DarkGray
        foreach ($db in $Databases) {
            Write-Host ''
            Write-Host ('  [{0}]' -f $db) -ForegroundColor White
            foreach ($f in @($SourceFiles[$db])) {
                $kind    = if ($f.FileType -eq 'L') { 'Log' } else { 'Data' }
                $srcDir  = [System.IO.Path]::GetDirectoryName($f.PhysicalName)
                $fallback = if ($f.FileType -eq 'L') { $defLog } else { $defData }

                $dir = Read-DagPathChoice -Catalog $Catalog -Kind $kind -Default $fallback -KeepPath $srcDir `
                        -Prompt ('  Directory for {0} ({1}, {2}) — now in {3}' -f `
                                    $f.LogicalName, (Get-DagFileKindLabel $f.FileType), (Format-DagBytes $f.SizeBytes), $srcDir)

                $fileEntries.Add([pscustomobject]@{
                    DatabaseName    = $db
                    LogicalName     = $f.LogicalName
                    FileType        = $f.FileType
                    TargetDirectory = $dir
                    TargetPath      = $null
                })
                if ($f.FileType -eq 'L') {
                    if (-not $logPath) { $logPath = $dir }
                } else {
                    if (-not $dataPath) { $dataPath = $dir }
                }
            }
        }
    }

    # A database with no data file at all is not a thing, but a selection of log-only or
    # data-only answers can still leave one side unset — fall back to the instance default
    # so the entry is always complete.
    if (-not $dataPath) { $dataPath = $defData }
    if (-not $logPath)  { $logPath  = $defLog }

    return [pscustomobject]@{
        Replica   = $Replica
        Precision = $Precision
        DataPath  = $dataPath
        LogPath   = $logPath
        Databases = @($dbEntries.ToArray())
        Files     = @($fileEntries.ToArray())
    }
}

function Copy-DagFileLayoutEntry {
    <#
    .SYNOPSIS
        The same answers, recorded against another replica.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Entry,
        [Parameter(Mandatory)][string]$Replica
    )

    $dbs = @()
    foreach ($d in @(Get-DagOptionalProperty -InputObject $Entry -Name 'Databases')) {
        if (-not $d) { continue }
        $dbs += [pscustomobject]@{ DatabaseName = $d.DatabaseName; DataPath = $d.DataPath; LogPath = $d.LogPath }
    }
    $files = @()
    foreach ($f in @(Get-DagOptionalProperty -InputObject $Entry -Name 'Files')) {
        if (-not $f) { continue }
        $files += [pscustomobject]@{
            DatabaseName    = $f.DatabaseName
            LogicalName     = $f.LogicalName
            FileType        = $f.FileType
            TargetDirectory = (Get-DagOptionalProperty -InputObject $f -Name 'TargetDirectory')
            TargetPath      = (Get-DagOptionalProperty -InputObject $f -Name 'TargetPath')
        }
    }

    return [pscustomobject]@{
        Replica   = $Replica
        Precision = (Get-DagOptionalProperty -InputObject $Entry -Name 'Precision')
        DataPath  = $Entry.DataPath
        LogPath   = $Entry.LogPath
        Databases = @($dbs)
        Files     = @($files)
    }
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

function Get-DagFileLayoutDatabaseEntry {
    <#
    .OUTPUTS
        The per-database directories recorded in one replica's entry, or $null.
    #>
    param(
        [AllowNull()]$Entry,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $dbs = @(Get-DagOptionalProperty -InputObject $Entry -Name 'Databases')
    $m = @($dbs | Where-Object { $_ -and $_.DatabaseName -eq $DatabaseName })
    if ($m.Count -gt 0) { return $m[0] }
    return $null
}

function Resolve-DagFileTarget {
    <#
    .SYNOPSIS
        The path one database file must be restored to on one replica.

    .DESCRIPTION
        CUSTOM resolution walks four levels, most specific first, and every level is
        allowed to be absent:

          1. a destination recorded for this exact file (by logical name)
          2. the directories recorded for its database
          3. the directories recorded for its replica
          4. the replica's instance defaults

        A file that joined the database after the plan was built therefore still lands
        somewhere deliberate rather than failing the restore — which is why level 3 is
        always populated by the interview even at FILE precision.
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

    $dataPath = $null
    $logPath  = $null

    if ($mode -eq 'CUSTOM') {
        $entry = Get-DagFileLayoutEntry -Plan $Plan -Instance $Instance
        if (-not $entry) {
            Write-DagLog "  [$Instance] the plan records no custom file layout for this replica — using its default data and log directories." WARN
        } else {
            # 1. This exact file. A full TargetPath wins outright (that is what an older
            #    plan recorded); a TargetDirectory keeps the file's own name.
            foreach ($f in @(Get-DagOptionalProperty -InputObject $entry -Name 'Files')) {
                if (-not $f) { continue }
                if ($f.DatabaseName -ne $DatabaseName -or $f.LogicalName -ne $LogicalName) { continue }

                $explicit = Get-DagOptionalProperty -InputObject $f -Name 'TargetPath'
                if ($explicit) { return [string]$explicit }

                $dir = Get-DagOptionalProperty -InputObject $f -Name 'TargetDirectory'
                if ($dir) {
                    return Get-DagDefaultFileTarget -DatabaseName $DatabaseName -LogicalName $LogicalName `
                                -PhysicalName $PhysicalName -FileType $FileType -DataPath ([string]$dir) -LogPath ([string]$dir)
                }
                break
            }

            # 2. Its database.
            $dbEntry = Get-DagFileLayoutDatabaseEntry -Entry $entry -DatabaseName $DatabaseName
            if ($dbEntry) {
                $d = Get-DagOptionalProperty -InputObject $dbEntry -Name 'DataPath'
                $l = Get-DagOptionalProperty -InputObject $dbEntry -Name 'LogPath'
                if ($d) { $dataPath = [string]$d }
                if ($l) { $logPath  = [string]$l }
            }

            # 3. Its replica.
            if (-not $dataPath -and (Get-DagOptionalProperty -InputObject $entry -Name 'DataPath')) { $dataPath = [string]$entry.DataPath }
            if (-not $logPath  -and (Get-DagOptionalProperty -InputObject $entry -Name 'LogPath'))  { $logPath  = [string]$entry.LogPath }
        }
    }

    # 4. The instance default is only consulted when nothing else answered, so an instance
    #    that has no default only fails the runs that actually needed one.
    if (-not $dataPath) { $dataPath = Get-DagInstanceDefaultPath -InstanceInfo $InstanceInfo -Kind Data }
    if (-not $logPath)  { $logPath  = Get-DagInstanceDefaultPath -InstanceInfo $InstanceInfo -Kind Log }

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

#region ── Placement: what the answers actually produce ──────────────────────

function Get-DagFileLayoutPlacement {
    <#
    .SYNOPSIS
        Every (replica, file) destination a set of answers produces.

    .DESCRIPTION
        Used while interviewing — before any plan exists — so it takes the mode and
        entries directly and wraps them in the shape Resolve-DagFileTarget reads. That
        keeps one resolver for the preview, the plan summary, preflight and the restore
        itself: a preview computed by separate code is a preview that can lie.
    #>
    param(
        [Parameter(Mandatory)][string]$Mode,
        [AllowEmptyCollection()][psobject[]]$Entries = @(),
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string[]]$RestoreTargets,
        [Parameter(Mandatory)][hashtable]$Catalogs
    )

    $shim = [pscustomobject]@{ FileLayoutMode = $Mode; FileLayout = @($Entries) }
    $out  = New-Object System.Collections.Generic.List[psobject]

    foreach ($t in $RestoreTargets) {
        foreach ($db in $Databases) {
            foreach ($f in @($SourceFiles[$db])) {
                $target = Resolve-DagFileTarget -Plan $shim -Instance $t -InstanceInfo $Catalogs[$t].InstanceInfo `
                            -DatabaseName $db -LogicalName $f.LogicalName `
                            -PhysicalName $f.PhysicalName -FileType $f.FileType
                $out.Add([pscustomobject]@{
                    Replica      = $t
                    DatabaseName = $db
                    LogicalName  = $f.LogicalName
                    FileType     = $f.FileType
                    SizeBytes    = $f.SizeBytes
                    SourcePath   = $f.PhysicalName
                    TargetPath   = $target
                    TargetDir    = (Get-DagTargetDirectory -TargetPath $target)
                })
            }
        }
    }
    return @($out.ToArray())
}

function Show-DagFileLayoutPlacement {
    <#
    .SYNOPSIS
        The resolved destinations, grouped so that the common case reads as two lines per
        database and the interesting case still shows every file.

    .DESCRIPTION
        A database whose data files all land in one directory and whose log files all land
        in another is summarised as exactly that. One whose files are split is listed file
        by file, because that is the case where an operator needs to check the detail.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Placements,
        [Parameter(Mandatory)][string]$Mode,
        [hashtable]$Catalogs
    )

    Write-Host ''
    Write-Host ('Where the files will land — {0}' -f (Get-DagFileLayoutLabel $Mode)) -ForegroundColor Cyan
    if ($Placements.Count -eq 0) {
        Write-Host '  (nothing to place)' -ForegroundColor DarkGray
        return
    }

    foreach ($replica in (@($Placements | ForEach-Object { $_.Replica }) | Select-Object -Unique)) {
        Write-Host "  $replica" -ForegroundColor White
        $forReplica = @($Placements | Where-Object { $_.Replica -eq $replica })

        foreach ($db in (@($forReplica | ForEach-Object { $_.DatabaseName }) | Select-Object -Unique)) {
            $files    = @($forReplica | Where-Object { $_.DatabaseName -eq $db })
            $dataDirs = @(@($files | Where-Object { $_.FileType -ne 'L' } | ForEach-Object { $_.TargetDir }) | Select-Object -Unique)
            $logDirs  = @(@($files | Where-Object { $_.FileType -eq 'L' } | ForEach-Object { $_.TargetDir }) | Select-Object -Unique)

            if ($dataDirs.Count -le 1 -and $logDirs.Count -le 1) {
                $dataText = if ($dataDirs.Count -eq 1) { $dataDirs[0] } else { '(none)' }
                $logText  = if ($logDirs.Count -eq 1)  { $logDirs[0] }  else { '(none)' }
                Write-Host ('      {0,-26} data -> {1,-30} log -> {2}' -f $db, $dataText, $logText)
            } else {
                Write-Host ('      {0}' -f $db)
                foreach ($f in $files) {
                    Write-Host ('          {0,-26} {1,-10} -> {2}' -f `
                        $f.LogicalName, (Get-DagFileKindLabel $f.FileType), $f.TargetPath) -ForegroundColor DarkGray
                }
            }
        }

        # How much is being asked of each volume, against what it has left. The arithmetic
        # is the reason an operator picked one directory over another, so show it.
        if ($Catalogs -and $Catalogs.ContainsKey($replica)) {
            Show-DagVolumeDemand -Placements $forReplica -FreeSpace $Catalogs[$replica].FreeSpace -Indent '      '
        }
    }
}

function Get-DagVolumeDemand {
    <#
    .OUTPUTS
        Per volume: bytes about to be restored onto it, and what it has free.
        Volumes that are not a local drive letter (a UNC destination) are skipped — there
        is no free-space figure for them and nothing useful to say.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Placements,
        [hashtable]$FreeSpace
    )

    $demand = @{}
    foreach ($p in $Placements) {
        if ($p.TargetPath -notmatch '^([A-Za-z]):') { continue }
        $letter = $Matches[1].ToUpperInvariant()
        if (-not $demand.ContainsKey($letter)) { $demand[$letter] = [long]0 }
        $demand[$letter] += [long]$p.SizeBytes
    }

    $out = New-Object System.Collections.Generic.List[psobject]
    foreach ($letter in ($demand.Keys | Sort-Object)) {
        $free = $null
        if ($FreeSpace -and $FreeSpace.ContainsKey($letter)) { $free = $FreeSpace[$letter] }
        $out.Add([pscustomobject]@{
            Volume    = ('{0}:' -f $letter)
            Bytes     = $demand[$letter]
            FreeBytes = $free
            Fits      = (($null -eq $free) -or ($demand[$letter] -le $free))
        })
    }
    return @($out.ToArray())
}

function Show-DagVolumeDemand {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Placements,
        [hashtable]$FreeSpace,
        [string]$Indent = '  '
    )

    foreach ($v in (Get-DagVolumeDemand -Placements $Placements -FreeSpace $FreeSpace)) {
        $text = ('{0}{1,-4} {2,10} of database files -> {3}' -f `
                    $Indent, $v.Volume, (Format-DagBytes $v.Bytes), (Get-DagFreeSpaceText $v.FreeBytes))
        if ($v.Fits) {
            Write-Host $text -ForegroundColor DarkGray
        } else {
            Write-Host ($text + '  << NOT ENOUGH ROOM') -ForegroundColor Yellow
        }
    }
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

        Free space is reported but never fatal: a volume that cannot hold today's file
        sizes is worth saying out loud, and is also routinely thin-provisioned or about to
        be extended, so it is the operator's call and not this script's.
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
        $placed = New-Object System.Collections.Generic.List[psobject]

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

                $placed.Add([pscustomobject]@{ TargetPath = $target; SizeBytes = $f.SizeBytes })

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

        # Room, now that every destination is known and every directory exists.
        $free = Get-DagVolumeFreeSpace -Instance $t
        foreach ($v in (Get-DagVolumeDemand -Placements @($placed.ToArray()) -FreeSpace $free)) {
            $msg = "  [$t] $($v.Volume) needs $(Format-DagBytes $v.Bytes) of database files, $(Get-DagFreeSpaceText $v.FreeBytes)"
            if ($v.Fits) { Write-DagLog $msg INFO } else { Write-DagLog ($msg + ' — NOT ENOUGH ROOM') WARN }
        }
    }
}

function Get-DagFileLayoutLabel {
    param([string]$Mode)
    switch ($Mode) {
        'SOURCE'        { 'REUSE the source file structure' }
        'TARGETDEFAULT' { 'each target''s DEFAULT data and log directories' }
        'CUSTOM'        { 'directories CHOSEN for this run' }
        default         { "unknown ($Mode)" }
    }
}

function Get-DagFileLayoutPrecisionLabel {
    param([AllowNull()]$Precision)
    switch ([string]$Precision) {
        'ALL'      { 'one pair of directories for every file' }
        'DATABASE' { 'a pair of directories per database' }
        'FILE'     { 'a directory per file' }
        default    { 'directories per replica' }
    }
}

function Show-DagFileLayoutSummary {
    <#
    .SYNOPSIS
        The file layout as it appears in the plan confirmation.
    .DESCRIPTION
        Reads only the plan, so it never touches a server: the summary is printed before
        preflight, and the full file-by-file resolution was already shown and accepted
        during the interview. Preflight reports it again against live state.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $mode = Get-DagFileLayoutMode -Plan $Plan
    Write-Host "  Data / log files    : $(Get-DagFileLayoutLabel $mode)"

    if ($mode -ne 'CUSTOM') { return }

    foreach ($e in @($Plan.FileLayout)) {
        if (-not $e) { continue }

        $precision = Get-DagOptionalProperty -InputObject $e -Name 'Precision'
        Write-Host ("    {0,-22} {1}" -f $e.Replica, (Get-DagFileLayoutPrecisionLabel $precision))

        $dbs   = @(Get-DagOptionalProperty -InputObject $e -Name 'Databases' | Where-Object { $_ })
        $files = @(Get-DagOptionalProperty -InputObject $e -Name 'Files' | Where-Object { $_ })

        if ($files.Count -gt 0) {
            foreach ($f in $files) {
                $dest = Get-DagOptionalProperty -InputObject $f -Name 'TargetPath'
                if (-not $dest) { $dest = Get-DagOptionalProperty -InputObject $f -Name 'TargetDirectory' }
                Write-Host ("      {0}.{1,-24} {2,-10} -> {3}" -f `
                    $f.DatabaseName, $f.LogicalName, (Get-DagFileKindLabel $f.FileType), $dest) -ForegroundColor DarkGray
            }
        } elseif ($dbs.Count -gt 0) {
            foreach ($d in $dbs) {
                Write-Host ("      {0,-24} data {1,-26} log {2}" -f $d.DatabaseName, $d.DataPath, $d.LogPath) -ForegroundColor DarkGray
            }
        }

        # The fallback, which is what catches a file added to a database after the plan was
        # built. Stated only when something more specific was listed above it: where one
        # pair of directories covers everything, repeating it says nothing.
        $label = if ($files.Count -gt 0 -or $dbs.Count -gt 0) { 'anything else' } else { 'every file' }
        Write-Host ("      {0,-24} data {1,-26} log {2}" -f $label, $e.DataPath, $e.LogPath) -ForegroundColor DarkGray
    }
}

#endregion
