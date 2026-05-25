#Requires -Version 5.1
<#
.SYNOPSIS
    Step 13 — Create and configure the SQL Server Always On Availability Group.

IDEMPOTENCY CHECKS:
    - AGShare on DC is created only if absent.
    - Hadr endpoints created only if not already present.
    - AG created on SQL1 only if it does not already exist.
    - Database backup/restore on SQL2 skipped if already in AG.
    - AG health is validated at end.
    - Checkpoint step-13.done skips if AG is online and healthy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-13.done"
if (Test-Path $cpFile) {
    Write-Log "Step 13 checkpoint found — verifying AG health..." INFO
    try {
        $agState = Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
            $result = Invoke-Sqlcmd -Query "SELECT name, primary_replica FROM sys.availability_groups" `
                -ServerInstance "localhost" -ErrorAction Stop
            return $result
        } -ErrorAction Stop
        if ($agState -and $agState.name -eq $AGName) {
            Write-Log "AG '$AGName' verified healthy. Skipping step 13." SUCCESS
            return
        }
    } catch { Write-Log "Checkpoint check failed — re-running step 13." WARN }
}
#endregion

$backupShare = "\\$DCComputerName\$AGShareName"

#region Create AGShare on DC
Write-Log "[$DCVMName] Creating AG backup share '$AGShareName'..." INFO
Invoke-Command -VMName $DCVMName -Credential $domainAdminCred -ScriptBlock {
    param($ShareName)
    $sharePath = "C:\AGShare"
    if (-not (Test-Path $sharePath)) { New-Item -ItemType Directory -Path $sharePath -Force | Out-Null }
    $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if (-not $share) {
        New-SmbShare -Name $ShareName -Path $sharePath -FullAccess "Everyone" -ErrorAction Stop | Out-Null
        Write-Output "Created share: $ShareName"
    } else {
        Write-Output "Share '$ShareName' already exists."
    }
} -ArgumentList $AGShareName -ErrorAction Stop |
    ForEach-Object { Write-Log "[$DCVMName] $_" INFO }
#endregion

#region Helper: run T-SQL on a VM
function Invoke-VMSQL {
    param(
        [string]$VMName,
        [string]$Query,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Database = "master"
    )
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($Q, $DB)
        Invoke-Sqlcmd -Query $Q -ServerInstance "localhost" -Database $DB -ErrorAction Stop
    } -ArgumentList $Query, $Database -ErrorAction Stop
}
#endregion

#region Create test database and take full backup on SQL1
Write-Log "[$SQL1VMName] Creating test database '$TestDatabase'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare)
    Import-Module SqlServer -ErrorAction SilentlyContinue

    $exists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '$DBName'" `
        -ServerInstance localhost -ErrorAction Stop
    if (-not $exists) {
        Invoke-Sqlcmd -Query @"
CREATE DATABASE [$DBName]
ON PRIMARY (NAME='$DBName', FILENAME='D:\SQLData\$DBName.mdf', SIZE=64MB)
LOG ON (NAME='${DBName}_log', FILENAME='D:\SQLLog\${DBName}_log.ldf', SIZE=16MB);
ALTER DATABASE [$DBName] SET RECOVERY FULL;
"@ -ServerInstance localhost -ErrorAction Stop
        Write-Output "Database '$DBName' created."
    } else {
        Write-Output "Database '$DBName' already exists — ensuring FULL recovery."
        Invoke-Sqlcmd -Query "ALTER DATABASE [$DBName] SET RECOVERY FULL" -ServerInstance localhost -ErrorAction SilentlyContinue
    }

    # Full backup
    $backupFile = "$BackupShare\${DBName}_full.bak"
    Invoke-Sqlcmd -Query "BACKUP DATABASE [$DBName] TO DISK='$backupFile' WITH INIT, FORMAT, COMPRESSION" `
        -ServerInstance localhost -QueryTimeout 300 -ErrorAction Stop
    Write-Output "Full backup completed: $backupFile"

    # Log backup (required before joining to AG)
    $logFile = "$BackupShare\${DBName}_log.bak"
    Invoke-Sqlcmd -Query "BACKUP LOG [$DBName] TO DISK='$logFile' WITH INIT, FORMAT" `
        -ServerInstance localhost -QueryTimeout 120 -ErrorAction Stop
    Write-Output "Log backup completed: $logFile"

} -ArgumentList $TestDatabase, $backupShare -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Create AG endpoint on both nodes
foreach ($pair in @(
    @{ VM = $SQL1VMName; IP = $SQL1StaticIP }
    @{ VM = $SQL2VMName; IP = $SQL2StaticIP }
)) {
    Write-Log "[$($pair.VM)] Creating AG endpoint on port $EndpointPort..." INFO
    Invoke-Command -VMName $pair.VM -Credential $domainAdminCred -ScriptBlock {
        param($Port, $SvcAccount)
        Import-Module SqlServer -ErrorAction SilentlyContinue
        $existing = Invoke-Sqlcmd -Query `
            "SELECT name FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'" `
            -ServerInstance localhost -ErrorAction Stop
        if ($existing) {
            Write-Output "AG endpoint already exists: $($existing.name)"
        } else {
            Invoke-Sqlcmd -Query @"
CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = $Port)
FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
"@ -ServerInstance localhost -ErrorAction Stop
            Write-Output "Endpoint created on port $Port."
        }
        # Grant connect permission to SQL service account and domain admins
        Invoke-Sqlcmd -Query @"
IF NOT EXISTS (
    SELECT 1 FROM sys.server_permissions p
    JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
    WHERE sp.name = '$SvcAccount' AND p.permission_name = 'CONNECT'
    AND p.class_desc = 'ENDPOINT'
)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SvcAccount')
        CREATE LOGIN [$SvcAccount] FROM WINDOWS;
    GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$SvcAccount];
END
"@ -ServerInstance localhost -ErrorAction SilentlyContinue
    } -ArgumentList $EndpointPort, $SQLSvcAccount -ErrorAction Stop |
        ForEach-Object { Write-Log "[$($pair.VM)] $_" INFO }
}
#endregion

#region Create Availability Group on SQL1
Write-Log "[$SQL1VMName] Creating Availability Group '$AGName'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName, $DBName, $SQL1Name, $SQL2Name, $SQL2IP, $ListenerName, $ListenerIP, $ListenerPort, $EPPort)
    Import-Module SqlServer -ErrorAction SilentlyContinue

    $existingAG = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name='$AGName'" `
        -ServerInstance localhost -ErrorAction Stop
    if ($existingAG) {
        Write-Output "AG '$AGName' already exists — skipping creation."
        return
    }

    $createAG = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE
)
FOR DATABASE [$DBName]
REPLICA ON
  N'$SQL1Name' WITH (
    ENDPOINT_URL = N'TCP://$SQL1Name.$($env:USERDNSDOMAIN):$EPPort',
    FAILOVER_MODE = AUTOMATIC,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  ),
  N'$SQL2Name' WITH (
    ENDPOINT_URL = N'TCP://$SQL2Name.$($env:USERDNSDOMAIN):$EPPort',
    FAILOVER_MODE = AUTOMATIC,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  );
"@
    Invoke-Sqlcmd -Query $createAG -ServerInstance localhost -QueryTimeout 120 -ErrorAction Stop
    Write-Output "AG '$AGName' created."

    # Add listener
    $addListener = @"
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER N'$ListenerName' (
    WITH IP (('$ListenerIP','255.255.255.0')),
    PORT=$ListenerPort
);
"@
    Invoke-Sqlcmd -Query $addListener -ServerInstance localhost -QueryTimeout 60 -ErrorAction Stop
    Write-Output "Listener '$ListenerName' added at $ListenerIP`:$ListenerPort."

} -ArgumentList $AGName, $TestDatabase, $SQL1ComputerName, $SQL2ComputerName, $SQL2StaticIP,
    $ListenerName, $ListenerIP, $ListenerPort, $EndpointPort -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Restore database on SQL2 and join to AG
Write-Log "[$SQL2VMName] Restoring database and joining AG..." INFO
Invoke-Command -VMName $SQL2VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare, $AGName, $SQL1Name, $EPPort)
    Import-Module SqlServer -ErrorAction SilentlyContinue

    # Check if already in AG
    $inAG = Invoke-Sqlcmd -Query @"
SELECT db.name FROM sys.databases db
JOIN sys.dm_hadr_database_replica_states rs ON db.database_id = rs.database_id
WHERE db.name = '$DBName'
"@ -ServerInstance localhost -ErrorAction Stop

    if ($inAG) {
        Write-Output "Database '$DBName' already part of AG — skipping restore."
    } else {
        $backupFile = "$BackupShare\${DBName}_full.bak"
        $logFile    = "$BackupShare\${DBName}_log.bak"

        # Drop existing DB if present (e.g. from a failed previous run)
        $exists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name='$DBName'" `
            -ServerInstance localhost -ErrorAction Stop
        if ($exists) {
            Invoke-Sqlcmd -Query "DROP DATABASE [$DBName]" -ServerInstance localhost -ErrorAction SilentlyContinue
        }

        Invoke-Sqlcmd -Query @"
RESTORE DATABASE [$DBName]
FROM DISK='$backupFile'
WITH NORECOVERY, REPLACE,
MOVE '$DBName' TO 'D:\SQLData\$DBName.mdf',
MOVE '${DBName}_log' TO 'D:\SQLLog\${DBName}_log.ldf';
"@ -ServerInstance localhost -QueryTimeout 300 -ErrorAction Stop
        Write-Output "Full backup restored with NORECOVERY."

        Invoke-Sqlcmd -Query @"
RESTORE LOG [$DBName]
FROM DISK='$logFile'
WITH NORECOVERY;
"@ -ServerInstance localhost -QueryTimeout 120 -ErrorAction Stop
        Write-Output "Log backup restored with NORECOVERY."
    }

    # Join replica to AG
    $inReplica = Invoke-Sqlcmd -Query @"
SELECT r.replica_server_name FROM sys.availability_replicas r
JOIN sys.availability_groups g ON r.group_id = g.group_id
WHERE g.name = '$AGName' AND r.replica_server_name = @@SERVERNAME
"@ -ServerInstance localhost -ErrorAction Stop

    if (-not $inReplica) {
        $joinEndpoint = "TCP://$SQL1Name`:$EPPort"
        Invoke-Sqlcmd -Query @"
ALTER AVAILABILITY GROUP [$AGName] JOIN;
"@ -ServerInstance localhost -ErrorAction Stop
        Write-Output "Replica joined AG '$AGName'."
    } else {
        Write-Output "Already joined to AG '$AGName'."
    }

    # Join database to AG
    Invoke-Sqlcmd -Query @"
ALTER DATABASE [$DBName] SET HADR AVAILABILITY GROUP = [$AGName];
"@ -ServerInstance localhost -ErrorAction SilentlyContinue
    Write-Output "Database '$DBName' joined to AG."

} -ArgumentList $TestDatabase, $backupShare, $AGName, $SQL1ComputerName, $EndpointPort -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL2VMName] $_" INFO }
#endregion

#region Validate AG health
Write-Log "[$SQL1VMName] Validating AG health..." INFO
Start-Sleep -Seconds 15   # Allow synchronization to start

Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName)
    Import-Module SqlServer -ErrorAction SilentlyContinue

    $health = Invoke-Sqlcmd -Query @"
SELECT
    ag.name                            AS AGName,
    ar.replica_server_name             AS ReplicaServer,
    ars.role_desc                      AS Role,
    ars.synchronization_health_desc    AS SyncHealth,
    ars.connected_state_desc           AS ConnectedState,
    ars.operational_state_desc         AS OperationalState
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar         ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AGName'
"@ -ServerInstance localhost -ErrorAction Stop

    foreach ($row in $health) {
        Write-Output ("  {0,-20} Role={1,-12} Sync={2,-15} Connected={3}" -f `
            $row.ReplicaServer, $row.Role, $row.SyncHealth, $row.ConnectedState)
    }

    $unhealthy = $health | Where-Object { $_.SyncHealth -ne 'HEALTHY' -and $_.SyncHealth -ne 'NOT_HEALTHY_SYNCHRONIZING' }
    if ($unhealthy) {
        Write-Output "WARNING: Some replicas are not fully healthy yet — this may resolve within a minute."
    }
} -ArgumentList $AGName -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] AG Health: $_" INFO }
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-13.done" SUCCESS
#endregion

Write-Log "Availability Group '$AGName' configuration complete." SUCCESS
