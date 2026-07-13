#Requires -Version 5.1
<#
.SYNOPSIS
    Initialize-DAG — end-to-end setup and database initialization for a SQL Server
    distributed availability group.

.DESCRIPTION
    Prompt-driven. Answer a short interview up front, confirm the plan, and the rest of
    the run is unattended. Wherever the valid answers can be discovered from the servers,
    you pick a number instead of typing.

    What it does:
      * Discovers both availability groups, their replicas, listeners and versions.
      * Validates and repairs the prerequisites (endpoint CONNECT grants, seeding modes,
        GRANT CREATE ANY DATABASE), and refuses to start when something is genuinely wrong.
      * Adds any selected database that is not yet in the global primary AG.
      * Creates the distributed AG and joins the forwarder.
      * Seeds the databases either automatically (SQL Server streams them) or manually
        (striped compressed backup to a share, restore, log-chain catch-up, join).
      * Settles the DAG into asynchronous commit and prints a health rollup.

    Assumptions:
      * Both availability groups already exist, each with a listener, in the same domain.
      * The mirroring endpoints use Windows authentication (NEGOTIATE), not certificates.
      * For manual seeding, the SQL Server service accounts on BOTH sides can read and
        write the backup share.

    Safe to re-run. Every action re-checks live server state first, so an interrupted run
    resumes where it stopped — including reusing a completed multi-terabyte full backup
    rather than taking it again.

.PARAMETER SeedTimeoutHours
    How long to wait for a single database to finish seeding. Default 24.

.PARAMETER Credential
    Optional. A SQL Server login to use for every replica connection. When omitted you
    are asked how to authenticate. Supplying it lets the script run from automation.

.PARAMETER HealthOnly
    Skip configuration; print the health rollup for a previously configured DAG.

.PARAMETER RemoveLogBackupJob
    Remove the transaction log backup job created for manual seeding, then exit.

.EXAMPLE
    .\Initialize-DAG.ps1

.EXAMPLE
    .\Initialize-DAG.ps1 -HealthOnly

.EXAMPLE
    .\Initialize-DAG.ps1 -RemoveLogBackupJob
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$SeedTimeoutHours = 24,

    [pscredential]$Credential,

    [switch]$HealthOnly,

    [switch]$RemoveLogBackupJob
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
        'DagCommon.ps1'
        'DagSql.ps1'
        'DagPrompt.ps1'
        'DagDiscovery.ps1'
        'DagFileOps.ps1'
        'DagBackupRestore.ps1'
        'DagAgentJob.ps1'
        'DagHealth.ps1'
        'DagState.ps1'
    )) {
    . (Join-Path $SharedDir $file)
}

foreach ($file in @(
        '00Preflight.ps1'
        '01BuildPlan.ps1'
        '02EnsureAGDatabases.ps1'
        '03CreateDAG.ps1'
        '04SeedAutomatic.ps1'
        '05SeedManual.ps1'
        '06Finalize.ps1'
        '07HealthRollup.ps1'
    )) {
    . (Join-Path $StepsDir $file)
}

#endregion

#region ── Plan (de)serialization helpers ────────────────────────────────────

function ConvertTo-DagArray {
    <#
        Normalises a deserialized value to a real array.

        Two traps combine here. ConvertFrom-Json collapses a one-element JSON array to a
        scalar and an empty array to $null. And `return @($x)` unrolls on the way out, so
        the naive fix hands back a scalar again. The leading comma stops the unroll, which
        is safe because every caller assigns the result straight to a property.

        It matters because under Set-StrictMode -Version Latest, .Count throws on both a
        String and $null — so a resumed plan would blow up on $Plan.ForwarderSecondaries.Count.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return ,@() }
    return ,@($Value)
}

function Restore-DagPlanShape {
    param([Parameter(Mandatory)][psobject]$Plan)

    foreach ($p in 'GlobalReplicas','GlobalSecondaries','ForwarderReplicas','ForwarderSecondaries','Databases','Progress') {
        $Plan.$p = ConvertTo-DagArray $Plan.$p
    }
    foreach ($rec in $Plan.Progress) {
        $rec.FullBackupFiles = ConvertTo-DagArray $rec.FullBackupFiles
        $rec.RestoredOn      = ConvertTo-DagArray $rec.RestoredOn
        $rec.JoinedOn        = ConvertTo-DagArray $rec.JoinedOn
    }
    return $Plan
}

function Get-DagSavedPlanList {
    $dir = Join-Path $ScriptRoot 'state'
    if (-not (Test-Path $dir)) { return @() }
    $plans = foreach ($f in (Get-ChildItem -Path $dir -Filter '*.json' -File)) {
        try { Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return @($plans | Where-Object { $_ })
}

function Select-DagExistingPlan {
    param([Parameter(Mandatory)][string]$Purpose)

    $saved = @(Get-DagSavedPlanList)
    if ($saved.Count -eq 0) {
        throw "No saved distributed availability group plans were found under '$(Join-Path $ScriptRoot 'state')'. Run Initialize-DAG.ps1 without switches first."
    }
    $chosen = Read-DagChoice -Title "Which distributed availability group do you want to $Purpose" -Items $saved -Display {
        param($p) '{0}  ({1} -> {2}, {3} seeding)' -f $p.DagName, $p.GlobalAgName, $p.ForwarderAgName, $p.SeedingMode
    }
    return (Restore-DagPlanShape -Plan $chosen)
}

#endregion

#region ── Entry ─────────────────────────────────────────────────────────────

try {
    Initialize-DagLog   -LogDirectory (Join-Path $ScriptRoot 'logs')   | Out-Null
    Initialize-DagState -StateDirectory (Join-Path $ScriptRoot 'state')

    Write-DagBanner 'INITIALIZE DISTRIBUTED AVAILABILITY GROUP'
    Write-Host 'Setup and database initialization for a SQL Server distributed availability group.' -ForegroundColor DarkGray
    Write-Host 'Both availability groups must already exist, each with a listener.' -ForegroundColor DarkGray

    if ($Credential) {
        Set-DagConnectionContext -Credential $Credential
        Write-DagLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-DagCredential
    }

    #region Maintenance switches
    if ($RemoveLogBackupJob) {
        $plan = Select-DagExistingPlan -Purpose 'remove the log backup job from?'
        Uninstall-DagTLogJob -Instances $plan.GlobalReplicas -DagName $plan.DagName
        Write-DagLog "Removed '$(Get-DagTLogJobName -DagName $plan.DagName)'." SUCCESS
        return
    }

    if ($HealthOnly) {
        $plan = Select-DagExistingPlan -Purpose 'report on?'
        $healthy = Show-DagHealthRollup -Plan $plan
        if (-not $healthy) { exit 1 }
        return
    }
    #endregion

    #region Resume or start fresh
    $plan  = $null
    $saved = @(Get-DagSavedPlanList)
    if ($saved.Count -gt 0) {
        $items = @($saved | ForEach-Object { $_ }) + @('Start a NEW distributed availability group')
        $pick = Read-DagChoice -Title 'A previous plan was found. What would you like to do?' -Items $items -Display {
            param($p)
            if ($p -is [string]) { return $p }
            $done = @($p.Progress | Where-Object { $_.Completed }).Count
            'Resume / verify {0}  ({1} -> {2}, {3} seeding, {4}/{5} databases done)' -f `
                $p.DagName, $p.GlobalAgName, $p.ForwarderAgName, $p.SeedingMode, $done, (ConvertTo-DagArray $p.Databases).Count
        } -DefaultIndex 0

        if ($pick -isnot [string]) {
            $plan = Restore-DagPlanShape -Plan $pick
            Write-DagLog "Resuming plan for [$($plan.DagName)]." INFO
        }
    }

    if (-not $plan) {
        $plan = New-DagPlan
        Save-DagPlan -Plan $plan
    }
    #endregion

    Show-DagPlanSummary -Plan $plan
    if (-not (Read-DagYesNo -Question 'Proceed with this plan?' -DefaultYes $true)) {
        Write-DagLog 'Aborted by operator.' WARN
        return
    }

    $started = Get-Date

    $pre = Invoke-DagPreflight -Plan $plan
    Save-DagPlan -Plan $plan

    Invoke-DagEnsureAgDatabases -Plan $plan -InstanceInfo $pre.InstanceInfo
    Invoke-DagCreate -Plan $plan

    if ($plan.SeedingMode -eq 'AUTOMATIC') {
        Invoke-DagSeedAutomatic -Plan $plan -TimeoutHours $SeedTimeoutHours
    } else {
        Invoke-DagSeedManual -Plan $plan -InstanceInfo $pre.InstanceInfo
    }

    Invoke-DagFinalize -Plan $plan
    Save-DagPlan -Plan $plan

    $healthy = Invoke-DagHealthRollup -Plan $plan

    Write-DagBanner ('DONE in {0}' -f (Format-DagDuration ((Get-Date) - $started)))
    if (-not $healthy) {
        Write-DagLog 'The distributed availability group was configured, but the health rollup reported problems (see above).' WARN
        exit 1
    }
    Write-DagLog "Distributed availability group [$($plan.DagName)] is configured and healthy." SUCCESS
}
catch {
    Write-Host ''
    Write-DagLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-DagLog $_.ScriptStackTrace DEBUG }
    Write-Host ''
    Write-DagLog 'Nothing was left half-applied that a re-run cannot recover: Initialize-DAG.ps1 is idempotent.' INFO
    Write-DagLog 'Fix the problem above and run it again — it will resume from where it stopped.' INFO
    exit 1
}

#endregion
