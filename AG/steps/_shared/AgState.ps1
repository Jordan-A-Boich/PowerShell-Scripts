#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — durable plan + per-database progress, so an interrupted run resumes.

.DESCRIPTION
    The state file is a HINT, never the source of truth. Every step re-checks the live
    server state before acting, so a deleted, stale or hand-edited state file can slow a
    re-run down but cannot make it do the wrong thing. What the file buys us is:

      * the operator is not re-prompted for the whole plan on a resume, and
      * a completed multi-terabyte FULL backup can be reused instead of retaken.

    Credentials are never written to disk.
#>

Set-StrictMode -Version Latest

$script:AgStateDirectory = $null

function Initialize-AgState {
    param([Parameter(Mandatory)][string]$StateDirectory)
    if (-not (Test-Path $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }
    $script:AgStateDirectory = $StateDirectory
}

function Get-AgStatePath {
    <#
    .SYNOPSIS
        One file per plan, named by its PlanId (CREATE-<AgName> or ADD-<AgName>), so an
        Initialize-AG run and a later Add-AGDatabase run against the same AG never share
        or overwrite each other's progress.
    #>
    param([Parameter(Mandatory)][string]$PlanId)
    Join-Path $script:AgStateDirectory ("{0}.json" -f (Get-AgSafeFileToken $PlanId))
}

function Save-AgPlan {
    param([Parameter(Mandatory)][psobject]$Plan)

    $path = Get-AgStatePath -PlanId $Plan.PlanId
    $copy = $Plan | Select-Object -Property * -ExcludeProperty Credential
    $copy | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    Write-AgLog "Saved plan state: $path" DEBUG
}

function Get-AgSavedPlan {
    <#
    .OUTPUTS
        The saved plan, or $null when there is none / it cannot be parsed.
    #>
    param([Parameter(Mandatory)][string]$PlanId)

    $path = Get-AgStatePath -PlanId $PlanId
    if (-not (Test-Path $path)) { return $null }
    try {
        return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-AgLog "Ignoring unreadable state file '$path': $($_.Exception.Message)" WARN
        return $null
    }
}

function Complete-AgPlan {
    <#
    .SYNOPSIS
        Marks a plan finished and moves its file to staterchive.
    .DESCRIPTION
        Only unfinished plans are offered for resume. A finished one is archived rather than
        deleted, so what a run decided stays inspectable, but it never turns up in the
        resume menu again pointing at work that is already done.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    $Plan.Completed = $true
    Save-AgPlan -Plan $Plan
    $path    = Get-AgStatePath -PlanId $Plan.PlanId
    $archive = Join-Path $script:AgStateDirectory 'archive'
    if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
    $dest = Join-Path $archive ('{0}_{1}.json' -f (Get-AgSafeFileToken $Plan.PlanId), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { Move-Item -Path $path -Destination $dest -Force -ErrorAction Stop } catch { }
    Write-AgLog "Plan archived: $dest" DEBUG
}

function Get-AgSavedPlanList {
    <#
    .SYNOPSIS
        Unfinished plans of one operation (CREATE or ADD), newest first.
    #>
    param([Parameter(Mandatory)][ValidateSet('CREATE','ADD')][string]$Operation)
    if (-not $script:AgStateDirectory -or -not (Test-Path $script:AgStateDirectory)) { return @() }
    $plans = foreach ($f in (Get-ChildItem -Path $script:AgStateDirectory -Filter '*.json' -File | Sort-Object LastWriteTime -Descending)) {
        try { Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return @($plans | Where-Object {
        $_ -and ($_.PSObject.Properties.Name -contains 'Operation') -and $_.Operation -eq $Operation -and -not $_.Completed
    })
}

function New-AgProgressRecord {
    <#
    .SYNOPSIS
        Empty per-database progress record used by the manual seeding path.
    #>
    param([Parameter(Mandatory)][string]$DatabaseName)
    [pscustomobject]@{
        DatabaseName    = $DatabaseName
        FullBackupFiles = @()
        FullBackupUtc   = $null
        FullCheckpointLsn = $null
        RestoredOn      = @()      # replicas that have the FULL applied
        Restores        = @()      # restore receipts; see New-AgRestoreReceipt
        JoinedOn        = @()      # secondary replicas where the db is joined to the AG
        Completed       = $false
    }
}

function Get-AgProgress {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    $rec = @($Plan.Progress | Where-Object { $_.DatabaseName -eq $DatabaseName })
    if ($rec.Count -gt 0) { return $rec[0] }
    return $null
}

function Set-AgProgress {
    <#
    .SYNOPSIS
        Replaces the progress record for one database and persists the plan.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][psobject]$Record
    )
    $others = @($Plan.Progress | Where-Object { $_.DatabaseName -ne $Record.DatabaseName })
    $Plan.Progress = @($others + $Record)
    Save-AgPlan -Plan $Plan
}

#region ── Restore receipts ──────────────────────────────────────────────────

<#
    One receipt per (replica, backup set). It is written BEFORE the restore starts and
    completed only when the restore returns, which is what makes the two states
    distinguishable afterwards:

      StartedUtc, no CompletedUtc  the restore was interrupted. Re-restoring is correct,
                                   and the resume path does exactly that.
      StartedUtc and CompletedUtc  the restore finished. If SQL Server nevertheless says
                                   the FULL is not applied, something is undoing it, and
                                   restoring it again would only start the loop over.

    That second case is the whole reason this exists: a multi-terabyte restore must never
    be issued twice on the strength of a check that has already been shown to be wrong.
#>

function New-AgRestoreReceipt {
    param(
        [Parameter(Mandatory)][string]$Replica,
        [Parameter(Mandatory)][string]$BackupSetGuid,
        [string]$LastLsn
    )
    [pscustomobject]@{
        Replica       = $Replica
        BackupSetGuid = $BackupSetGuid
        LastLsn       = $LastLsn
        StartedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        CompletedUtc  = $null
    }
}

function Get-AgRestoreReceipt {
    <#
    .OUTPUTS
        The receipt for this backup set on this replica, or $null.
    #>
    param(
        [psobject]$Record,
        [Parameter(Mandatory)][string]$Replica,
        [Parameter(Mandatory)][string]$BackupSetGuid
    )
    if (-not $Record) { return $null }
    $m = @($Record.Restores | Where-Object { $_.Replica -eq $Replica -and $_.BackupSetGuid -eq $BackupSetGuid })
    if ($m.Count -gt 0) { return $m[0] }
    return $null
}

function Set-AgRestoreReceipt {
    <#
    .SYNOPSIS
        Upserts one receipt into the database's progress record and persists the plan.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][psobject]$Record,
        [Parameter(Mandatory)][psobject]$Receipt
    )
    $others = @($Record.Restores | Where-Object {
        -not ($_.Replica -eq $Receipt.Replica -and $_.BackupSetGuid -eq $Receipt.BackupSetGuid)
    })
    $Record.Restores = @($others + $Receipt)
    Set-AgProgress -Plan $Plan -Record $Record
}

#endregion

#region ── Plan (de)serialization ───────────────────────────────────────────

function ConvertTo-AgArray {
    <#
        Normalises a deserialized value to a real array.

        Two traps combine here. ConvertFrom-Json collapses a one-element JSON array to a
        scalar and an empty array to $null. And `return @($x)` unrolls on the way out, so
        the naive fix hands back a scalar again. The leading comma stops the unroll, which
        is safe because every caller assigns the result straight to a property.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return ,@() }
    return ,@($Value)
}

function Restore-AgPlanShape {
    <#
    .SYNOPSIS
        Puts a plan read back from JSON into the shape the steps expect, so that under
        Set-StrictMode -Version Latest a resumed plan behaves exactly as a fresh one.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    foreach ($p in 'SecondaryReplicas','ReplicaNames','Replicas','Databases','Repairs','DropLeftoverCopies',
                   'ContainedLogins','Progress','ShareRoots','FileLayout','OriginalSeedingModes') {
        if ($Plan.PSObject.Properties.Name -notcontains $p) { $Plan | Add-Member -NotePropertyName $p -NotePropertyValue @() }
        $Plan.$p = ConvertTo-AgArray $Plan.$p
    }
    if ($Plan.Listener) { $Plan.Listener.Addresses = ConvertTo-AgArray $Plan.Listener.Addresses }

    foreach ($entry in $Plan.FileLayout) {
        foreach ($p in 'Precision','Databases','Files') {
            if ($entry.PSObject.Properties.Name -notcontains $p) { $entry | Add-Member -NotePropertyName $p -NotePropertyValue $null }
        }
        $entry.Databases = ConvertTo-AgArray $entry.Databases
        $entry.Files     = ConvertTo-AgArray $entry.Files
        foreach ($f in $entry.Files) {
            foreach ($p in 'TargetDirectory','TargetPath') {
                if ($f.PSObject.Properties.Name -notcontains $p) { $f | Add-Member -NotePropertyName $p -NotePropertyValue $null }
            }
        }
    }
    foreach ($rec in $Plan.Progress) {
        if ($rec.PSObject.Properties.Name -notcontains 'Restores') { $rec | Add-Member -NotePropertyName Restores -NotePropertyValue @() }
        $rec.FullBackupFiles = ConvertTo-AgArray $rec.FullBackupFiles
        $rec.RestoredOn      = ConvertTo-AgArray $rec.RestoredOn
        $rec.Restores        = ConvertTo-AgArray $rec.Restores
        $rec.JoinedOn        = ConvertTo-AgArray $rec.JoinedOn
    }
    return $Plan
}

function Select-AgResumePlan {
    <#
    .SYNOPSIS
        Offers any unfinished plan of this operation for resume. Returns the plan, or $null
        to start a new one.
    #>
    param([Parameter(Mandatory)][ValidateSet('CREATE','ADD')][string]$Operation)

    $saved = @(Get-AgSavedPlanList -Operation $Operation)
    if ($saved.Count -eq 0) { return $null }
    $newLabel = if ($Operation -eq 'CREATE') { 'Start a NEW availability group' } else { 'Start a NEW add' }
    $items = @($saved) + @($newLabel)
    $pick = Read-AgChoice -Title 'An unfinished plan was found. What would you like to do?' -Items $items -DefaultIndex 0 -Display {
        param($p)
        if ($p -is [string]) { return $p }
        $done = @(ConvertTo-AgArray $p.Progress | Where-Object { $_.Completed }).Count
        'Resume [{0}] on {1}  ({2} seeding, {3}/{4} databases done, planned {5})' -f `
            $p.AgName, $p.PrimaryReplica, $p.SeedingMode, $done, (ConvertTo-AgArray $p.Databases).Count, ([datetime]$p.CreatedUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    }
    if ($pick -is [string]) { return $null }
    return (Restore-AgPlanShape -Plan $pick)
}

#endregion
