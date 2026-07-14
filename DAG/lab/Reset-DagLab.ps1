#Requires -Version 5.1
<#
.SYNOPSIS
    Lab utility — rebuilds the SQL Server lab into a known starting state for testing
    Initialize-DAG.ps1 and Failover-DAG.ps1.

.DESCRIPTION
    THIS IS DESTRUCTIVE AND IT IS ONLY FOR THE LAB. It drops the distributed availability
    group and drops every database named in -Databases on all four replicas, then rebuilds
    them from nothing. Do not point it at anything you care about.

    It exists because testing these scripts consumes the thing being tested:

      * A cross-version failover is a ONE-WAY trip. Once the databases come online on the
        higher version they are upgraded, and the older side can never take them back. So
        every end-to-end failover test destroys the distributed AG it ran against.
      * Manual seeding can only be tested from a state where the forwarder does NOT already
        have the databases.

    Two starting states:

      -State ManualSeed     (default)
          No distributed AG. The databases exist on the global primary AG only; the
          forwarder side is empty. The backup share is created and proven writable from
          every replica. This is the state Initialize-DAG.ps1 expects when you want to
          exercise MANUAL seeding.

      -State FailoverReady
          Everything above, plus the distributed AG created, joined, seeded to the forwarder
          and settled on asynchronous commit. This is the state Failover-DAG.ps1 expects.

.PARAMETER ShareRoot
    UNC path for the manual-seeding backup share. It must be readable and writable by the
    SQL Server SERVICE ACCOUNTS on both sides — not by you. The script proves this by having
    each instance write a real backup to it, which is the only check that means anything.

    The default sits under the cluster witness share because that is the only share this lab
    has and it is open to Everyone. The quorum file lives in its own GUID-named folder and is
    not touched. On anything real, use a dedicated share.

.EXAMPLE
    .\Reset-DagLab.ps1
    Rebuilds the lab ready for a MANUAL seeding run of Initialize-DAG.ps1.

.EXAMPLE
    .\Reset-DagLab.ps1 -State FailoverReady
    Rebuilds the lab ready for a run of Failover-DAG.ps1.
#>

[CmdletBinding()]
param(
    [ValidateSet('ManualSeed', 'FailoverReady')]
    [string]$State = 'ManualSeed',

    [pscredential]$Credential,

    [string]$ShareRoot = '\\SQLLAB-DC\ClusterWitness\DAGBackup',

    [string]$DagName = 'DistAG_SQLLabAG2_SQLLabAG',

    [string]$GlobalAgName    = 'SQLLabAG2',
    [string[]]$GlobalReplicas = @('SQLLAB-SQL3', 'SQLLAB-SQL4'),
    [string]$GlobalListenerUrl = 'TCP://SQLLabListener2.SQLLAB.LOCAL:5022',

    [string]$ForwarderAgName    = 'SQLLabAG',
    [string[]]$ForwarderReplicas = @('SQLLAB-SQL1', 'SQLLAB-SQL2'),
    [string]$ForwarderListenerUrl = 'TCP://SQLLabListener.SQLLAB.LOCAL:5022',

    [string[]]$Databases = @('DAGTest_Alpha', 'DAGTest_Beta', 'DAGTest_Gamma', 'DAGTest_Delta'),

    [ValidateRange(8, 8192)]
    [int]$DataFileMB = 64,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$DagRoot    = Split-Path $ScriptRoot -Parent
$SharedDir  = Join-Path $DagRoot 'steps\_shared'

Import-Module SqlServer -DisableNameChecking -ErrorAction Stop
foreach ($f in 'DagCommon.ps1','DagSql.ps1','DagPrompt.ps1','DagDiscovery.ps1','DagFileOps.ps1','DagHealth.ps1','DagFailover.ps1') {
    . (Join-Path $SharedDir $f)
}

$AllReplicas = @($GlobalReplicas) + @($ForwarderReplicas)

#region ── helpers ───────────────────────────────────────────────────────────

function Invoke-LabSql {
    param([string]$Instance, [string]$Query, [int]$Timeout = 300)
    Invoke-DagSql -Instance $Instance -Query $Query -QueryTimeout $Timeout -Activity 'lab reset' | Out-Null
}

function Invoke-LabSqlTolerant {
    param([string]$Instance, [string]$Query, [int]$Timeout = 300)
    try { Invoke-LabSql -Instance $Instance -Query $Query -Timeout $Timeout }
    catch { Write-DagLog "    (ignored on ${Instance}: $($_.Exception.Message.Split("`n")[0]))" DEBUG }
}

function Get-LabScalar {
    param([string]$Instance, [string]$Query)
    return Get-DagScalar -Instance $Instance -Query $Query
}

function Get-LabAgPrimary {
    <#
        The replica currently holding the PRIMARY role of a member AG. Discovered, not
        assumed: a lab that has been failed over and rebuilt a few times does not always
        put the primary back where you left it.
    #>
    param([string]$AgName, [string[]]$Replicas)
    foreach ($i in $Replicas) {
        if (-not (Test-DagConnection -Instance $i)) { continue }
        $v = Get-LabScalar -Instance $i -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars
     ON ars.replica_id = ar.replica_id AND ars.is_local = 1
WHERE ag.name = $(ConvertTo-DagQuotedString $AgName) AND ars.role_desc = 'PRIMARY'
"@
        if ([int]$v -gt 0) { return $i }
    }
    throw "No replica of availability group '$AgName' currently reports the PRIMARY role (looked at: $($Replicas -join ', '))."
}

function Remove-LabDatabase {
    <#
        Drops one database on one instance, whatever state it is in.

        The order is load-bearing. SET SINGLE_USER is illegal against a database that is
        still joined to an availability group, and issuing it there leaves sessions in the
        kill state. And a database that has just LEFT an AG still has sessions attached (the
        AG worker, readable-secondary connections), so a bare DROP loses a race with
        "currently in use". Evict, then drop, and retry.
    #>
    param([string]$Instance, [string]$Database)

    if ([int](Get-LabScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.databases WHERE name = $(ConvertTo-DagQuotedString $Database)") -eq 0) { return }

    $joined = [int](Get-LabScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.databases WHERE name = $(ConvertTo-DagQuotedString $Database) AND group_database_id IS NOT NULL")
    if ($joined -gt 0) {
        Invoke-LabSqlTolerant -Instance $Instance -Query "ALTER DATABASE $(ConvertTo-DagQuotedName $Database) SET HADR OFF;" -Timeout 120
        Start-Sleep -Seconds 2
    }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'lab db state' -Query @"
SELECT state_desc AS s, CAST(CASE WHEN group_database_id IS NULL THEN 0 ELSE 1 END AS int) AS g
FROM sys.databases WHERE name = $(ConvertTo-DagQuotedString $Database)
"@
        if ($rows.Count -eq 0) { return }

        if ($rows[0].s -eq 'ONLINE' -and [int]$rows[0].g -eq 0) {
            Invoke-LabSqlTolerant -Instance $Instance -Timeout 120 -Query @"
DECLARE @kill nvarchar(max) = N'';
SELECT @kill += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';'
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID($(ConvertTo-DagQuotedString $Database)) AND session_id <> @@SPID;
IF LEN(@kill) > 0 EXEC(@kill);
ALTER DATABASE $(ConvertTo-DagQuotedName $Database) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
"@
        }
        Invoke-LabSqlTolerant -Instance $Instance -Query "DROP DATABASE $(ConvertTo-DagQuotedName $Database);"

        if ([int](Get-LabScalar -Instance $Instance -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.databases WHERE name = $(ConvertTo-DagQuotedString $Database)") -eq 0) { return }
        Start-Sleep -Seconds 3
    }
    throw "Could not drop [$Database] on '$Instance'."
}

#endregion

#region ── entry ─────────────────────────────────────────────────────────────

Initialize-DagLog -LogDirectory (Join-Path $DagRoot 'logs') -NamePrefix 'Reset-DagLab' | Out-Null

Write-DagBanner 'LAB RESET — THIS DESTROYS DATA'
Write-Host ''
Write-Host "  Target state : $State" -ForegroundColor White
Write-Host "  Distributed AG to drop : $DagName" -ForegroundColor DarkGray
Write-Host "  Databases to DROP and recreate on every replica:" -ForegroundColor Yellow
Write-Host ("    {0}" -f ($Databases -join ', ')) -ForegroundColor Yellow
Write-Host ("    on: {0}" -f ($AllReplicas -join ', ')) -ForegroundColor Yellow
Write-Host ''

if ($Credential) {
    Set-DagConnectionContext -Credential $Credential
    Write-DagLog "Authentication: SQL login '$($Credential.UserName)'" INFO
} else {
    Read-DagCredential
}

if (-not $Force) {
    if (-not (Read-DagYesNo -Question 'Drop and rebuild these databases and the distributed availability group?' -DefaultYes $false)) {
        Write-DagLog 'Aborted. Nothing was changed.' WARN
        return
    }
}

$started = Get-Date

#region 1. Drop the distributed AG
Write-DagBanner 'STEP 1 — DROP THE DISTRIBUTED AVAILABILITY GROUP'
foreach ($i in $AllReplicas) {
    if (-not (Test-DagConnection -Instance $i)) { throw "Cannot connect to '$i'." }
    Invoke-LabSqlTolerant -Instance $i -Query @"
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = $(ConvertTo-DagQuotedString $DagName) AND is_distributed = 1)
    DROP AVAILABILITY GROUP $(ConvertTo-DagQuotedName $DagName);
"@
}
Write-DagLog "  Dropped [$DagName] wherever it existed." SUCCESS

# The saved plan describes a distributed AG that no longer exists. Leaving it in place means
# Initialize-DAG.ps1 offers to "resume" something that is gone. Archive rather than delete:
# it is the only record of how the DAG was configured last time.
$stateDir = Join-Path $DagRoot 'state'
$planFile = Join-Path $stateDir ("{0}.json" -f (Get-DagSafeFileToken $DagName))
if (Test-Path $planFile) {
    $archiveDir = Join-Path $stateDir 'archive'
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $dest = Join-Path $archiveDir ("{0}_{1}.json" -f (Get-DagSafeFileToken $DagName), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Move-Item -Path $planFile -Destination $dest -Force
    Write-DagLog "  Archived the stale saved plan to $dest" INFO
}
#endregion

#region 2. Drop the test databases everywhere
Write-DagBanner 'STEP 2 — DROP THE TEST DATABASES'
foreach ($ag in @($GlobalAgName, $ForwarderAgName)) {
    $replicas = if ($ag -eq $GlobalAgName) { $GlobalReplicas } else { $ForwarderReplicas }
    $primary  = Get-LabAgPrimary -AgName $ag -Replicas $replicas
    foreach ($db in $Databases) {
        Invoke-LabSqlTolerant -Instance $primary -Query @"
IF EXISTS (SELECT 1 FROM sys.availability_databases_cluster AS adc
           JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
           WHERE ag.name = $(ConvertTo-DagQuotedString $ag) AND adc.database_name = $(ConvertTo-DagQuotedString $db))
    ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $ag) REMOVE DATABASE $(ConvertTo-DagQuotedName $db);
"@
    }
    Write-DagLog "  [$ag] removed the test databases from the availability group (on $primary)." SUCCESS
}

foreach ($i in $AllReplicas) {
    foreach ($db in $Databases) { Remove-LabDatabase -Instance $i -Database $db }
    Write-DagLog "  [$i] clear." SUCCESS
}
#endregion

#region 3. Rebuild the databases on the global primary AG
Write-DagBanner 'STEP 3 — REBUILD THE DATABASES ON THE GLOBAL PRIMARY AG'
$gp = Get-LabAgPrimary -AgName $GlobalAgName -Replicas $GlobalReplicas
$gpInfo = Get-DagInstanceInfo -Instance $gp
Write-DagLog "Global primary AG '$GlobalAgName' primary replica: $gp ($($gpInfo.ProductVersion))" INFO

# Automatic seeding to the LOCAL secondary only. The forwarder is a separate matter and is
# what Initialize-DAG.ps1 is going to do.
foreach ($r in $GlobalReplicas) {
    Invoke-LabSql -Instance $gp -Timeout 120 -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $GlobalAgName)
MODIFY REPLICA ON $(ConvertTo-DagQuotedString $r) WITH (SEEDING_MODE = AUTOMATIC);
"@
}
foreach ($r in @($GlobalReplicas | Where-Object { $_ -ne $gp })) {
    Invoke-LabSql -Instance $r -Timeout 120 -Query "ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $GlobalAgName) GRANT CREATE ANY DATABASE;"
}
Write-DagLog '  Local seeding prerequisites set.' SUCCESS

$backupDir = Get-DagScalar -Instance $gp -Query @'
DECLARE @p nvarchar(512);
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
     N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @p OUTPUT;
SELECT @p AS v;
'@

foreach ($db in $Databases) {
    $q = ConvertTo-DagQuotedName $db
    Invoke-LabSql -Instance $gp -Timeout 900 -Query @"
CREATE DATABASE $q;
ALTER DATABASE $q SET RECOVERY FULL;
ALTER DATABASE $q MODIFY FILE (NAME = N'$db', SIZE = ${DataFileMB}MB);
"@
    # Something to see, and enough of it that a manual seed has real work to do.
    Invoke-LabSql -Instance $gp -Timeout 900 -Query @"
USE $q;
CREATE TABLE dbo.T (id int IDENTITY PRIMARY KEY, v nvarchar(200) NOT NULL, ts datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
INSERT INTO dbo.T (v)
SELECT TOP (2000) N'seed-' + CAST(NEWID() AS nvarchar(40))
FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
"@
    # An AG will not take a database that has never been backed up: without a full backup it
    # behaves as though it were in SIMPLE recovery.
    Invoke-LabSql -Instance $gp -Timeout 900 -Query @"
BACKUP DATABASE $q TO DISK = $(ConvertTo-DagQuotedString (Join-DagPath -Path $backupDir -ChildPath @("$db`_labinit.bak")))
WITH INIT, FORMAT, COMPRESSION, CHECKSUM;
"@
    Invoke-LabSql -Instance $gp -Timeout 600 -Query "ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $GlobalAgName) ADD DATABASE $q;"
    Write-DagLog "  [$db] created ($DataFileMB MB), backed up, added to [$GlobalAgName]." SUCCESS
}

$localSecondaries = @($GlobalReplicas | Where-Object { $_ -ne $gp })
foreach ($sec in $localSecondaries) {
    $ok = Wait-DagCondition -Activity "[$GlobalAgName] seeding to $sec" -TimeoutSeconds 900 -PollSeconds 5 -Condition {
        $n = Get-DagScalar -Instance $sec -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $GlobalAgName) AND drs.is_local = 1
  AND drs.synchronization_state_desc IN ('SYNCHRONIZED','SYNCHRONIZING')
"@
        return ([int]$n -eq $Databases.Count)
    }
    if (-not $ok) { throw "The local secondary '$sec' did not receive all $($Databases.Count) databases." }
    Write-DagLog "  [$sec] has all $($Databases.Count) databases." SUCCESS
}
#endregion

#region 4. The backup share
Write-DagBanner 'STEP 4 — BACKUP SHARE FOR MANUAL SEEDING'
Write-DagLog "Share root: $ShareRoot" INFO
foreach ($i in $AllReplicas) {
    New-DagRemoteDirectory -Instance $i -Path $ShareRoot
}
# Proven the only way that means anything: each instance writes a real backup and reads it
# back, as its own service account. A directory create is not proof of file-write permission.
foreach ($i in $AllReplicas) {
    $err = Test-DagShareWritable -Instance $i -Path $ShareRoot
    if ($err) {
        throw @"
'$i' cannot write to the backup share '$ShareRoot'.

    $err

Manual seeding needs the SQL Server SERVICE ACCOUNT on every replica of BOTH sides to be able
to read and write it. Grant it, or pass a different -ShareRoot.
"@
    }
    Write-DagLog "  [$i] can read and write $ShareRoot" SUCCESS
}
#endregion

#region 5. Optionally build the distributed AG
if ($State -eq 'FailoverReady') {
    Write-DagBanner 'STEP 5 — CREATE THE DISTRIBUTED AVAILABILITY GROUP'
    $fp = Get-LabAgPrimary -AgName $ForwarderAgName -Replicas $ForwarderReplicas

    $onClause = @"
AVAILABILITY GROUP ON
    $(ConvertTo-DagQuotedString $GlobalAgName) WITH
    (
        LISTENER_URL      = $(ConvertTo-DagQuotedString $GlobalListenerUrl),
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE     = MANUAL,
        SEEDING_MODE      = AUTOMATIC
    ),
    $(ConvertTo-DagQuotedString $ForwarderAgName) WITH
    (
        LISTENER_URL      = $(ConvertTo-DagQuotedString $ForwarderListenerUrl),
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE     = MANUAL,
        SEEDING_MODE      = AUTOMATIC
    )
"@
    Invoke-LabSql -Instance $gp -Timeout 600 -Query "CREATE AVAILABILITY GROUP $(ConvertTo-DagQuotedName $DagName) WITH (DISTRIBUTED) $onClause;"
    Write-DagLog "  Created [$DagName] on $gp." SUCCESS
    Invoke-LabSql -Instance $fp -Timeout 600 -Query "ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $DagName) JOIN $onClause;"
    Write-DagLog "  Joined [$ForwarderAgName] on $fp." SUCCESS

    $ok = Wait-DagCondition -Activity "[$DagName] seeding to the forwarder" -TimeoutSeconds 1800 -PollSeconds 10 -Condition {
        $n = Get-DagScalar -Instance $fp -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $ForwarderAgName) AND drs.is_local = 1
  AND drs.synchronization_state_desc IN ('SYNCHRONIZED','SYNCHRONIZING')
"@
        return ([int]$n -eq $Databases.Count)
    }
    if (-not $ok) { throw "The forwarder did not receive all $($Databases.Count) databases." }
    Write-DagLog "  The forwarder has all $($Databases.Count) databases." SUCCESS
}
#endregion

#region 6. Report
Write-DagBanner ('LAB READY — {0} (in {1})' -f $State, (Format-DagDuration ((Get-Date) - $started)))

Write-Host ''
Write-Host 'Databases:' -ForegroundColor White
foreach ($i in $AllReplicas) {
    $rows = Invoke-DagSql -Instance $i -Retry -Activity 'lab report' -Query @"
SELECT d.name AS n, d.state_desc AS s
FROM sys.databases AS d
WHERE d.name IN ($(($Databases | ForEach-Object { ConvertTo-DagQuotedString $_ }) -join ', '))
ORDER BY d.name
"@
    $summary = if ($rows.Count -eq 0) { '(none)' } else { ($rows | ForEach-Object { "$($_.n)=$($_.s)" }) -join ' ' }
    Write-Host ("  {0,-14} {1}" -f $i, $summary)
}

Write-Host ''
if ($State -eq 'FailoverReady') {
    Write-Host 'Distributed availability group:' -ForegroundColor White
    @(Get-DagDistributedAgState -Instance $gp -DagName $DagName) |
        Format-Table MemberAg, Role, AvailabilityMode, ConnectedState, SyncHealth -AutoSize |
        Out-String -Width 200 | Write-Host

    Write-Host 'Next:' -ForegroundColor Green
    Write-Host '    cd ..' -ForegroundColor Green
    Write-Host '    .\Failover-DAG.ps1 -ReadinessOnly     # dry run: rollup only, changes nothing' -ForegroundColor Green
    Write-Host '    .\Failover-DAG.ps1                    # the real thing' -ForegroundColor Green
} else {
    Write-Host ("No distributed availability group. '{0}' holds the databases; '{1}' is empty." -f $GlobalAgName, $ForwarderAgName) -ForegroundColor White
    Write-Host ''
    Write-Host 'Next:' -ForegroundColor Green
    Write-Host '    cd ..' -ForegroundColor Green
    Write-Host '    .\Initialize-DAG.ps1' -ForegroundColor Green
    Write-Host ''
    Write-Host '  In the interview, choose:' -ForegroundColor DarkGray
    Write-Host ("    seed instance    : {0}" -f $gp) -ForegroundColor DarkGray
    Write-Host ("    seeding mode     : MANUAL" -f $gp) -ForegroundColor DarkGray
    Write-Host ("    backup share     : {0}" -f $ShareRoot) -ForegroundColor DarkGray
}
Write-Host ''
Write-DagLog "Log: $script:DagLogFile" INFO
#endregion
