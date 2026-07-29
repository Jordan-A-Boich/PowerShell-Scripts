#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — the 15-minute transaction log backup job used during manual seeding.

.DESCRIPTION
    The job is created on EVERY replica of the global primary availability group, not
    just the current primary. SQL Agent jobs do not replicate, so if the global AG fails
    over mid-seed a job that exists only on the old primary would silently stop backing
    up logs and the seed would starve. Each copy guards itself: the step exits quietly
    unless its local replica currently holds the PRIMARY role.
#>

Set-StrictMode -Version Latest

function Get-DagTLogJobName {
    param([Parameter(Mandatory)][string]$DagName)
    "DAG-TLogBackup-$DagName"
}

function Get-DagLogDirectory {
    <#
    .SYNOPSIS
        Canonical per-database log backup folder: <root>\<DagName>\<Database>\LOG
    #>
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    Join-DagPath -Path $ShareRoot -ChildPath @((Get-DagSafeFileToken $DagName), (Get-DagSafeFileToken $DatabaseName), 'LOG')
}

function Get-DagFullDirectory {
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    Join-DagPath -Path $ShareRoot -ChildPath @((Get-DagSafeFileToken $DagName), (Get-DagSafeFileToken $DatabaseName), 'FULL')
}

function Get-DagPlanShareRoots {
    <#
    .SYNOPSIS
        The backup share roots a plan uses, as an array, newest field first.
    .DESCRIPTION
        ShareRoots (a list, for striping a FULL backup across several nodes) was added after
        ShareRoot (a single path). A plan written before then, or one hand-built without the
        list, still carries ShareRoot — so fall back to it. Always returns at least one entry
        for a manual-seeding plan.
    #>
    param([Parameter(Mandatory)][psobject]$Plan)

    if ($Plan.PSObject.Properties.Name -contains 'ShareRoots') {
        $roots = @($Plan.ShareRoots | Where-Object { $_ })
        if ($roots.Count -gt 0) { return $roots }
    }
    if ($Plan.PSObject.Properties.Name -contains 'ShareRoot' -and $Plan.ShareRoot) {
        return @($Plan.ShareRoot)
    }
    return @()
}

function Get-DagFullDirectoryList {
    <#
    .SYNOPSIS
        The per-database FULL backup folder on EVERY backup share, in the share order the
        plan records. One entry per share; a single-share plan yields one directory.
    .DESCRIPTION
        Manual seeding can stripe a FULL backup across several file-server nodes at once.
        Each node is a share root of its own, and each gets the same
        <root>\<DagName>\<Database>\FULL sub-tree so the stripes written to it are found in
        a predictable place on a resume.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ShareRoots,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    @($ShareRoots | Where-Object { $_ } | ForEach-Object {
        Get-DagFullDirectory -ShareRoot $_ -DagName $DagName -DatabaseName $DatabaseName
    })
}

#region ── Job step body ─────────────────────────────────────────────────────

function Get-DagTLogJobStepSql {
    param(
        [Parameter(Mandatory)][string]$GlobalAgName,
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string[]]$Databases
    )

    $dbValues = ($Databases | ForEach-Object { "($(ConvertTo-DagQuotedString $_))" }) -join ",`r`n    "

    @"
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Only the PRIMARY replica of the global primary availability group backs up logs.
-- Every other copy of this job exits here, which is what makes the job failover-safe.
IF NOT EXISTS (
    SELECT 1
    FROM sys.dm_hadr_availability_replica_states AS ars
    JOIN sys.availability_groups AS ag ON ag.group_id = ars.group_id
    WHERE ag.name = $(ConvertTo-DagQuotedString $GlobalAgName)
      AND ars.is_local = 1
      AND ars.role_desc = 'PRIMARY'
)
BEGIN
    PRINT 'Local replica is not the primary of $GlobalAgName - nothing to do.';
    RETURN;
END

DECLARE @Scope TABLE (DatabaseName sysname PRIMARY KEY);
INSERT INTO @Scope (DatabaseName) VALUES
    $dbValues;

DECLARE @db       sysname,
        @dir      nvarchar(512),
        @file     nvarchar(1024),
        @sql      nvarchar(max),
        @stamp    nvarchar(32),
        @failures int = 0,
        @errmsg   nvarchar(2048);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.DatabaseName
    FROM @Scope AS s
    JOIN sys.databases AS d ON d.name = s.DatabaseName
    JOIN sys.availability_databases_cluster AS adc
         ON adc.database_name = d.name
    JOIN sys.availability_groups AS ag
         ON ag.group_id = adc.group_id AND ag.name = $(ConvertTo-DagQuotedString $GlobalAgName)
    WHERE d.state_desc      = 'ONLINE'
      AND d.recovery_model_desc IN ('FULL','BULK_LOGGED')
      -- A log backup is illegal until the database has a full backup to chain from.
      AND EXISTS (SELECT 1 FROM msdb.dbo.backupset AS b
                  WHERE b.database_name = d.name AND b.type = 'D' AND b.is_copy_only = 0)
    ORDER BY s.DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @dir = N'$($ShareRoot.TrimEnd('\'))\$(Get-DagSafeFileToken $DagName)\' + REPLACE(REPLACE(@db, '\', '_'), '/', '_') + N'\LOG';
        EXEC master.dbo.xp_create_subdir @dir;

        SET @stamp = CONVERT(nvarchar(8), GETUTCDATE(), 112) + N'_'
                   + REPLACE(CONVERT(nvarchar(8), GETUTCDATE(), 108), ':', '');

        SET @file = @dir + N'\' + REPLACE(REPLACE(@db, '\', '_'), '/', '_')
                  + N'_LOG_' + @stamp + N'_' + CAST(ABS(CHECKSUM(NEWID())) % 100000 AS nvarchar(8)) + N'.trn';

        SET @sql = N'BACKUP LOG ' + QUOTENAME(@db)
                 + N' TO DISK = N''' + REPLACE(@file, '''', '''''') + N''''
                 + N' WITH COMPRESSION, CHECKSUM, DESCRIPTION = N''Initialize-DAG scheduled log backup'';';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @failures += 1;
        SET @errmsg = N'Log backup failed for [' + @db + N']: ' + ERROR_MESSAGE();
        RAISERROR(@errmsg, 10, 1) WITH NOWAIT;   -- severity 10: log it, keep going
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

IF @failures > 0
BEGIN
    SET @errmsg = CAST(@failures AS nvarchar(10)) + N' database(s) failed to back up.';
    RAISERROR(@errmsg, 16, 1);   -- fail the job so the operator sees it
END
"@
}

#endregion

#region ── Job lifecycle ─────────────────────────────────────────────────────

function Install-DagTLogJob {
    <#
    .SYNOPSIS
        Creates (or replaces) the 15-minute log backup job on one replica. Idempotent.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][string]$GlobalAgName,
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string[]]$Databases,
        [int]$IntervalMinutes = 15
    )

    $jobName  = Get-DagTLogJobName -DagName $DagName
    $stepSql  = Get-DagTLogJobStepSql -GlobalAgName $GlobalAgName -ShareRoot $ShareRoot -DagName $DagName -Databases $Databases
    $jobLit   = ConvertTo-DagQuotedString $jobName
    $stepLit  = ConvertTo-DagQuotedString $stepSql
    $schedule = "$jobName-Every${IntervalMinutes}Min"

    # Drop and recreate so a re-run with a different database scope updates the step body.
    $sql = @"
USE msdb;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_delete_job @job_name = $jobLit, @delete_unused_schedule = 1;

DECLARE @jobId uniqueidentifier;

EXEC msdb.dbo.sp_add_job
     @job_name        = $jobLit,
     @enabled         = 1,
     @description     = N'Transaction log backups feeding manual seeding of distributed availability group $DagName. Created by Initialize-DAG.ps1.',
     @owner_login_name= N'sa',
     @job_id          = @jobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
     @job_id          = @jobId,
     @step_name       = N'Backup transaction logs',
     @subsystem       = N'TSQL',
     @database_name   = N'master',
     @command         = $stepLit,
     @on_success_action = 1,
     @on_fail_action    = 2,
     @retry_attempts    = 2,
     @retry_interval    = 1;

EXEC msdb.dbo.sp_add_jobschedule
     @job_id   = @jobId,
     @name     = $(ConvertTo-DagQuotedString $schedule),
     @enabled  = 1,
     @freq_type = 4,                 -- daily
     @freq_interval = 1,
     @freq_subday_type = 4,          -- minutes
     @freq_subday_interval = $IntervalMinutes,
     @active_start_time = 000000;

EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
"@

    Invoke-DagSql -Instance $Instance -Query $sql -QueryTimeout 120 -Activity 'install tlog job' | Out-Null
    Write-DagLog "  [$Instance] installed job '$jobName' (every $IntervalMinutes min, $($Databases.Count) database(s) in scope)" SUCCESS
}

function Set-DagTLogJobEnabled {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $jobLit = ConvertTo-DagQuotedString (Get-DagTLogJobName -DagName $DagName)
    $flag   = if ($Enabled) { 1 } else { 0 }

    Invoke-DagSql -Instance $Instance -QueryTimeout 60 -Activity 'toggle tlog job' -Query @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_update_job @job_name = $jobLit, @enabled = $flag;
"@ | Out-Null
}

function Test-DagJobRunning {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DagName
    )
    $jobLit = ConvertTo-DagQuotedString (Get-DagTLogJobName -DagName $DagName)
    $v = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
JOIN (SELECT MAX(session_id) AS session_id FROM msdb.dbo.syssessions) AS s ON s.session_id = ja.session_id
WHERE j.name = $jobLit
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
"@
    return ([int]$v -gt 0)
}

function Suspend-DagTLogJob {
    <#
    .SYNOPSIS
        Disables the log backup job on every replica and waits for any in-flight
        execution to finish.

    .DESCRIPTION
        Disabling a SQL Agent job does not stop the execution already running. If a
        scheduled log backup fires between our final log backup and the database being
        joined to the forwarder AG, it takes the tail of the log and the forwarder is
        permanently short one log backup. So we disable first, then wait.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$DagName,
        [int]$WaitSeconds = 900
    )

    foreach ($i in $Instances) { Set-DagTLogJobEnabled -Instance $i -DagName $DagName -Enabled $false }
    Write-DagLog "  Disabled log backup job on: $($Instances -join ', ')" INFO

    foreach ($i in $Instances) {
        if (-not (Test-DagJobRunning -Instance $i -DagName $DagName)) { continue }
        Write-DagLog "  [$i] a scheduled log backup is currently running; waiting for it to finish..." INFO
        $ok = Wait-DagCondition -Activity "in-flight log backup on $i" -TimeoutSeconds $WaitSeconds -PollSeconds 10 `
                -Condition { -not (Test-DagJobRunning -Instance $i -DagName $DagName) }
        if (-not $ok) {
            throw "A scheduled log backup on '$i' is still running after $WaitSeconds seconds. Resolve it, then re-run — the script will pick up where it left off."
        }
    }
}

function Resume-DagTLogJob {
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$DagName
    )
    foreach ($i in $Instances) { Set-DagTLogJobEnabled -Instance $i -DagName $DagName -Enabled $true }
    Write-DagLog "  Re-enabled log backup job on: $($Instances -join ', ')" INFO
}

function Uninstall-DagTLogJob {
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$DagName
    )
    $jobLit = ConvertTo-DagQuotedString (Get-DagTLogJobName -DagName $DagName)
    foreach ($i in $Instances) {
        Invoke-DagSql -Instance $i -QueryTimeout 60 -Activity 'remove tlog job' -Query @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_delete_job @job_name = $jobLit, @delete_unused_schedule = 1;
"@ | Out-Null
    }
    Write-DagLog "  Removed log backup job from: $($Instances -join ', ')" INFO
}

#endregion

#region ── Competing log backup detection ────────────────────────────────────

function Get-DagCompetingLogBackup {
    <#
    .SYNOPSIS
        Finds log backups of the in-scope databases taken in the last 24 hours to a
        destination OUTSIDE our share root.

    .DESCRIPTION
        This is the single most common way a manual seed silently breaks: a pre-existing
        maintenance job keeps taking log backups elsewhere, so the log chain we restore
        from the share has holes. Detecting it up front is far kinder than failing with
        error 4305 four hours into a restore.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string[]]$Databases,
        [Parameter(Mandatory)][string]$ShareRoot
    )

    if ($Databases.Count -eq 0) { return @() }
    $dbList = ($Databases | ForEach-Object { ConvertTo-DagQuotedString $_ }) -join ', '
    $rootLike = ConvertTo-DagQuotedString ($ShareRoot.TrimEnd('\') + '\%')

    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'competing log backup scan' -Query @"
SELECT bs.database_name          AS DatabaseName,
       COUNT(*)                  AS BackupCount,
       MAX(bs.backup_finish_date) AS LastBackup,
       MAX(bmf.physical_device_name) AS SampleDevice
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.type = 'L'
  AND bs.backup_finish_date > DATEADD(HOUR, -24, GETDATE())
  AND bs.database_name IN ($dbList)
  AND bmf.physical_device_name NOT LIKE $rootLike
GROUP BY bs.database_name
"@
    if (-not $rows) { return @() }
    foreach ($r in $rows) {
        [pscustomobject]@{
            DatabaseName = $r.DatabaseName
            BackupCount  = [int]$r.BackupCount
            LastBackup   = $r.LastBackup
            SampleDevice = $r.SampleDevice
        }
    }
}

#endregion
