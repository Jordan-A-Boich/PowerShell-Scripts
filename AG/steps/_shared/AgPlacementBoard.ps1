#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit - the placement board: deciding where dozens of databases' files land
    without answering a question per database, and without doing the arithmetic by hand.

.DESCRIPTION
    Per-database and per-file placement used to be one numbered menu per database (or per
    file). That is fine for three databases and unworkable for thirty: 28 databases is 56
    menus, and the only record of which drive already took what - and how much room is left
    on it - is the operator's memory.

    The board turns that around:

      1. Pick the SET of directories data files may go to, and the set log files may go to,
         once, by number ("1,3,4").
      2. Every database (or file) is spread across them automatically, largest first, each
         one onto whichever destination leaves the most room on its volume.
      3. Everything is shown as one table with a running ledger - per destination and per
         VOLUME, free now / assigned / left after - and is adjusted with short commands:

            1-5,9 D2      data of databases 1-5 and 9 to D2
            Sales* L1     log of every database whose name starts with Sales to L1
            D1 D3         everything on D1 moves to D3
            auto          rebalance everything (or: auto 10-28)

    Free space is accounted per volume, not per directory: D:\Data and D:\Data2 draw on the
    same disk, and so do a data and a log directory that happen to share one.

    When one set of answers is used on several replicas, the free space shown for a volume
    is the SMALLEST any of them reports - the answers have to fit on all of them.

    The board only ever produces the plan entries the existing resolver already reads
    (entry.Databases at DATABASE precision, entry.Files at FILE precision, and the
    replica-level DataPath / LogPath fallback), so nothing downstream changes.

    This file is ASCII-only on purpose; it prints to consoles of every code page.
#>

Set-StrictMode -Version Latest

#region -- Volumes and free space ---------------------------------------------

function Get-AgPathVolume {
    <#
    .OUTPUTS
        Upper-case drive letter of a local path, or $null for a UNC path (which has no
        free-space figure to account against).
    #>
    param([AllowNull()][string]$Path)
    if ($Path -and $Path -match '^([A-Za-z]):') { return $Matches[1].ToUpperInvariant() }
    return $null
}

function Get-AgSharedFreeSpace {
    <#
    .SYNOPSIS
        Free space per volume that one set of answers can count on across several replicas.
    .DESCRIPTION
        The smallest figure any of them reports, because the same directories are used on
        every one of them. A volume one replica does not have at all is recorded too - the
        board says so next to it, since preflight would otherwise be the first to notice.
        A replica whose free space could not be read at all contributes nothing: unknown is
        not the same as missing.
    .OUTPUTS
        { Free = letter -> bytes; Missing = letter -> replica names }
    #>
    param(
        [Parameter(Mandatory)][string[]]$Replicas,
        [Parameter(Mandatory)][hashtable]$Catalogs
    )

    $letters = @{}
    foreach ($r in $Replicas) {
        foreach ($k in @($Catalogs[$r].FreeSpace.Keys)) { $letters[$k] = $true }
    }

    $free    = @{}
    $missing = @{}
    foreach ($l in $letters.Keys) {
        $min = $null
        foreach ($r in $Replicas) {
            $fs = $Catalogs[$r].FreeSpace
            if ($fs.Count -eq 0) { continue }
            if ($fs.ContainsKey($l)) {
                if ($null -eq $min -or $fs[$l] -lt $min) { $min = $fs[$l] }
            } else {
                if (-not $missing.ContainsKey($l)) { $missing[$l] = @() }
                $missing[$l] += $r
            }
        }
        $free[$l] = $min
    }
    return [pscustomobject]@{ Free = $free; Missing = $missing }
}

#endregion

#region -- Building the board -------------------------------------------------

function New-AgPlacementSlot {
    <#
    .SYNOPSIS
        One placeable unit: a database's data files, a database's log files, or one file.
    .DESCRIPTION
        Leaves are the file names the slot's files will have on the target - the same name
        Get-AgDefaultFileTarget produces - so collisions can be spotted on the board instead
        of at preflight.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind,
        [Parameter(Mandatory)][psobject[]]$Files,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][int]$RowNo,
        [Parameter(Mandatory)][int]$Order
    )

    $bytes  = [long]0
    $leaves = New-Object System.Collections.Generic.List[string]
    $dirs   = @{}
    foreach ($f in $Files) {
        $bytes += [long]$f.SizeBytes
        $probe = Get-AgDefaultFileTarget -DatabaseName $DatabaseName -LogicalName $f.LogicalName `
                    -PhysicalName $f.PhysicalName -FileType $f.FileType -DataPath 'X:\' -LogPath 'X:\'
        $leaves.Add([System.IO.Path]::GetFileName($probe))
        $d = [System.IO.Path]::GetDirectoryName($f.PhysicalName)
        if ($d) { $dirs[$d.TrimEnd('\').ToLowerInvariant()] = $d.TrimEnd('\') }
    }

    # 'keep' needs a single directory to keep. A database whose data files are already
    # scattered over several has no one answer for that, so it gets none.
    $sourceDir = $null
    if ($dirs.Count -eq 1) { $sourceDir = @($dirs.Values)[0] }

    return [pscustomobject]@{
        RowNo     = $RowNo
        Order     = $Order
        Kind      = $Kind
        Bytes     = $bytes
        FileCount = $Files.Count
        Leaves    = @($leaves.ToArray())
        SourceDir = $sourceDir
        Dir       = $null
        Pinned    = $false
    }
}

function New-AgPlacementBoard {
    <#
    .SYNOPSIS
        An empty board: every database (DATABASE precision) or file (FILE precision) as a
        numbered row, nothing assigned, no destinations yet.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('DATABASE','FILE')][string]$Precision,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [hashtable]$FreeSpace = @{},
        [hashtable]$MissingVolume = @{},
        [string[]]$Replicas = @()
    )

    $rows  = New-Object System.Collections.Generic.List[psobject]
    $order = 0
    foreach ($db in $Databases) {
        $files = @($SourceFiles[$db])
        if ($Precision -eq 'DATABASE') {
            $no    = $rows.Count + 1
            $slots = New-Object System.Collections.Generic.List[psobject]
            $data  = @($files | Where-Object { $_.FileType -ne 'L' })
            $log   = @($files | Where-Object { $_.FileType -eq 'L' })
            if ($data.Count -gt 0) { $slots.Add((New-AgPlacementSlot -Kind Data -Files $data -DatabaseName $db -RowNo $no -Order ($order++))) }
            if ($log.Count  -gt 0) { $slots.Add((New-AgPlacementSlot -Kind Log  -Files $log  -DatabaseName $db -RowNo $no -Order ($order++))) }
            $rows.Add([pscustomobject]@{
                No           = $no
                DatabaseName = $db
                LogicalName  = $null
                FileType     = $null
                Slots        = @($slots.ToArray())
            })
        } else {
            foreach ($f in $files) {
                $no   = $rows.Count + 1
                $kind = if ($f.FileType -eq 'L') { 'Log' } else { 'Data' }
                $rows.Add([pscustomobject]@{
                    No           = $no
                    DatabaseName = $db
                    LogicalName  = $f.LogicalName
                    FileType     = $f.FileType
                    Slots        = @(New-AgPlacementSlot -Kind $kind -Files @($f) -DatabaseName $db -RowNo $no -Order ($order++))
                })
            }
        }
    }

    return [pscustomobject]@{
        Precision     = $Precision
        Rows          = @($rows.ToArray())
        Destinations  = (New-Object System.Collections.Generic.List[psobject])
        FreeSpace     = $FreeSpace
        MissingVolume = $MissingVolume
        Replicas      = @($Replicas)
        History       = (New-Object System.Collections.Generic.List[psobject])
    }
}

function Get-AgPlacementSlot {
    <#
    .OUTPUTS
        Every slot on the board, or those of the given rows, in board order.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [psobject[]]$Rows
    )
    $src = if ($PSBoundParameters.ContainsKey('Rows')) { $Rows } else { $Board.Rows }
    $out = New-Object System.Collections.Generic.List[psobject]
    foreach ($r in $src) { foreach ($s in $r.Slots) { $out.Add($s) } }
    return @($out.ToArray())
}

#endregion

#region -- Destinations -------------------------------------------------------

function Get-AgPlacementDestination {
    <#
    .OUTPUTS
        The destination with this id (D1, L2 ...), or $null.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [Parameter(Mandatory)][string]$Id
    )
    foreach ($d in $Board.Destinations) { if ($d.Id -eq $Id.ToUpperInvariant()) { return $d } }
    return $null
}

function Get-AgPlacementDestinationByPath {
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [AllowNull()][string]$Path,
        [string]$Kind
    )
    if (-not $Path) { return $null }
    $key = $Path.TrimEnd('\').ToLowerInvariant()
    foreach ($d in $Board.Destinations) {
        if ($Kind -and $d.Kind -ne $Kind) { continue }
        if ($d.Path.TrimEnd('\').ToLowerInvariant() -eq $key) { return $d }
    }
    return $null
}

function Add-AgPlacementDestination {
    <#
    .SYNOPSIS
        Adds a directory to the data or log pool and returns it. Ids are never reused, so
        an id the operator has been typing keeps meaning the same directory after a removal.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind,
        [Parameter(Mandatory)][string]$Path
    )

    $path = $Path.TrimEnd('\')
    if ($path -match '^[A-Za-z]:$') { $path += '\' }

    $existing = Get-AgPlacementDestinationByPath -Board $Board -Path $path -Kind $Kind
    if ($existing) { return $existing }

    $prefix = if ($Kind -eq 'Data') { 'D' } else { 'L' }
    $max = 0
    foreach ($d in $Board.Destinations) {
        if ($d.Id -match ('^' + $prefix + '(\d+)$') -and [int]$Matches[1] -gt $max) { $max = [int]$Matches[1] }
    }

    $dest = [pscustomobject]@{
        Id     = ('{0}{1}' -f $prefix, ($max + 1))
        Kind   = $Kind
        Path   = $path
        Volume = (Get-AgPathVolume $path)
    }
    $Board.Destinations.Add($dest)
    return $dest
}

#endregion

#region -- Arithmetic: the ledger, balancing, collisions -----------------------

function Get-AgPlacementLedger {
    <#
    .SYNOPSIS
        What the current assignments ask of every destination and every volume.
    .OUTPUTS
        { Destinations = per destination { Destination; Files; Bytes };
          Volumes      = per volume { Volume; FreeBytes; Bytes; LeftBytes; Fits; Ids; MissingOn };
          Other        = assignments to directories that are not in either pool (kept
                         source directories) { Path; Files; Bytes } }
    #>
    param([Parameter(Mandatory)][psobject]$Board)

    $byDir = @{}   # lower(path) + kind -> { Files; Bytes }
    $byVol = @{}   # letter -> bytes
    foreach ($s in (Get-AgPlacementSlot -Board $Board)) {
        if (-not $s.Dir) { continue }
        $key = $s.Kind + '|' + $s.Dir.TrimEnd('\').ToLowerInvariant()
        if (-not $byDir.ContainsKey($key)) { $byDir[$key] = [pscustomobject]@{ Path = $s.Dir; Kind = $s.Kind; Files = 0; Bytes = [long]0 } }
        $byDir[$key].Files += $s.FileCount
        $byDir[$key].Bytes += $s.Bytes

        $v = Get-AgPathVolume $s.Dir
        if ($v) {
            if (-not $byVol.ContainsKey($v)) { $byVol[$v] = [long]0 }
            $byVol[$v] += $s.Bytes
        }
    }

    $dests = New-Object System.Collections.Generic.List[psobject]
    $claimed = @{}
    foreach ($d in $Board.Destinations) {
        $key = $d.Kind + '|' + $d.Path.TrimEnd('\').ToLowerInvariant()
        $claimed[$key] = $true
        $files = 0; $bytes = [long]0
        if ($byDir.ContainsKey($key)) { $files = $byDir[$key].Files; $bytes = $byDir[$key].Bytes }
        $dests.Add([pscustomobject]@{ Destination = $d; Files = $files; Bytes = $bytes })
    }

    $other = New-Object System.Collections.Generic.List[psobject]
    foreach ($k in ($byDir.Keys | Sort-Object)) {
        if (-not $claimed.ContainsKey($k)) { $other.Add($byDir[$k]) }
    }

    # Every volume a destination lives on, plus any an assignment reaches (a kept source
    # directory on a volume that is not in either pool still uses that volume's room).
    $letters = @{}
    foreach ($d in $Board.Destinations) { if ($d.Volume) { $letters[$d.Volume] = $true } }
    foreach ($v in $byVol.Keys) { $letters[$v] = $true }

    $vols = New-Object System.Collections.Generic.List[psobject]
    foreach ($l in ($letters.Keys | Sort-Object)) {
        $free  = $null
        if ($Board.FreeSpace.ContainsKey($l)) { $free = $Board.FreeSpace[$l] }
        $bytes = [long]0
        if ($byVol.ContainsKey($l)) { $bytes = $byVol[$l] }
        $ids = @($Board.Destinations | Where-Object { $_.Volume -eq $l } | ForEach-Object { $_.Id })
        $missingOn = @()
        if ($Board.MissingVolume.ContainsKey($l)) { $missingOn = @($Board.MissingVolume[$l]) }
        $left = $null
        if ($null -ne $free) { $left = [long]$free - $bytes }
        $vols.Add([pscustomobject]@{
            Volume    = $l
            FreeBytes = $free
            Bytes     = $bytes
            LeftBytes = $left
            Fits      = (($null -eq $free) -or ($bytes -le $free))
            Ids       = $ids
            MissingOn = $missingOn
        })
    }

    return [pscustomobject]@{
        Destinations = @($dests.ToArray())
        Volumes      = @($vols.ToArray())
        Other        = @($other.ToArray())
    }
}

function Invoke-AgPlacementBalance {
    <#
    .SYNOPSIS
        Spreads the given slots across the pool of their kind; every other slot stays put.

    .DESCRIPTION
        Largest first, each onto the destination whose VOLUME has the most room left after
        everything already placed - so a 6 TB drive takes work before a 500 GB one does, and
        the volumes end up with as much headroom as the sizes allow. Two destinations on one
        volume tie on that, and the tie goes to whichever directory holds less so far, which
        alternates between them.

        When a candidate's free space is unknown (a UNC path, or a replica that would not
        report it) there is nothing to compare, and the pool is balanced on bytes assigned
        per destination instead.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Slots
    )

    # Whatever is handed in is being re-planned, so it is no longer the operator's choice.
    foreach ($s in $Slots) { $s.Dir = $null; $s.Pinned = $false }

    $volBytes = @{}
    $dirBytes = @{}
    foreach ($s in (Get-AgPlacementSlot -Board $Board)) {
        if (-not $s.Dir) { continue }
        $v = Get-AgPathVolume $s.Dir
        if ($v) { if (-not $volBytes.ContainsKey($v)) { $volBytes[$v] = [long]0 }; $volBytes[$v] += $s.Bytes }
        $k = $s.Dir.TrimEnd('\').ToLowerInvariant()
        if (-not $dirBytes.ContainsKey($k)) { $dirBytes[$k] = [long]0 }
        $dirBytes[$k] += $s.Bytes
    }

    $ordered = @($Slots | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true }, @{ Expression = 'Order'; Descending = $false })
    foreach ($s in $ordered) {
        $cands = @($Board.Destinations | Where-Object { $_.Kind -eq $s.Kind })
        if ($cands.Count -eq 0) { continue }

        $unknown = $false
        foreach ($c in $cands) {
            if (-not $c.Volume -or -not $Board.FreeSpace.ContainsKey($c.Volume) -or $null -eq $Board.FreeSpace[$c.Volume]) { $unknown = $true }
        }

        $best = $null; $bestLeft = $null; $bestDir = $null
        foreach ($c in $cands) {
            $dk = $c.Path.TrimEnd('\').ToLowerInvariant()
            $onDir = [long]0
            if ($dirBytes.ContainsKey($dk)) { $onDir = $dirBytes[$dk] }

            if ($unknown) {
                if ($null -eq $best -or $onDir -lt $bestDir) { $best = $c; $bestDir = $onDir }
                continue
            }

            $used = [long]0
            if ($volBytes.ContainsKey($c.Volume)) { $used = $volBytes[$c.Volume] }
            $left = [long]$Board.FreeSpace[$c.Volume] - $used
            if ($null -eq $best -or $left -gt $bestLeft -or ($left -eq $bestLeft -and $onDir -lt $bestDir)) {
                $best = $c; $bestLeft = $left; $bestDir = $onDir
            }
        }

        $s.Dir = $best.Path
        if ($best.Volume) {
            if (-not $volBytes.ContainsKey($best.Volume)) { $volBytes[$best.Volume] = [long]0 }
            $volBytes[$best.Volume] += $s.Bytes
        }
        $bk = $best.Path.TrimEnd('\').ToLowerInvariant()
        if (-not $dirBytes.ContainsKey($bk)) { $dirBytes[$bk] = [long]0 }
        $dirBytes[$bk] += $s.Bytes
    }
}

function Get-AgPlacementCollision {
    <#
    .SYNOPSIS
        Files the current assignments would restore to the same path.
    .DESCRIPTION
        The same check preflight makes, made while the operator can still do something
        about it in one command. Two databases from different source directories can share
        a file name, and putting both in one directory is exactly what consolidating does.
    .OUTPUTS
        One line of text per collision.
    #>
    param([Parameter(Mandatory)][psobject]$Board)

    $claims = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in (Get-AgPlacementSlot -Board $Board)) {
        if (-not $s.Dir) { continue }
        foreach ($leaf in $s.Leaves) {
            $path = Join-AgPath -Path $s.Dir -ChildPath @($leaf)
            $key  = $path.ToLowerInvariant()
            if ($claims.ContainsKey($key)) {
                $out.Add(('{0}  <- rows {1} and {2}' -f $path, $claims[$key], $s.RowNo))
            } else {
                $claims[$key] = $s.RowNo
            }
        }
    }
    return @($out.ToArray())
}

#endregion

#region -- Commands -----------------------------------------------------------

function Save-AgPlacementUndo {
    <#
    .SYNOPSIS
        Remembers the board as it is, so the next change can be taken back.
    #>
    param([Parameter(Mandatory)][psobject]$Board)
    $slots = @(Get-AgPlacementSlot -Board $Board)
    $dests = @($Board.Destinations | ForEach-Object { $_ })
    $Board.History.Add([pscustomobject]@{
        Dirs         = @($slots | ForEach-Object { $_.Dir })
        Pins         = @($slots | ForEach-Object { $_.Pinned })
        Destinations = $dests
    })
}

function Undo-AgPlacement {
    param([Parameter(Mandatory)][psobject]$Board)
    if ($Board.History.Count -eq 0) { return $false }
    $snap = $Board.History[$Board.History.Count - 1]
    $Board.History.RemoveAt($Board.History.Count - 1)
    $slots = @(Get-AgPlacementSlot -Board $Board)
    for ($i = 0; $i -lt $slots.Count; $i++) { $slots[$i].Dir = $snap.Dirs[$i]; $slots[$i].Pinned = $snap.Pins[$i] }
    $Board.Destinations.Clear()
    foreach ($d in $snap.Destinations) { $Board.Destinations.Add($d) }
    return $true
}

function Resolve-AgPlacementSelection {
    <#
    .SYNOPSIS
        Turns selector tokens into the slots they name.

    .DESCRIPTION
        A token is any of:
          all           every row
          7  or  3-9    rows by number (several, comma- or space-separated)
          D2            whatever is assigned to destination D2 right now
          Sales*        rows whose database name (or, per file, logical file name)
                        matches the wildcard; a plain name must match exactly
    .OUTPUTS
        { Slots; Error } - Error is the text to show when a token matched nothing.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens
    )

    $picked = New-Object System.Collections.Generic.List[psobject]
    $seen   = @{}
    $add = {
        param($slot)
        $k = '{0}|{1}' -f $slot.RowNo, $slot.Kind
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $picked.Add($slot) }
    }

    foreach ($tok in $Tokens) {
        if ($tok -eq 'all') {
            foreach ($s in (Get-AgPlacementSlot -Board $Board)) { & $add $s }
            continue
        }
        if ($tok -match '^\d+(\s*-\s*\d+)?$') {
            $idx = Read-AgNumberSet -Text $tok -Max $Board.Rows.Count
            if ($null -eq $idx) {
                return [pscustomobject]@{ Slots = @(); Error = ("'{0}' is not a row number between 1 and {1}." -f $tok, $Board.Rows.Count) }
            }
            foreach ($n in $idx) { foreach ($s in $Board.Rows[$n - 1].Slots) { & $add $s } }
            continue
        }
        $dest = $null
        if ($tok -match '^[DdLl]\d+$') { $dest = Get-AgPlacementDestination -Board $Board -Id $tok }
        if ($dest) {
            foreach ($s in (Get-AgPlacementSlot -Board $Board)) {
                if ($s.Kind -eq $dest.Kind -and $s.Dir -and $s.Dir.TrimEnd('\').ToLowerInvariant() -eq $dest.Path.TrimEnd('\').ToLowerInvariant()) { & $add $s }
            }
            continue
        }

        $hit = $false
        foreach ($r in $Board.Rows) {
            $names = @($r.DatabaseName)
            if ($r.LogicalName) { $names += $r.LogicalName }
            $match = $false
            foreach ($n in $names) { if ($n -like $tok) { $match = $true } }
            if ($match) { $hit = $true; foreach ($s in $r.Slots) { & $add $s } }
        }
        if (-not $hit) {
            return [pscustomobject]@{ Slots = @(); Error = ("Nothing matches '{0}'. Use row numbers (3, 1-5), a destination (D2), a name or wildcard (Sales*), or 'all'." -f $tok) }
        }
    }
    return [pscustomobject]@{ Slots = @($picked.ToArray()); Error = $null }
}

function Split-AgPlacementCommand {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return @() }
    return @(($Text -split '[\s,]+') | Where-Object { $_ })
}

function Get-AgPlacementHelpText {
    param([Parameter(Mandatory)][psobject]$Board)
    $unit = if ($Board.Precision -eq 'FILE') { 'file' } else { 'database' }
    $lines = @(
        ''
        'Commands (case does not matter; separate numbers with commas or spaces):'
        ''
        '  <rows> <dest>         Send the selected rows'' files to a destination (and mark them *).'
        '                          3 D2           data of row 3 to D2'
        '                          1-5,9 L1       log of rows 1-5 and 9 to L1'
        ('                          4 D3 L2        row 4''s data to D3 and its log to L2' + $(if ($Board.Precision -eq 'FILE') { ' (whichever applies)' } else { '' }))
        '                          Sales* D1      every row whose name matches the wildcard'
        '                          D1 D3          everything on D1 moves to D3 (drain a drive)'
        '                        A D destination only takes data files and an L destination only'
        '                        log files, so "all D2" moves every data file and no log files.'
        ''
        '  auto                  Rebalance everything you have not placed yourself, largest first,'
        '                        each onto the destination whose volume keeps the most room.'
        '                        Rows you placed are marked * and stay put.'
        '  auto <rows> | all     Rebalance exactly those rows (or all of them), * included.'
        '  add data | add log    Add another directory to the data or log pool.'
        '  remove <dest>         Take a destination out of the pool; what was on it is'
        '                        rebalanced across the rest of that pool.'
        ('  keep <rows>           Leave the selected {0}s'' files in the directory they have today.' -f $unit)
        '  undo                  Take back the last change.'
        '  ENTER or done         Finished - show every file''s destination for approval.'
        ''
    )
    return ($lines -join "`n")
}

function Invoke-AgPlacementCommand {
    <#
    .SYNOPSIS
        Applies one board command.

    .DESCRIPTION
        Everything except 'add' and finishing over an overcommitted volume is decided
        without asking anything further, which is what makes the board testable with no
        console: those two prompt, and only they need -Catalog.

    .OUTPUTS
        { Done = [bool]; Message = text to show above the next prompt, or $null }
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [AllowEmptyString()][string]$Text,
        [psobject]$Catalog
    )

    $result = { param($done, $msg, $color = 'Gray') [pscustomobject]@{ Done = $done; Message = $msg; Color = $color } }

    $tokens = @(Split-AgPlacementCommand $Text)
    if ($tokens.Count -eq 0 -or ($tokens.Count -eq 1 -and $tokens[0] -in @('done','finish','ok'))) {
        $collisions = @(Get-AgPlacementCollision -Board $Board)
        if ($collisions.Count -gt 0) {
            return (& $result $false ("Two or more files would land on the same path - give one of each pair another destination first:`n    " + ($collisions -join "`n    ")) 'Yellow')
        }
        $over = @((Get-AgPlacementLedger -Board $Board).Volumes | Where-Object { -not $_.Fits })
        if ($over.Count -gt 0) {
            $names = ($over | ForEach-Object { '{0}: (over by {1})' -f $_.Volume, (Format-AgBytes ($_.Bytes - $_.FreeBytes)) }) -join ', '
            if (-not (Read-AgYesNo -Question ("{0} would not fit as assigned. Finish anyway? (thin-provisioned or about to be extended)" -f $names) -DefaultYes $false)) {
                return (& $result $false 'Not finished - move something off the full volume, or "add" a destination elsewhere.' 'Yellow')
            }
        }
        return (& $result $true $null)
    }

    $verb = $tokens[0].ToLowerInvariant()
    $rest = @(); if ($tokens.Count -gt 1) { $rest = @($tokens[1..($tokens.Count - 1)]) }

    switch ($verb) {
        { $_ -in @('?','help','h') } {
            return (& $result $false (Get-AgPlacementHelpText -Board $Board) 'DarkGray')
        }

        'undo' {
            if (Undo-AgPlacement -Board $Board) { return (& $result $false 'Took back the last change.') }
            return (& $result $false 'Nothing to undo.' 'Yellow')
        }

        { $_ -in @('auto','balance','rebalance') } {
            # A bare 'auto' works around what the operator placed by hand; naming rows (or
            # 'all') is how to say "those too".
            $pinnedLeft = 0
            if ($rest.Count -eq 0) {
                $all = @(Get-AgPlacementSlot -Board $Board)
                $sel = [pscustomobject]@{ Slots = @($all | Where-Object { -not $_.Pinned }); Error = $null }
                $pinnedLeft = $all.Count - @($sel.Slots).Count
            } else {
                $sel = Resolve-AgPlacementSelection -Board $Board -Tokens $rest
            }
            if ($sel.Error) { return (& $result $false $sel.Error 'Yellow') }
            Save-AgPlacementUndo -Board $Board
            Invoke-AgPlacementBalance -Board $Board -Slots @($sel.Slots)
            $msg = 'Rebalanced {0} placement(s), largest first.' -f @($sel.Slots).Count
            if ($pinnedLeft -gt 0) { $msg += (' {0} you placed yourself (marked *) were left where they are - "auto all" includes them.' -f $pinnedLeft) }
            return (& $result $false $msg)
        }

        'keep' {
            if ($rest.Count -eq 0) { return (& $result $false 'keep needs rows, e.g. "keep 3" or "keep 1-4".' 'Yellow') }
            $sel = Resolve-AgPlacementSelection -Board $Board -Tokens $rest
            if ($sel.Error) { return (& $result $false $sel.Error 'Yellow') }
            Save-AgPlacementUndo -Board $Board
            $kept = 0; $skipped = 0
            foreach ($s in $sel.Slots) {
                if ($s.SourceDir) { $s.Dir = $s.SourceDir; $s.Pinned = $true; $kept++ } else { $skipped++ }
            }
            $msg = 'Kept {0} placement(s) in their current directory.' -f $kept
            if ($skipped -gt 0) { $msg += (' {0} skipped: their files are spread over several directories today, so there is no single one to keep - use per-file precision for those.' -f $skipped) }
            return (& $result $false $msg)
        }

        'add' {
            $kindTok = if ($rest.Count -gt 0) { $rest[0].ToLowerInvariant() } else { '' }
            $kind = switch -Regex ($kindTok) { '^d(ata)?$' { 'Data' } '^l(og)?$' { 'Log' } default { $null } }
            if (-not $kind) { return (& $result $false 'Say which pool: "add data" or "add log".' 'Yellow') }
            if (-not $Catalog) { return (& $result $false 'Adding a destination needs the replica''s path catalog.' 'Yellow') }
            $path = Read-AgPathChoice -Catalog $Catalog -Kind $kind -Prompt ('  Add a {0} destination' -f $kind.ToLower())
            if (Get-AgPlacementDestinationByPath -Board $Board -Path $path -Kind $kind) {
                return (& $result $false ('{0} is already in the {1} pool.' -f $path, $kind.ToLower()) 'Yellow')
            }
            Save-AgPlacementUndo -Board $Board
            $d = Add-AgPlacementDestination -Board $Board -Kind $kind -Path $path
            return (& $result $false ('Added {0} = {1}. Nothing is on it yet: "auto" rebalances across it, or "<rows> {0}" sends specific ones.' -f $d.Id, $d.Path))
        }

        { $_ -in @('remove','rm','drop') } {
            if ($rest.Count -ne 1) { return (& $result $false 'remove takes one destination, e.g. "remove D2".' 'Yellow') }
            $d = Get-AgPlacementDestination -Board $Board -Id $rest[0]
            if (-not $d) { return (& $result $false ("There is no destination '{0}'." -f $rest[0]) 'Yellow') }
            $others = @($Board.Destinations | Where-Object { $_.Kind -eq $d.Kind -and $_.Id -ne $d.Id })
            if ($others.Count -eq 0) { return (& $result $false ('{0} is the only {1} destination; add another before removing it.' -f $d.Id, $d.Kind.ToLower()) 'Yellow') }
            $sel = Resolve-AgPlacementSelection -Board $Board -Tokens @($d.Id)
            Save-AgPlacementUndo -Board $Board
            [void]$Board.Destinations.Remove($d)
            Invoke-AgPlacementBalance -Board $Board -Slots @($sel.Slots)
            return (& $result $false ('Removed {0}; its {1} placement(s) were rebalanced across the rest of the {2} pool.' -f $d.Id, @($sel.Slots).Count, $d.Kind.ToLower()))
        }
    }

    # <selector...> <dest> [<dest>] - destinations are read from the end, at most one of
    # each kind, so that "D1 D3" reads as "what is on D1, to D3".
    $targets = @{}
    $i = $tokens.Count - 1
    while ($i -ge 1) {
        $tok = $tokens[$i]
        if ($tok -notmatch '^[DdLl]\d+$') { break }
        $d = Get-AgPlacementDestination -Board $Board -Id $tok
        if (-not $d) {
            return (& $result $false ("There is no destination '{0}'. The destinations are listed under the table." -f $tok) 'Yellow')
        }
        if ($targets.ContainsKey($d.Kind)) { break }
        $targets[$d.Kind] = $d
        $i--
    }
    if ($targets.Count -eq 0) {
        return (& $result $false ("Did not understand '{0}'. Type ? for the list of commands." -f $Text.Trim()) 'Yellow')
    }

    $sel = Resolve-AgPlacementSelection -Board $Board -Tokens @($tokens[0..$i])
    if ($sel.Error) { return (& $result $false $sel.Error 'Yellow') }

    Save-AgPlacementUndo -Board $Board
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($kind in 'Data','Log') {
        if (-not $targets.ContainsKey($kind)) { continue }
        $dest = $targets[$kind]
        $n = 0
        foreach ($s in $sel.Slots) {
            if ($s.Kind -ne $kind) { continue }
            $s.Dir = $dest.Path
            $s.Pinned = $true
            $n++
        }
        $parts.Add(('{0} {1} placement(s) to {2}' -f $n, $kind.ToLower(), $dest.Id))
    }
    $msg = 'Moved ' + ($parts -join ', ') + '.'
    if (@($sel.Slots | Where-Object { $targets.ContainsKey($_.Kind) }).Count -eq 0) {
        [void]$Board.History.RemoveAt($Board.History.Count - 1)
        $kinds = (@($targets.Keys) | ForEach-Object { $_.ToLower() }) -join ' or '
        return (& $result $false ('None of the selected rows has {0} files, so nothing moved. D destinations take data files, L destinations log files.' -f $kinds) 'Yellow')
    }
    return (& $result $false $msg)
}

#endregion

#region -- Showing the board --------------------------------------------------

function Get-AgPlacementDirLabel {
    <#
    .SYNOPSIS
        How an assignment is shown in the table: its destination id, or 'src' for a kept
        source directory that is not in either pool - with a * when the operator put it
        there, which is what a bare 'auto' leaves alone.
    #>
    param([Parameter(Mandatory)][psobject]$Board, [Parameter(Mandatory)][psobject]$Slot)
    if (-not $Slot.Dir) { return '--' }
    $mark = if ($Slot.Pinned) { '*' } else { '' }
    $d = Get-AgPlacementDestinationByPath -Board $Board -Path $Slot.Dir -Kind $Slot.Kind
    if ($d) { return ($d.Id + $mark) }
    return ('src' + $mark)
}

function Get-AgUsageBar {
    param([long]$Bytes, [AllowNull()]$FreeBytes, [int]$Width = 20)
    if ($null -eq $FreeBytes -or $FreeBytes -le 0) { return ('[' + ('?' * $Width) + ']') }
    $fill = [int][math]::Ceiling(($Bytes / [double]$FreeBytes) * $Width)
    if ($Bytes -gt 0 -and $fill -lt 1) { $fill = 1 }
    if ($fill -gt $Width) { $fill = $Width }
    return ('[' + ('#' * $fill) + ('.' * ($Width - $fill)) + ']')
}

function Show-AgPlacementBoard {
    <#
    .SYNOPSIS
        The table of rows and assignments, then the ledger: destinations, then volumes.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [string]$Title
    )

    Write-Host ''
    if ($Title) { Write-Host $Title -ForegroundColor Cyan }

    $nameW = 14
    foreach ($r in $Board.Rows) {
        $n = if ($Board.Precision -eq 'FILE') { '{0}.{1}' -f $r.DatabaseName, $r.LogicalName } else { $r.DatabaseName }
        if ($n.Length -gt $nameW) { $nameW = $n.Length }
    }
    if ($nameW -gt 44) { $nameW = 44 }
    $noW = ([string]$Board.Rows.Count).Length

    if ($Board.Precision -eq 'DATABASE') {
        Write-Host (('  {0,' + $noW + '}  {1,-' + $nameW + '}  {2,-18}   {3}') -f '#', 'Database', '      Data -> to', '       Log -> to') -ForegroundColor DarkGray
        foreach ($r in $Board.Rows) {
            $cells = @{ Data = ''; Log = '' }
            foreach ($s in $r.Slots) {
                $cells[$s.Kind] = '{0,10} -> {1,-4}' -f (Format-AgBytes $s.Bytes), (Get-AgPlacementDirLabel -Board $Board -Slot $s)
            }
            $name = $r.DatabaseName
            if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW - 1) + '~' }
            Write-Host (('  {0,' + $noW + '}  {1,-' + $nameW + '}  {2,-18}   {3}') -f $r.No, $name, $cells.Data, $cells.Log)
        }
    } else {
        Write-Host (('  {0,' + $noW + '}  {1,-' + $nameW + '}  {2,-5} {3,10}  ->') -f '#', 'Database.File', 'Kind', 'Size') -ForegroundColor DarkGray
        foreach ($r in $Board.Rows) {
            $s = $r.Slots[0]
            $name = '{0}.{1}' -f $r.DatabaseName, $r.LogicalName
            if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW - 1) + '~' }
            Write-Host (('  {0,' + $noW + '}  {1,-' + $nameW + '}  {2,-5} {3,10}  -> {4}') -f `
                $r.No, $name, (Get-AgFileKindLabel $r.FileType), (Format-AgBytes $s.Bytes), (Get-AgPlacementDirLabel -Board $Board -Slot $s))
        }
    }

    if (@(Get-AgPlacementSlot -Board $Board | Where-Object { $_.Pinned }).Count -gt 0) {
        Write-Host '  * placed by you - "auto" leaves these alone' -ForegroundColor DarkGray
    }

    $ledger = Get-AgPlacementLedger -Board $Board

    Write-Host ''
    Write-Host '  Destinations' -ForegroundColor Cyan
    $pathW = Get-AgPathColumnWidth -Paths @($Board.Destinations | ForEach-Object { $_.Path }) -Minimum 12
    foreach ($e in $ledger.Destinations) {
        $d = $e.Destination
        $countText = if ($Board.Precision -eq 'DATABASE') {
            $dbs = @(Get-AgPlacementSlot -Board $Board | Where-Object { $_.Kind -eq $d.Kind -and $_.Dir -and $_.Dir.TrimEnd('\').ToLowerInvariant() -eq $d.Path.TrimEnd('\').ToLowerInvariant() }).Count
            '{0,3} db(s)' -f $dbs
        } else {
            '{0,3} file(s)' -f $e.Files
        }
        Write-Host (('    {0,-4} {1,-' + $pathW + '}  {2,-4}  {3}  {4,10}') -f $d.Id, $d.Path, $d.Kind.ToLower(), $countText, (Format-AgBytes $e.Bytes))
    }
    foreach ($o in $ledger.Other) {
        Write-Host (('    {0,-4} {1,-' + $pathW + '}  {2,-4}  {3,3} file(s)  {4,10}   (kept where it is today)') -f 'src', $o.Path, $o.Kind.ToLower(), $o.Files, (Format-AgBytes $o.Bytes)) -ForegroundColor DarkGray
    }

    Write-Host ''
    $freeNote = if (@($Board.Replicas).Count -gt 1) { ' - free is the smallest of ' + ($Board.Replicas -join ', ') } else { '' }
    Write-Host ('  Volumes  (directories on one volume share its space{0})' -f $freeNote) -ForegroundColor Cyan
    Write-Host ('    {0,-4} {1,-22} {2,12} {3,12} {4,12}' -f '', '', 'free now', 'assigned', 'left after') -ForegroundColor DarkGray
    foreach ($v in $ledger.Volumes) {
        $leftText = if ($null -eq $v.LeftBytes) { 'unknown' } elseif ($v.LeftBytes -lt 0) { '-' + (Format-AgBytes (-$v.LeftBytes)) } else { Format-AgBytes $v.LeftBytes }
        $freeText = if ($null -eq $v.FreeBytes) { 'unknown' } else { Format-AgBytes $v.FreeBytes }
        $line = '    {0,-4} {1,-22} {2,12} {3,12} {4,12}   {5}' -f ($v.Volume + ':'), (Get-AgUsageBar -Bytes $v.Bytes -FreeBytes $v.FreeBytes), $freeText, (Format-AgBytes $v.Bytes), $leftText, ($v.Ids -join ' ')
        if (-not $v.Fits) {
            Write-Host ($line + '   << OVER') -ForegroundColor Yellow
        } else {
            Write-Host $line
        }
        if (@($v.MissingOn).Count -gt 0) {
            Write-Host ('         ! there is no {0}: drive on {1} - preflight will fail there' -f $v.Volume, ($v.MissingOn -join ', ')) -ForegroundColor Yellow
        }
    }

    foreach ($c in (Get-AgPlacementCollision -Board $Board)) {
        Write-Host ('  ! same path twice: {0}' -f $c) -ForegroundColor Yellow
    }
}

#endregion

#region -- The interactive pieces ---------------------------------------------

function Get-AgPathCandidateNote {
    <#
    .SYNOPSIS
        The annotation shown next to a catalog directory: where it came from and how much
        room its volume has.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind,
        [AllowNull()]$FreeBytes
    )
    $notes = New-Object System.Collections.Generic.List[string]
    switch ($Candidate.Origin) {
        'default' { $notes.Add(('default {0} location' -f $Kind.ToLower())) }
        'inuse'   { $notes.Add(('holds {0} database file(s)' -f $Candidate.FileCount)) }
        'folder'  { $notes.Add('existing folder, empty') }
        'volume'  { $notes.Add('volume root') }
    }
    if ($Candidate.IsDefault -and $Candidate.Origin -ne 'default') { $notes.Add(('default {0} location' -f $Kind.ToLower())) }
    $notes.Add((Get-AgFreeSpaceText $FreeBytes))
    return ($notes -join ', ')
}

function Read-AgDestinationPool {
    <#
    .SYNOPSIS
        Picks the SET of directories one kind of file may be spread across, by number.
    .OUTPUTS
        string[] of directories, in the order given.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][ValidateSet('Data','Log')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$FreeSpace,
        [Parameter(Mandatory)][long]$TotalBytes,
        [hashtable]$MissingVolume = @{}
    )

    $cands = if ($Kind -eq 'Data') { @($Catalog.DataPaths) } else { @($Catalog.LogPaths) }
    $numW  = ([string]($cands.Count + 1)).Length
    $fmt   = '  [{0,' + $numW + '}] {1,-' + (Get-AgPathColumnWidth -Paths @($cands | ForEach-Object { $_.Path })) + '}  {2}'

    Write-Host ''
    Write-Host ('Which directories should {0} files be spread across?  ({1} of {0} files in total)' -f $Kind.ToLower(), (Format-AgBytes $TotalBytes)) -ForegroundColor Cyan
    Write-Host '  Pick every one you want used - e.g. 2,3,4 - and they are filled automatically, keeping the' -ForegroundColor DarkGray
    Write-Host '  most room free on each volume. You can move anything afterwards.' -ForegroundColor DarkGray

    $defaultIdx = 0
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $v = Get-AgPathVolume $c.Path
        $free = $null; if ($v -and $FreeSpace.ContainsKey($v)) { $free = $FreeSpace[$v] }
        if ($c.IsDefault) { $defaultIdx = $i }
        $note = Get-AgPathCandidateNote -Candidate $c -Kind $Kind -FreeBytes $free
        if ($v -and $MissingVolume.ContainsKey($v)) {
            Write-Host ($fmt -f ($i + 1), $c.Path, ($note + ' - NOT on ' + ($MissingVolume[$v] -join ', '))) -ForegroundColor Yellow
        } else {
            Write-Host ($fmt -f ($i + 1), $c.Path, $note)
        }
    }
    $typeNo = $cands.Count + 1
    Write-Host (('  [{0,' + $numW + '}] Type paths that are not listed (they do not have to exist yet)') -f $typeNo)

    while ($true) {
        $defText = if ($cands.Count -gt 0) { " [default $($defaultIdx + 1)]" } else { '' }
        $raw = (Read-AgLine -Prompt ("Numbers (e.g. 1,3 or 2-4){0}" -f $defText)).Trim()
        if (-not $raw -and $cands.Count -gt 0) { $raw = [string]($defaultIdx + 1) }

        $idx = Read-AgNumberSet -Text $raw -Max $typeNo
        if ($null -eq $idx -or @($idx).Count -eq 0) {
            Write-Host ("  Use numbers, commas and ranges within 1-{0}." -f $typeNo) -ForegroundColor Yellow
            continue
        }

        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($n in $idx) {
            if ($n -eq $typeNo) { continue }
            $paths.Add($cands[$n - 1].Path)
        }
        if (@($idx) -contains $typeNo) {
            Write-Host ('  Type one directory per line as {0} sees it; ENTER on an empty line when done.' -f $Catalog.Instance) -ForegroundColor DarkGray
            while ($true) {
                $p = (Read-AgLine -Prompt '  Directory').Trim()
                if (-not $p) { break }
                if ($p -notmatch $script:AgRootedPathPattern) {
                    Write-Host '  Enter a rooted path, such as E:\SQLData or \\fileserver\share.' -ForegroundColor Yellow
                    continue
                }
                $paths.Add($p.TrimEnd('\'))
            }
        }
        if ($paths.Count -eq 0) {
            Write-Host '  At least one directory is needed.' -ForegroundColor Yellow
            continue
        }
        return @($paths.ToArray())
    }
}

function Read-AgPlacementBoard {
    <#
    .SYNOPSIS
        The board's command loop. Returns when the operator finishes.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [psobject]$Catalog,
        [string]$Title
    )

    $msg = $null; $color = 'Gray'
    $first = $true
    while ($true) {
        Show-AgPlacementBoard -Board $Board -Title $Title
        if ($first) {
            Write-Host ''
            Write-Host '  Adjust with "<rows> <destination>" - e.g. 1-5,9 D2 or Sales* L1 or D1 D3 - or "auto" to' -ForegroundColor DarkGray
            Write-Host '  rebalance. ? lists every command. Press ENTER when it looks right.' -ForegroundColor DarkGray
            $first = $false
        }
        if ($msg) { Write-Host ''; Write-Host ('  ' + $msg) -ForegroundColor $color }

        $raw = Read-AgLine -Prompt 'Board'
        $r = Invoke-AgPlacementCommand -Board $Board -Text $raw -Catalog $Catalog
        if ($r.Done) { return }
        $msg = $r.Message; $color = $r.Color
    }
}

function Copy-AgPlacementAssignment {
    <#
    .SYNOPSIS
        Starts a board from another one's destinations and assignments - the second replica
        of a per-replica layout is usually the first one with a difference or two.
    #>
    param(
        [Parameter(Mandatory)][psobject]$From,
        [Parameter(Mandatory)][psobject]$To
    )
    foreach ($d in $From.Destinations) {
        $To.Destinations.Add([pscustomobject]@{ Id = $d.Id; Kind = $d.Kind; Path = $d.Path; Volume = $d.Volume })
    }
    $src = @(Get-AgPlacementSlot -Board $From)
    $dst = @(Get-AgPlacementSlot -Board $To)
    for ($i = 0; $i -lt $dst.Count; $i++) { $dst[$i].Dir = $src[$i].Dir; $dst[$i].Pinned = $src[$i].Pinned }
}

function ConvertTo-AgFileLayoutEntry {
    <#
    .SYNOPSIS
        A finished board as the plan entry for one replica.
    .DESCRIPTION
        The replica-level DataPath / LogPath - the fallback for a file that joins a database
        after the plan was built - is the destination of that kind with the most room left,
        which is where such a file has the best chance of fitting.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Board,
        [Parameter(Mandatory)][string]$Replica,
        [psobject]$InstanceInfo
    )

    $ledger = Get-AgPlacementLedger -Board $Board
    $fallback = @{}
    foreach ($kind in 'Data','Log') {
        $best = $null; $bestLeft = $null
        foreach ($e in @($ledger.Destinations | Where-Object { $_.Destination.Kind -eq $kind })) {
            $v = @($ledger.Volumes | Where-Object { $_.Volume -eq $e.Destination.Volume })
            $left = if ($v.Count -gt 0 -and $null -ne $v[0].LeftBytes) { [double]$v[0].LeftBytes } else { [double]::MinValue }
            if ($null -eq $best -or $left -gt $bestLeft) { $best = $e.Destination; $bestLeft = $left }
        }
        $fallback[$kind] = if ($best) { $best.Path } else { $null }
    }
    if (-not $fallback.Data -and $InstanceInfo) { $fallback.Data = Get-AgDefaultPathText $InstanceInfo.DefaultDataPath }
    if (-not $fallback.Log  -and $InstanceInfo) { $fallback.Log  = Get-AgDefaultPathText $InstanceInfo.DefaultLogPath }

    $dbs   = New-Object System.Collections.Generic.List[psobject]
    $files = New-Object System.Collections.Generic.List[psobject]
    foreach ($r in $Board.Rows) {
        if ($Board.Precision -eq 'DATABASE') {
            $d = @($r.Slots | Where-Object { $_.Kind -eq 'Data' })
            $l = @($r.Slots | Where-Object { $_.Kind -eq 'Log' })
            $dbs.Add([pscustomobject]@{
                DatabaseName = $r.DatabaseName
                DataPath     = $(if ($d.Count -gt 0) { $d[0].Dir } else { $null })
                LogPath      = $(if ($l.Count -gt 0) { $l[0].Dir } else { $null })
            })
        } else {
            $files.Add([pscustomobject]@{
                DatabaseName    = $r.DatabaseName
                LogicalName     = $r.LogicalName
                FileType        = $r.FileType
                TargetDirectory = $r.Slots[0].Dir
                TargetPath      = $null
            })
        }
    }

    return [pscustomobject]@{
        Replica   = $Replica
        Precision = $Board.Precision
        DataPath  = $fallback.Data
        LogPath   = $fallback.Log
        Databases = @($dbs.ToArray())
        Files     = @($files.ToArray())
    }
}

function Read-AgPlacementLayout {
    <#
    .SYNOPSIS
        DATABASE / FILE precision of the CUSTOM layout, by board. Returns one plan entry per
        restore target.
    .PARAMETER PerReplica
        Answer separately for each replica. Otherwise one board is used for all of them, and
        it counts on the smallest free space any of them reports.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('DATABASE','FILE')][string]$Precision,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string[]]$RestoreTargets,
        [Parameter(Mandatory)][hashtable]$SourceFiles,
        [Parameter(Mandatory)][hashtable]$Catalogs,
        [bool]$PerReplica = $false
    )

    $groups = New-Object System.Collections.Generic.List[object]
    if ($PerReplica) { foreach ($t in $RestoreTargets) { $groups.Add(@($t)) } }
    else             { $groups.Add(@($RestoreTargets)) }

    $totals = @{ Data = [long]0; Log = [long]0 }
    foreach ($db in $Databases) {
        foreach ($f in @($SourceFiles[$db])) {
            if ($f.FileType -eq 'L') { $totals.Log += [long]$f.SizeBytes } else { $totals.Data += [long]$f.SizeBytes }
        }
    }

    $entries  = New-Object System.Collections.Generic.List[psobject]
    $previous = $null
    foreach ($group in $groups) {
        $replicas = @($group)
        $catalog  = $Catalogs[$replicas[0]]
        $space    = Get-AgSharedFreeSpace -Replicas $replicas -Catalogs $Catalogs
        $board    = New-AgPlacementBoard -Precision $Precision -Databases $Databases -SourceFiles $SourceFiles `
                        -FreeSpace $space.Free -MissingVolume $space.Missing -Replicas $replicas

        $title = if ($replicas.Count -gt 1) { 'Placement - used on every replica: ' + ($replicas -join ', ') } else { 'Placement on ' + $replicas[0] }
        Write-Host ''
        Write-Host $title -ForegroundColor Cyan

        $fresh = $true
        if ($previous) {
            $start = Read-AgChoice -DefaultIndex 0 -Title ('How should {0} start?' -f $replicas[0]) -Items @(
                ('From the assignments just made for {0} - then change what differs.' -f $previous.Replicas[0])
                'Fresh - pick its directories and balance from scratch.'
            )
            if ($start -like 'From*') {
                Copy-AgPlacementAssignment -From $previous -To $board
                $fresh = $false
            }
        }
        if ($fresh) {
            foreach ($kind in 'Data','Log') {
                $pool = @(Read-AgDestinationPool -Catalog $catalog -Kind $kind -FreeSpace $space.Free -TotalBytes $totals[$kind] -MissingVolume $space.Missing)
                foreach ($p in $pool) { [void](Add-AgPlacementDestination -Board $board -Kind $kind -Path $p) }
            }
            Invoke-AgPlacementBalance -Board $board -Slots @(Get-AgPlacementSlot -Board $board)
        }

        Read-AgPlacementBoard -Board $board -Catalog $catalog -Title $title

        foreach ($r in $replicas) {
            $entries.Add((ConvertTo-AgFileLayoutEntry -Board $board -Replica $r -InstanceInfo $Catalogs[$r].InstanceInfo))
        }
        $previous = $board
    }
    return @($entries.ToArray())
}

#endregion
