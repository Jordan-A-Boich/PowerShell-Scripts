#Requires -Version 5.1
<#
.SYNOPSIS
    Add-AGDatabase — add one or more databases to an existing availability group, end to end.

.DESCRIPTION
    The same interview, checks and seeding engine as Initialize-AG.ps1, against an AG that
    already exists. Connect to any replica; the AG is picked by number and the work is
    re-anchored on its current primary.

      * Lists every database on the primary with what it still needs, and why the rest
        cannot be added (OFFLINE, READ_ONLY, in another AG, ONLINE under the same name on a
        secondary, TDE certificate missing on a secondary, FILESTREAM not enabled there).
      * Offers to fix what it can: FULL recovery, a full backup (you choose where),
        AUTO_CLOSE OFF, dropping leftover copies on the secondaries.
      * Seeds AUTOMATICALLY (a throttled, self-healing sliding window) or MANUALLY (striped
        backup to a share, restore with the file layout you choose, log-chain catch-up,
        join). The AG's current seeding mode is the default, and each replica's original
        seeding mode is put back afterwards.
      * For a contained AG, copies the databases' logins into the AG's own master.
      * Finishes with a health rollup.

    Safe to re-run; an interrupted run is offered for resume.

.PARAMETER Instance
    Any replica of the availability group. When omitted you are asked.

.PARAMETER AgName
    The availability group. When omitted you pick it from a numbered list.

.PARAMETER SeedTimeoutHours
    How long to wait for a single database to finish seeding. Default 24.

.PARAMETER MaxConcurrentSeeds
    The default offered for how many databases may seed automatically at once. Default 3.

.PARAMETER Credential
    A SQL Server login used for every connection.

.PARAMETER Force
    Restore a FULL backup even when the script cannot prove the target needs it.

.EXAMPLE
    .\Add-AGDatabase.ps1

.EXAMPLE
    .\Add-AGDatabase.ps1 -Instance SQLLAB-SQL3 -AgName AG1
#>

[CmdletBinding()]
param(
    [string]$Instance,
    [string]$AgName,

    [ValidateRange(1, 720)]
    [int]$SeedTimeoutHours = 24,

    [ValidateRange(1, 10)]
    [int]$MaxConcurrentSeeds = 3,

    [pscredential]$Credential,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$SharedDir  = Join-Path $ScriptRoot 'steps\_shared'
$StepsDir   = Join-Path $ScriptRoot 'steps'

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

try {
    Initialize-AgLog   -LogDirectory (Join-Path $ScriptRoot 'logs') -NamePrefix 'Add-AGDatabase' | Out-Null
    Initialize-AgState -StateDirectory (Join-Path $ScriptRoot 'state')

    Write-AgBanner 'ADD DATABASES TO AN AVAILABILITY GROUP'

    if ($Credential) {
        Set-AgConnectionContext -Credential $Credential
        Write-AgLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-AgCredential
    }

    $plan = $null
    if (-not $Instance -and -not $AgName) { $plan = Select-AgResumePlan -Operation 'ADD' }
    if ($plan) {
        Write-AgLog "Resuming plan for [$($plan.AgName)]." INFO
    } else {
        $plan = New-AgAddPlan -MaxConcurrentSeeds $MaxConcurrentSeeds -Instance $Instance -AgName $AgName
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

    $healthy = Invoke-AgFinalize -Plan $plan
    Complete-AgPlan -Plan $plan

    Write-AgBanner ('DONE in {0}' -f (Format-AgDuration ((Get-Date) - $started)))
    if (-not $healthy) {
        Write-AgLog "The databases were added to [$($plan.AgName)], but the health rollup reported problems (see above)." WARN
        exit 1
    }
    Write-AgLog "$($plan.Databases.Count) database(s) added to [$($plan.AgName)] and synchronizing." SUCCESS
}
catch {
    Write-Host ''
    Write-AgLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-AgLog $_.ScriptStackTrace DEBUG }
    Write-Host ''
    Write-AgLog 'Add-AGDatabase.ps1 is idempotent. Fix the problem above and run it again — choose "Resume".' INFO
    exit 1
}
