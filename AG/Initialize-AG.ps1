#Requires -Version 5.1
<#
.SYNOPSIS
    Initialize-AG — end-to-end creation of a SQL Server Always On availability group on an
    existing Windows Server Failover Cluster.

.DESCRIPTION
    Prompt-driven. You type one instance name; everything else is discovered and offered as
    a numbered choice with a default on ENTER. Answer the interview, confirm the plan, and
    the rest of the run is unattended.

    What it does:
      * Discovers the cluster, its nodes, the SQL Server instance on each, their versions,
        editions, endpoints, subnets and databases.
      * Lets you choose the replicas, which are synchronous with automatic failover and
        which asynchronous, readable secondaries, backup preference, and the AG options
        (or takes the recommended values).
      * Standard, CONTAINED (SQL Server 2022+) or — on Standard Edition — BASIC AGs.
      * Checks every database against every replica: recovery model, log chain, AUTO_CLOSE,
        a same-named database already on a secondary, TDE certificates, FILESTREAM. Offers
        to fix what it can: FULL recovery, a full backup (you pick where), AUTO_CLOSE OFF,
        dropping leftover copies.
      * Creates missing mirroring endpoints, grants CONNECT to each replica's service
        account, starts the AlwaysOn_health session everywhere.
      * Creates the AG, joins the secondaries, and the listener — one IP per subnet for a
        multi-subnet cluster — with read-only routing when secondaries are readable.
      * Seeds the databases AUTOMATICALLY (a throttled, self-healing sliding window) or
        MANUALLY (striped compressed backups to a share, restore with your choice of file
        layout, log-chain catch-up, join) — the same engine as Initialize-DAG.ps1.
      * For a contained AG, copies the databases' logins into the AG's own master.
      * Finishes with a health rollup that waits for the AG to settle before judging.

    Safe to re-run: every action re-checks live state first, and an interrupted run is
    offered for resume — including reuse of a completed multi-terabyte full backup.

.PARAMETER SeedTimeoutHours
    How long to wait for a single database to finish seeding. Default 24.

.PARAMETER MaxConcurrentSeeds
    The default offered for how many databases may seed automatically at once. Default 3.

.PARAMETER Credential
    A SQL Server login used for every connection. When omitted you are asked how to
    authenticate.

.PARAMETER HealthOnly
    Skip configuration; print the health rollup for an existing availability group.

.PARAMETER Force
    Restore a FULL backup even when the script cannot prove the target needs it. See
    Initialize-DAG.ps1 -Force: re-restoring a multi-terabyte FULL on a guess is exactly what
    the default refuses to do.

.EXAMPLE
    .\Initialize-AG.ps1

.EXAMPLE
    .\Initialize-AG.ps1 -HealthOnly
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$SeedTimeoutHours = 24,

    [ValidateRange(1, 10)]
    [int]$MaxConcurrentSeeds = 3,

    [pscredential]$Credential,

    [switch]$HealthOnly,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$SharedDir  = Join-Path $ScriptRoot 'steps\_shared'
$StepsDir   = Join-Path $ScriptRoot 'steps'

#region ── Load modules and step files ───────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw @'
The SqlServer PowerShell module is required and was not found.

    Install-Module -Name SqlServer -Scope CurrentUser
'@
}
Import-Module SqlServer -DisableNameChecking -ErrorAction Stop

foreach ($file in @(
        'AgCommon.ps1', 'AgSql.ps1', 'AgPrompt.ps1', 'AgDiscovery.ps1', 'AgCluster.ps1', 'AgDatabase.ps1',
        'AgFileOps.ps1', 'AgFileLayout.ps1', 'AgPlacementBoard.ps1', 'AgBackupRestore.ps1',
        'AgAgentJob.ps1', 'AgHealth.ps1', 'AgState.ps1'
    )) { . (Join-Path $SharedDir $file) }

foreach ($file in @(
        '01Interview.ps1', '02Preflight.ps1', '03PrepareDatabases.ps1', '04CreateAG.ps1',
        '05Listener.ps1', '06SeedAutomatic.ps1', '07SeedManual.ps1', '08Finalize.ps1'
    )) { . (Join-Path $StepsDir $file) }

#endregion

try {
    Initialize-AgLog   -LogDirectory (Join-Path $ScriptRoot 'logs') -NamePrefix 'Initialize-AG' | Out-Null
    Initialize-AgState -StateDirectory (Join-Path $ScriptRoot 'state')

    Write-AgBanner 'INITIALIZE AVAILABILITY GROUP'
    Write-Host 'End-to-end creation of an Always On availability group on an existing failover cluster.' -ForegroundColor DarkGray

    if ($Credential) {
        Set-AgConnectionContext -Credential $Credential
        Write-AgLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-AgCredential
    }

    if ($HealthOnly) {
        $sel = Select-AgExistingAg -Purpose 'report on'
        $ok  = Show-AgHealthRollup -PrimaryInstance $sel.Topology.PrimaryReplica -AgName $sel.Topology.AgName
        if (-not $ok) { exit 1 }
        return
    }

    $plan = Select-AgResumePlan -Operation 'CREATE'
    if ($plan) {
        Write-AgLog "Resuming plan for [$($plan.AgName)]." INFO
    } else {
        $plan = New-AgCreatePlan -MaxConcurrentSeeds $MaxConcurrentSeeds
    }

    Show-AgPlanSummary -Plan $plan
    if (-not (Read-AgYesNo -Question 'Proceed with this plan?' -DefaultYes $true)) {
        Write-AgLog 'Aborted by operator.' WARN
        return
    }
    Save-AgPlan -Plan $plan

    $started = Get-Date

    $instanceInfo = Invoke-AgPreflight -Plan $plan
    Invoke-AgPrepareDatabases -Plan $plan
    Invoke-AgCreate -Plan $plan -InstanceInfo $instanceInfo
    $listenerOk = Invoke-AgListener -Plan $plan

    if ($plan.Databases.Count -gt 0) {
        if ($plan.SecondaryReplicas.Count -eq 0) {
            foreach ($db in $plan.Databases) {
                if (-not (Test-AgDatabaseInAg -Instance $plan.PrimaryReplica -AgName $plan.AgName -DatabaseName $db)) {
                    Invoke-AgSql -Instance $plan.PrimaryReplica -QueryTimeout 300 -Activity 'add database' `
                        -Query "ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $plan.AgName) ADD DATABASE $(ConvertTo-AgQuotedName $db);" | Out-Null
                    Write-AgLog "  [$db] added to [$($plan.AgName)]" SUCCESS
                }
            }
        } elseif ($plan.SeedingMode -eq 'AUTOMATIC') {
            Invoke-AgSeedAutomatic -Plan $plan -TimeoutHours $SeedTimeoutHours
        } else {
            Invoke-AgSeedManual -Plan $plan -InstanceInfo $instanceInfo -TimeoutHours $SeedTimeoutHours -Force:$Force
        }
    }

    $healthy = Invoke-AgFinalize -Plan $plan -ListenerOk $listenerOk
    Complete-AgPlan -Plan $plan

    Write-AgBanner ('DONE in {0}' -f (Format-AgDuration ((Get-Date) - $started)))
    if (-not $healthy -or -not $listenerOk) {
        Write-AgLog "Availability group [$($plan.AgName)] was created, but there are problems to look at (see above)." WARN
        exit 1
    }
    Write-AgLog "Availability group [$($plan.AgName)] is created and healthy." SUCCESS
}
catch {
    Write-Host ''
    Write-AgLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-AgLog $_.ScriptStackTrace DEBUG }
    Write-Host ''
    Write-AgLog 'Nothing was left half-applied that a re-run cannot recover: Initialize-AG.ps1 is idempotent.' INFO
    Write-AgLog 'Fix the problem above and run it again — choose "Resume" and it carries on from where it stopped.' INFO
    exit 1
}
