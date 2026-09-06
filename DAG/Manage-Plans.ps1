#Requires -Version 5.1
<#
.SYNOPSIS
    Manage-Plans — find and clean up the saved distributed availability group plans that
    Initialize-DAG.ps1 and Failover-DAG.ps1 offer you, plus the leftovers that belong to them.

.DESCRIPTION
    Everything those two scripts remember between runs is one JSON file per distributed AG
    under .\state. Both enumerate that folder and offer every file in it as a choice —
    neither checks that the distributed AG still exists. Tear a DAG down and its plan keeps
    turning up in the menu, pointing at servers and databases that may be long gone.

    This script probes each saved plan against the live servers and lets you clear the dead
    ones out by number. For every plan you select it removes what would still reference it:

      * the plan file itself (.\state\<DagName>.json) — the entry in both menus. Archived to
        .\state\archive by default, which nothing enumerates, or deleted with -Delete.
      * the SQL Agent transaction log backup job 'DAG-TLogBackup-<DagName>' on every replica
        that still has it. This one matters beyond tidiness: it keeps taking log backups of
        the plan's databases on a schedule, and those backups keep breaking the log chain of
        whatever else backs them up now.
      * with -RemoveBackups, the plan's backup folders (<share>\<DagName>) on any backup
        share this host can reach.

    It also reports 'DAG-TLogBackup-*' jobs found on the probed servers that no saved plan
    accounts for — an orphan left by a plan file that was deleted by hand — and offers them
    for removal in the same list.

    IT NEVER TOUCHES SQL SERVER STATE BEYOND THAT JOB. It does not drop distributed AGs,
    availability groups or databases, and a plan whose DAG is still live is flagged and
    requires an extra confirmation, because forgetting a plan for a running DAG is legal but
    is almost never what you meant. To tear a lab DAG down, use lab\Reset-DagLab.ps1.

.PARAMETER Credential
    A SQL Server login used for every probe connection. When omitted you are asked how to
    authenticate, exactly as the other two scripts do.

.PARAMETER Instance
    Extra SQL Server instances to probe for leftover log backup jobs, beyond the replicas
    named in the saved plans. Use this when the plan file for a DAG has already been deleted
    and you want its job found anyway.

.PARAMETER Delete
    Delete the selected plan files instead of moving them to .\state\archive.

.PARAMETER RemoveBackups
    Also delete each selected plan's backup folder (<share>\<DagName>) from every backup
    share this host can reach. Off by default: those folders hold the FULL and log backups
    taken during manual seeding, and they are not needed to make the menus forget a plan.

.PARAMETER ListOnly
    Probe and report, then stop. Changes nothing.

.PARAMETER Force
    Skip the confirmation prompts, including the one guarding a plan whose distributed AG is
    still live. Intended for automation; think before you use it interactively.

.EXAMPLE
    .\Manage-Plans.ps1
    Probe every saved plan, then choose by number (1,3,4 or 1-3) which to clean up.

.EXAMPLE
    .\Manage-Plans.ps1 -ListOnly
    Show what is saved and what state each plan is in. Changes nothing.

.EXAMPLE
    .\Manage-Plans.ps1 -Delete -RemoveBackups
    Clean up completely: delete the plan files outright and remove their backup folders.

.EXAMPLE
    .\Manage-Plans.ps1 -Instance SQLLAB-SQL1,SQLLAB-SQL3
    Also probe those two instances for log backup jobs no saved plan accounts for.
#>

[CmdletBinding()]
param(
    [pscredential]$Credential,

    [string[]]$Instance,

    [switch]$Delete,

    [switch]$RemoveBackups,

    [switch]$ListOnly,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$SharedDir  = Join-Path $ScriptRoot 'steps\_shared'
$StateDir   = Join-Path $ScriptRoot 'state'
$ArchiveDir = Join-Path $StateDir 'archive'

#region ── Load modules ──────────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw @'
The SqlServer PowerShell module is required and was not found.

    Install-Module -Name SqlServer -Scope CurrentUser
'@
}
Import-Module SqlServer -DisableNameChecking -ErrorAction Stop

foreach ($file in @(
        'DagCommon.ps1'      # logging, quoting, Get-DagSafeFileToken, Join-DagPath
        'DagSql.ps1'         # Invoke-DagSql, Test-DagConnection, connection context
        'DagPrompt.ps1'      # Read-DagChoice / Read-DagNumberSet / Read-DagYesNo
        'DagFailover.ps1'    # Get-DagDistributedAgNames
        'DagAgentJob.ps1'    # Get-DagTLogJobName, Uninstall-DagTLogJob, Get-DagPlanShareRoots
    )) {
    . (Join-Path $SharedDir $file)
}

#endregion

#region ── Probes ────────────────────────────────────────────────────────────

<#
    Every probe is cached per instance. The same four replicas appear in every plan of a lab,
    and a plan set of any size otherwise re-tests the same servers a dozen times — which on
    an unreachable instance means a dozen connection timeouts before the menu appears.
#>
$script:ReachCache = @{}
$script:DagCache   = @{}
$script:AgCache    = @{}
$script:JobCache   = @{}

function Test-InstanceReachable {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:ReachCache.ContainsKey($Name)) {
        $script:ReachCache[$Name] = Test-DagConnection -Instance $Name
    }
    return $script:ReachCache[$Name]
}

function Get-InstanceDagName {
    <#
    .SYNOPSIS
        Names of the distributed availability groups that exist on one instance.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:DagCache.ContainsKey($Name)) {
        try   { $script:DagCache[$Name] = @(Get-DagDistributedAgNames -Instance $Name) }
        catch { $script:DagCache[$Name] = @() }
    }
    return $script:DagCache[$Name]
}

function Get-InstanceAgName {
    <#
    .SYNOPSIS
        Names of the ordinary (non-distributed) availability groups on one instance.
    .DESCRIPTION
        Reported so that "the distributed AG is gone but its member availability groups are
        still there" is visible in the listing. That is a normal state after a DAG is dropped
        and the clusters are kept, and it changes nothing about whether the plan is stale.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:AgCache.ContainsKey($Name)) {
        try {
            $rows = Invoke-DagSql -Instance $Name -Retry -Activity 'availability groups' `
                        -Query 'SELECT name AS n FROM sys.availability_groups WHERE is_distributed = 0 ORDER BY name'
            $script:AgCache[$Name] = @($rows | ForEach-Object { [string]$_.n })
        } catch { $script:AgCache[$Name] = @() }
    }
    return $script:AgCache[$Name]
}

function Get-InstanceTLogJobName {
    <#
    .SYNOPSIS
        Every 'DAG-TLogBackup-*' job on one instance.
    .DESCRIPTION
        Read as a set rather than "does the job for THIS plan exist", so the same query also
        finds the jobs no saved plan accounts for.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:JobCache.ContainsKey($Name)) {
        try {
            $rows = Invoke-DagSql -Instance $Name -Retry -Activity 'log backup jobs' -Query @'
SELECT name AS n FROM msdb.dbo.sysjobs WHERE name LIKE 'DAG-TLogBackup-%' ORDER BY name
'@
            $script:JobCache[$Name] = @($rows | ForEach-Object { [string]$_.n })
        } catch { $script:JobCache[$Name] = @() }
    }
    return $script:JobCache[$Name]
}

function Get-DagPlanValue {
    <#
    .SYNOPSIS
        Reads a property from a saved plan, tolerating plans written by older versions that
        never had it.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($Plan.PSObject.Properties.Name -contains $Name -and $null -ne $Plan.$Name) { return $Plan.$Name }
    return $Default
}

function Get-DagPlanBackupFolder {
    <#
    .SYNOPSIS
        The <share>\<DagName> folder on each of the plan's backup shares, with whether this
        host can see it.
    .DESCRIPTION
        State is 'present', 'absent' or 'unreachable' — the share is written to by the SQL
        Server service accounts, not by whoever runs this, so "I cannot see it" is a normal
        answer and must not be reported as "it is not there".
    #>
    param([Parameter(Mandatory)][psobject]$Plan, [Parameter(Mandatory)][string]$DagName)

    $token = Get-DagSafeFileToken $DagName
    foreach ($root in @(Get-DagPlanShareRoots -Plan $Plan)) {
        $path = Join-DagPath -Path $root -ChildPath @($token)

        # Test-Path answers $false both for "not there" and for "I cannot see the share",
        # so the share root is checked first. Otherwise a share this account has no rights
        # to would be reported as an already-cleaned plan.
        $rootVisible = try { Test-Path -LiteralPath $root } catch { $false }
        $state = if (-not $rootVisible) { 'unreachable' }
                 else { try { if (Test-Path -LiteralPath $path) { 'present' } else { 'absent' } } catch { 'unreachable' } }

        [pscustomobject]@{ Path = $path; State = $state }
    }
}

function Get-DagPlanFinding {
    <#
    .SYNOPSIS
        One saved plan, probed against the servers it names.
    .OUTPUTS
        A finding object; see Show-DagFindingList for what each field is used for.
    #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    try { $plan = Get-Content -Path $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $plan = $null }

    # A file that is not a plan is still something the menus try to read, so it is still a
    # finding — just one with nothing to probe.
    if (-not $plan -or -not ($plan.PSObject.Properties.Name -contains 'DagName')) {
        return [pscustomobject]@{
            Kind = 'Plan'; Name = $File.BaseName; File = $File.FullName; Status = 'UNREADABLE'
            GlobalAg = ''; ForwarderAg = ''; Databases = @(); CreatedUtc = $null
            Replicas = @(); Reachable = @(); Unreachable = @(); LiveOn = @()
            MemberAgsPresent = @(); JobOn = @(); BackupFolders = @()
        }
    }

    $dagName  = [string]$plan.DagName
    $globalAg = [string](Get-DagPlanValue -Plan $plan -Name 'GlobalAgName'    -Default '')
    $fwdAg    = [string](Get-DagPlanValue -Plan $plan -Name 'ForwarderAgName' -Default '')

    $replicas = @()
    foreach ($prop in 'GlobalReplicas','ForwarderReplicas') {
        $replicas += @(Get-DagPlanValue -Plan $plan -Name $prop -Default @())
    }
    $replicas = @($replicas | Where-Object { $_ } | Select-Object -Unique)

    $reachable = @(); $unreachable = @(); $liveOn = @(); $agsPresent = @(); $jobOn = @()
    foreach ($r in $replicas) {
        if (-not (Test-InstanceReachable -Name $r)) { $unreachable += $r; continue }
        $reachable += $r
        if ((Get-InstanceDagName -Name $r) -contains $dagName) { $liveOn += $r }
        foreach ($ag in @($globalAg, $fwdAg)) {
            if ($ag -and (Get-InstanceAgName -Name $r) -contains $ag -and $agsPresent -notcontains $ag) {
                $agsPresent += $ag
            }
        }
        if ((Get-InstanceTLogJobName -Name $r) -contains (Get-DagTLogJobName -DagName $dagName)) { $jobOn += $r }
    }

    # LIVE and GONE are claims about the servers. UNKNOWN is the honest answer when nothing
    # the plan names could be reached — it is never upgraded to GONE, because "I could not
    # connect" and "it is not there" are the same observation only to a careless tool.
    $status = if ($liveOn.Count -gt 0)     { 'LIVE' }
              elseif ($reachable.Count -eq 0) { 'UNKNOWN' }
              else                            { 'GONE' }

    [pscustomobject]@{
        Kind             = 'Plan'
        Name             = $dagName
        File             = $File.FullName
        Status           = $status
        GlobalAg         = $globalAg
        ForwarderAg      = $fwdAg
        Databases        = @(Get-DagPlanValue -Plan $plan -Name 'Databases' -Default @())
        CreatedUtc       = Get-DagPlanValue -Plan $plan -Name 'CreatedUtc' -Default $null
        Replicas         = $replicas
        Reachable        = $reachable
        Unreachable      = $unreachable
        LiveOn           = $liveOn
        MemberAgsPresent = $agsPresent
        JobOn            = $jobOn
        BackupFolders    = @(Get-DagPlanBackupFolder -Plan $plan -DagName $dagName)
    }
}

function Get-DagOrphanJobFinding {
    <#
    .SYNOPSIS
        Log backup jobs on the probed instances that no saved plan accounts for.
    .DESCRIPTION
        What a hand-deleted plan file leaves behind. The plan is gone from both menus, so
        nothing offers to clean the job up, and it keeps backing up logs on a schedule.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Instances,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownDagNames
    )

    $byDag = @{}
    foreach ($i in $Instances) {
        if (-not (Test-InstanceReachable -Name $i)) { continue }
        foreach ($job in (Get-InstanceTLogJobName -Name $i)) {
            $dagName = $job.Substring('DAG-TLogBackup-'.Length)
            if ($KnownDagNames -contains $dagName) { continue }
            if (-not $byDag.ContainsKey($dagName)) { $byDag[$dagName] = New-Object System.Collections.Generic.List[string] }
            $byDag[$dagName].Add($i)
        }
    }

    foreach ($dagName in ($byDag.Keys | Sort-Object)) {
        $instances = @($byDag[$dagName])
        [pscustomobject]@{
            Kind             = 'OrphanJob'
            Name             = $dagName
            File             = $null
            Status           = 'ORPHAN'
            GlobalAg         = ''
            ForwarderAg      = ''
            Databases        = @()
            CreatedUtc       = $null
            Replicas         = $instances
            Reachable        = $instances
            Unreachable      = @()
            LiveOn           = @()
            MemberAgsPresent = @()
            JobOn            = $instances
            BackupFolders    = @()
        }
    }
}

#endregion

#region ── Presentation ──────────────────────────────────────────────────────

function Get-DagFindingColor {
    param([Parameter(Mandatory)][string]$Status)
    switch ($Status) {
        'LIVE'    { 'Green'  }
        'GONE'    { 'Yellow' }
        'ORPHAN'  { 'Yellow' }
        default   { 'DarkGray' }   # UNKNOWN / UNREADABLE
    }
}

function Show-DagFindingList {
    param([Parameter(Mandatory)][object[]]$Findings)

    Write-Host ''
    Write-Host 'Saved plans and leftovers found:' -ForegroundColor White
    Write-Host ('-' * 78) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Findings.Count; $i++) {
        $f = $Findings[$i]
        Write-Host ('  [{0}] ' -f ($i + 1)) -ForegroundColor White -NoNewline
        Write-Host ('{0,-28}' -f $f.Name) -NoNewline
        Write-Host ('{0,-11}' -f $f.Status) -ForegroundColor (Get-DagFindingColor $f.Status) -NoNewline

        $detail = switch ($f.Kind) {
            'OrphanJob' { "log backup job with no saved plan" }
            default {
                if ($f.Status -eq 'UNREADABLE') { 'file is not a readable plan' }
                else { "{0} -> {1}, {2} database(s)" -f $f.GlobalAg, $f.ForwarderAg, $f.Databases.Count }
            }
        }
        Write-Host $detail -ForegroundColor DarkGray

        #region The second line: what cleaning this up would actually act on
        $bits = @()
        if ($f.Kind -eq 'Plan') {
            $bits += "replicas $($f.Reachable.Count)/$($f.Replicas.Count) reachable"
            if ($f.Status -eq 'LIVE')  { $bits += "DAG live on $($f.LiveOn -join ', ')" }
            if ($f.Status -eq 'GONE' -and $f.MemberAgsPresent.Count -gt 0) {
                $bits += "member AG(s) still present: $($f.MemberAgsPresent -join ', ')"
            }
        }
        if ($f.JobOn.Count -gt 0) { $bits += "log backup job on $($f.JobOn -join ', ')" }
        $present = @($f.BackupFolders | Where-Object { $_.State -eq 'present' })
        if ($present.Count -gt 0) { $bits += "backup folder(s): $($present.Count)" }
        if ($f.CreatedUtc) {
            $when = try { ([datetime]$f.CreatedUtc).ToLocalTime().ToString('yyyy-MM-dd') } catch { [string]$f.CreatedUtc }
            $bits += "saved $when"
        }
        if ($bits.Count -gt 0) { Write-Host ('      ' + ($bits -join '  ·  ')) -ForegroundColor DarkGray }
        #endregion
    }

    Write-Host ('-' * 78) -ForegroundColor DarkGray
    Write-Host '  LIVE    = the distributed availability group still exists. Cleaning up only makes' -ForegroundColor DarkGray
    Write-Host '            the menus forget it; the DAG itself is left running.' -ForegroundColor DarkGray
    Write-Host '  GONE    = no reachable replica has this distributed AG. Safe to clear.' -ForegroundColor DarkGray
    Write-Host '  UNKNOWN = none of its replicas answered, so nothing could be checked.' -ForegroundColor DarkGray
    Write-Host '  ORPHAN  = a log backup job whose plan file is already gone.' -ForegroundColor DarkGray
}

function Read-DagFindingSelection {
    <#
    .SYNOPSIS
        Numbered multi-select: "1,3,4", "1-3", "all", or ENTER for nothing.
    .DESCRIPTION
        ENTER means change nothing. Every other prompt in this tool set defaults to the safe
        answer, and here the safe answer is to leave the state directory alone.
    #>
    param([Parameter(Mandatory)][object[]]$Findings)

    Write-Host ''
    Write-Host 'Which of these do you want to clean up?' -ForegroundColor Cyan
    Write-Host '  Numbers, commas and ranges: 1,3,4 or 1-3. "all" for everything listed.' -ForegroundColor DarkGray
    Write-Host '  Press ENTER to change nothing.' -ForegroundColor DarkGray

    while ($true) {
        # A null answer is possible in a non-interactive host, and is the same as ENTER.
        $raw = ([string](Read-Host "Clean up which (1-$($Findings.Count))")).Trim()

        # The leading commas keep an empty or single-item result an ARRAY through the
        # function's return pipeline; without them "nothing" comes back as $null and one
        # item comes back bare, and the caller's .Count fails.
        if (-not $raw -or $raw -match '^(none|0)$') { return ,@() }
        if ($raw -match '^(all|\*)$')               { return ,@($Findings) }

        $idx = Read-DagNumberSet -Text $raw -Max $Findings.Count
        if ($null -eq $idx) {
            Write-Host "  Could not parse that. Use numbers, commas and ranges within 1-$($Findings.Count)." -ForegroundColor Yellow
            continue
        }
        return ,@($idx | ForEach-Object { $Findings[$_ - 1] })
    }
}

function Show-DagCleanupPlan {
    <#
    .SYNOPSIS
        Exactly what will be done, before anything is done.
    .OUTPUTS
        [int] the number of actions the cleanup will perform.
    #>
    param([Parameter(Mandatory)][object[]]$Selected)

    $actions = 0
    Write-Host ''
    Write-Host 'This is what will be done:' -ForegroundColor White
    foreach ($f in $Selected) {
        Write-Host ''
        Write-Host ("  {0}" -f $f.Name) -ForegroundColor White
        if ($f.JobOn.Count -gt 0) {
            Write-Host ("    - remove SQL Agent job '{0}' from: {1}" -f (Get-DagTLogJobName -DagName $f.Name), ($f.JobOn -join ', ')) -ForegroundColor Yellow
            $actions++
        }
        if ($f.File) {
            $verb = if ($Delete) { 'delete' } else { "archive to $ArchiveDir" }
            Write-Host ("    - {0} the plan file {1}" -f $verb, $f.File) -ForegroundColor Yellow
            $actions++
        }
        $present = @($f.BackupFolders | Where-Object { $_.State -eq 'present' })
        if ($RemoveBackups -and $present.Count -gt 0) {
            foreach ($d in $present) {
                Write-Host ("    - DELETE the backup folder {0} and everything under it" -f $d.Path) -ForegroundColor Red
                $actions++
            }
        } elseif ($present.Count -gt 0) {
            Write-Host ("    - leaving {0} backup folder(s) in place (pass -RemoveBackups to delete them)" -f $present.Count) -ForegroundColor DarkGray
        }
        if ($f.Kind -eq 'Plan' -and $f.Unreachable.Count -gt 0) {
            Write-Host ("    ! could not check {0} — if it holds a copy of the job, remove it by hand" -f ($f.Unreachable -join ', ')) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    return $actions
}

#endregion

#region ── Cleanup ───────────────────────────────────────────────────────────

function Invoke-DagFindingCleanup {
    <#
    .OUTPUTS
        pscustomobject with Done and Failed counts.
    #>
    param([Parameter(Mandatory)][psobject]$Finding)

    $done = 0; $failed = 0

    #region The SQL Agent job — removed first
    <#
        Before the plan file, deliberately. If this fails, the file stays put and the job is
        still discoverable on the next run; do it the other way round and a failure here
        leaves a job running with nothing left that names it.
    #>
    if ($Finding.JobOn.Count -gt 0) {
        try {
            Uninstall-DagTLogJob -Instances $Finding.JobOn -DagName $Finding.Name
            $done++
        } catch {
            Write-DagLog "  Could not remove the log backup job for [$($Finding.Name)]: $($_.Exception.Message.Split("`n")[0])" ERROR
            $failed++
        }
    }
    #endregion

    #region Backup folders
    foreach ($d in @($Finding.BackupFolders | Where-Object { $_.State -eq 'present' })) {
        if (-not $RemoveBackups) { continue }

        # Never recurse-delete a path that is not the per-DAG folder this plan owns. A plan
        # with an empty or malformed share root would otherwise resolve to the share itself.
        $leaf = Split-Path -Path $d.Path -Leaf
        if ($leaf -ne (Get-DagSafeFileToken $Finding.Name)) {
            Write-DagLog "  Refusing to delete '$($d.Path)': it is not the [$($Finding.Name)] backup folder." WARN
            $failed++
            continue
        }
        try {
            Remove-Item -LiteralPath $d.Path -Recurse -Force -ErrorAction Stop
            Write-DagLog "  Deleted backup folder $($d.Path)" SUCCESS
            $done++
        } catch {
            Write-DagLog "  Could not delete '$($d.Path)': $($_.Exception.Message.Split("`n")[0])" ERROR
            $failed++
        }
    }
    #endregion

    #region The plan file — the thing both menus read
    if ($Finding.File) {
        try {
            if ($Delete) {
                Remove-Item -LiteralPath $Finding.File -Force -ErrorAction Stop
                Write-DagLog "  Deleted plan file $($Finding.File)" SUCCESS
            } else {
                if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
                $dest = Join-Path $ArchiveDir ("{0}_{1}.json" -f (Get-DagSafeFileToken $Finding.Name), (Get-Date -Format 'yyyyMMdd_HHmmss'))
                Move-Item -LiteralPath $Finding.File -Destination $dest -Force -ErrorAction Stop
                Write-DagLog "  Archived plan file to $dest" SUCCESS
            }
            $done++
        } catch {
            Write-DagLog "  Could not remove '$($Finding.File)': $($_.Exception.Message.Split("`n")[0])" ERROR
            $failed++
        }
    }
    #endregion

    return [pscustomobject]@{ Done = $done; Failed = $failed }
}

#endregion

#region ── Entry ─────────────────────────────────────────────────────────────

try {
    Initialize-DagLog -LogDirectory (Join-Path $ScriptRoot 'logs') -NamePrefix 'Manage-Plans' | Out-Null

    Write-DagBanner 'MANAGE SAVED DISTRIBUTED AG PLANS'
    Write-Host 'Clears out the saved plans that Initialize-DAG.ps1 and Failover-DAG.ps1 offer you,' -ForegroundColor DarkGray
    Write-Host 'along with the log backup jobs those plans left on the servers.' -ForegroundColor DarkGray
    Write-Host "State directory: $StateDir" -ForegroundColor DarkGray

    #region What is saved
    $planFiles = @()
    if (Test-Path $StateDir) {
        # Non-recursive on purpose: state\archive is where cleaned-up plans go, and neither
        # of the two scripts enumerates it. Reading it here would offer to clean up what has
        # already been cleaned up.
        $planFiles = @(Get-ChildItem -Path $StateDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    }

    $extraInstances = @($Instance | Where-Object { $_ })
    if ($planFiles.Count -eq 0 -and $extraInstances.Count -eq 0) {
        Write-Host ''
        Write-DagLog 'No saved plans found — both scripts will start from a clean interview already.' SUCCESS
        Write-DagLog "Pass -Instance <server> to search servers for leftover log backup jobs anyway." INFO
        return
    }
    #endregion

    if ($Credential) {
        Set-DagConnectionContext -Credential $Credential
        Write-DagLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-DagCredential
    }

    #region Probe
    Write-Host ''
    Write-DagLog "Probing $($planFiles.Count) saved plan(s) against the servers they name..." INFO

    $findings = @()
    foreach ($f in $planFiles) { $findings += Get-DagPlanFinding -File $f }

    $probeInstances = @()
    foreach ($f in $findings) { $probeInstances += @($f.Replicas) }
    $probeInstances += $extraInstances
    $probeInstances = @($probeInstances | Where-Object { $_ } | Select-Object -Unique)

    if ($extraInstances.Count -gt 0) {
        Write-DagLog "Also probing: $($extraInstances -join ', ')" INFO
    }
    $findings += @(Get-DagOrphanJobFinding -Instances $probeInstances -KnownDagNames @($findings | ForEach-Object { $_.Name }))

    $unreached = @($probeInstances | Where-Object { -not (Test-InstanceReachable -Name $_) })
    if ($unreached.Count -gt 0) {
        Write-DagLog "Not reachable, so nothing on them could be checked: $($unreached -join ', ')" WARN
    }

    if ($findings.Count -eq 0) {
        Write-Host ''
        Write-DagLog 'Nothing found: no saved plans, and no leftover log backup jobs on the servers probed.' SUCCESS
        return
    }
    #endregion

    Show-DagFindingList -Findings $findings

    if ($ListOnly) {
        Write-Host ''
        Write-DagLog '-ListOnly: nothing was changed.' SUCCESS
        return
    }

    #region Choose
    # Both branches yield an array with the ',@(...)' idiom used throughout this tool set:
    # the leading comma survives the one level of unrolling that assignment applies, so an
    # empty selection stays an empty ARRAY rather than becoming $null. Do NOT wrap this in
    # @() — that re-wraps the already-intact array and produces a nested one, whose single
    # element is an array that has no .JobOn and no .Status.
    $selected = if ($Force) { ,@($findings) } else { Read-DagFindingSelection -Findings $findings }
    if ($selected.Count -eq 0) {
        Write-Host ''
        Write-DagLog 'Nothing selected. No plans were changed.' SUCCESS
        return
    }
    if ($Force) { Write-DagLog "-Force: cleaning up all $($selected.Count) item(s)." WARN }
    #endregion

    #region Confirm
    $actions = Show-DagCleanupPlan -Selected $selected
    if ($actions -eq 0) {
        Write-DagLog 'There is nothing to do for the items selected.' SUCCESS
        return
    }

    $live = @($selected | Where-Object { $_.Status -eq 'LIVE' })
    if ($live.Count -gt 0 -and -not $Force) {
        Write-DagBanner 'ONE OR MORE OF THESE DISTRIBUTED AGs IS STILL LIVE'
        Write-Host ''
        foreach ($f in $live) {
            Write-Host ("  [{0}] exists on {1}" -f $f.Name, ($f.LiveOn -join ', ')) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  Nothing below drops it — the distributed availability group, its databases and its' -ForegroundColor DarkGray
        Write-Host '  replicas are left exactly as they are. What you lose is the saved plan: both scripts' -ForegroundColor DarkGray
        Write-Host '  stop offering it by name, and you re-enter the server names next time. If the plan' -ForegroundColor DarkGray
        Write-Host '  was used for MANUAL seeding you also lose its restore receipts, so an interrupted' -ForegroundColor DarkGray
        Write-Host '  seed can no longer resume and a FULL backup may have to be taken again.' -ForegroundColor DarkGray
        Write-Host ''
        if (-not (Read-DagYesNo -Question 'Forget the saved plan for a distributed AG that is still live?' -DefaultYes $false)) {
            Write-DagLog 'Cancelled. Nothing was changed.' SUCCESS
            return
        }
    }

    if (-not $Force -and -not (Read-DagYesNo -Question "Perform the $actions action(s) listed above?" -DefaultYes $false)) {
        Write-DagLog 'Cancelled. Nothing was changed.' SUCCESS
        return
    }
    #endregion

    #region Do it
    Write-Host ''
    $done = 0; $failed = 0
    foreach ($f in $selected) {
        Write-DagLog "Cleaning up [$($f.Name)]..." INFO
        $r = Invoke-DagFindingCleanup -Finding $f
        $done   += $r.Done
        $failed += $r.Failed
    }
    #endregion

    #region Summary
    Write-DagBanner 'DONE'
    Write-Host ''
    if ($failed -eq 0) {
        Write-DagLog "$done action(s) completed." SUCCESS
    } else {
        Write-DagLog "$done action(s) completed, $failed failed (see above)." WARN
    }

    $remaining = @(Get-ChildItem -Path $StateDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Write-DagLog 'No saved plans remain — both scripts will now start from a fresh interview.' SUCCESS
    } else {
        Write-DagLog "Saved plans still offered by both scripts: $(($remaining | ForEach-Object { $_.BaseName }) -join ', ')" INFO
    }

    Write-Host ''
    Write-Host 'Not touched by this script:' -ForegroundColor DarkGray
    Write-Host '  - distributed availability groups, availability groups and databases on the servers' -ForegroundColor DarkGray
    Write-Host "  - archived plans under $ArchiveDir (nothing reads them)" -ForegroundColor DarkGray
    if (-not $RemoveBackups) {
        Write-Host '  - backup files on the shares (re-run with -RemoveBackups to delete those too)' -ForegroundColor DarkGray
    }
    Write-Host ''
    #endregion
}
catch {
    Write-Host ''
    Write-DagLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-DagLog $_.ScriptStackTrace DEBUG }
    Write-Host ''
    Write-DagLog 'Nothing here is destructive to SQL Server state beyond the log backup job, and the' INFO
    Write-DagLog 'script is safe to re-run: it re-probes everything from scratch.' INFO
    exit 1
}

#endregion
