#Requires -Version 5.1
<#
.SYNOPSIS
    SQLLabBuilder — Add another 2-node Always On AG to an existing lab.

    Builds two additional small VMs, joins them to the SAME existing domain
    controller, creates a NEW Windows Failover Cluster (its own quorum witness),
    installs SQL Server, enables Always On, and creates a NEW Availability Group
    with its own listener — completely independent of the primary AG.

    The lab's domain controller, virtual switch, NAT and sqlsvc service account
    are reused. Every heavy operation is a shared function from
    steps\_shared\LabFunctions.ps1, so this path and the primary build run the
    same code.

.DESCRIPTION
    Repeatable: each run adds the next cluster (index 2, then 3, ...). Names and
    IPs are derived from the index by Get-LabClusterContext in config.ps1, so
    clusters never collide. Phase checkpoints (addcluster-cN-XX.done) make the
    build resumable — re-run and it continues where it stopped.

    Invoked via .\StartLabBuild.ps1 -AddCluster (recommended) or directly.

.PARAMETER SQLVersion
    SQL Server Developer version for the new nodes: "2019", "2022", or "2025".
    Default (empty) auto-detects the SQL ISO already downloaded for the lab.

.PARAMETER ContainedAG
    Create the new AG as a Contained AG (requires SQL 2022 or later).

.PARAMETER ClusterIndex
    Force a specific cluster index (>= 2). Default 0 = auto-pick the next free
    slot, or resume the highest incomplete one.

.EXAMPLE
    .\StartLabBuild.ps1 -AddCluster
    .\StartLabBuild.ps1 -AddCluster -ContainedAG
    .\AddCluster.ps1 -SQLVersion 2022 -ClusterIndex 3
#>

[CmdletBinding()]
param(
    [ValidateSet("2019","2022","2025","")]
    [string]$SQLVersion = "",

    [switch]$ContainedAG,

    [int]$ClusterIndex = 0
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
    Write-Error "AddCluster must be run as Administrator. Re-launch PowerShell as Administrator."
    exit 1
}
#endregion

#region Open log file
if ($LogPath -and -not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
if ($LogPath) {
    $global:LogFile = Join-Path $LogPath ("addcluster-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
    New-Item -ItemType File -Path $global:LogFile -Force | Out-Null
}
#endregion

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        SQL LAB BUILDER — Add Availability Group          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

#region Preconditions — the primary lab must already exist
if (-not $CheckpointPath -or -not (Test-Path $CheckpointPath)) {
    Write-Log "No lab checkpoints found. Build the base lab first with .\StartLabBuild.ps1 before adding a cluster." ERROR
    exit 1
}
$dcVM = Get-VM -Name $DCVMName -ErrorAction SilentlyContinue
if (-not $dcVM) {
    Write-Log "Domain controller VM '$DCVMName' not found. Build the base lab first with .\StartLabBuild.ps1." ERROR
    exit 1
}
if (-not (Test-Path (Join-Path $CheckpointPath "step-13.done"))) {
    Write-Log "Primary AG build has not completed (step-13.done missing). Finish the base build before adding a cluster." ERROR
    exit 1
}
Write-Log "Base lab detected — DC '$DCVMName' present, primary AG built." SUCCESS
#endregion

#region Resolve SQL version + ISO
$isoMap = @{ "2019" = $SQL2019ISOName; "2022" = $SQL2022ISOName; "2025" = $SQL2025ISOName }
if (-not $SQLVersion) {
    $present = @()
    foreach ($ver in @("2019","2022","2025")) {
        if (Test-Path (Join-Path $ISOPath $isoMap[$ver])) { $present += $ver }
    }
    if ($present.Count -eq 1) {
        $SQLVersion = $present[0]
        Write-Log "Auto-detected SQL Server $SQLVersion ISO for the new nodes." INFO
    } elseif ($present.Count -gt 1) {
        $SQLVersion = ($present | Sort-Object -Descending)[0]
        Write-Log "Multiple SQL ISOs present ($($present -join ', ')). Using $SQLVersion — pass -SQLVersion to override." WARN
    } else {
        Write-Log "No SQL Server ISO found in $ISOPath. Run the base build (step 02) or place an ISO, then retry." ERROR
        exit 1
    }
}
if ($ContainedAG -and $SQLVersion -eq "2019") {
    Write-Log "Contained Availability Groups require SQL Server 2022 or later. Remove -ContainedAG or use a newer -SQLVersion." ERROR
    exit 1
}
$global:SQLVersion  = $SQLVersion       # step 02 reads this to pick which ISO to fetch
$global:ContainedAG = $ContainedAG.IsPresent

$sqlISOHostPath = Join-Path $ISOPath $isoMap[$SQLVersion]
if (-not (Test-Path $sqlISOHostPath)) {
    # The requested version's ISO isn't downloaded (e.g. base lab is 2025 but you want
    # a 2022 AG). Acquire it now using the exact same downloader as the base build's
    # step 02, then continue. Wrapped in a function so step 02's internal 'return'
    # ends the acquisition, not this script.
    Write-Log "SQL Server $SQLVersion ISO not present — acquiring it now (same downloader as the base build)..." WARN
    function Invoke-IsoAcquire { . (Join-Path $ScriptRoot "steps\02DownloadISOs.ps1") }
    try { Invoke-IsoAcquire } catch { Write-Log "ISO acquisition failed: $_" ERROR; exit 1 }
    if (-not (Test-Path $sqlISOHostPath)) {
        Write-Log "SQL Server $SQLVersion ISO still not found at: $sqlISOHostPath" ERROR
        exit 1
    }
    Write-Log "SQL Server $SQLVersion ISO acquired." SUCCESS
}
#endregion

#region Determine target cluster index
if ($ClusterIndex -gt 0) {
    if ($ClusterIndex -lt 2) { Write-Log "-ClusterIndex must be >= 2 (index 1 is the primary lab)." ERROR; exit 1 }
    $targetIndex = $ClusterIndex
} else {
    $targetIndex = 2
    for ($i = 2; $i -le 50; $i++) {
        $c        = Get-LabClusterContext -Index $i
        $n1       = Get-VM -Name $c.Node1VMName -ErrorAction SilentlyContinue
        $n2       = Get-VM -Name $c.Node2VMName -ErrorAction SilentlyContinue
        $complete = Test-Path (Join-Path $CheckpointPath "addcluster$($c.CpSuffix)-15.done")
        if ($n1 -or $n2) {
            if (-not $complete) { $targetIndex = $i; break }   # resume this partial one
            continue                                            # this one done — try next
        } else {
            $targetIndex = $i; break                            # first free slot
        }
    }
}

$Ctx = Get-LabClusterContext -Index $targetIndex
Write-Log "Target cluster index: $targetIndex" INFO
Write-Log "  Nodes    : $($Ctx.Node1Computer) ($($Ctx.Node1IP)), $($Ctx.Node2Computer) ($($Ctx.Node2IP))" INFO
Write-Log "  WSFC     : $($Ctx.ClusterName) ($($Ctx.ClusterIP)) — witness \\$DCComputerName\$($Ctx.WitnessShare)" INFO
Write-Log "  AG       : $($Ctx.AGName) — listener $($Ctx.ListenerName) ($($Ctx.ListenerIP):$ListenerPort)" INFO
Write-Log "  SQL      : SQL Server $SQLVersion$(if ($ContainedAG) { ' (Contained AG)' })" INFO
#endregion

#region Credentials
$adminCred       = New-Object System.Management.Automation.PSCredential("Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
$localAdminCred  = $adminCred
#endregion

#region Ensure the DC is running (needed for domain join, witness share, DNS)
$dc = Get-VM -Name $DCVMName -ErrorAction SilentlyContinue
if ($dc -and $dc.State -ne 'Running') {
    Write-Log "[$DCVMName] Starting domain controller..." INFO
    Start-VM -Name $DCVMName -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and (Get-VM -Name $DCVMName).State -ne 'Running') { Start-Sleep -Seconds 5 }
    Write-Log "[$DCVMName] State: $((Get-VM -Name $DCVMName).State)" INFO
}

function Start-CtxNodes {
    foreach ($vmName in @($Ctx.Node1VMName, $Ctx.Node2VMName)) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne 'Running') {
            Write-Log "[$vmName] Starting..." INFO
            Start-VM -Name $vmName -ErrorAction Stop
        }
    }
}
#endregion

#region Phase runner
function Invoke-Phase {
    param([string]$Num, [string]$Label, [scriptblock]$Body)

    $cpFile = Join-Path $CheckpointPath "addcluster$($Ctx.CpSuffix)-$Num.done"
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    if (Test-Path $cpFile) {
        Write-Log "PHASE $Num ($Label) — checkpoint present, skipping." SUCCESS
        Write-Host ("=" * 70) -ForegroundColor DarkGray
        return
    }
    Write-Log "PHASE $Num — $Label" INFO
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    try {
        & $Body
    } catch {
        Write-Log "PHASE $Num FAILED: $Label — $_" ERROR
        Write-Log "Full error: $($_.ScriptStackTrace)" ERROR
        throw
    }
    New-Item -ItemType File -Path $cpFile -Force | Out-Null
    Write-Log "Checkpoint written: addcluster$($Ctx.CpSuffix)-$Num.done" SUCCESS
}
#endregion

$nodeSpecsBasic = @(
    @{ VMName = $Ctx.Node1VMName; ComputerName = $Ctx.Node1Computer }
    @{ VMName = $Ctx.Node2VMName; ComputerName = $Ctx.Node2Computer }
)

try {
    #region 04 — Create the two small VMs
    Invoke-Phase "04" "Create VMs" {
        # Small nodes: 2 vCPU, 1 GB min / 3 GB max dynamic, 64 GB OS + 20 GB data.
        # Sized only to host the OS and run SQL Server — no workload is expected.
        foreach ($spec in $nodeSpecsBasic) {
            New-LabVM `
                -VMName          $spec.VMName `
                -ComputerName    $spec.ComputerName `
                -MemoryMaxBytes  (3GB) `
                -MemoryMinBytes  (1GB) `
                -OSDiskGB        64 `
                -AddDataDisk     $true `
                -DataDiskGB      20
        }
    }
    #endregion

    #region 05 — Apply Windows Server
    Invoke-Phase "05" "Apply Windows Server" {
        # VHDX must be dismounted (VM off) before Install-LabWindows mounts it.
        foreach ($spec in $nodeSpecsBasic) {
            $vm = Get-VM -Name $spec.VMName -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -ne 'Off') {
                Write-Log "Stopping $($spec.VMName) before VHDX operations..." INFO
                Stop-VM -Name $spec.VMName -TurnOff -Force -ErrorAction Stop
            }
        }
        Install-LabWindows -NodeSpecs $nodeSpecsBasic
    }
    #endregion

    #region 06 — Guest networking
    Invoke-Phase "06" "Configure guest networking" {
        Start-CtxNodes
        $netSpecs = @(
            @{ VMName = $Ctx.Node1VMName; IP = $Ctx.Node1IP; DNSPrimary = $DCStaticIP }
            @{ VMName = $Ctx.Node2VMName; IP = $Ctx.Node2IP; DNSPrimary = $DCStaticIP }
        )
        Set-LabNodesNetworking -NodeSpecs $netSpecs -HostDnsIP $DCStaticIP `
            -AdminCred $adminCred -DomainAdminCred $domainAdminCred
    }
    #endregion

    #region 08 — Join the new nodes to the existing domain
    Invoke-Phase "08" "Join nodes to domain" {
        Start-CtxNodes
        Join-LabNodesToDomain -NodeSpecs $nodeSpecsBasic `
            -LocalAdminCred $localAdminCred -DomainAdminCred $domainAdminCred
    }
    #endregion

    #region 09 — Create the new Windows Failover Cluster
    Invoke-Phase "09" "Create Windows Failover Cluster" {
        Start-CtxNodes
        New-LabWSFC `
            -ClusterName    $Ctx.ClusterName `
            -ClusterIP      $Ctx.ClusterIP `
            -Node1VMName    $Ctx.Node1VMName `
            -Node1Computer  $Ctx.Node1Computer `
            -Node2VMName    $Ctx.Node2VMName `
            -Node2Computer  $Ctx.Node2Computer `
            -WitnessShare   $Ctx.WitnessShare `
            -DCVMName       $DCVMName `
            -DCComputer     $DCComputerName `
            -DomainAdminCred $domainAdminCred
    }
    #endregion

    #region 10 — Grant sqlsvc "Log on as a service" on the new nodes
    Invoke-Phase "10" "Grant SQL service logon right" {
        Start-CtxNodes
        # The sqlsvc domain account already exists (created by the base build). We
        # only grant the local logon-as-service right on the two new nodes.
        foreach ($vmName in @($Ctx.Node1VMName, $Ctx.Node2VMName)) {
            Write-Log "[$vmName] Granting 'Log on as a service' to '$SQLSvcAccount'..." INFO
            Grant-LogonAsService -VMName $vmName -Credential $domainAdminCred
        }
    }
    #endregion

    #region 11 — Install SQL Server
    Invoke-Phase "11" "Install SQL Server" {
        Start-CtxNodes
        Install-LabSQLNodes -NodeSpecs $nodeSpecsBasic -SQLISOHostPath $sqlISOHostPath `
            -Credential $domainAdminCred
    }
    #endregion

    #region 12 — Enable Always On
    Invoke-Phase "12" "Enable Always On" {
        Start-CtxNodes
        Enable-LabAlwaysOn -Node1VMName $Ctx.Node1VMName -Node2VMName $Ctx.Node2VMName `
            -Credential $domainAdminCred
    }
    #endregion

    #region 13 — Create the new Availability Group
    Invoke-Phase "13" "Create Availability Group" {
        Start-CtxNodes
        New-LabAG `
            -Node1VMName   $Ctx.Node1VMName `
            -Node1Computer $Ctx.Node1Computer `
            -Node1IP       $Ctx.Node1IP `
            -Node2VMName   $Ctx.Node2VMName `
            -Node2Computer $Ctx.Node2Computer `
            -Node2IP       $Ctx.Node2IP `
            -AGName        $Ctx.AGName `
            -ListenerName  $Ctx.ListenerName `
            -ListenerIP    $Ctx.ListenerIP `
            -ListenerPort  $ListenerPort `
            -EndpointPort  $EndpointPort `
            -IsContained   $ContainedAG.IsPresent `
            -DomainAdminCred $domainAdminCred
    }
    #endregion

    #region 14 — Host access (hosts file for the new names)
    Invoke-Phase "14" "Configure host access" {
        Add-LabClusterHostEntries -Ctx $Ctx

        Write-Log "Testing connectivity from host to new SQL endpoints on port 1433..." INFO
        foreach ($t in @(
            @{ Address = $Ctx.Node1IP;   Label = $Ctx.Node1Computer }
            @{ Address = $Ctx.Node2IP;   Label = $Ctx.Node2Computer }
            @{ Address = $Ctx.ListenerIP; Label = "$($Ctx.ListenerName) (AG)" }
        )) {
            try {
                $r = Test-NetConnection -ComputerName $t.Address -Port 1433 -WarningAction SilentlyContinue
                Write-Log "  $($t.Label) ($($t.Address)):1433 — $(if ($r.TcpTestSucceeded){'PASS'}else{'FAIL'})" $(if ($r.TcpTestSucceeded){'SUCCESS'}else{'WARN'})
            } catch {
                Write-Log "  $($t.Label) — connectivity test error: $_" WARN
            }
        }
    }
    #endregion

    #region 15 — Summary
    Invoke-Phase "15" "Generate summary" {
        $agLabel = if ($ContainedAG) { "Contained Availability Group" } else { "Availability Group" }
        $summary = @"
╔══════════════════════════════════════════════════════════╗
║        ADD-CLUSTER COMPLETE — $($Ctx.AGName)
╚══════════════════════════════════════════════════════════╝

  Domain (shared):     $DomainName
  Cluster (new WSFC):  $($Ctx.ClusterName) ($($Ctx.ClusterIP))
  AG:                  $($Ctx.AGName)  [$agLabel]
  AG Listener:         $($Ctx.ListenerName) ($($Ctx.ListenerIP):$ListenerPort)
  SQL Version:         SQL Server $SQLVersion Developer
  Witness:             \\$DCComputerName\$($Ctx.WitnessShare)

VIRTUAL MACHINES (new)
  $($Ctx.Node1Computer)  $($Ctx.Node1IP)  SQL Primary Replica
  $($Ctx.Node2Computer)  $($Ctx.Node2IP)  SQL Secondary Replica

CONNECTING FROM YOUR HOST MACHINE (SQL Auth)
  Server:   $($Ctx.ListenerName),$ListenerPort  (or $($Ctx.Node1Computer) / $($Ctx.Node2Computer) direct)
  Login:    $LabAdminUser
  Password: $LabAdminPassword

  Read-intent secondary routing:
    Server: $($Ctx.ListenerName),$ListenerPort  ApplicationIntent=ReadOnly

HOSTS FILE ENTRIES (added under marker '$($Ctx.HostsMarker)')
  $($Ctx.Node1IP) $($Ctx.Node1Computer)   $($Ctx.Node1Computer).$DomainName
  $($Ctx.Node2IP) $($Ctx.Node2Computer)   $($Ctx.Node2Computer).$DomainName
  $($Ctx.ClusterIP)    $($Ctx.ClusterName)   $($Ctx.ClusterName).$DomainName
  $($Ctx.ListenerIP)   $($Ctx.ListenerName)  $($Ctx.ListenerName).$DomainName

GENERATED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        Write-Host ""
        Write-Host $summary -ForegroundColor Cyan
        Write-Host ""
        $summaryFile = Join-Path $LogPath "addcluster$($Ctx.CpSuffix)-summary.txt"
        $summary | Set-Content -Path $summaryFile -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Log "Summary saved to: $summaryFile" SUCCESS
    }
    #endregion

} catch {
    Write-Log "ADD-CLUSTER FAILED: $_" ERROR
    Write-Host ""
    Write-Host "The add-cluster build hit a fatal error. Fix the issue and re-run — completed phases are skipped via checkpoints." -ForegroundColor Yellow
    if ($global:LogFile) { Write-Host "Full log: $global:LogFile" -ForegroundColor Yellow }
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║        ADD-CLUSTER BUILD COMPLETE                        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
