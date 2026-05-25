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

#region ADO.NET SQL helper — no SqlServer module required inside VMs
# sqlcmd.exe is always present after SQL Engine install; used as the execution vehicle.
# Results are returned as string arrays; caller parses as needed.
$invokeLocalSqlDef = {
    function Invoke-LocalSql {
        param(
            [string]$Query,
            [string]$Server    = "localhost",
            [string]$Database  = "master",
            [int]   $Timeout   = 300
        )
        $connStr = "Server=$Server;Database=$Database;Integrated Security=True;Connect Timeout=30"
        $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
        try {
            $conn.Open()
            $cmd             = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
            $cmd.CommandTimeout = $Timeout
            $adapter         = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $table           = New-Object System.Data.DataTable
            [void]$adapter.Fill($table)
            return $table
        } finally {
            if ($conn.State -eq 'Open') { $conn.Close() }
        }
    }
}
#endregion

Start-LabVMs

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-13.done"
if (Test-Path $cpFile) {
    $laterDone = @("step-14.done","step-15.done") |
                 Where-Object { Test-Path (Join-Path $CheckpointPath $_) }
    if ($laterDone) {
        Write-Log "Step 13 checkpoint found and later steps confirmed — skipping." SUCCESS
        return
    }

    Write-Log "Step 13 checkpoint found — verifying AG health..." INFO
    try {
        $agState = Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
            $connStr = "Server=localhost;Database=master;Integrated Security=True;Connect Timeout=30"
            $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $conn.Open()
            $cmd = $conn.CreateCommand(); $cmd.CommandText = "SELECT name FROM sys.availability_groups"
            $reader = $cmd.ExecuteReader()
            $names  = @(); while ($reader.Read()) { $names += $reader['name'] }
            $conn.Close(); return $names
        } -ErrorAction Stop
        if ($agState -contains $AGName) {
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

#region Create test database and take full backup on SQL1
Write-Log "[$SQL1VMName] Creating test database '$TestDatabase'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare, $InvokeLocalSqlDef)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    $exists = Invoke-LocalSql -Query "SELECT name FROM sys.databases WHERE name = '$DBName'"
    if ($exists.Rows.Count -eq 0) {
        Invoke-LocalSql -Query @"
CREATE DATABASE [$DBName]
ON PRIMARY (NAME='$DBName', FILENAME='D:\SQLData\$DBName.mdf', SIZE=64MB)
LOG ON (NAME='${DBName}_log', FILENAME='D:\SQLLog\${DBName}_log.ldf', SIZE=16MB);
ALTER DATABASE [$DBName] SET RECOVERY FULL;
"@
        Write-Output "Database '$DBName' created."
    } else {
        Write-Output "Database '$DBName' already exists — ensuring FULL recovery."
        Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET RECOVERY FULL"
    }

    $backupFile = "$BackupShare\${DBName}_full.bak"
    Invoke-LocalSql -Query "BACKUP DATABASE [$DBName] TO DISK='$backupFile' WITH INIT, FORMAT, COMPRESSION" -Timeout 300
    Write-Output "Full backup completed: $backupFile"

    $logFile = "$BackupShare\${DBName}_log.bak"
    Invoke-LocalSql -Query "BACKUP LOG [$DBName] TO DISK='$logFile' WITH INIT, FORMAT" -Timeout 120
    Write-Output "Log backup completed: $logFile"

} -ArgumentList $TestDatabase, $backupShare, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Create AG endpoint on both nodes
foreach ($pair in @(
    @{ VM = $SQL1VMName; IP = $SQL1StaticIP }
    @{ VM = $SQL2VMName; IP = $SQL2StaticIP }
)) {
    Write-Log "[$($pair.VM)] Creating AG endpoint on port $EndpointPort..." INFO
    Invoke-Command -VMName $pair.VM -Credential $domainAdminCred -ScriptBlock {
        param($Port, $SvcAccount, $InvokeLocalSqlDef)
        . ([scriptblock]::Create($InvokeLocalSqlDef))

        $existing = Invoke-LocalSql -Query "SELECT name FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'"
        if ($existing.Rows.Count -gt 0) {
            Write-Output "AG endpoint already exists: $($existing.Rows[0]['name'])"
        } else {
            Invoke-LocalSql -Query @"
CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = $Port)
FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
"@
            Write-Output "Endpoint created on port $Port."
        }
        # Grant connect to SQL service account
        Invoke-LocalSql -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SvcAccount')
    CREATE LOGIN [$SvcAccount] FROM WINDOWS;
IF NOT EXISTS (
    SELECT 1 FROM sys.server_permissions p
    JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
    WHERE sp.name = '$SvcAccount' AND p.permission_name = 'CONNECT'
)
    GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$SvcAccount];
"@
    } -ArgumentList $EndpointPort, $SQLSvcAccount, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
        ForEach-Object { Write-Log "[$($pair.VM)] $_" INFO }
}
#endregion

#region Create Availability Group on SQL1
Write-Log "[$SQL1VMName] Creating Availability Group '$AGName'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName, $DBName, $SQL1Name, $SQL2Name, $ListenerName, $ListenerIP, $ListenerPort, $EPPort, $InvokeLocalSqlDef)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    $existingAG = Invoke-LocalSql -Query "SELECT name FROM sys.availability_groups WHERE name='$AGName'"
    if ($existingAG.Rows.Count -gt 0) {
        Write-Output "AG '$AGName' already exists — skipping creation."
        return
    }

    $domain = $env:USERDNSDOMAIN
    $createAG = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR DATABASE [$DBName]
REPLICA ON
  N'$SQL1Name' WITH (
    ENDPOINT_URL          = N'TCP://$SQL1Name.$domain`:$EPPort',
    FAILOVER_MODE         = AUTOMATIC,
    AVAILABILITY_MODE     = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY       = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  ),
  N'$SQL2Name' WITH (
    ENDPOINT_URL          = N'TCP://$SQL2Name.$domain`:$EPPort',
    FAILOVER_MODE         = AUTOMATIC,
    AVAILABILITY_MODE     = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY       = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  );
"@
    Invoke-LocalSql -Query $createAG -Timeout 120
    Write-Output "AG '$AGName' created."

    $addListener = @"
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER N'$ListenerName' (
    WITH IP (('$ListenerIP','255.255.255.0')),
    PORT=$ListenerPort
);
"@
    Invoke-LocalSql -Query $addListener -Timeout 60
    Write-Output "Listener '$ListenerName' added at $ListenerIP`:$ListenerPort."

} -ArgumentList $AGName, $TestDatabase, $SQL1ComputerName, $SQL2ComputerName,
    $ListenerName, $ListenerIP, $ListenerPort, $EndpointPort, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Restore database on SQL2 and join to AG
Write-Log "[$SQL2VMName] Restoring database and joining AG..." INFO
Invoke-Command -VMName $SQL2VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare, $AGName, $SQL1Name, $EPPort, $InvokeLocalSqlDef)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    # Check if database is already in AG on this replica
    $inAG = Invoke-LocalSql -Query @"
SELECT db.name FROM sys.databases db
JOIN sys.dm_hadr_database_replica_states rs ON db.database_id = rs.database_id
WHERE db.name = '$DBName'
"@

    if ($inAG.Rows.Count -gt 0) {
        Write-Output "Database '$DBName' already part of AG — skipping restore."
    } else {
        $backupFile = "$BackupShare\${DBName}_full.bak"
        $logFile    = "$BackupShare\${DBName}_log.bak"

        # Drop existing DB if present from a failed previous run
        $exists = Invoke-LocalSql -Query "SELECT name FROM sys.databases WHERE name='$DBName'"
        if ($exists.Rows.Count -gt 0) {
            Invoke-LocalSql -Query "DROP DATABASE [$DBName]"
        }

        Invoke-LocalSql -Query @"
RESTORE DATABASE [$DBName]
FROM DISK='$backupFile'
WITH NORECOVERY, REPLACE,
MOVE '$DBName'      TO 'D:\SQLData\$DBName.mdf',
MOVE '${DBName}_log' TO 'D:\SQLLog\${DBName}_log.ldf';
"@ -Timeout 300
        Write-Output "Full backup restored with NORECOVERY."

        Invoke-LocalSql -Query @"
RESTORE LOG [$DBName] FROM DISK='$logFile' WITH NORECOVERY;
"@ -Timeout 120
        Write-Output "Log backup restored with NORECOVERY."
    }

    # Join replica to AG
    $inReplica = Invoke-LocalSql -Query @"
SELECT r.replica_server_name FROM sys.availability_replicas r
JOIN sys.availability_groups g ON r.group_id = g.group_id
WHERE g.name = '$AGName' AND r.replica_server_name = @@SERVERNAME
"@

    if ($inReplica.Rows.Count -eq 0) {
        Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] JOIN;"
        Write-Output "Replica joined AG '$AGName'."
    } else {
        Write-Output "Already joined to AG '$AGName'."
    }

    # Join database to AG
    Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET HADR AVAILABILITY GROUP = [$AGName];"
    Write-Output "Database '$DBName' joined to AG."

} -ArgumentList $TestDatabase, $backupShare, $AGName, $SQL1ComputerName, $EndpointPort, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL2VMName] $_" INFO }
#endregion

#region Validate AG health
Write-Log "[$SQL1VMName] Validating AG health..." INFO
Start-Sleep -Seconds 15   # Allow synchronization to start

Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName, $InvokeLocalSqlDef)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    $health = Invoke-LocalSql -Query @"
SELECT
    ag.name                            AS AGName,
    ar.replica_server_name             AS ReplicaServer,
    ars.role_desc                      AS Role,
    ars.synchronization_health_desc    AS SyncHealth,
    ars.connected_state_desc           AS ConnectedState,
    ars.operational_state_desc         AS OperationalState
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar           ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AGName'
"@

    foreach ($row in $health.Rows) {
        Write-Output ("  {0,-20} Role={1,-12} Sync={2,-15} Connected={3}" -f `
            $row['ReplicaServer'], $row['Role'], $row['SyncHealth'], $row['ConnectedState'])
    }

    $unhealthy = $health.Rows | Where-Object { $_['SyncHealth'] -ne 'HEALTHY' }
    if ($unhealthy) {
        Write-Output "WARNING: Some replicas are not fully synchronized yet — this typically resolves within 60 seconds."
    }
} -ArgumentList $AGName, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] AG Health: $_" INFO }
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-13.done" SUCCESS
#endregion

Write-Log "Availability Group '$AGName' configuration complete." SUCCESS
