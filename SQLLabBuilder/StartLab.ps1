#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Start the lab (all clusters, or just the nodes you pick).

    Powers on the domain controller and the SQL nodes you select — the primary AG
    plus any add-cluster AGs — then brings each selected node back to a healthy
    runtime state: data disk online, SQL data/log/backup/temp directories present,
    and the cluster service, SQL Server engine, and SQL Agent running.

.DESCRIPTION
    This is the post-shutdown "turn the lab on" command. Unlike re-running
    .\StartLabBuild.ps1, which only knows about the primary three VMs, this
    enumerates every cluster that has been built (via Get-LabClusterContext +
    checkpoints) and lets you start all of them or a subset.

    The domain controller is ALWAYS started — the SQL nodes need it for DNS, the
    cluster witness share, and Kerberos — so the menu only covers SQL nodes.

    Order of operations:
      1. List every built SQL node VM and prompt for a selection (skipped when
         -Nodes or -All is supplied).
      2. Start the domain controller first and wait until it answers.
      3. Start each selected SQL node VM and wait for its guest's PowerShell Direct.
      4. Run the shared Restore-LabNodeHealth recovery pass on each selected node
         (re-online D:\ if offline, start ClusSvc / MSSQLSERVER / SQL Agent).

    Read-only against configuration and idempotent: already-running VMs and
    already-online disks are left as-is. Invoked via
    .\StartLabBuild.ps1 -Start (recommended) or directly.

.PARAMETER TimeoutSeconds
    Per-phase wait budget for VMs to reach the Running state (default 180).

.PARAMETER Nodes
    Skips the interactive menu and starts exactly these SQL nodes. Accepts menu
    numbers ("1,3,4"), ranges ("1-4"), VM names ("SQLLab-SQL1"), computer names
    ("SQLLAB-SQL1"), the word "all", or "none" (DC only). Values may be comma- or
    space-separated. The DC starts regardless.

.PARAMETER All
    Skips the interactive menu and starts every built SQL node (the previous
    behaviour). Equivalent to -Nodes all.

.EXAMPLE
    .\StartLabBuild.ps1 -Start
    .\StartLab.ps1
    .\StartLab.ps1 -Nodes 1,3,4
    .\StartLab.ps1 -Nodes 1-4
    .\StartLab.ps1 -Nodes SQLLab-SQL1,SQLLab-SQL2
    .\StartLab.ps1 -Nodes none
    .\StartLab.ps1 -All
#>

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 180,

    [string[]]$Nodes,

    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot

#region Shared Write-Log
$global:LogFile = $null
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        default   { 'Cyan'   }
    }
    Write-Host $entry -ForegroundColor $color
    if ($global:LogFile) { Add-Content -Path $global:LogFile -Value $entry -Encoding UTF8 }
}
#endregion

#region Load config + shared functions
$configPath = Join-Path $ScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) { Write-Error "config.ps1 not found at: $configPath"; exit 1 }
. $configPath

$funcPath = Join-Path $ScriptRoot "steps\_shared\LabFunctions.ps1"
if (-not (Test-Path $funcPath)) { Write-Error "Shared functions not found at: $funcPath"; exit 1 }
. $funcPath
#endregion

#region Elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Error "StartLab must be run as Administrator. Re-launch PowerShell as Administrator."
    exit 1
}
#endregion

#region Open log file
if ($LogPath -and -not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
if ($LogPath) {
    $global:LogFile = Join-Path $LogPath ("startlab-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
    New-Item -ItemType File -Path $global:LogFile -Force | Out-Null
}
#endregion

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║             SQL LAB BUILDER — Start Lab                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

#region Preconditions — the lab must already exist
if (-not $CheckpointPath -or -not (Test-Path $CheckpointPath)) {
    Write-Log "No lab checkpoints found. Build the lab first with .\StartLabBuild.ps1." ERROR
    exit 1
}
$dcVM = Get-VM -Name $DCVMName -ErrorAction SilentlyContinue
if (-not $dcVM) {
    Write-Log "Domain controller VM '$DCVMName' not found. Build the lab first with .\StartLabBuild.ps1." ERROR
    exit 1
}
#endregion

#region Discover every built cluster
# Index 1 is the primary lab; indices >= 2 are add-cluster AGs. A cluster counts as
# "built" when its node VMs exist. We scan a generous range so a gap (e.g. a middle
# cluster torn down) doesn't stop discovery of the ones after it.
$MaxClusterIndex = 50
$clusters = @()
for ($i = 1; $i -le $MaxClusterIndex; $i++) {
    # High indices run out of /24 address space and Get-LabClusterContext throws.
    # Those slots can't hold a built cluster, so stop scanning at that point.
    try   { $ctx = Get-LabClusterContext -Index $i }
    catch { break }
    $n1 = Get-VM -Name $ctx.Node1VMName -ErrorAction SilentlyContinue
    $n2 = Get-VM -Name $ctx.Node2VMName -ErrorAction SilentlyContinue
    if ($n1 -or $n2) { $clusters += $ctx }
}
if ($clusters.Count -eq 0) {
    Write-Log "No SQL node VMs found. Build the lab first with .\StartLabBuild.ps1." ERROR
    exit 1
}

# Flatten the clusters into a numbered catalog of SQL node VMs — the menu the user
# picks from. Only VMs that actually exist are listed; a half-torn-down cluster
# contributes just its surviving node.
$nodeCatalog = @()
foreach ($c in $clusters) {
    $label = if ($c.IsPrimary) { "primary" } else { "cluster $($c.Index)" }
    Write-Log "Found $label AG '$($c.AGName)': $($c.Node1Computer), $($c.Node2Computer)" INFO
    foreach ($n in @(
        @{ VMName = $c.Node1VMName; Computer = $c.Node1Computer; IP = $c.Node1IP },
        @{ VMName = $c.Node2VMName; Computer = $c.Node2Computer; IP = $c.Node2IP })) {

        $vm = Get-VM -Name $n.VMName -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        $nodeCatalog += [pscustomobject]@{
            Number   = $nodeCatalog.Count + 1
            VMName   = $n.VMName
            Computer = $n.Computer
            IP       = $n.IP
            AGName   = $c.AGName
            Cluster  = $label
            State    = [string]$vm.State
            MemoryGB = [math]::Round($vm.MemoryStartup / 1GB, 1)
        }
    }
}
if ($nodeCatalog.Count -eq 0) {
    Write-Log "No SQL node VMs found. Build the lab first with .\StartLabBuild.ps1." ERROR
    exit 1
}
Write-Log "Lab spans $($clusters.Count) cluster(s), $($nodeCatalog.Count) SQL node VM(s) + the DC." INFO
#endregion

#region Select which SQL nodes to start
# The DC is never part of the selection — every SQL node depends on it for DNS,
# Kerberos and the witness share, so it is always started.

# Turns one selection string into catalog entries. Accepts menu numbers, numeric
# ranges (1-4), VM names, computer names, "all" and "none". Throws on anything
# that doesn't resolve so the caller can re-prompt (or fail fast in -Nodes mode).
function Resolve-NodeSelection {
    param(
        [string[]]$Tokens,
        [object[]]$Catalog
    )
    $expanded = @()
    foreach ($t in $Tokens) {
        if ($null -eq $t) { continue }
        $expanded += ($t -split '[,\s]+' | Where-Object { $_ -ne '' })
    }
    # NOTE: the leading comma keeps an empty result an empty ARRAY rather than
    # $null, which is what lets the caller's prompt loop treat "none" as answered.
    if ($expanded.Count -eq 0) { return ,@($Catalog) }   # bare Enter = everything

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($token in $expanded) {
        if ($token -match '^(all|\*)$')  { foreach ($e in $Catalog) { if (-not $selected.Contains($e)) { $selected.Add($e) } }; continue }
        if ($token -match '^(none|0)$')  { return ,@() }

        # NOTE: $Matches is the automatic regex variable — use $hits for our results.
        $hits = @()
        if ($token -match '^(\d+)\s*-\s*(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $tmp = $from; $from = $to; $to = $tmp }
            $hits = @($Catalog | Where-Object { $_.Number -ge $from -and $_.Number -le $to })
            if ($hits.Count -eq 0) { throw "Range '$token' matches no listed node (valid numbers: 1-$($Catalog.Count))." }
        }
        elseif ($token -match '^\d+$') {
            $hits = @($Catalog | Where-Object { $_.Number -eq [int]$token })
            if ($hits.Count -eq 0) { throw "'$token' is not a listed node number (valid numbers: 1-$($Catalog.Count))." }
        }
        else {
            $hits = @($Catalog | Where-Object { $_.VMName -eq $token -or $_.Computer -eq $token })
            if ($hits.Count -eq 0) { throw "'$token' is not a listed VM or computer name." }
        }
        foreach ($m in $hits) { if (-not $selected.Contains($m)) { $selected.Add($m) } }
    }
    return ,@($selected)
}

function Show-NodeMenu {
    param([object[]]$Catalog)
    $freeRAMGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    Write-Host ""
    Write-Host "Available SQL node VMs (host RAM free: ${freeRAMGB} GB)" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    foreach ($e in $Catalog) {
        $stateColor = if ($e.State -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ("  [{0}] " -f $e.Number) -ForegroundColor White -NoNewline
        Write-Host ("{0,-14}" -f $e.VMName) -NoNewline
        Write-Host ("{0,-10}" -f $e.State) -ForegroundColor $stateColor -NoNewline
        Write-Host ("{0,-10} {1,-18} {2,4} GB" -f $e.Cluster, "AG $($e.AGName)", $e.MemoryGB) -ForegroundColor DarkGray
    }
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    Write-Host "  The domain controller ($DCVMName) always starts." -ForegroundColor DarkGray
    Write-Host "  Enter numbers (1,3,4), a range (1-4), 'all', or 'none' for DC only." -ForegroundColor DarkGray
    Write-Host "  Press Enter for all." -ForegroundColor DarkGray
    Write-Host ""
}

if ($All -and $Nodes) {
    Write-Log "-All and -Nodes cannot be combined. Use one or the other." ERROR
    exit 1
}

$selectedNodes = $null
if ($All) {
    $selectedNodes = @($nodeCatalog)
    Write-Log "-All specified — starting every SQL node." INFO
}
elseif ($Nodes) {
    try { $selectedNodes = Resolve-NodeSelection -Tokens $Nodes -Catalog $nodeCatalog }
    catch {
        Write-Log "Invalid -Nodes value: $_" ERROR
        Show-NodeMenu -Catalog $nodeCatalog
        exit 1
    }
}
else {
    Show-NodeMenu -Catalog $nodeCatalog
    while ($null -eq $selectedNodes) {
        $answer = Read-Host "Which SQL nodes should be started?"
        try   { $selectedNodes = Resolve-NodeSelection -Tokens @($answer) -Catalog $nodeCatalog }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

$sqlVMNames = @($selectedNodes | ForEach-Object { $_.VMName })
$skippedNodes = @($nodeCatalog | Where-Object { $sqlVMNames -notcontains $_.VMName })

if ($sqlVMNames.Count -eq 0) {
    Write-Log "No SQL nodes selected — starting the domain controller only." WARN
} else {
    Write-Log "Selected $($sqlVMNames.Count) of $($nodeCatalog.Count) SQL node(s): $($sqlVMNames -join ', ')" INFO
}
if ($skippedNodes.Count -gt 0) {
    Write-Log "Leaving alone: $(($skippedNodes | ForEach-Object { $_.VMName }) -join ', ')" INFO
}

# Rough RAM sanity check on what still has to be powered on, so an over-large
# selection surfaces here rather than as a Hyper-V start failure mid-run.
$pendingGB = 0
foreach ($n in @($selectedNodes | Where-Object { $_.State -ne 'Running' })) { $pendingGB += $n.MemoryGB }
$pendingGB = [math]::Round($pendingGB, 1)
$freeGB    = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
if ($pendingGB -gt 0 -and $pendingGB -gt $freeGB) {
    Write-Log "Selection needs about ${pendingGB} GB of startup RAM but only ${freeGB} GB is free — VMs may fail to start or the host may swap heavily." WARN
}
#endregion

#region Credentials
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
#endregion

#region Helpers
# Start any VMs in $Names that aren't already running, then wait for the Running
# (Hyper-V heartbeat) state. Does not guarantee the guest OS is ready — see
# Wait-GuestReady for that.
function Start-VMsAndWait {
    param([string[]]$Names, [int]$Timeout)
    $toStart = @()
    foreach ($name in $Names) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { Write-Log "[$name] VM not found - skipping." WARN; continue }
        if ($vm.State -ne 'Running') {
            Write-Log "[$name] '$($vm.State)' - starting..." INFO
            Start-VM -Name $name -ErrorAction Stop
            $toStart += $name
        } else {
            Write-Log "[$name] already running." SUCCESS
        }
    }
    if ($toStart.Count -eq 0) { return }
    $deadline = (Get-Date).AddSeconds($Timeout)
    $pending  = [System.Collections.Generic.List[string]]$toStart
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $still = @()
        foreach ($name in $pending) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -eq 'Running') {
                Write-Log "[$name] Running." SUCCESS
            } else { $still += $name }
        }
        $pending = [System.Collections.Generic.List[string]]$still
        if ($pending.Count -gt 0) { Start-Sleep -Seconds 5 }
    }
    if ($pending.Count -gt 0) {
        Write-Log "VMs did not reach Running within ${Timeout}s: $($pending -join ', ')" WARN
    }
}

# Wait until the guest answers PowerShell Direct with the given credential, so a
# subsequent Invoke-Command (the health recovery) doesn't fail on a still-booting OS.
function Wait-GuestReady {
    param([string]$VMName, [System.Management.Automation.PSCredential]$Credential, [int]$TimeoutSeconds = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { 1 } -ErrorAction Stop | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 10 }
    }
    Write-Log "[$VMName] Guest not answering PowerShell Direct after ${TimeoutSeconds}s - will still attempt recovery." WARN
    return $false
}
#endregion

try {
    #region 1 — Domain controller first
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "PHASE 1 — Start domain controller" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Start-VMsAndWait -Names @($DCVMName) -Timeout $TimeoutSeconds
    Write-Log "Waiting for the DC to answer (DNS / witness / Kerberos depend on it)..." INFO
    Wait-GuestReady -VMName $DCVMName -Credential $domainAdminCred -TimeoutSeconds $TimeoutSeconds | Out-Null
    #endregion

    #region 2 — Start the selected SQL node VMs
    $healthy = 0
    if ($sqlVMNames.Count -eq 0) {
        Write-Host ""
        Write-Log "No SQL nodes selected — skipping phases 2 and 3." INFO
    } else {
        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor DarkGray
        Write-Log "PHASE 2 — Start selected SQL node VMs ($($sqlVMNames.Count))" INFO
        Write-Host ("=" * 70) -ForegroundColor DarkGray
        Start-VMsAndWait -Names $sqlVMNames -Timeout $TimeoutSeconds
        #endregion

        #region 3 — Recover each selected SQL node (disk online, services up)
        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor DarkGray
        Write-Log "PHASE 3 — Bring disks online and start SQL on each node" INFO
        Write-Host ("=" * 70) -ForegroundColor DarkGray
        foreach ($name in $sqlVMNames) {
            Wait-GuestReady -VMName $name -Credential $domainAdminCred -TimeoutSeconds $TimeoutSeconds | Out-Null
            if (Restore-LabNodeHealth -VMName $name -Credential $domainAdminCred) { $healthy++ }
        }
    }
    #endregion

    #region Summary
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "Lab startup summary" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "Domain controller : $DCVMName" INFO
    foreach ($c in $clusters) {
        $clusterNodes = @($selectedNodes | Where-Object { $_.AGName -eq $c.AGName })
        if ($clusterNodes.Count -eq 0) { continue }
        $label = if ($c.IsPrimary) { "Primary AG" } else { "AG (cluster $($c.Index))" }
        Write-Log "$label $($c.AGName) — listener $($c.ListenerName) ($($c.ListenerIP):$ListenerPort)" INFO
        Write-Log "    started: $(($clusterNodes | ForEach-Object { "$($_.Computer) ($($_.IP))" }) -join ', ')" INFO
        if ($clusterNodes.Count -eq 1) {
            Write-Log "    only one replica of $($c.AGName) is up — the cluster has no quorum partner and the AG will be degraded." WARN
        }
    }
    if ($skippedNodes.Count -gt 0) {
        Write-Log "Not started      : $(($skippedNodes | ForEach-Object { $_.VMName }) -join ', ')" INFO
    }
    if ($sqlVMNames.Count -eq 0) {
        Write-Log "Domain controller only — no SQL nodes were started." WARN
    } else {
        Write-Log "$healthy of $($sqlVMNames.Count) SQL node(s) reported healthy." $(if ($healthy -eq $sqlVMNames.Count) { 'SUCCESS' } else { 'WARN' })
    }
    #endregion

} catch {
    Write-Log "START-LAB FAILED: $_" ERROR
    Write-Host ""
    Write-Host "The lab start-up hit a fatal error. Review the log above and re-run." -ForegroundColor Yellow
    if ($global:LogFile) { Write-Host "Full log: $global:LogFile" -ForegroundColor Yellow }
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║               SQL LAB IS UP                              ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
