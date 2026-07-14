#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 00: validate (and where safe, repair) everything the plan needs.

.DESCRIPTION
    Preflight is where a distributed AG deployment is won or lost. Almost every failure
    that surfaces hours into a seed — an endpoint the other side cannot connect to, a
    forwarder AG that already contains databases, a share the SQL service account cannot
    write to, a maintenance job quietly stealing the log chain — is detectable in seconds
    before any data moves.

    Hard failures throw. Soft findings warn. Two things are repaired in place, because
    they are prerequisites the tool is expected to own: endpoint CONNECT permissions for
    the peer service accounts, and GRANT CREATE ANY DATABASE on the forwarder replicas.
#>

Set-StrictMode -Version Latest

function Get-DagServiceNetworkLogin {
    <#
    .SYNOPSIS
        The Windows principal an instance presents to its peers over the AG endpoint.

    .DESCRIPTION
        Virtual accounts (NT SERVICE\MSSQLSERVER), LocalSystem and NetworkService all
        authenticate on the wire as the COMPUTER account, so granting CONNECT to the
        literal service_account string would silently grant nothing. Resolve to
        DOMAIN\MACHINE$ in those cases.
    #>
    param([Parameter(Mandatory)][psobject]$InstanceInfo)

    $acct = Get-DagScalar -Instance $InstanceInfo.Instance -Query @'
SELECT TOP 1 service_account AS v
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%'
'@
    if (-not $acct) { throw "Could not determine the SQL Server service account on '$($InstanceInfo.Instance)'." }

    $isMachineIdentity = ($acct -match '^(NT SERVICE\\|NT AUTHORITY\\)') -or ($acct -eq 'LocalSystem') -or ($acct -match '\$$')
    if ($isMachineIdentity -and $acct -notmatch '\$$') {
        return '{0}\{1}$' -f $InstanceInfo.NetbiosDomain, $InstanceInfo.MachineName
    }
    return $acct
}

function Test-DagLoginIsSysadmin {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$LoginName
    )
    $v = Get-DagScalar -Instance $Instance -Query "SELECT CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin', $(ConvertTo-DagQuotedString $LoginName)), 0) AS int) AS v"
    return ([int]$v -eq 1)
}

function Grant-DagEndpointConnect {
    <#
    .SYNOPSIS
        Ensures $LoginName exists on $Instance and holds CONNECT on the mirroring endpoint.
        Idempotent; a no-op when the login is already a sysadmin.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$LoginName,
        [Parameter(Mandatory)][string]$EndpointName
    )

    if (Test-DagLoginIsSysadmin -Instance $Instance -LoginName $LoginName) {
        Write-DagLog "  [$Instance] '$LoginName' is sysadmin — CONNECT on the endpoint is implicit." DEBUG
        return
    }

    $granted = Get-DagScalar -Instance $Instance -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.server_permissions AS perm
JOIN sys.server_principals AS sp ON sp.principal_id = perm.grantee_principal_id
JOIN sys.endpoints         AS e  ON e.endpoint_id   = perm.major_id
WHERE perm.class = 105
  AND perm.permission_name = 'CONNECT'
  AND perm.state IN ('G','W')
  AND e.name  = $(ConvertTo-DagQuotedString $EndpointName)
  AND sp.name = $(ConvertTo-DagQuotedString $LoginName)
"@
    if ([int]$granted -gt 0) {
        Write-DagLog "  [$Instance] '$LoginName' already has CONNECT on endpoint [$EndpointName]." DEBUG
        return
    }

    Write-DagLog "  [$Instance] granting CONNECT on [$EndpointName] to '$LoginName'..." INFO
    Invoke-DagSql -Instance $Instance -QueryTimeout 60 -Activity 'grant endpoint connect' -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $(ConvertTo-DagQuotedString $LoginName))
    CREATE LOGIN $(ConvertTo-DagQuotedName $LoginName) FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::$(ConvertTo-DagQuotedName $EndpointName) TO $(ConvertTo-DagQuotedName $LoginName);
"@ | Out-Null
    Write-DagLog "  [$Instance] granted CONNECT to '$LoginName'." SUCCESS
}

function Invoke-DagPreflight {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-DagBanner 'STEP 2 of 7 — PREFLIGHT'

    $allReplicas   = @($Plan.GlobalReplicas) + @($Plan.ForwarderReplicas)
    $warnings      = New-Object System.Collections.Generic.List[string]
    $instanceInfo  = @{}
    $endpointInfo  = @{}

    #region Reachability, privileges, HADR, endpoints
    Write-DagLog 'Checking every replica for connectivity, sysadmin, Always On and its mirroring endpoint...' INFO
    foreach ($r in $allReplicas) {
        if (-not (Test-DagConnection -Instance $r)) {
            throw "Cannot connect to replica '$r'. Every replica of both availability groups must be reachable."
        }
        $info = Get-DagInstanceInfo -Instance $r
        $instanceInfo[$r] = $info

        if (-not $info.IsHadrEnabled) { throw "Always On availability groups is not enabled on '$r'." }
        if (-not $info.IsSysadmin)    { throw "The connected login is not sysadmin on '$r'. Distributed AG configuration requires sysadmin on every replica." }

        $ep = Get-DagEndpointInfo -Instance $r
        if (-not $ep) { throw "Replica '$r' has no database mirroring (Hadr) endpoint. Create one before configuring a distributed availability group." }
        if ($ep.StateDesc -ne 'STARTED') { throw "The mirroring endpoint [$($ep.EndpointName)] on '$r' is $($ep.StateDesc), not STARTED." }
        if ($ep.RoleDesc  -ne 'ALL')     { $warnings.Add("Endpoint on '$r' has ROLE = $($ep.RoleDesc); ROLE = ALL is recommended for distributed AGs.") }
        if ($ep.AuthDesc  -notmatch 'NEGOTIATE|NTLM|KERBEROS') {
            $warnings.Add("Endpoint on '$r' authenticates with '$($ep.AuthDesc)'. This tool assumes Windows authentication between endpoints.")
        }
        $endpointInfo[$r] = $ep

        Write-DagLog ("  {0,-24} {1,-18} endpoint [{2}] port {3} {4}" -f $r, (Get-DagSqlVersionName $info.MajorVersion), $ep.EndpointName, $ep.Port, $ep.AuthDesc) SUCCESS
    }
    #endregion

    #region Endpoint port consistency
    # The DAG addresses a member AG by listener name + endpoint port. If replicas within
    # one AG listen on different ports, the URL is only correct while one node is primary.
    foreach ($side in @(@{ n = 'global primary'; r = $Plan.GlobalReplicas }, @{ n = 'forwarder'; r = $Plan.ForwarderReplicas })) {
        $ports = @($side.r | ForEach-Object { $endpointInfo[$_].Port } | Sort-Object -Unique)
        if ($ports.Count -gt 1) {
            $warnings.Add("Replicas of the $($side.n) AG listen on different endpoint ports ($($ports -join ', ')). Replication will stop after a local failover. Standardise the endpoint port.")
        }
    }
    #endregion

    #region Endpoint CONNECT permissions between the two sides
    Write-DagLog 'Verifying each side can authenticate to the other side''s endpoint...' INFO
    $globalLogins    = @($Plan.GlobalReplicas    | ForEach-Object { Get-DagServiceNetworkLogin -InstanceInfo $instanceInfo[$_] } | Sort-Object -Unique)
    $forwarderLogins = @($Plan.ForwarderReplicas | ForEach-Object { Get-DagServiceNetworkLogin -InstanceInfo $instanceInfo[$_] } | Sort-Object -Unique)

    Write-DagLog "  Global primary service account(s): $($globalLogins -join ', ')" INFO
    Write-DagLog "  Forwarder service account(s)     : $($forwarderLogins -join ', ')" INFO

    foreach ($r in $Plan.ForwarderReplicas) {
        foreach ($login in $globalLogins) { Grant-DagEndpointConnect -Instance $r -LoginName $login -EndpointName $endpointInfo[$r].EndpointName }
    }
    foreach ($r in $Plan.GlobalReplicas) {
        foreach ($login in $forwarderLogins) { Grant-DagEndpointConnect -Instance $r -LoginName $login -EndpointName $endpointInfo[$r].EndpointName }
    }
    #endregion

    #region Cluster quorum
    foreach ($r in @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica)) {
        $rows = Invoke-DagSql -Instance $r -Retry -Activity 'cluster state' -Query 'SELECT cluster_name AS ClusterName, quorum_state_desc AS QuorumState FROM sys.dm_hadr_cluster'
        if ($rows) {
            if ($rows[0].QuorumState -notlike 'NORMAL*') {
                $warnings.Add("Cluster '$($rows[0].ClusterName)' (via $r) reports quorum state '$($rows[0].QuorumState)'.")
            }
            Write-DagLog "  $r is on cluster '$($rows[0].ClusterName)' ($($rows[0].QuorumState))" INFO
        }
    }
    #endregion

    #region Forwarder AG must be empty
    $fwDbCount = Get-DagScalar -Instance $Plan.ForwarderPrimaryReplica -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_databases_cluster AS adc
JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
WHERE ag.name = $(ConvertTo-DagQuotedString $Plan.ForwarderAgName)
"@
    $dagExists = Test-DagIsDistributed -Instance $Plan.GlobalPrimaryReplica -DagName $Plan.DagName

    if ([int]$fwDbCount -gt 0 -and -not $dagExists) {
        throw @"
The forwarder availability group '$($Plan.ForwarderAgName)' already contains $fwDbCount database(s).

A forwarder AG receives its databases from the distributed AG and must be empty before it
is joined. Remove the existing databases from '$($Plan.ForwarderAgName)' and re-run.
"@
    }
    if ([int]$fwDbCount -gt 0 -and $dagExists) {
        Write-DagLog "  Forwarder AG holds $fwDbCount database(s) and the distributed AG already exists — this is a resume." INFO
    }
    #endregion

    #region DAG name collision with a normal AG
    foreach ($r in @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica)) {
        $clash = Get-DagScalar -Instance $r -Query @"
SELECT CAST(COUNT(*) AS int) AS v
FROM sys.availability_groups
WHERE name = $(ConvertTo-DagQuotedString $Plan.DagName) AND is_distributed = 0
"@
        if ([int]$clash -gt 0) {
            throw "'$($Plan.DagName)' is already the name of a normal (non-distributed) availability group on '$r'. Choose a different name."
        }
    }
    #endregion

    #region Selected databases still eligible
    foreach ($db in $Plan.Databases) {
        $state = Get-DagDatabaseState -Instance $Plan.GlobalPrimaryReplica -DatabaseName $db
        if (-not $state)                        { throw "Database [$db] no longer exists on '$($Plan.GlobalPrimaryReplica)'." }
        if ($state.StateDesc -ne 'ONLINE')      { throw "Database [$db] on '$($Plan.GlobalPrimaryReplica)' is $($state.StateDesc), not ONLINE." }
        if ($state.RecoveryModel -eq 'SIMPLE')  { throw "Database [$db] is in SIMPLE recovery. Availability groups require FULL recovery." }

        # A name collision on the forwarder is only a problem if that database is not
        # already the copy this DAG put there.
        foreach ($fr in $Plan.ForwarderReplicas) {
            $fstate = Get-DagDatabaseState -Instance $fr -DatabaseName $db
            if ($fstate -and $fstate.StateDesc -eq 'ONLINE' -and -not $fstate.IsJoinedToAg) {
                throw @"
Database [$db] already exists and is ONLINE on forwarder replica '$fr', and is not part of
an availability group there. Seeding would overwrite it.

Drop or rename [$db] on '$fr', or exclude it from this run, then re-run.
"@
            }
        }
    }
    #endregion

    #region Manual seeding prerequisites
    if ($Plan.SeedingMode -eq 'MANUAL') {
        Write-DagLog "Validating backup share '$($Plan.ShareRoot)' from every replica..." INFO
        foreach ($r in $allReplicas) {
            $err = Test-DagShareWritable -Instance $r -Path $Plan.ShareRoot
            if ($err) {
                throw @"
Replica '$r' cannot write to '$($Plan.ShareRoot)'.

  $err

The SQL Server service account on every replica of both availability groups needs read and
write access (full control is simplest) to the backup share.
"@
            }
            Write-DagLog "  [$r] backup share is readable and writable." SUCCESS
        }

        foreach ($r in $Plan.GlobalReplicas) {
            if ($instanceInfo[$r].AgentStatus -ne 'Running') {
                throw "SQL Server Agent is '$($instanceInfo[$r].AgentStatus)' on '$r'. Manual seeding schedules a log backup job on every replica of the global primary AG."
            }
        }

        # Where the restored files land, proven now rather than hours into a restore.
        Test-DagFileLayoutTarget -Plan $Plan -InstanceInfo $instanceInfo

        $competing = @(Get-DagCompetingLogBackup -Instance $Plan.GlobalPrimaryReplica -Databases $Plan.Databases -ShareRoot $Plan.ShareRoot)
        if ($competing.Count -gt 0) {
            Write-Host ''
            Write-DagLog 'Another process is taking transaction log backups of these databases to a different location:' WARN
            foreach ($c in $competing) {
                Write-DagLog ("  {0}: {1} log backup(s) in the last 24h, most recently {2}" -f $c.DatabaseName, $c.BackupCount, $c.LastBackup) WARN
                Write-DagLog ("      e.g. {0}" -f $c.SampleDevice) WARN
            }
            Write-Host ''
            Write-DagLog 'Those backups take the log records this seed needs. Unless they are disabled for the' WARN
            Write-DagLog 'duration of the seed, the restore will fail with a log chain gap (error 4305).' WARN
            $warnings.Add('Competing transaction log backup jobs were detected on the global primary.')
        }
    }
    #endregion

    #region Automatic seeding prerequisites
    if ($Plan.SeedingMode -eq 'AUTOMATIC') {
        # Without this the forwarder logs error 41158 and seeding never starts.
        foreach ($r in $Plan.ForwarderReplicas) {
            Invoke-DagSql -Instance $r -QueryTimeout 60 -Activity 'grant create any database' `
                -Query "ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.ForwarderAgName) GRANT CREATE ANY DATABASE;" | Out-Null
            Write-DagLog "  [$r] GRANT CREATE ANY DATABASE on [$($Plan.ForwarderAgName)]" SUCCESS
        }
    }
    #endregion

    #region Summary
    Write-Host ''
    if ($warnings.Count -gt 0) {
        Write-DagLog "Preflight completed with $($warnings.Count) warning(s):" WARN
        $warnings | ForEach-Object { Write-DagLog "  - $_" WARN }
        Write-Host ''
        if (-not (Read-DagYesNo -Question 'Continue anyway?' -DefaultYes $false)) {
            throw 'Aborted by operator after preflight warnings.'
        }
    } else {
        Write-DagLog 'Preflight passed with no warnings.' SUCCESS
    }
    #endregion

    return [pscustomobject]@{
        InstanceInfo = $instanceInfo
        EndpointInfo = $endpointInfo
    }
}
