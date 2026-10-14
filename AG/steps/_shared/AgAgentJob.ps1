#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — the transaction log backup job used during manual seeding.

.DESCRIPTION
    The job is created on EVERY replica of the availability group, not just the current
    primary. SQL Agent jobs do not replicate, so if the AG fails over mid-seed a job that
    exists only on the old primary would silently stop backing up logs. Each copy guards
    itself: the step exits quietly unless its local replica currently holds the PRIMARY role.

    Its scope is a fixed list of databases, and it does not require them to be AG members:
    during a manual seed they are not members yet — joining is the last thing that happens.
    Re-installing MERGES the new databases into the existing scope rather than replacing it,
    so a second Add-AGDatabase run against the same AG never silently drops the first run's
    databases out of their log backups.
#>

Set-StrictMode -Version Latest

function Get-AgTLogJobName {
    param([Parameter(Mandatory)][string]$AgName)
    "AG-TLogBackup-$AgName"
}

function Get-AgLogDirectory {
    <#
    .SYNOPSIS
        Canonical per-database log backup folder: <root>\<AgName>\<Database>\LOG
    #>
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    Join-AgPath -Path $ShareRoot -ChildPath @((Get-AgSafeFileToken $AgName), (Get-AgSafeFileToken $DatabaseName), 'LOG')
}

function Get-AgFullDirectory {
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    Join-AgPath -Path $ShareRoot -ChildPath @((Get-AgSafeFileToken $AgName), (Get-AgSafeFileToken $DatabaseName), 'FULL')
}

function Get-AgPlanShareRoots {
    <#
    .SYNOPSIS
        The backup share roots a plan uses, as an array. Always at least one entry for a
        manual-seeding plan.
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

function Get-AgFullDirectoryList {
    <#
    .SYNOPSIS
        The per-database FULL backup folder on EVERY backup share, in the share order the
        plan records. One entry per share; a single-share plan yields one directory.
    .DESCRIPTION
        Manual seeding can stripe a FULL backup across several file-server nodes at once.
        Each node is a share root of its own, and each gets the same
        <root>\<AgName>\<Database>\FULL sub-tree so the stripes written to it are found in
        a predictable place on a resume.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ShareRoots,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    @($ShareRoots | Where-Object { $_ } | ForEach-Object {
        Get-AgFullDirectory -ShareRoot $_ -AgName $AgName -DatabaseName $DatabaseName
    })
}

#region ── Job step body ─────────────────────────────────────────────────────

# The scope list is fenced by these markers inside the job step, which is what lets a later
# install read it back and merge rather than overwrite.
$script:AgScopeBegin = '-- AG-TOOLKIT-SCOPE-BEGIN'
$script:AgScopeEnd   = '-- AG-TOOLKIT-SCOPE-END'

function Get-AgTLogJobStepSql {
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string[]]$Databases
    )

    $dbValues = ($Databases | ForEach-Object { "($(ConvertTo-AgQuotedString $_))" }) -join ",`r`n    "
    $agText   = $AgName.Replace("'", "''")
    $rootText = $ShareRoot.TrimEnd('\').Replace("'", "''")
    $agToken  = (Get-AgSafeFileToken $AgName).Replace("'", "''")

    @"
-- AG-TOOLKIT-SHARE-ROOT: $($ShareRoot.TrimEnd('\'))
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Only the PRIMARY replica of the availability group backs up logs. Every other copy of
-- this job exits here, which is what makes the job failover-safe.
IF NOT EXISTS (
    SELECT 1
    FROM sys.dm_hadr_availability_replica_states AS ars
    JOIN sys.availability_groups AS ag ON ag.group_id = ars.group_id
    WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)
      AND ars.is_local = 1
      AND ars.role_desc = 'PRIMARY'
)
BEGIN
    PRINT 'Local replica is not the primary of $agText - nothing to do.';
    RETURN;
END

DECLARE @Scope TABLE (DatabaseName sysname PRIMARY KEY);
INSERT INTO @Scope (DatabaseName) VALUES
$($script:AgScopeBegin)
    $dbValues
$($script:AgScopeEnd)
;

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
    WHERE d.state_desc      = 'ONLINE'
      AND d.recovery_model_desc IN ('FULL','BULK_LOGGED')
      -- A log backup is legal only once a NON-copy-only full backup has established the log
      -- chain. That is read from the DATABASE'S OWN state, not from msdb.dbo.backupset,
      -- because backup history lies in exactly the cases that matter: the last full was
      -- COPY_ONLY (enterprise backup tools take those), the database arrived by automatic
      -- seeding (no backupset row at all), or the history was groomed away.
      -- last_log_backup_lsn is NULL exactly while the database is in pseudo-simple mode.
      AND EXISTS (SELECT 1 FROM sys.database_recovery_status AS drs
                  WHERE drs.database_id = d.database_id
                    AND drs.last_log_backup_lsn IS NOT NULL)
    ORDER BY s.DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @dir = N'$rootText\$agToken\' + REPLACE(REPLACE(@db, '\', '_'), '/', '_') + N'\LOG';
        EXEC master.dbo.xp_create_subdir @dir;

        SET @stamp = CONVERT(nvarchar(8), GETUTCDATE(), 112) + N'_'
                   + REPLACE(CONVERT(nvarchar(8), GETUTCDATE(), 108), ':', '');

        SET @file = @dir + N'\' + REPLACE(REPLACE(@db, '\', '_'), '/', '_')
                  + N'_LOG_' + @stamp + N'_' + CAST(ABS(CHECKSUM(NEWID())) % 100000 AS nvarchar(8)) + N'.trn';

        SET @sql = N'BACKUP LOG ' + QUOTENAME(@db)
                 + N' TO DISK = N''' + REPLACE(@file, '''', '''''') + N''''
                 + N' WITH COMPRESSION, CHECKSUM, DESCRIPTION = N''AG toolkit scheduled log backup'';';
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

function Get-AgTLogJobScope {
    <#
    .SYNOPSIS
        The databases an installed log backup job covers, read back from its step, or an
        empty array when the job does not exist.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $cmd = Get-AgScalar -Instance $Instance -Query @"
SELECT TOP 1 js.command AS v
FROM msdb.dbo.sysjobsteps AS js
JOIN msdb.dbo.sysjobs AS j ON j.job_id = js.job_id
WHERE j.name = $(ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName))
ORDER BY js.step_id
"@
    if (-not $cmd) { return @() }
    $b = $cmd.IndexOf($script:AgScopeBegin)
    $e = $cmd.IndexOf($script:AgScopeEnd)
    if ($b -lt 0 -or $e -le $b) { return @() }
    $block = $cmd.Substring($b, $e - $b)
    return @([regex]::Matches($block, "N'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value.Replace("''", "'") })
}

function Get-AgTLogJobSetting {
    <#
    .SYNOPSIS
        The share root and interval an installed log backup job was created with, or $null.
        Lets a later run re-install the job with a different scope without asking again.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $jobLit = ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName)
    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'tlog job settings' -Query @"
SELECT TOP 1 js.command AS Command, ISNULL(s.freq_subday_interval, 15) AS IntervalMinutes
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules AS jsch ON jsch.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = jsch.schedule_id
WHERE j.name = $jobLit
ORDER BY js.step_id
"@
    if ($rows.Count -eq 0) { return $null }
    $share = if ([string]$rows[0].Command -match '(?m)^-- AG-TOOLKIT-SHARE-ROOT: (.+?)\s*$') { $Matches[1] } else { $null }
    [pscustomobject]@{ ShareRoot = $share; IntervalMinutes = [int]$rows[0].IntervalMinutes }
}

#endregion

#region ── Job lifecycle ─────────────────────────────────────────────────────

function Install-AgTLogJob {
    <#
    .SYNOPSIS
        Creates (or re-creates) the log backup job on one replica. Idempotent, and additive:
        databases already in an existing job's scope stay in it.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string[]]$Databases,
        [int]$IntervalMinutes = 15,
        # Install exactly $Databases instead of merging them into the existing scope — used
        # to take a run's databases back out again without touching anyone else's.
        [switch]$ReplaceScope
    )

    $existing = if ($ReplaceScope) { @() } else { @(Get-AgTLogJobScope -Instance $Instance -AgName $AgName) }
    $scope    = @(@($existing) + @($Databases) | Where-Object { $_ } | Sort-Object -Unique)

    $jobName  = Get-AgTLogJobName -AgName $AgName
    $stepSql  = Get-AgTLogJobStepSql -ShareRoot $ShareRoot -AgName $AgName -Databases $scope
    $jobLit   = ConvertTo-AgQuotedString $jobName
    $stepLit  = ConvertTo-AgQuotedString $stepSql
    $schedule = "$jobName-Every${IntervalMinutes}Min"
    $descLit  = ConvertTo-AgQuotedString "Transaction log backups for databases manually seeded into availability group $AgName. Created by the AG toolkit (Initialize-AG / Add-AGDatabase)."

    # Drop and recreate so the step body always carries the merged scope.
    $sql = @"
USE msdb;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_delete_job @job_name = $jobLit, @delete_unused_schedule = 1;

DECLARE @jobId uniqueidentifier;

EXEC msdb.dbo.sp_add_job
     @job_name        = $jobLit,
     @enabled         = 1,
     @description     = $descLit,
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
     @name     = $(ConvertTo-AgQuotedString $schedule),
     @enabled  = 1,
     @freq_type = 4,                 -- daily
     @freq_interval = 1,
     @freq_subday_type = 4,          -- minutes
     @freq_subday_interval = $IntervalMinutes,
     @active_start_time = 000000;

EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
"@

    Invoke-AgSql -Instance $Instance -Query $sql -QueryTimeout 120 -Activity 'install tlog job' | Out-Null
    $detail = if ($ReplaceScope) { 'scope replaced' } else { "$(@($Databases | Where-Object { @($existing) -notcontains $_ }).Count) new" }
    Write-AgLog "  [$Instance] installed job '$jobName' (every $IntervalMinutes min, $($scope.Count) database(s) in scope, $detail)" SUCCESS
}

function Test-AgTLogJobExists {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $v = Get-AgScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM msdb.dbo.sysjobs WHERE name = $(ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName))"
    return ([int]$v -gt 0)
}

function Set-AgTLogJobEnabled {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $jobLit = ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName)
    $flag   = if ($Enabled) { 1 } else { 0 }

    Invoke-AgSql -Instance $Instance -QueryTimeout 60 -Activity 'toggle tlog job' -Query @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_update_job @job_name = $jobLit, @enabled = $flag;
"@ | Out-Null
}

function Test-AgJobRunning {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $jobLit = ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName)
    $v = Get-AgScalar -Instance $Instance -Query @"
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

function Suspend-AgTLogJob {
    <#
    .SYNOPSIS
        Disables the log backup job on every replica and waits for any in-flight
        execution to finish.

    .DESCRIPTION
        Disabling a SQL Agent job does not stop the execution already running. If a
        scheduled log backup fires between our final log backup and the database being
        joined on the secondaries, it takes the tail of the log and the secondaries are
        permanently short one log backup. So we disable first, then wait.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$AgName,
        [int]$WaitSeconds = 900
    )

    foreach ($i in $Instances) { Set-AgTLogJobEnabled -Instance $i -AgName $AgName -Enabled $false }
    Write-AgLog "  Disabled log backup job on: $($Instances -join ', ')" INFO

    foreach ($i in $Instances) {
        if (-not (Test-AgJobRunning -Instance $i -AgName $AgName)) { continue }
        Write-AgLog "  [$i] a scheduled log backup is currently running; waiting for it to finish..." INFO
        $ok = Wait-AgCondition -Activity "in-flight log backup on $i" -TimeoutSeconds $WaitSeconds -PollSeconds 10 `
                -Condition { -not (Test-AgJobRunning -Instance $i -AgName $AgName) }
        if (-not $ok) {
            throw "A scheduled log backup on '$i' is still running after $WaitSeconds seconds. Resolve it, then re-run — the script will pick up where it left off."
        }
    }
}

function Resume-AgTLogJob {
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$AgName
    )
    foreach ($i in $Instances) { Set-AgTLogJobEnabled -Instance $i -AgName $AgName -Enabled $true }
    Write-AgLog "  Re-enabled log backup job on: $($Instances -join ', ')" INFO
}

function Uninstall-AgTLogJob {
    param(
        [Parameter(Mandatory)][string[]]$Instances,
        [Parameter(Mandatory)][string]$AgName
    )
    $jobLit = ConvertTo-AgQuotedString (Get-AgTLogJobName -AgName $AgName)
    foreach ($i in $Instances) {
        Invoke-AgSql -Instance $i -QueryTimeout 60 -Activity 'remove tlog job' -Query @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $jobLit)
    EXEC msdb.dbo.sp_delete_job @job_name = $jobLit, @delete_unused_schedule = 1;
"@ | Out-Null
    }
    Write-AgLog "  Removed log backup job from: $($Instances -join ', ')" INFO
}

#endregion

#region ── Competing log backup detection ────────────────────────────────────

function Get-AgCompetingLogBackup {
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
    $dbList = ($Databases | ForEach-Object { ConvertTo-AgQuotedString $_ }) -join ', '
    $rootLike = ConvertTo-AgQuotedString ($ShareRoot.TrimEnd('\') + '\%')

    $rows = Invoke-AgSql -Instance $Instance -Retry -Activity 'competing log backup scan' -Query @"
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
