#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 03: make the selected databases ready to join.

.DESCRIPTION
    Applies exactly the repairs the operator agreed to in the interview — FULL recovery,
    AUTO_CLOSE OFF, the full backup that starts the log chain — and drops the leftover copies
    on secondaries that they agreed to drop. Each repair re-reads the live setting first,
    so a resumed run repeats nothing that already happened.
#>

Set-StrictMode -Version Latest

function Invoke-AgPrepareDatabases {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-AgBanner 'PREPARE THE DATABASES'

    if ($Plan.Databases.Count -eq 0) {
        Write-AgLog 'No databases in this run.' INFO
        return
    }

    $repairs = @($Plan.Repairs)
    if ($repairs.Count -eq 0) {
        Write-AgLog 'Every selected database already meets the prerequisites.' SUCCESS
    }
    foreach ($r in $repairs) {
        $dir = if ($r.TakeFullBackup) { $Plan.RepairBackupDirectory } else { $null }
        Invoke-AgDatabaseRepair -Instance $Plan.PrimaryReplica -DatabaseName $r.DatabaseName `
            -SetFullRecovery $r.SetFullRecovery -SetAutoCloseOff $r.SetAutoCloseOff -BackupDirectory $dir
    }

    # Automatic seeding cannot proceed without a log chain; manual seeding starts its own.
    if ($Plan.SeedingMode -eq 'AUTOMATIC') {
        foreach ($db in $Plan.Databases) {
            if (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $db) { continue }
            if (-not (Test-AgLogChain -Instance $Plan.PrimaryReplica -DatabaseName $db)) {
                throw "[$db] has no log chain (it has never had a full backup in FULL recovery), so it cannot join the availability group. Take a full backup of it and re-run."
            }
        }
    }

    foreach ($pair in @($Plan.DropLeftoverCopies)) {
        $db, $replica = $pair -split '\|', 2
        # Once the database is in the AG — a resumed run — the copy on the secondary is the
        # AG's own, possibly still seeding. Dropping it then would destroy the seed.
        if (Test-AgExists -Instance $Plan.PrimaryReplica -AgName $Plan.AgName) {
            if (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $db) { continue }
        }
        Write-AgLog "  [$replica] dropping the leftover copy of [$db] ..." INFO
        Remove-AgDatabaseCopy -Instance $replica -DatabaseName $db
    }

    Write-AgLog 'Databases are ready.' SUCCESS
}
