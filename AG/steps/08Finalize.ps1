#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 08: the finishing touches, the health rollup, and what to do next.
#>

Set-StrictMode -Version Latest

function Invoke-AgFinalize {
    <#
    .OUTPUTS
        [bool] the health rollup's verdict.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [bool]$ListenerOk = $true
    )

    Write-AgBanner 'FINALIZE'
    $p = $Plan.PrimaryReplica

    #region Contained AG logins
    if ($Plan.IsContained -and $Plan.ContainedLogins.Count -gt 0) {
        Write-AgLog 'Creating the databases'' logins inside the contained availability group...' INFO
        Copy-AgLoginToContainedAg -Instance $p -AgName $Plan.AgName -Logins @($Plan.ContainedLogins)
    }
    #endregion

    #region Read-only routing
    if ($Plan.Operation -eq 'CREATE' -and $ListenerOk) { Set-AgReadOnlyRouting -Plan $Plan }
    #endregion

    #region Seeding modes back to what the AG had (ADD)
    if ($Plan.Operation -eq 'ADD' -and $Plan.OriginalSeedingModes.Count -gt 0) {
        foreach ($m in $Plan.OriginalSeedingModes) {
            if ($m.Replica -eq $p) { continue }
            Set-AgReplicaSeedingMode -PrimaryInstance $p -AgName $Plan.AgName -Replicas @($m.Replica) -Mode $m.SeedingMode
        }
    }
    #endregion

    #region The seeding log backup job
    if ($Plan.SeedingMode -eq 'MANUAL' -and $Plan.Databases.Count -gt 0 -and $Plan.SecondaryReplicas.Count -gt 0 -and -not $Plan.KeepLogBackupJob) {
        foreach ($r in $Plan.ReplicaNames) {
            $remaining = @(Get-AgTLogJobScope -Instance $r -AgName $Plan.AgName | Where-Object { $Plan.Databases -notcontains $_ })
            if ($remaining.Count -eq 0) {
                Uninstall-AgTLogJob -Instances @($r) -AgName $Plan.AgName
            } else {
                Install-AgTLogJob -Instance $r -AgName $Plan.AgName -ShareRoot $Plan.ShareRoot -Databases $remaining `
                    -IntervalMinutes $Plan.TLogIntervalMinutes -ReplaceScope
                Write-AgLog "  [$r] kept the job for $($remaining.Count) database(s) from an earlier run; this run's databases are out of its scope." INFO
            }
        }
    }
    #endregion

    $healthy = Show-AgHealthRollup -PrimaryInstance $p -AgName $Plan.AgName

    #region What happens next
    Write-AgBanner 'WHAT HAPPENS NEXT'
    if ($Plan.Operation -eq 'CREATE' -and (-not $Plan.Listener -or -not $Plan.Listener.Create)) {
        Write-Host 'No listener was created. When you are ready, run on the primary, for example:' -ForegroundColor White
        Write-Host "    ALTER AVAILABILITY GROUP [$($Plan.AgName)] ADD LISTENER N'$($Plan.AgName -replace '[^A-Za-z0-9-]','')-LSN' (WITH IP ((N'<ip>', N'<mask>')), PORT = 1433);" -ForegroundColor DarkGray
        Write-Host '    (one (ip, mask) pair per subnet the replicas live in)' -ForegroundColor DarkGray
        Write-Host ''
    }
    $topo = Get-AgTopology -Instance $p -AgName $Plan.AgName -AllowNoPrimary
    if ($topo.Listeners.Count -gt 0) {
        $l = $topo.Listeners[0]
        $msf = if ($l.Addresses.Count -gt 1) { ';MultiSubnetFailover=True' } else { '' }
        Write-Host 'Connect applications to the listener:' -ForegroundColor White
        Write-Host ("    Server={0},{1};Database=<db>{2}" -f $l.DnsName, $l.Port, $msf) -ForegroundColor DarkGray
        if (@($topo.Replicas | Where-Object { $_.SecondaryConnections -ne 'NO' }).Count -gt 0) {
            Write-Host ("    read-only work: add ;ApplicationIntent=ReadOnly") -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    if ($Plan.IsContained) {
        Write-Host 'Contained availability group:' -ForegroundColor White
        Write-Host '  * Connect through the listener (or with a contained database as the initial catalog) to' -ForegroundColor DarkGray
        Write-Host '    work inside the AG: logins, users and Agent jobs created there move with every failover.' -ForegroundColor DarkGray
        Write-Host '  * Instance-level logins and jobs created on a replica directly do NOT follow the AG.' -ForegroundColor DarkGray
        Write-Host ''
    }
    Write-Host 'Backups:' -ForegroundColor White
    Write-Host "  * Backup preference is $($topo.BackupPreference). Backup jobs should run on every replica and" -ForegroundColor DarkGray
    Write-Host '    skip unless sys.fn_hadr_backup_is_preferred_replica(''<db>'') = 1, so they follow failovers.' -ForegroundColor DarkGray
    if ($Plan.SeedingMode -eq 'MANUAL' -and $Plan.KeepLogBackupJob -and $Plan.Databases.Count -gt 0 -and $Plan.SecondaryReplicas.Count -gt 0) {
        Write-Host "  * The job '$(Get-AgTLogJobName -AgName $Plan.AgName)' keeps backing up these databases' logs to" -ForegroundColor DarkGray
        Write-Host "    $($Plan.ShareRoot) every $($Plan.TLogIntervalMinutes) minutes, on whichever replica is primary." -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Day-two tools in this folder:' -ForegroundColor White
    Write-Host '    .\Add-AGDatabase.ps1      add more databases (same checks, same seeding choices)' -ForegroundColor DarkGray
    Write-Host '    .\Remove-AGDatabase.ps1   take databases out again' -ForegroundColor DarkGray
    Write-Host '    .\Initialize-AG.ps1 -HealthOnly   this rollup, any time' -ForegroundColor DarkGray
    Write-Host ''
    #endregion

    return $healthy
}
