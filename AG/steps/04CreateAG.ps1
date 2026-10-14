#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 04: endpoints, the availability group, and the secondaries joining it.

.DESCRIPTION
    The AG is created EMPTY and databases are added afterwards by the seeding step. That is
    one code path for every database whatever the seeding mode, and it is what lets automatic
    seeding admit databases through a sliding window rather than all at once.

    A contained AG's own master and msdb can only be seeded automatically, so a contained AG
    is created with SEEDING_MODE = AUTOMATIC on every replica, its system databases are waited
    for, and only then are the replicas switched to the seeding mode the plan chose.

    Every statement is guarded by a live check, so a re-run after an interruption neither
    re-creates nor re-joins anything.
#>

Set-StrictMode -Version Latest

function Set-AgReplicaSeedingMode {
    <#
    .SYNOPSIS
        Sets SEEDING_MODE on replicas of one AG. Runs on the primary. Idempotent.
    #>
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$AgName,
        [Parameter(Mandatory)][string[]]$Replicas,
        [Parameter(Mandatory)][ValidateSet('AUTOMATIC','MANUAL')][string]$Mode
    )
    $topo = Get-AgTopology -Instance $PrimaryInstance -AgName $AgName
    foreach ($r in $Replicas) {
        $current = @($topo.Replicas | Where-Object { $_.ReplicaServerName -eq $r })
        if ($current.Count -eq 1 -and $current[0].SeedingMode -eq $Mode) {
            Write-AgLog "  [$AgName] $r already SEEDING_MODE = $Mode" DEBUG
            continue
        }
        Invoke-AgSql -Instance $PrimaryInstance -QueryTimeout 120 -Activity 'set seeding mode' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $AgName)
MODIFY REPLICA ON $(ConvertTo-AgQuotedString $r) WITH (SEEDING_MODE = $Mode);
"@ | Out-Null
        Write-AgLog "  [$AgName] $r SEEDING_MODE -> $Mode" SUCCESS
    }
}

function Grant-AgCreateAnyDatabase {
    <#
    .SYNOPSIS
        Lets automatic seeding create the database on a secondary. Without it the secondary
        logs error 41158 and seeding never starts. Runs ON the secondary.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    Invoke-AgSql -Instance $Instance -QueryTimeout 60 -Activity 'grant create any database' `
        -Query "ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $AgName) GRANT CREATE ANY DATABASE;" | Out-Null
    Write-AgLog "  [$Instance] GRANT CREATE ANY DATABASE on [$AgName]" SUCCESS
}

function Get-AgReplicaSpecSql {
    param(
        [Parameter(Mandatory)][psobject]$Replica,
        [Parameter(Mandatory)][string]$SeedingMode,
        [Parameter(Mandatory)][psobject]$Plan
    )
    $parts = @(
        "ENDPOINT_URL = $(ConvertTo-AgQuotedString $Replica.EndpointUrl)"
        "AVAILABILITY_MODE = $($Replica.AvailabilityMode)"
        "FAILOVER_MODE = $($Replica.FailoverMode)"
        "SEEDING_MODE = $SeedingMode"
        "SESSION_TIMEOUT = $([int]$Replica.SessionTimeout)"
    )
    if (-not $Plan.IsBasic) {
        $parts += "BACKUP_PRIORITY = $([int]$Replica.BackupPriority)"
        $parts += "SECONDARY_ROLE (ALLOW_CONNECTIONS = $($Replica.SecondaryConnections))"
        $parts += 'PRIMARY_ROLE (ALLOW_CONNECTIONS = ALL)'
    }
    "    $(ConvertTo-AgQuotedString $Replica.Name) WITH (`r`n        " + ($parts -join ",`r`n        ") + "`r`n    )"
}

function Get-AgCreateSql {
    param([Parameter(Mandatory)][psobject]$Plan)

    $o = $Plan.AgOptions
    $with = New-Object System.Collections.Generic.List[string]
    if ($Plan.IsBasic) {
        $with.Add('BASIC')
    } else {
        $with.Add("AUTOMATED_BACKUP_PREFERENCE = $($o.AutomatedBackupPreference)")
    }
    $with.Add("FAILURE_CONDITION_LEVEL = $([int]$o.FailureConditionLevel)")
    $with.Add("HEALTH_CHECK_TIMEOUT = $([int]$o.HealthCheckTimeout)")
    $with.Add("DB_FAILOVER = $(if ($o.DbFailover) { 'ON' } else { 'OFF' })")
    if (-not $Plan.IsBasic -and $Plan.MinMajorVersion -ge 13) { $with.Add("DTC_SUPPORT = $($o.DtcSupport)") }
    if (-not $Plan.IsBasic -and $Plan.MinMajorVersion -ge 14) {
        $with.Add('CLUSTER_TYPE = WSFC')
        $with.Add("REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = $([int]$o.RequiredSyncedSecondaries)")
    }
    if ($Plan.IsContained) {
        $with.Add($(if ($Plan.ReuseSystemDatabases) { 'CONTAINED, REUSE_SYSTEM_DATABASES' } else { 'CONTAINED' }))
    }

    # A contained AG's system databases only seed automatically.
    $createMode = if ($Plan.IsContained -or $Plan.SeedingMode -eq 'AUTOMATIC') { 'AUTOMATIC' } else { 'MANUAL' }
    $specs = @($Plan.Replicas | ForEach-Object { Get-AgReplicaSpecSql -Replica $_ -SeedingMode $createMode -Plan $Plan })

    @"
CREATE AVAILABILITY GROUP $(ConvertTo-AgQuotedName $Plan.AgName)
WITH (
    $($with -join ",`r`n    ")
)
FOR
REPLICA ON
$($specs -join ",`r`n");
"@
}

function Test-AgJoinedOnSecondary {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$AgName
    )
    $v = Get-AgScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id AND ars.is_local = 1
WHERE ag.name = $(ConvertTo-AgQuotedString $AgName)
  AND ars.role_desc = 'SECONDARY'
"@
    return ([int]$v -gt 0)
}

function Invoke-AgEndpoints {
    <#
    .SYNOPSIS
        Creates or starts the mirroring endpoints the plan calls for, grants CONNECT to each
        peer's service account, and makes sure AlwaysOn_health is running everywhere.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo
    )

    Write-AgBanner 'ENDPOINTS AND PERMISSIONS'

    foreach ($r in $Plan.Replicas) {
        $ep = Get-AgEndpointInfo -Instance $r.Name
        if (-not $ep) {
            New-AgMirroringEndpoint -Instance $r.Name -EndpointName $r.EndpointName -Port $r.EndpointPort
        } elseif ($ep.StateDesc -ne 'STARTED') {
            Start-AgMirroringEndpoint -Instance $r.Name -EndpointName $ep.EndpointName
        } else {
            Write-AgLog "  [$($r.Name)] endpoint [$($ep.EndpointName)] is STARTED on port $($ep.Port)." SUCCESS
        }
    }

    Write-AgLog 'Making sure every replica can authenticate to every other replica''s endpoint...' INFO
    $logins = @{}
    foreach ($r in $Plan.Replicas) { $logins[$r.Name] = Get-AgServiceNetworkLogin -InstanceInfo $InstanceInfo[$r.Name] }
    Write-AgLog "  Service accounts: $(($logins.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" INFO
    foreach ($r in $Plan.Replicas) {
        $epName = (Get-AgEndpointInfo -Instance $r.Name).EndpointName
        foreach ($peer in $Plan.Replicas | Where-Object { $_.Name -ne $r.Name }) {
            # Even when every replica runs as the same domain account, that account still needs
            # a login with CONNECT here: the peer arrives as it over the wire.
            $login = $logins[$peer.Name]
            Grant-AgEndpointConnect -Instance $r.Name -LoginName $login -EndpointName $epName
        }
    }

    foreach ($r in $Plan.Replicas) { Enable-AgHealthSession -Instance $r.Name }
}

function Invoke-AgCreate {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][hashtable]$InstanceInfo
    )

    Invoke-AgEndpoints -Plan $Plan -InstanceInfo $InstanceInfo

    Write-AgBanner "CREATE AVAILABILITY GROUP [$($Plan.AgName)]"
    $p = $Plan.PrimaryReplica

    #region Contained system databases being replaced
    if ($Plan.IsContained -and -not $Plan.ReuseSystemDatabases -and -not (Test-AgExists -Instance $p -AgName $Plan.AgName)) {
        foreach ($sysdb in (Get-AgContainedSystemDatabaseNames -AgName $Plan.AgName)) {
            foreach ($r in $Plan.ReplicaNames) {
                if (Get-AgDatabaseState -Instance $r -DatabaseName $sysdb) {
                    Write-AgLog "  [$r] dropping [$sysdb] left by an earlier contained AG of this name (the operator chose not to reuse it)." INFO
                    Invoke-AgSql -Instance $r -QueryTimeout 120 -Activity 'drop old contained system db' -Query @"
IF DB_ID($(ConvertTo-AgQuotedString $sysdb)) IS NOT NULL
BEGIN
    IF DATABASEPROPERTYEX($(ConvertTo-AgQuotedString $sysdb), 'Status') = 'ONLINE'
        ALTER DATABASE $(ConvertTo-AgQuotedName $sysdb) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE $(ConvertTo-AgQuotedName $sysdb);
END
"@ | Out-Null
                }
            }
        }
    }
    if ($Plan.IsContained -and $Plan.ReuseSystemDatabases) {
        # REUSE_SYSTEM_DATABASES takes them from the primary and seeds them afresh.
        foreach ($sysdb in (Get-AgContainedSystemDatabaseNames -AgName $Plan.AgName)) {
            foreach ($s in $Plan.SecondaryReplicas) {
                $st = Get-AgDatabaseState -Instance $s -DatabaseName $sysdb
                if ($st -and -not $st.IsJoinedToAg) {
                    Write-AgLog "  [$s] dropping stale [$sysdb] so the reused copy can seed there." INFO
                    Remove-AgDatabaseCopy -Instance $s -DatabaseName $sysdb
                }
            }
        }
    }
    #endregion

    #region CREATE on the primary
    if (Test-AgExists -Instance $p -AgName $Plan.AgName) {
        Write-AgLog "  [$p] [$($Plan.AgName)] already exists — skipping CREATE." SUCCESS
    } else {
        $sql = Get-AgCreateSql -Plan $Plan
        if ($Plan.IsContained -and $Plan.ReuseSystemDatabases) {
            # REUSE needs the old contained master and msdb to itself. A pooled connection
            # whose database context is one of them holds a shared lock on it for as long as
            # the pool keeps it, and the CREATE then fails with lock timeout 1222.
            foreach ($t in 'Microsoft.Data.SqlClient.SqlConnection', 'System.Data.SqlClient.SqlConnection') {
                $type = $t -as [type]
                if ($type) { try { $type::ClearAllPools() } catch { } }
            }
            $inUse = Invoke-AgSql -Instance $p -Query @"
SELECT s.session_id AS Spid, ISNULL(s.program_name, '') AS Program, DB_NAME(s.database_id) AS Db
FROM sys.dm_exec_sessions AS s
WHERE s.database_id IN (DB_ID($(ConvertTo-AgQuotedString "$($Plan.AgName)_master")), DB_ID($(ConvertTo-AgQuotedString "$($Plan.AgName)_msdb")))
  AND s.session_id <> @@SPID
"@
            if ($inUse.Count -gt 0) {
                throw "Sessions are using the contained system databases being reused: $(($inUse | ForEach-Object { "spid $($_.Spid) ($($_.Program)) in $($_.Db)" }) -join '; '). Close them and re-run."
            }
        }
        Write-AgLog "  [$p] creating [$($Plan.AgName)]..." INFO
        Write-AgLog $sql DEBUG
        Invoke-AgSql -Instance $p -QueryTimeout 600 -Activity 'create availability group' -Query $sql | Out-Null
        Write-AgLog "  Created [$($Plan.AgName)] on $p." SUCCESS
    }
    #endregion

    #region JOIN from each secondary
    $needsGrant = $Plan.IsContained -or $Plan.SeedingMode -eq 'AUTOMATIC'
    foreach ($s in $Plan.SecondaryReplicas) {
        $ok = Wait-AgCondition -Activity "[$s] seeing [$($Plan.AgName)] in the cluster" -TimeoutSeconds 120 -PollSeconds 3 -Condition {
            [int](Get-AgScalar -Instance $s -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.availability_groups_cluster WHERE name = $(ConvertTo-AgQuotedString $Plan.AgName)") -gt 0
        }
        if (-not $ok) { throw "'$s' never saw [$($Plan.AgName)] in the cluster configuration. Check the cluster's health." }

        if (Test-AgJoinedOnSecondary -Instance $s -AgName $Plan.AgName) {
            Write-AgLog "  [$s] already joined to [$($Plan.AgName)]." SUCCESS
        } else {
            $join = "ALTER AVAILABILITY GROUP $(ConvertTo-AgQuotedName $Plan.AgName) JOIN"
            if ($Plan.MinMajorVersion -ge 14 -and -not $Plan.IsBasic) { $join += ' WITH (CLUSTER_TYPE = WSFC)' }
            Invoke-AgWithRetry -Activity "join $s" -MaxAttempts 5 -DelaySeconds 5 -ScriptBlock {
                Invoke-AgSql -Instance $s -QueryTimeout 300 -Activity 'join availability group' -Query "$join;" | Out-Null
            }
            Write-AgLog "  [$s] joined [$($Plan.AgName)]." SUCCESS
        }
        if ($needsGrant) { Grant-AgCreateAnyDatabase -Instance $s -AgName $Plan.AgName }
    }
    #endregion

    #region Wait for every secondary to connect
    if ($Plan.SecondaryReplicas.Count -gt 0) {
        $connected = Wait-AgCondition -Activity "secondaries connecting to [$($Plan.AgName)]" -TimeoutSeconds 300 -PollSeconds 5 `
            -Condition {
                $t = Get-AgTopology -Instance $p -AgName $Plan.AgName
                @($t.Replicas | Where-Object { $_.Role -ne 'PRIMARY' -and $_.ConnectedState -ne 'CONNECTED' }).Count -eq 0
            } `
            -ProgressMessage {
                $t = Get-AgTopology -Instance $p -AgName $Plan.AgName
                ($t.Replicas | Where-Object { $_.Role -ne 'PRIMARY' } | ForEach-Object { "$($_.ReplicaServerName)=$($_.ConnectedState)" }) -join ' '
            }
        if (-not $connected) {
            throw @"
Not every secondary replica reached CONNECTED within 5 minutes.

Most common causes, in order:
  * A firewall is blocking the endpoint port (usually 5022) between the nodes.
  * An endpoint URL does not resolve from the other nodes: $(($Plan.Replicas | ForEach-Object { $_.EndpointUrl }) -join ', ')
  * The service accounts cannot authenticate to each other (Kerberos/SPN or NTLM problems).

Read the SQL Server error log and the AlwaysOn_health session on $p and the disconnected secondaries.
Re-running Initialize-AG.ps1 is safe and resumes from here.
"@
        }
    }
    #endregion

    #region Contained: system databases first, then the plan's seeding mode
    if ($Plan.IsContained -and $Plan.SecondaryReplicas.Count -gt 0) {
        foreach ($sysdb in (Get-AgContainedSystemDatabaseNames -AgName $Plan.AgName)) {
            foreach ($s in $Plan.SecondaryReplicas) {
                $ok = Wait-AgCondition -Activity "contained [$sysdb] seeding to $s" -TimeoutSeconds 900 -PollSeconds 5 `
                    -Condition { Test-AgDatabaseSynchronizing -Instance $s -AgName $Plan.AgName -DatabaseName $sysdb }
                if (-not $ok) { throw "The contained system database [$sysdb] did not seed to '$s'. Check sys.dm_hadr_automatic_seeding on $p." }
            }
        }
        if ($Plan.SeedingMode -eq 'MANUAL') {
            Set-AgReplicaSeedingMode -PrimaryInstance $p -AgName $Plan.AgName -Replicas $Plan.ReplicaNames -Mode 'MANUAL'
        }
    }
    #endregion

    Write-AgLog "Availability group [$($Plan.AgName)] is created and every secondary is connected." SUCCESS
}
