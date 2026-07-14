#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Start the whole lab at once (all clusters).

    Powers on the domain controller and every built cluster's SQL nodes — the
    primary AG plus any add-cluster AGs — then brings each node back to a healthy
    runtime state: data disk online, SQL data/log/backup/temp directories present,
    and the cluster service, SQL Server engine, and SQL Agent running.

.DESCRIPTION
    This is the post-shutdown "turn the lab on" command. Unlike re-running
    .\StartLabBuild.ps1, which only knows about the primary three VMs, this
    enumerates every cluster that has been built (via Get-LabClusterContext +
    checkpoints) and starts them all.

    Order of operations:
      1. Start the domain controller first and wait until it answers — the SQL
         nodes need it for DNS, the cluster witness share, and Kerberos.
      2. Start every SQL node VM and wait for each guest's PowerShell Direct.
      3. Run the shared Restore-LabNodeHealth recovery pass on each SQL node
         (re-online D:\ if offline, start ClusSvc / MSSQLSERVER / SQL Agent).

    Read-only against configuration and idempotent: already-running VMs and
    already-online disks are left as-is. Invoked via
    .\StartLabBuild.ps1 -Start (recommended) or directly.

.PARAMETER TimeoutSeconds
    Per-phase wait budget for VMs to reach the Running state (default 180).

.EXAMPLE
    .\StartLabBuild.ps1 -Start
    .\StartLab.ps1
#>

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 180
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

$sqlVMNames = @()
foreach ($c in $clusters) {
    $label = if ($c.IsPrimary) { "primary" } else { "cluster $($c.Index)" }
    Write-Log "Found $label AG '$($c.AGName)': $($c.Node1Computer), $($c.Node2Computer)" INFO
    $sqlVMNames += @($c.Node1VMName, $c.Node2VMName)
}
Write-Log "Lab spans $($clusters.Count) cluster(s), $($sqlVMNames.Count) SQL node VM(s) + the DC." INFO
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

    #region 2 — Start every SQL node VM
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "PHASE 2 — Start SQL node VMs ($($sqlVMNames.Count))" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Start-VMsAndWait -Names $sqlVMNames -Timeout $TimeoutSeconds
    #endregion

    #region 3 — Recover each SQL node (disk online, services up)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "PHASE 3 — Bring disks online and start SQL on each node" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    $healthy = 0
    foreach ($name in $sqlVMNames) {
        Wait-GuestReady -VMName $name -Credential $domainAdminCred -TimeoutSeconds $TimeoutSeconds | Out-Null
        if (Restore-LabNodeHealth -VMName $name -Credential $domainAdminCred) { $healthy++ }
    }
    #endregion

    #region Summary
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "Lab startup summary" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Log "Domain controller : $DCVMName" INFO
    foreach ($c in $clusters) {
        $label = if ($c.IsPrimary) { "Primary AG" } else { "AG (cluster $($c.Index))" }
        Write-Log "$label $($c.AGName) — listener $($c.ListenerName) ($($c.ListenerIP):$ListenerPort)" INFO
        Write-Log "    nodes: $($c.Node1Computer) ($($c.Node1IP)), $($c.Node2Computer) ($($c.Node2IP))" INFO
    }
    Write-Log "$healthy of $($sqlVMNames.Count) SQL node(s) reported healthy." $(if ($healthy -eq $sqlVMNames.Count) { 'SUCCESS' } else { 'WARN' })
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
