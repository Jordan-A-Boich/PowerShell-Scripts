#Requires -Version 5.1
<#
.SYNOPSIS
    Reset-AgLab — tears down the AG toolkit's test availability groups and rebuilds the test
    databases, so Initialize-AG / Add-AGDatabase / Remove-AGDatabase can be exercised end to
    end against a known starting point.

.DESCRIPTION
    LAB USE ONLY. Drops every availability group whose name matches -AgPattern (default
    'AGT*'), the contained system databases they leave behind, every database matching
    'AGT_*' on every replica, and the toolkit's AG-TLogBackup-* jobs. Never touches anything
    outside those patterns.

    Then creates, on the primary, one database per prerequisite scenario:

      AGT_Sales      ready: FULL recovery, log chain started, two data files in two folders
      AGT_HR         ready
      AGT_App        ready, with a user mapped to the SQL login agt_app (contained AG test)
      AGT_Simple     SIMPLE recovery                       -> the tool offers FULL + a backup
      AGT_NoBackup   FULL recovery, never backed up         -> the tool offers a backup
      AGT_AutoClose  AUTO_CLOSE ON                          -> the tool offers AUTO_CLOSE OFF
      AGT_Leftover   ready, plus a RESTORING copy on the secondary -> the tool offers to drop it
      AGT_Clash      ready, but ONLINE under the same name on the secondary -> not offered
      AGT_Multi      ready, four data files in three folders (manual seeding file layout)

.EXAMPLE
    .\Reset-AgLab.ps1 -Credential (Get-Credential labadmin)
#>
[CmdletBinding()]
param(
    [string]$Primary   = 'SQLLAB-SQL3',
    [string[]]$Secondaries = @('SQLLAB-SQL4'),
    [string]$AgPattern = 'AGT*',
    [string]$SetupShare = '\\SQLLAB-DC\ClusterWitness\AGBackup\_labsetup',
    [pscredential]$Credential,
    [switch]$TeardownOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module SqlServer -DisableNameChecking

$shared = Join-Path $PSScriptRoot '..\steps\_shared'
foreach ($f in 'AgCommon.ps1','AgSql.ps1','AgDiscovery.ps1','AgFileOps.ps1','AgDatabase.ps1') { . (Join-Path $shared $f) }
Initialize-AgLog -LogDirectory (Join-Path $PSScriptRoot '..\logs') -NamePrefix 'Reset-AgLab' | Out-Null
Set-AgConnectionContext -Credential $Credential

$all = @($Primary) + $Secondaries
function Q { param($i, $sql, $db = 'master') Invoke-AgSql -Instance $i -Database $db -QueryTimeout 600 -Query $sql }

Write-AgBanner 'TEARDOWN'

#region Availability groups
foreach ($i in $all) {
    $ags = Q $i "SELECT ag.name, ISNULL(ars.role_desc,'') AS role FROM sys.availability_groups ag LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id AND ars.is_local = 1 WHERE ag.is_distributed = 0 AND ag.name LIKE '$($AgPattern.Replace('*','%'))'"
    foreach ($a in $ags | Where-Object { $_.role -eq 'PRIMARY' }) {
        Write-AgLog "[$i] DROP AVAILABILITY GROUP [$($a.name)]" INFO
        Q $i "DROP AVAILABILITY GROUP $(ConvertTo-AgQuotedName $a.name);" | Out-Null
    }
}
Start-Sleep -Seconds 5
foreach ($i in $all) {
    $ags = Q $i "SELECT name FROM sys.availability_groups WHERE is_distributed = 0 AND name LIKE '$($AgPattern.Replace('*','%'))'"
    foreach ($a in $ags) {
        Write-AgLog "[$i] DROP AVAILABILITY GROUP [$($a.name)] (local leftover)" INFO
        try { Q $i "DROP AVAILABILITY GROUP $(ConvertTo-AgQuotedName $a.name);" | Out-Null } catch { Write-AgLog "  $($_.Exception.Message)" WARN }
    }
}
#endregion

#region Databases and jobs
foreach ($i in $all) {
    $dbs = Q $i "SELECT name, state_desc FROM sys.databases WHERE name LIKE 'AGT[_]%' OR name LIKE '$($AgPattern.Replace('*','%'))[_]master' OR name LIKE '$($AgPattern.Replace('*','%'))[_]msdb'"
    foreach ($d in $dbs) {
        $n = ConvertTo-AgQuotedName $d.name
        Write-AgLog "[$i] dropping [$($d.name)] ($($d.state_desc))" INFO
        $sql = if ($d.state_desc -eq 'ONLINE') { "ALTER DATABASE $n SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $n;" } else { "DROP DATABASE $n;" }
        for ($t = 1; $t -le 5; $t++) {
            try { Q $i $sql | Out-Null; break } catch { if ($t -eq 5) { throw }; Start-Sleep -Seconds 3 }
        }
    }
    Q $i @'
DECLARE @j sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'AG-TLogBackup-%';
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_delete_job @job_name = @j, @delete_unused_schedule = 1; FETCH NEXT FROM c INTO @j; END
CLOSE c; DEALLOCATE c;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'agt_app') DROP LOGIN [agt_app];
'@ | Out-Null
}
#endregion

if ($TeardownOnly) { Write-AgLog 'Teardown complete.' SUCCESS; return }

Write-AgBanner 'BUILD THE TEST DATABASES'

$data = ([string](Get-AgScalar -Instance $Primary -Query "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS v")).TrimEnd('\')
$log  = ([string](Get-AgScalar -Instance $Primary -Query "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)) AS v")).TrimEnd('\')
$drive = $data.Substring(0, 2)
foreach ($d in "$drive\AGTData2", "$drive\AGTSrcA", "$drive\AGTSrcB") { New-AgRemoteDirectory -Instance $Primary -Path $d }

function New-TestDb {
    param([string]$Name, [string]$Files = '', [string]$Recovery = 'FULL', [switch]$NoBackup, [switch]$AutoClose)
    $q = ConvertTo-AgQuotedName $Name
    $create = if ($Files) { "CREATE DATABASE $q $Files;" } else { "CREATE DATABASE $q;" }
    Q $Primary $create | Out-Null
    Q $Primary "ALTER DATABASE $q SET RECOVERY $Recovery;" | Out-Null
    Q $Primary "CREATE TABLE dbo.Probe (Id int IDENTITY PRIMARY KEY, Payload char(500) NOT NULL DEFAULT 'x', Created datetime2 NOT NULL DEFAULT SYSUTCDATETIME()); INSERT dbo.Probe DEFAULT VALUES; INSERT dbo.Probe (Payload) SELECT TOP (2000) 'seed' FROM sys.all_objects;" $Name | Out-Null
    if ($AutoClose) { Q $Primary "ALTER DATABASE $q SET AUTO_CLOSE ON;" | Out-Null }
    # A backup to NUL starts the log chain exactly as a real one does, at no cost.
    if (-not $NoBackup -and $Recovery -eq 'FULL') { Q $Primary "BACKUP DATABASE $q TO DISK = 'NUL';" | Out-Null }
    Write-AgLog "  created [$Name]" SUCCESS
}

New-TestDb -Name 'AGT_Sales' -Files "ON PRIMARY (NAME = AGT_Sales, FILENAME = '$data\AGT_Sales.mdf', SIZE = 16MB), (NAME = AGT_Sales_2, FILENAME = '$drive\AGTData2\AGT_Sales_2.ndf', SIZE = 16MB) LOG ON (NAME = AGT_Sales_log, FILENAME = '$log\AGT_Sales_log.ldf', SIZE = 8MB)"
New-TestDb -Name 'AGT_HR'
New-TestDb -Name 'AGT_App'
New-TestDb -Name 'AGT_Simple' -Recovery 'SIMPLE'
New-TestDb -Name 'AGT_NoBackup' -NoBackup
New-TestDb -Name 'AGT_AutoClose' -AutoClose
New-TestDb -Name 'AGT_Leftover'
New-TestDb -Name 'AGT_Clash'
New-TestDb -Name 'AGT_Multi' -Files "ON PRIMARY (NAME = AGT_Multi, FILENAME = '$drive\AGTSrcA\AGT_Multi.mdf', SIZE = 16MB), (NAME = AGT_Multi_2, FILENAME = '$drive\AGTSrcA\AGT_Multi_2.ndf', SIZE = 16MB), (NAME = AGT_Multi_3, FILENAME = '$drive\AGTSrcB\AGT_Multi_3.ndf', SIZE = 16MB), (NAME = AGT_Multi_4, FILENAME = '$data\AGT_Multi_4.ndf', SIZE = 16MB) LOG ON (NAME = AGT_Multi_log, FILENAME = '$drive\AGTSrcB\AGT_Multi_log.ldf', SIZE = 8MB)"

#region The login a contained AG has to carry
foreach ($i in $all) {
    Q $i "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'agt_app') CREATE LOGIN [agt_app] WITH PASSWORD = N'AgtApp2025!', CHECK_POLICY = OFF, SID = 0x8C9C1D5A2B7E4F31A6D0C3B2E1F09A7D;" | Out-Null
}
Q $Primary "CREATE USER [agt_app] FOR LOGIN [agt_app]; ALTER ROLE db_owner ADD MEMBER [agt_app];" 'AGT_App' | Out-Null
#endregion

#region The secondary-side scenarios
New-AgRemoteDirectory -Instance $Primary -Path $SetupShare
$bak = Join-AgPath -Path $SetupShare -ChildPath @('AGT_Leftover.bak')
Q $Primary "BACKUP DATABASE [AGT_Leftover] TO DISK = N'$bak' WITH INIT, FORMAT, COPY_ONLY;" | Out-Null
foreach ($s in $Secondaries) {
    Q $s "RESTORE DATABASE [AGT_Leftover] FROM DISK = N'$bak' WITH NORECOVERY, REPLACE;" | Out-Null
    Write-AgLog "  [$s] AGT_Leftover restored WITH NORECOVERY (a leftover RESTORING copy)" SUCCESS
    Q $s "CREATE DATABASE [AGT_Clash];" | Out-Null
    Write-AgLog "  [$s] AGT_Clash created ONLINE (a same-name clash)" SUCCESS
}
#endregion

Write-AgLog 'Lab reset complete.' SUCCESS
