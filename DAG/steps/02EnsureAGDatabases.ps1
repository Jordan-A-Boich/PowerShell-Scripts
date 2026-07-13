#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 03: align seeding modes and make sure every selected database
    is a healthy member of the global primary availability group.

.DESCRIPTION
    A distributed availability group can only ship databases that its global primary AG
    already owns. This step brings the source side into the shape the DAG needs:

      1. Every replica of BOTH availability groups is set to the chosen seeding mode.
         The DAG has no seeding mode of its own that is independent of its members.
      2. Any selected database not yet in the global primary AG is added — seeded to the
         local secondaries automatically or by backup/restore, matching the chosen mode.
#>

Set-StrictMode -Version Latest

function Get-DagDefaultBackupPath {
    <#
    .SYNOPSIS
        The instance's configured backup directory, used when a database needs its first
        full backup and no share is in play (automatic seeding).
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'default backup path' -Query @'
DECLARE @path nvarchar(512);
EXEC master.dbo.xp_instance_regread
     N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',
     N'BackupDirectory', @path OUTPUT;
SELECT @path AS v;
'@
    if (-not $rows -or -not $rows[0].v) { throw "Could not determine the default backup directory on '$Instance'." }
    return [string]$rows[0].v
}

function Set-DagReplicaSeedingMode {
    <#
    .SYNOPSIS
        Sets SEEDING_MODE on every replica of one AG. Runs on that AG's primary. Idempotent.
    #>
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string[]]$Replicas,
        [Parameter(Mandatory)][ValidateSet('AUTOMATIC','MANUAL')][string]$Mode
    )

    $topo = Get-DagAgTopology -Instance $PrimaryInstance -AgName $AgName
    foreach ($r in $Replicas) {
        $current = @($topo.Replicas | Where-Object { $_.ReplicaServerName -eq $r })
        if ($current.Count -eq 1 -and $current[0].SeedingMode -eq $Mode) {
            Write-DagLog "  [$AgName] $r already SEEDING_MODE = $Mode" DEBUG
            continue
        }
        Invoke-DagSql -Instance $PrimaryInstance -QueryTimeout 120 -Activity 'set seeding mode' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $AgName)
MODIFY REPLICA ON $(ConvertTo-DagQuotedString $r) WITH (SEEDING_MODE = $Mode);
"@ | Out-Null
        Write-DagLog "  [$AgName] $r SEEDING_MODE -> $Mode" SUCCESS
    }
}

function Wait-DagDatabaseJoined {
    <#
    .SYNOPSIS
        Waits until a database is joined and moving data on the given replica.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName,
        [int]$TimeoutSeconds = 3600
    )
    return Wait-DagCondition -Activity "[$DatabaseName] joining [$AgName] on $Instance" -TimeoutSeconds $TimeoutSeconds -PollSeconds 10 `
        -Condition {
            $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'join wait' -Query @"
SELECT drs.synchronization_state_desc AS SyncState
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $AgName)
  AND DB_NAME(drs.database_id) = $(ConvertTo-DagQuotedString $DatabaseName)
  AND drs.is_local = 1
"@
            return ($rows -and $rows[0].SyncState -in @('SYNCHRONIZED','SYNCHRONIZING'))
        } `
        -ProgressMessage {
            $s = @(Get-DagSeedingProgress -Instance $Instance -AgName $AgName)
            $active = @($s | Where-Object { $_.DatabaseName -eq $DatabaseName -and $_.CurrentState -ne 'COMPLETED' })
            if ($active.Count -gt 0) { "seeding state $($active[0].CurrentState)" } else { $null }
        }
}

function Add-DagDatabaseToGlobalAg {
    <#
    .SYNOPSIS
        Adds one database to the global primary AG and gets it joined on the local secondaries.
    .OUTPUTS
        string[] — the FULL backup stripe paths, when manual seeding produced them
        (so the forwarder restore can reuse the same backup instead of taking another).
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][hashtable]$InstanceInfo,
        [switch]$Force
    )

    $gp = $Plan.GlobalPrimaryReplica
    Write-DagLog "  [$DatabaseName] is not in [$($Plan.GlobalAgName)] — adding it." INFO

    $fullFiles = @()

    if ($Plan.SeedingMode -eq 'AUTOMATIC') {
        # A database must have a full backup before it can join an AG; without one it
        # behaves as if it were in SIMPLE recovery.
        $hasFull = Get-DagScalar -Instance $gp -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM msdb.dbo.backupset
WHERE database_name = $(ConvertTo-DagQuotedString $DatabaseName) AND type = 'D' AND is_copy_only = 0
"@
        if ([int]$hasFull -eq 0) {
            $dir  = Get-DagDefaultBackupPath -Instance $gp
            $file = Join-DagPath -Path $dir -ChildPath @("$(Get-DagSafeFileToken $DatabaseName)_InitialFull.bak")
            Write-DagLog "  [$DatabaseName] has never been backed up; taking an initial full backup to $file" INFO
            Invoke-DagLongOp -Instance $gp -Activity "initial FULL backup of [$DatabaseName]" -Query @"
BACKUP DATABASE $(ConvertTo-DagQuotedName $DatabaseName) TO DISK = $(ConvertTo-DagQuotedString $file)
WITH INIT, COMPRESSION, CHECKSUM, FORMAT, DESCRIPTION = N'Initialize-DAG initial full backup';
"@
        }

        Invoke-DagSql -Instance $gp -QueryTimeout 300 -Activity 'add database to AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.GlobalAgName)
ADD DATABASE $(ConvertTo-DagQuotedName $DatabaseName);
"@ | Out-Null
        Write-DagLog "  [$DatabaseName] added to [$($Plan.GlobalAgName)]; automatic seeding to local secondaries..." INFO

    } else {
        # MANUAL: back up to the share, restore NORECOVERY on each local secondary, then join.
        $fullDir = Get-DagFullDirectory -ShareRoot $Plan.ShareRoot -DagName $Plan.DagName -DatabaseName $DatabaseName
        $logDir  = Get-DagLogDirectory  -ShareRoot $Plan.ShareRoot -DagName $Plan.DagName -DatabaseName $DatabaseName
        New-DagRemoteDirectory -Instance $gp -Path $fullDir
        New-DagRemoteDirectory -Instance $gp -Path $logDir

        $fullFiles = @(New-DagFullBackup -Instance $gp -DatabaseName $DatabaseName -Directory $fullDir -StripeCount $Plan.StripeCount)
        $header    = Get-DagBackupHeader -Instance $gp -Files $fullFiles

        # No log backups exist for this chain yet, so there is nothing to probe with. That
        # is fine on the path that gets here — the database is being added to the AG for
        # the first time, so a copy already sitting in RESTORING on a secondary is genuinely
        # unexplained, and Restore-DagFullBackup is right to stop and say so rather than
        # overwrite it.
        foreach ($sec in $Plan.GlobalSecondaries) {
            Restore-DagFullBackup -Instance $sec -DatabaseName $DatabaseName -Files $fullFiles `
                -InstanceInfo $InstanceInfo[$sec] -Header $header -Plan $Plan -Force:$Force
        }

        Invoke-DagSql -Instance $gp -QueryTimeout 300 -Activity 'add database to AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.GlobalAgName)
ADD DATABASE $(ConvertTo-DagQuotedName $DatabaseName);
"@ | Out-Null

        foreach ($sec in $Plan.GlobalSecondaries) {
            Invoke-DagSql -Instance $sec -QueryTimeout 300 -Activity 'join database to AG' -Query @"
ALTER DATABASE $(ConvertTo-DagQuotedName $DatabaseName)
SET HADR AVAILABILITY GROUP = $(ConvertTo-DagQuotedName $Plan.GlobalAgName);
"@ | Out-Null
            Write-DagLog "  [$DatabaseName] joined to [$($Plan.GlobalAgName)] on $sec" SUCCESS
        }
    }

    foreach ($sec in $Plan.GlobalSecondaries) {
        if (-not (Wait-DagDatabaseJoined -Instance $sec -AgName $Plan.GlobalAgName -DatabaseName $DatabaseName)) {
            throw "[$DatabaseName] did not reach a synchronizing state on '$sec' within the timeout."
        }
    }

    return @($fullFiles)
}

function Invoke-DagEnsureAgDatabases {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo,
        [switch]$Force
    )

    Write-DagBanner 'STEP 3 of 7 — ALIGN SEEDING MODES AND SOURCE DATABASES'

    #region Seeding modes on both member AGs
    Write-DagLog "Setting SEEDING_MODE = $($Plan.SeedingMode) on every replica of both availability groups..." INFO
    Set-DagReplicaSeedingMode -PrimaryInstance $Plan.GlobalPrimaryReplica -AgName $Plan.GlobalAgName `
        -Replicas $Plan.GlobalReplicas -Mode $Plan.SeedingMode
    Set-DagReplicaSeedingMode -PrimaryInstance $Plan.ForwarderPrimaryReplica -AgName $Plan.ForwarderAgName `
        -Replicas $Plan.ForwarderReplicas -Mode $Plan.SeedingMode
    #endregion

    #region Automatic seeding needs the create-database right on secondaries
    if ($Plan.SeedingMode -eq 'AUTOMATIC') {
        foreach ($sec in $Plan.GlobalSecondaries) {
            Invoke-DagSql -Instance $sec -QueryTimeout 60 -Activity 'grant create any database' `
                -Query "ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.GlobalAgName) GRANT CREATE ANY DATABASE;" | Out-Null
            Write-DagLog "  [$sec] GRANT CREATE ANY DATABASE on [$($Plan.GlobalAgName)]" SUCCESS
        }
    }
    #endregion

    #region Ensure each database is in the global primary AG
    foreach ($db in $Plan.Databases) {
        if (Test-DagDatabaseInAg -Instance $Plan.GlobalPrimaryReplica -AgName $Plan.GlobalAgName -DatabaseName $db) {
            Write-DagLog "  [$db] already in [$($Plan.GlobalAgName)]" SUCCESS
            continue
        }

        $fullFiles = @(Add-DagDatabaseToGlobalAg -Plan $Plan -DatabaseName $db -InstanceInfo $InstanceInfo -Force:$Force)

        if ($fullFiles.Count -gt 0) {
            # Let the forwarder restore reuse this backup rather than take a second full.
            $rec = Get-DagProgress -Plan $Plan -DatabaseName $db
            $rec.FullBackupFiles = @($fullFiles)
            $rec.FullBackupUtc   = (Get-Date).ToUniversalTime().ToString('o')
            Set-DagProgress -Plan $Plan -Record $rec
        }
    }
    #endregion

    Write-DagLog 'All selected databases are members of the global primary availability group.' SUCCESS
}
