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

        # Open Windows Firewall for the HADR endpoint port (idempotent)
        $fwRule = Get-NetFirewallRule -DisplayName "SQL HADR Endpoint" -ErrorAction SilentlyContinue
        if (-not $fwRule) {
            New-NetFirewallRule -DisplayName "SQL HADR Endpoint" -Direction Inbound `
                -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-Output "Firewall rule added: allow TCP inbound port $Port."
        } else {
            Write-Output "Firewall rule 'SQL HADR Endpoint' already exists."
        }

    } -ArgumentList $EndpointPort, $SQLSvcAccount, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
        ForEach-Object { Write-Log "[$($pair.VM)] $_" INFO }
}
#endregion

#region Create Availability Group on SQL1
$agTypeLabel = if ($global:ContainedAG) { "Contained Availability Group" } else { "Availability Group" }
Write-Log "[$SQL1VMName] Creating $agTypeLabel '$AGName'..." INFO
Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName, $SQL1Name, $SQL2Name, $ListenerName, $ListenerIP, $ListenerPort, $EPPort, $InvokeLocalSqlDef, $IsContained)
    . ([scriptblock]::Create($InvokeLocalSqlDef))
    $agTypeLabel = if ($IsContained) { "Contained AG" } else { "AG" }

    $existingAG = Invoke-LocalSql -Query "SELECT name FROM sys.availability_groups WHERE name='$AGName'"
    if ($existingAG.Rows.Count -gt 0) {
        Write-Output "$agTypeLabel '$AGName' already exists."
    } else {
        $domain = $env:USERDNSDOMAIN
        $containedClause = if ($IsContained) { "CONTAINED, " } else { "" }
        $seedingClause   = if ($IsContained) { ",`n    SEEDING_MODE        = AUTOMATIC" } else { "" }
        try {
            Invoke-LocalSql -Query "
CREATE AVAILABILITY GROUP [$AGName]
WITH (${containedClause}AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR
REPLICA ON
  N'$SQL1Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL1Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)${seedingClause}
  ),
  N'$SQL2Name' WITH (
    ENDPOINT_URL        = N'TCP://$SQL2Name.$domain`:$EPPort',
    FAILOVER_MODE       = AUTOMATIC,
    AVAILABILITY_MODE   = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY     = 50,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)${seedingClause}
  )" -Timeout 120
            Write-Output "$agTypeLabel '$AGName' created."
        } catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            Write-Output "$agTypeLabel '$AGName' already exists (caught on create) — continuing."
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

    # For Contained AG: ensure SEEDING_MODE = AUTOMATIC on both replicas, then
    # GRANT CREATE ANY DATABASE on the primary. Both are required for auto-seeding:
    # the primary GRANT authorizes SQL Server to push databases to secondaries;
    # the secondary GRANT (done in the SQL2 scriptblock) authorizes receiving them.
    if ($IsContained) {
        foreach ($replicaName in @($SQL1Name, $SQL2Name)) {
            try {
                Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] MODIFY REPLICA ON N'$replicaName' WITH (SEEDING_MODE = AUTOMATIC)"
                Write-Output "SEEDING_MODE = AUTOMATIC confirmed on '$replicaName'."
            } catch {
                Write-Output "MODIFY REPLICA warning on '$replicaName' (non-fatal): $($_.Exception.Message -replace '\r?\n.*','')"
            }
        }
        try {
            Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE"
            Write-Output "Granted CREATE ANY DATABASE on primary — auto-seeding authorized."
        } catch {
            if ($_.Exception.Message -notmatch 'already') { throw }
            Write-Output "CREATE ANY DATABASE already granted on primary."
        }
    }

} -ArgumentList $AGName, $SQL1ComputerName, $SQL2ComputerName,
    $ListenerName, $ListenerIP, $ListenerPort, $EndpointPort, $invokeLocalSqlDef.ToString(), $global:ContainedAG -ErrorAction Stop |
    ForEach-Object { Write-Log "[$SQL1VMName] $_" INFO }
#endregion

#region Join SQL2 to AG
Write-Log "[$SQL2VMName] Joining replica to AG '$AGName'..." INFO
Invoke-Command -VMName $SQL2VMName -Credential $domainAdminCred -ScriptBlock {
    param($AGName, $InvokeLocalSqlDef, $IsContained)
    . ([scriptblock]::Create($InvokeLocalSqlDef))

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
            if ($_.Exception.Message -notmatch 'already exists|already joined') { throw }
            Write-Output "Replica already joined to AG '$AGName'."
        }
    } else {
        Write-Output "Replica already joined to AG '$AGName'."
    }

    if ($IsContained) {
        try {
            Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE"
            Write-Output "Granted CREATE ANY DATABASE to Contained AG '$AGName'."
        } catch {
            if ($_.Exception.Message -notmatch 'already') { throw }
            Write-Output "CREATE ANY DATABASE already granted — continuing."
        }
    }

} -ArgumentList $AGName, $invokeLocalSqlDef.ToString(), $global:ContainedAG -ErrorAction Stop |
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

#region Create labadmin logins
# Server-level login on each node — for direct connections to SQL1/SQL2.
foreach ($vmName in @($SQL1VMName, $SQL2VMName)) {
    Write-Log "[$vmName] Creating server-level login '$LabAdminUser'..." INFO
    Invoke-Command -VMName $vmName -Credential $domainAdminCred -ScriptBlock {
        param($SqlUser, $SqlPass, $InvokeLocalSqlDef)
        . ([scriptblock]::Create($InvokeLocalSqlDef))

        $escapedPass = $SqlPass -replace "'","''"
        try {
            Invoke-LocalSql -Query "CREATE LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF"
            Write-Output "Created server-level login '$SqlUser'."
        } catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            $existing = Invoke-LocalSql -Query "SELECT type FROM sys.server_principals WHERE name = '$SqlUser' COLLATE SQL_Latin1_General_CP1_CI_AS"
            if ($existing.Rows.Count -gt 0 -and [string]$existing.Rows[0]['type'] -eq 'S') {
                Invoke-LocalSql -Query "ALTER LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF"
                Write-Output "Server-level login '$SqlUser' already exists - password confirmed."
            } else {
                $t = if ($existing.Rows.Count -gt 0) { [string]$existing.Rows[0]['type'] } else { 'unknown' }
                Write-Output "Principal '$SqlUser' already exists as type '$t' - skipping."
            }
        }

        $isSA = Invoke-LocalSql -Query "SELECT 1 AS r FROM sys.server_role_members rm JOIN sys.server_principals rp ON rm.role_principal_id = rp.principal_id JOIN sys.server_principals mp ON rm.member_principal_id = mp.principal_id WHERE rp.name = 'sysadmin' AND mp.name = '$SqlUser'"
        if ($isSA.Rows.Count -eq 0) {
            try {
                Invoke-LocalSql -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER [$SqlUser]"
                Write-Output "Granted sysadmin to '$SqlUser'."
            } catch {
                if ($_.Exception.Message -notmatch 'already') { throw }
                Write-Output "sysadmin already granted to '$SqlUser'."
            }
        } else {
            Write-Output "sysadmin already granted to '$SqlUser'."
        }

    } -ArgumentList $LabAdminUser, $LabAdminPassword, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
        ForEach-Object { Write-Log "[$vmName] $_" INFO }
}

# Contained AG: also create the login via the listener so the Contained AG's replication
# context manages it. This is in addition to the per-node creates above.
if ($global:ContainedAG) {
    Write-Log "[$SQL1VMName] Creating server-level login '$LabAdminUser' via listener (Contained AG context)..." INFO
    Invoke-Command -VMName $SQL1VMName -Credential $domainAdminCred -ScriptBlock {
        param($ListenerName, $ListenerPort, $SqlUser, $SqlPass, $InvokeLocalSqlDef)
        . ([scriptblock]::Create($InvokeLocalSqlDef))

        $escapedPass = $SqlPass -replace "'","''"
        try {
            Invoke-LocalSql -Query "CREATE LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF" `
                -Server "$ListenerName,$ListenerPort"
            Write-Output "Created login '$SqlUser' via listener."
        } catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            $existing = Invoke-LocalSql -Query "SELECT type FROM sys.server_principals WHERE name = '$SqlUser' COLLATE SQL_Latin1_General_CP1_CI_AS" `
                -Server "$ListenerName,$ListenerPort"
            if ($existing.Rows.Count -gt 0 -and [string]$existing.Rows[0]['type'] -eq 'S') {
                Invoke-LocalSql -Query "ALTER LOGIN [$SqlUser] WITH PASSWORD = '$escapedPass', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF" `
                    -Server "$ListenerName,$ListenerPort"
                Write-Output "Login '$SqlUser' already exists via listener - password confirmed."
            } else {
                $t = if ($existing.Rows.Count -gt 0) { [string]$existing.Rows[0]['type'] } else { 'unknown' }
                Write-Output "Principal '$SqlUser' exists as type '$t' via listener - skipping create/alter."
            }
        }

        try {
            Invoke-LocalSql -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER [$SqlUser]" `
                -Server "$ListenerName,$ListenerPort"
            Write-Output "Granted sysadmin to '$SqlUser' via listener."
        } catch {
            if ($_.Exception.Message -notmatch 'already') { throw }
            Write-Output "sysadmin already granted to '$SqlUser' via listener."
        }

    } -ArgumentList $ListenerName, $ListenerPort, $LabAdminUser, $LabAdminPassword, $invokeLocalSqlDef.ToString() -ErrorAction Stop |
        ForEach-Object { Write-Log "[$SQL1VMName] Listener login: $_" INFO }
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-13.done" SUCCESS
#endregion

Write-Log "Availability Group '$AGName' configuration complete." SUCCESS