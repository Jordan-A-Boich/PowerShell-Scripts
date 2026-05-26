#Requires -Version 5.1
<#
.SYNOPSIS
    Step 13 — Create and configure the SQL Server Always On Availability Group.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$domainAdminCred = New-Object System.Management.Automation.PSCredential("$NetBIOSName\Administrator",
                       (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

#region ADO.NET SQL helper — single-statement only, no here-string variable capture issues
$invokeLocalSqlDef = {
    function Invoke-LocalSql {
        param(
            [string]$Query,
            [string]$Server   = "localhost",
            [string]$Database = "master",
            [int]   $Timeout  = 300
        )
        $connStr = "Server=$Server;Database=$Database;Integrated Security=True;Connect Timeout=30"
        $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
        try {
            $conn.Open()
            $cmd                = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
            $cmd.CommandTimeout = $Timeout
            $adapter            = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $table              = New-Object System.Data.DataTable
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
            $cmd             = $conn.CreateCommand()
            $cmd.CommandText = "SELECT name FROM sys.availability_groups"
            $reader          = $cmd.ExecuteReader()
            $names           = @()
            while ($reader.Read()) { $names += $reader['name'] }
            $conn.Close()
            return $names
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

#region Prepare test database on SQL1 and take fresh backups
Write-Log "[$SQL1VMName] Preparing test database '$TestDatabase'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare, $InvokeLocalSqlDef, $AGName)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    # Check current state of the database
    $existsRow = Invoke-LocalSql -Query "SELECT name, state_desc FROM sys.databases WHERE name = '$DBName'"

    if ($existsRow.Rows.Count -gt 0) {
        $stateDesc = $existsRow.Rows[0]['state_desc']
        Write-Output "Database '$DBName' exists in state '$stateDesc'."

        if ($stateDesc -ne 'ONLINE') {
            # Non-ONLINE state — force single-user to break connections, then drop and recreate
            Write-Output "Non-ONLINE state detected — dropping database '$DBName'..."
            try {
                Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
            } catch {
                Write-Output "SET SINGLE_USER warning (non-fatal): $($_.Exception.Message -replace '\r?\n.*','')"
            }
            Invoke-LocalSql -Query "DROP DATABASE [$DBName]"
            Write-Output "Dropped database '$DBName'."

            Invoke-LocalSql -Query "CREATE DATABASE [$DBName] ON PRIMARY (NAME='$DBName', FILENAME='D:\SQLData\$DBName.mdf', SIZE=64MB) LOG ON (NAME='${DBName}_log', FILENAME='D:\SQLLog\${DBName}_log.ldf', SIZE=16MB)"
            Write-Output "Database '$DBName' created."
            Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET RECOVERY FULL"
            Write-Output "Recovery model set to FULL."
        } else {
            # ONLINE — just ensure correct recovery model
            Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET RECOVERY FULL"
            Write-Output "Database '$DBName' is ONLINE — recovery model confirmed FULL."
        }
    } else {
        Write-Output "Database '$DBName' not found — creating..."
        try {
            Invoke-LocalSql -Query "CREATE DATABASE [$DBName] ON PRIMARY (NAME='$DBName', FILENAME='D:\SQLData\$DBName.mdf', SIZE=64MB) LOG ON (NAME='${DBName}_log', FILENAME='D:\SQLLog\${DBName}_log.ldf', SIZE=16MB)"
            Write-Output "Database '$DBName' created."
        } catch {
            # CREATE DATABASE fails "already exists" when the database is in an AG from a
            # prior run but not visible in sys.databases (HADR startup timing).  The catalog
            # entry can't be dropped while the database is an AG member, so we must remove
            # it from the AG first, then drop, then delete any orphaned files, then retry.
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            Write-Output "WARNING: CREATE DATABASE reported 'already exists' but sys.databases shows no row — cleaning up prior AG state..."

            # Step 1: Remove from AG using the known $AGName directly.
            # sys.availability_databases_cluster is empty immediately after SQL Server restart
            # (WSFC reconnection in progress), so a catalog query is unreliable here.
            # Retry up to 60 s in case the HADR manager is still initializing post-restart.
            $agRemoved = $false
            $agRetryDeadline = (Get-Date).AddSeconds(60)
            while (-not $agRemoved -and (Get-Date) -lt $agRetryDeadline) {
                try {
                    Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] REMOVE DATABASE [$DBName]"
                    Write-Output "Removed '$DBName' from AG '$AGName'."
                    $agRemoved = $true
                } catch {
                    $rmMsg = $_.Exception.Message -replace '\r?\n.*',''
                    if ($rmMsg -match 'not.*member|does not exist|Cannot find|not found|not joined') {
                        Write-Output "DB '$DBName' not in AG '$AGName' (or AG not found) - no removal needed."
                        $agRemoved = $true
                    } else {
                        Write-Output "AG removal (will retry in 5s): $rmMsg"
                        Start-Sleep -Seconds 5
                    }
                }
            }
            if (-not $agRemoved) {
                Write-Output "WARNING: Could not confirm AG removal after 60s — proceeding with DROP attempt."
            }

            # Step 2: force single-user then drop
            try {
                Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
            } catch { }
            try {
                Invoke-LocalSql -Query "DROP DATABASE IF EXISTS [$DBName]"
                Write-Output "Database '$DBName' dropped."
            } catch {
                Write-Output "DROP attempt (non-fatal): $($_.Exception.Message -replace '\r?\n.*','')"
            }

            # Step 3: remove any orphaned physical files
            foreach ($f in @("D:\SQLData\$DBName.mdf", "D:\SQLLog\${DBName}_log.ldf")) {
                if (Test-Path $f) {
                    Remove-Item $f -Force -ErrorAction SilentlyContinue
                    Write-Output "Removed orphaned file: $f"
                }
            }

            # Step 4: retry create
            Invoke-LocalSql -Query "CREATE DATABASE [$DBName] ON PRIMARY (NAME='$DBName', FILENAME='D:\SQLData\$DBName.mdf', SIZE=64MB) LOG ON (NAME='${DBName}_log', FILENAME='D:\SQLLog\${DBName}_log.ldf', SIZE=16MB)"
            Write-Output "Database '$DBName' created (after AG cleanup)."
        }
        Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET RECOVERY FULL"
        Write-Output "Recovery model set to FULL."
    }

    Write-Output "Taking full backup..."
    Invoke-LocalSql -Query "BACKUP DATABASE [$DBName] TO DISK='$BackupShare\${DBName}_full.bak' WITH INIT, FORMAT, COMPRESSION" -Timeout 300
    Write-Output "Full backup completed: $BackupShare\${DBName}_full.bak"

    Write-Output "Taking log backup..."
    Invoke-LocalSql -Query "BACKUP LOG [$DBName] TO DISK='$BackupShare\${DBName}_log.bak' WITH INIT, FORMAT" -Timeout 120
    Write-Output "Log backup completed: $BackupShare\${DBName}_log.bak"

} -ArgumentList $TestDatabase, $backupShare, $invokeLocalSqlDef.ToString(), $AGName -ErrorAction Stop |
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

        $existing = Invoke-LocalSql -Query "SELECT name, state_desc FROM sys.endpoints WHERE name = 'Hadr_endpoint'"
        if ($existing.Rows.Count -gt 0) {
            Write-Output "AG endpoint already exists (state: $($existing.Rows[0]['state_desc']))"
        } else {
            try {
                Invoke-LocalSql -Query "CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED AS TCP (LISTENER_PORT = $Port) FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES)"
                Write-Output "Endpoint created on port $Port."
            } catch {
                # Treat 'already exists' as success — endpoint was created by a concurrent/prior run
                if ($_.Exception.Message -notmatch 'already exists') { throw }
                Write-Output "Endpoint 'Hadr_endpoint' already exists (caught on create) — continuing."
            }
        }

        # Ensure started regardless
        Invoke-LocalSql -Query "ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED"
        Write-Output "Endpoint state confirmed STARTED."

        # Create login if missing — separate statement, not batched
        $loginExists = Invoke-LocalSql -Query "SELECT name FROM sys.server_principals WHERE name = '$SvcAccount'"
        if ($loginExists.Rows.Count -eq 0) {
            try {
                Invoke-LocalSql -Query "CREATE LOGIN [$SvcAccount] FROM WINDOWS"
                Write-Output "Created login for '$SvcAccount'."
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { throw }
                Write-Output "Login '$SvcAccount' already exists (caught on create) — continuing."
            }
        } else {
            Write-Output "Login '$SvcAccount' already exists."
        }

        # Grant CONNECT on endpoint — separate statement
        $grantExists = Invoke-LocalSql -Query @"
SELECT 1 AS granted
FROM sys.server_permissions p
JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
WHERE sp.name = '$SvcAccount' AND p.permission_name = 'CONNECT'
"@
        if ($grantExists.Rows.Count -eq 0) {
            Invoke-LocalSql -Query "GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$SvcAccount]"
            Write-Output "CONNECT granted to '$SvcAccount' on endpoint."
        } else {
            Write-Output "CONNECT already granted to '$SvcAccount'."
        }

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
        Write-Output "AG '$AGName' already exists."
        # If the database was removed and recreated it won't be a member anymore — re-add it.
        $dbInAG = Invoke-LocalSql -Query "
SELECT database_name FROM sys.availability_databases_cluster
WHERE  database_name = '$DBName'
  AND  group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$AGName')"
        if ($dbInAG.Rows.Count -eq 0) {
            try {
                Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$DBName]"
                Write-Output "Re-added '$DBName' to existing AG '$AGName'."
            } catch {
                if ($_.Exception.Message -notmatch 'already') { throw }
                Write-Output "Database '$DBName' already in AG '$AGName'."
            }
        } else {
            Write-Output "Database '$DBName' already in AG '$AGName'."
        }
    } else {
        $domain = $env:USERDNSDOMAIN
        try {
            Invoke-LocalSql -Query "
CREATE AVAILABILITY GROUP [$AGName]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR DATABASE [$DBName]
REPLICA ON
  N'$SQL1Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL1Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  ),
  N'$SQL2Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL2Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
  )" -Timeout 120
            Write-Output "AG '$AGName' created."
        } catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            Write-Output "AG '$AGName' already exists (caught on create) — continuing."
        }

        # Idempotent: ensure the (freshly recreated) database is in the AG.
        # Required when the AG pre-existed but was invisible in sys.availability_groups
        # during the initial check (HADR timing) — the catch above skips the FOR DATABASE
        # clause, so the database is never added.
        try {
            Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$DBName]"
            Write-Output "Added '$DBName' to AG '$AGName'."
        } catch {
            if ($_.Exception.Message -notmatch 'already') { throw }
            Write-Output "Database '$DBName' already in AG '$AGName'."
        }

        try {
            Invoke-LocalSql -Query "
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER N'$ListenerName' (
    WITH IP (('$ListenerIP','255.255.255.0')),
    PORT=$ListenerPort
)" -Timeout 60
            Write-Output "Listener '$ListenerName' added at $ListenerIP`:$ListenerPort."
        } catch {
            # SQL returns "already has a listener" (not "already exists") when the listener DNS name is taken
            if ($_.Exception.Message -notmatch 'already exists|already has a listener') { throw }
            Write-Output "Listener '$ListenerName' already exists (caught on create) — continuing."
        }
    }

} -ArgumentList $AGName, $TestDatabase, $SQL1ComputerName, $SQL2ComputerName,
    $ListenerName, $ListenerIP, $ListenerPort, $EndpointPort, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Restore database on SQL2 and join to AG
Write-Log "[$SQL2VMName] Restoring database and joining AG..." INFO
Invoke-Command -VMName $SQL2VMName -Credential $domainAdminCred -ScriptBlock {
    param($DBName, $BackupShare, $AGName, $InvokeLocalSqlDef)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

    # Check if already in AG
    $inAG = Invoke-LocalSql -Query "
SELECT db.name
FROM sys.databases db
JOIN sys.dm_hadr_database_replica_states rs ON db.database_id = rs.database_id
WHERE db.name = '$DBName'"

    if ($inAG.Rows.Count -gt 0) {
        Write-Output "Database '$DBName' already part of AG — skipping restore."
    } else {
        # Drop any existing copy regardless of state
        $existsRow = Invoke-LocalSql -Query "SELECT name, state_desc FROM sys.databases WHERE name = '$DBName'"
        if ($existsRow.Rows.Count -gt 0) {
            $stateDesc = $existsRow.Rows[0]['state_desc']
            Write-Output "Found existing database '$DBName' in state '$stateDesc' — dropping..."
            try {
                Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
            } catch {
                Write-Output "SET SINGLE_USER warning (non-fatal): $($_.Exception.Message -replace '\r?\n.*','')"
            }
            Invoke-LocalSql -Query "DROP DATABASE [$DBName]"
            Write-Output "Dropped existing database '$DBName'."
        }

        Write-Output "Restoring full backup..."
        Invoke-LocalSql -Query "
RESTORE DATABASE [$DBName]
FROM DISK='$BackupShare\${DBName}_full.bak'
WITH NORECOVERY, REPLACE,
MOVE '$DBName'       TO 'D:\SQLData\$DBName.mdf',
MOVE '${DBName}_log' TO 'D:\SQLLog\${DBName}_log.ldf'" -Timeout 300
        Write-Output "Full backup restored with NORECOVERY."

        Invoke-LocalSql -Query "RESTORE LOG [$DBName] FROM DISK='$BackupShare\${DBName}_log.bak' WITH NORECOVERY" -Timeout 120
        Write-Output "Log backup restored with NORECOVERY."
    }

    # Join replica to AG
    $inReplica = Invoke-LocalSql -Query "
SELECT r.replica_server_name
FROM sys.availability_replicas r
JOIN sys.availability_groups g ON r.group_id = g.group_id
WHERE g.name = '$AGName' AND r.replica_server_name = @@SERVERNAME"

    if ($inReplica.Rows.Count -eq 0) {
        try {
            Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] JOIN"
            Write-Output "Replica joined AG '$AGName'."
        } catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            Write-Output "Replica already joined to AG '$AGName' (caught on join) - continuing."
        }
    } else {
        Write-Output "Replica already joined to AG '$AGName'."
    }

    # Join database to AG
    try {
        Invoke-LocalSql -Query "ALTER DATABASE [$DBName] SET HADR AVAILABILITY GROUP = [$AGName]"
        Write-Output "Database '$DBName' joined to AG."
    } catch {
        $msg = $_.Exception.Message -replace '\r?\n.*',''
        if ($msg -match 'already') {
            Write-Output "Database '$DBName' already joined to AG (skipped)."
        } else {
            throw
        }
    }

} -ArgumentList $TestDatabase, $backupShare, $AGName, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL2VMName] $_" INFO }
#endregion

#region Validate AG health
Write-Log "[$SQL1VMName] Validating AG health..." INFO
Start-Sleep -Seconds 15

try {
    Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
        param($AGName, $InvokeLocalSqlDef)
        . ([scriptblock]::Create($InvokeLocalSqlDef))

        $health = Invoke-LocalSql -Query "
SELECT
    ag.name                            AS AGName,
    ar.replica_server_name             AS ReplicaServer,
    ars.role_desc                      AS Role,
    ars.synchronization_health_desc    AS SyncHealth,
    ars.connected_state_desc           AS ConnectedState,
    ars.operational_state_desc         AS OperationalState
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar            ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AGName'"

        if ($null -eq $health -or $health.Rows.Count -eq 0) {
            Write-Output "No replica health data available yet — AG may still be initializing."
            return
        }

        foreach ($row in $health.Rows) {
            if ($null -eq $row) { continue }
            $server    = if (-not $row.IsNull('ReplicaServer')) { [string]$row['ReplicaServer'] } else { '' }
            $role      = if (-not $row.IsNull('Role'))          { [string]$row['Role'] }          else { '' }
            $sync      = if (-not $row.IsNull('SyncHealth'))    { [string]$row['SyncHealth'] }    else { '' }
            $connected = if (-not $row.IsNull('ConnectedState')){ [string]$row['ConnectedState'] } else { '' }
            Write-Output ("  {0,-20} Role={1,-12} Sync={2,-15} Connected={3}" -f $server, $role, $sync, $connected)
        }

        $unhealthy = $health.Rows | Where-Object { $null -ne $_ -and -not $_.IsNull('SyncHealth') -and $_['SyncHealth'] -ne 'HEALTHY' }
        if ($unhealthy) {
            Write-Output "WARNING: Some replicas not yet synchronized — typically resolves within 60 s."
        }
    } -ArgumentList $AGName, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
        ForEach-Object { Write-Log "[$SQL1VMName] AG Health: $_" INFO }
} catch {
    Write-Log "[$SQL1VMName] AG health check failed (non-fatal — AG was configured successfully): $($_.Exception.Message -replace '\r?\n.*','')" WARN
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-13.done" SUCCESS
#endregion

Write-Log "Availability Group '$AGName' configuration complete." SUCCESS