#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 07: final health rollup and next steps.
#>

Set-StrictMode -Version Latest

function Invoke-DagHealthRollup {
    param([Parameter(Mandatory)][psobject]$Plan)

    $healthy = Show-DagHealthRollup -Plan $Plan

    Write-DagBanner 'STEP 7 of 7 — WHAT HAPPENS NEXT'

    Write-Host 'The distributed availability group is configured and the databases are flowing.' -ForegroundColor White
    Write-Host ''
    Write-Host 'When you are ready to fail over to the forwarder:' -ForegroundColor White
    Write-Host '  1. Stop application traffic against the global primary.'
    Write-Host '  2. Set BOTH member AGs to SYNCHRONOUS_COMMIT and wait for the forwarder to report'
    Write-Host '     SYNCHRONIZED (run the ALTER on both the global primary and the forwarder primary):'
    Write-Host ''
    Write-Host "     ALTER AVAILABILITY GROUP [$($Plan.DagName)] MODIFY" -ForegroundColor DarkGray
    Write-Host '     AVAILABILITY GROUP ON' -ForegroundColor DarkGray
    Write-Host "         N'$($Plan.GlobalAgName)'    WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT)," -ForegroundColor DarkGray
    Write-Host "         N'$($Plan.ForwarderAgName)' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  3. On $($Plan.GlobalPrimaryReplica):  ALTER AVAILABILITY GROUP [$($Plan.DagName)] SET (ROLE = SECONDARY);"
    Write-Host "  4. On $($Plan.ForwarderPrimaryReplica):  ALTER AVAILABILITY GROUP [$($Plan.DagName)] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
    Write-Host ''
    Write-Host '     FORCE_FAILOVER_ALLOW_DATA_LOSS is the only supported failover for a distributed AG.'
    Write-Host '     With both sides synchronized and traffic stopped, there is nothing to lose.'

    if ($Plan.IsCrossVersion) {
        Write-Host ''
        Write-Host 'Because this is a cross-version distributed availability group:' -ForegroundColor Yellow
        Write-Host "  - Until you fail over, the forwarder's databases stay in Recovering / Synchronizing" -ForegroundColor DarkGray
        Write-Host '    and cannot be read. This is expected, not a fault.' -ForegroundColor DarkGray
        Write-Host "  - The failover upgrades the databases to $(Get-DagSqlVersionName $Plan.ForwarderMajorVersion)." -ForegroundColor DarkGray
        Write-Host "  - After that, failing back to $(Get-DagSqlVersionName $Plan.GlobalMajorVersion) is not possible." -ForegroundColor DarkGray
    }

    if ($Plan.SeedingMode -eq 'MANUAL') {
        Write-Host ''
        Write-Host "Log backup job '$(Get-DagTLogJobName -DagName $Plan.DagName)' remains on the global primary AG replicas." -ForegroundColor White
        Write-Host '  Remove it once your regular log backup maintenance covers these databases:' -ForegroundColor DarkGray
        Write-Host '      .\Initialize-DAG.ps1 -RemoveLogBackupJob' -ForegroundColor DarkGray
    }

    Write-Host ''
    return $healthy
}
