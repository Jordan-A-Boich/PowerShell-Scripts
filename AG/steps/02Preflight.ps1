#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — Step 02: validate (and where safe, repair) everything the plan needs.

.DESCRIPTION
    Almost every failure that surfaces deep into an AG build — a secondary with no D:\SQLData
    for automatic seeding to write into, a share one replica's service account cannot read,
    a maintenance job quietly stealing the log chain, a TDE certificate that never made it to
    the secondary — is detectable in seconds before anything changes. Hard failures throw.
    Soft findings are collected and shown together, and the operator decides.

    Nothing here changes a database. The only repairs made are directories the restores or
    the automatic seed will need, which is what the plan asked for anyway.
#>

Set-StrictMode -Version Latest

function Get-AgAutoSeedTargetPath {
    <#
    .SYNOPSIS
        Where automatic seeding will put each file of a database on a given secondary.
    .DESCRIPTION
        Automatic seeding does not take a MOVE. A file that lives in the PRIMARY's default
        data (or log) directory lands in the SECONDARY's default directory; every other file
        lands at exactly the path it has on the primary (SQL Server 2017 and later; 2016
        always uses the primary's path). The directory has to exist there, or the seed fails
        on the secondary with nothing in the error log the operator would connect to it.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][psobject]$PrimaryInfo,
        [Parameter(Mandatory)][psobject]$SecondaryInfo
    )
    $files = @(Get-AgDatabaseFileLayout -Instance $PrimaryInfo.Instance -DatabaseName $DatabaseName)
    $pData = ([string]$PrimaryInfo.DefaultDataPath).TrimEnd('\')
    $pLog  = ([string]$PrimaryInfo.DefaultLogPath).TrimEnd('\')
    foreach ($f in $files) {
        $dir  = Split-Path -Path $f.PhysicalName -Parent
        $leaf = Split-Path -Path $f.PhysicalName -Leaf
        $target = $dir
        if ($SecondaryInfo.MajorVersion -ge 14) {
            if ($f.FileType -eq 'L' -and $dir.TrimEnd('\') -ieq $pLog) { $target = ([string]$SecondaryInfo.DefaultLogPath).TrimEnd('\') }
            elseif ($f.FileType -ne 'L' -and $dir.TrimEnd('\') -ieq $pData) { $target = ([string]$SecondaryInfo.DefaultDataPath).TrimEnd('\') }
        }
        [pscustomobject]@{
            LogicalName = $f.LogicalName
            FileType    = $f.FileType
            SizeBytes   = $f.SizeBytes
            Directory   = $target
            TargetPath  = Join-AgPath -Path $target -ChildPath @($leaf)
        }
    }
}

function Invoke-AgPreflight {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-AgBanner 'PREFLIGHT'

    $warnings     = New-Object System.Collections.Generic.List[string]
    $instanceInfo = @{}
    $replicas     = @($Plan.ReplicaNames)

    #region Reachability, privileges, Always On
    Write-AgLog 'Checking every replica for connectivity, sysadmin and Always On...' INFO
    foreach ($r in $replicas) {
        if (-not (Test-AgConnection -Instance $r)) { throw "Cannot connect to replica '$r'. Every replica must be reachable from this machine." }
        $info = Get-AgInstanceInfo -Instance $r
        $instanceInfo[$r] = $info
        if (-not $info.IsHadrEnabled) { throw "Always On availability groups is not enabled on '$r'. Run: Enable-SqlAlwaysOn -ServerInstance '$r' -Force  (restarts SQL Server)." }
        if (-not $info.IsSysadmin)    { throw "The connected login is not sysadmin on '$r'." }
        Write-AgLog ("  {0,-24} {1,-16} {2}" -f $r, (Get-AgSqlVersionName $info.MajorVersion), $info.Edition) SUCCESS
    }
    $primaryInfo = $instanceInfo[$Plan.PrimaryReplica]

    $majors = @($instanceInfo.Values | ForEach-Object { $_.MajorVersion } | Sort-Object -Unique)
    if ($majors.Count -gt 1) {
        $warnings.Add("Replicas run different SQL Server versions ($(( $majors | ForEach-Object { Get-AgSqlVersionName $_ }) -join ', ')). That is supported only during a rolling upgrade, and a database cannot fail back to an older version once it has run on a newer one.")
    }
    foreach ($s in $Plan.SecondaryReplicas) {
        if ($instanceInfo[$s].MajorVersion -lt $primaryInfo.MajorVersion) {
            throw "'$s' runs $(Get-AgSqlVersionName $instanceInfo[$s].MajorVersion), older than the primary's $(Get-AgSqlVersionName $primaryInfo.MajorVersion). A database cannot be seeded or restored onto an older version."
        }
    }
    if ($Plan.IsContained -and @($instanceInfo.Values | Where-Object { $_.MajorVersion -lt 16 }).Count -gt 0) {
        throw 'Contained availability groups need SQL Server 2022 or later on every replica.'
    }
    #endregion

    #region Cluster
    $clusters = @{}
    foreach ($r in $replicas) {
        $c = Get-AgClusterInfo -Instance $r
        if (-not $c) { throw "'$r' is not running on a Windows Server Failover Cluster node." }
        $clusters[$r] = $c.ClusterName
        if ($r -eq $Plan.PrimaryReplica -and $c.QuorumState -notlike 'NORMAL*') {
            $warnings.Add("Cluster '$($c.ClusterName)' reports quorum state '$($c.QuorumState)'.")
        }
    }
    $names = @($clusters.Values | Sort-Object -Unique)
    if ($names.Count -gt 1) {
        throw "The replicas are not all in one cluster: $(($clusters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '). A WSFC availability group lives inside a single cluster (use a distributed AG to span two)."
    }
    Write-AgLog "  All replicas are nodes of cluster '$($names[0])'." SUCCESS
    #endregion

    #region The availability group itself
    $agExists = Test-AgExists -Instance $Plan.PrimaryReplica -AgName $Plan.AgName
    if ($Plan.Operation -eq 'CREATE') {
        if ($agExists) {
            $topo = Get-AgTopology -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -AllowNoPrimary
            $have = @($topo.Replicas | ForEach-Object { $_.ReplicaServerName } | Sort-Object)
            $want = @($replicas | Sort-Object)
            if (($have -join ',') -ne ($want -join ',')) {
                throw "Availability group [$($Plan.AgName)] already exists with replicas $($have -join ', '), not the planned $($want -join ', '). Choose another name or drop it first."
            }
            if ($topo.PrimaryReplica -and $topo.PrimaryReplica -ne $Plan.PrimaryReplica) {
                throw "Availability group [$($Plan.AgName)] already exists and its primary is now $($topo.PrimaryReplica), not $($Plan.PrimaryReplica). Fail it back, or finish the remaining steps by hand."
            }
            Write-AgLog "  [$($Plan.AgName)] already exists with the planned replicas — this is a resume." INFO
        } else {
            $clash = Get-AgScalar -Instance $Plan.PrimaryReplica -Query "SELECT CAST(COUNT(*) AS int) AS v FROM sys.availability_groups_cluster WHERE name = $(ConvertTo-AgQuotedString $Plan.AgName)"
            if ([int]$clash -gt 0) { throw "An availability group named [$($Plan.AgName)] already exists elsewhere in this cluster." }
        }
    } else {
        if (-not $agExists) { throw "Availability group [$($Plan.AgName)] no longer exists on '$($Plan.PrimaryReplica)'." }
        $topo = Get-AgTopology -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -AllowNoPrimary
        if ($topo.PrimaryReplica -ne $Plan.PrimaryReplica) {
            throw "The primary of [$($Plan.AgName)] is now $($topo.PrimaryReplica), not $($Plan.PrimaryReplica) as planned. Re-run Add-AGDatabase.ps1 and start a new plan."
        }
    }
    #endregion

    #region Endpoints
    if ($Plan.Operation -eq 'CREATE') {
        foreach ($r in $Plan.Replicas) {
            $ep = Get-AgEndpointInfo -Instance $r.Name
            if ($ep) {
                if ($ep.AuthDesc -notmatch 'NEGOTIATE|NTLM|KERBEROS') {
                    $warnings.Add("Endpoint [$($ep.EndpointName)] on '$($r.Name)' authenticates with '$($ep.AuthDesc)'. This tool grants CONNECT to Windows service accounts; certificate endpoints need their certificates exchanged by hand.")
                }
                if ($ep.RoleDesc -ne 'ALL' -and $ep.RoleDesc -ne 'PARTNER') {
                    throw "The mirroring endpoint on '$($r.Name)' has ROLE = $($ep.RoleDesc). An availability group replica needs ROLE = ALL or PARTNER."
                }
            }
        }
        $encs = @($Plan.Replicas | ForEach-Object { Get-AgEndpointInfo -Instance $_.Name } | Where-Object { $_ } | ForEach-Object { "$($_.IsEncrypted)/$($_.EncryptionDesc)" } | Sort-Object -Unique)
        if ($encs.Count -gt 1) {
            $warnings.Add("The existing endpoints use different encryption settings ($($encs -join '; ')). Replicas whose settings are incompatible cannot connect.")
        }
        $ports = @($Plan.Replicas | ForEach-Object { $_.EndpointPort } | Sort-Object -Unique)
        if ($ports.Count -gt 1) { $warnings.Add("Replicas will use different endpoint ports ($($ports -join ', ')). That works, but a firewall rule per port is needed.") }
        foreach ($r in $Plan.Replicas | Where-Object { $_.CreateEndpoint }) {
            Write-AgLog "  [$($r.Name)] has no mirroring endpoint — one will be created on port $($r.EndpointPort)." INFO
        }
    } else {
        foreach ($r in $replicas) {
            $ep = Get-AgEndpointInfo -Instance $r
            if (-not $ep -or $ep.StateDesc -ne 'STARTED') { throw "The mirroring endpoint on '$r' is $(if ($ep) { $ep.StateDesc } else { 'missing' }). Start it before adding databases." }
        }
    }
    #endregion

    #region Databases
    foreach ($db in $Plan.Databases) {
        $state = Get-AgDatabaseState -Instance $Plan.PrimaryReplica -DatabaseName $db
        if (-not $state) { throw "Database [$db] no longer exists on '$($Plan.PrimaryReplica)'." }
        if ($state.StateDesc -ne 'ONLINE') { throw "Database [$db] on '$($Plan.PrimaryReplica)' is $($state.StateDesc), not ONLINE." }
        if ($state.IsJoinedToAg -and -not (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $db)) {
            throw "Database [$db] has joined another availability group since the plan was made."
        }
        $repair = @($Plan.Repairs | Where-Object { $_.DatabaseName -eq $db })
        if ($state.RecoveryModel -ne 'FULL' -and -not ($repair.Count -gt 0 -and $repair[0].SetFullRecovery)) {
            throw "Database [$db] is in $($state.RecoveryModel) recovery and the plan does not switch it to FULL."
        }
        # Already in the AG (a resume): whatever sits on the secondaries is the AG's own copy.
        if ($agExists -and (Test-AgDatabaseInAg -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -DatabaseName $db)) { continue }
        foreach ($s in $Plan.SecondaryReplicas) {
            $copy = Get-AgDatabaseState -Instance $s -DatabaseName $db
            if (-not $copy) { continue }
            $agreed = $Plan.DropLeftoverCopies -contains "$db|$s"
            if ($copy.StateDesc -eq 'ONLINE' -and -not $copy.IsJoinedToAg) {
                throw "A database named [$db] is ONLINE on '$s' and is not part of an availability group. Seeding would overwrite it; drop or rename it there first."
            }
            if ($Plan.SeedingMode -eq 'AUTOMATIC' -and -not $copy.IsJoinedToAg -and -not $agreed) {
                throw "[$db] already exists on '$s' ($($copy.StateDesc)). Automatic seeding cannot seed over it. Drop it there, or re-run and agree to drop leftover copies."
            }
        }
    }
    #endregion

    #region Automatic seeding: directories on the secondaries
    if ($Plan.SeedingMode -eq 'AUTOMATIC' -and $Plan.Databases.Count -gt 0) {
        Write-AgLog 'Checking where automatic seeding will create each file on every secondary...' INFO
        foreach ($s in $Plan.SecondaryReplicas) {
            $dirs = @{}
            $placed = New-Object System.Collections.Generic.List[psobject]
            foreach ($db in $Plan.Databases) {
                foreach ($t in (Get-AgAutoSeedTargetPath -DatabaseName $db -PrimaryInfo $primaryInfo -SecondaryInfo $instanceInfo[$s])) {
                    $dirs[$t.Directory.ToLowerInvariant()] = $t.Directory
                    $placed.Add([pscustomobject]@{ TargetPath = $t.TargetPath; SizeBytes = $t.SizeBytes })
                }
            }
            foreach ($d in $dirs.Values) {
                $probe = Test-AgRemotePath -Instance $s -Path $d
                if ($probe.IsDirectory) { Write-AgLog "  [$s] $d exists." SUCCESS; continue }
                try {
                    New-AgRemoteDirectory -Instance $s -Path $d
                } catch {
                    throw @"
Automatic seeding would create database files in '$d' on '$s', and that directory cannot be created there:

  $($_.Exception.Message.Split("`n")[0])

Automatic seeding puts files at the same path as on the primary (or in the secondary's default
directory when the primary's file is in the primary's default directory). Usually the drive simply
does not exist on '$s'. Either give '$s' that drive, or re-run and choose MANUAL seeding, which
lets you choose where every file lands.
"@
                }
                Write-AgLog "  [$s] created $d" SUCCESS
            }
            $free = Get-AgVolumeFreeSpace -Instance $s
            foreach ($v in (Get-AgVolumeDemand -Placements @($placed.ToArray()) -FreeSpace $free)) {
                $msg = "  [$s] $($v.Volume) needs $(Format-AgBytes $v.Bytes) of database files, $(Get-AgFreeSpaceText $v.FreeBytes)"
                if ($v.Fits) { Write-AgLog $msg INFO } else { Write-AgLog ($msg + ' — NOT ENOUGH ROOM') WARN; $warnings.Add("$s $($v.Volume) may not have room for the seeded databases.") }
            }
        }
    }
    #endregion

    #region Prerequisite backup location
    if ($Plan.RepairBackupDirectory -and @($Plan.Repairs | Where-Object { $_.TakeFullBackup }).Count -gt 0) {
        $err = Test-AgShareWritable -Instance $Plan.PrimaryReplica -Path $Plan.RepairBackupDirectory
        if ($err) { throw "The primary cannot write backups to '$($Plan.RepairBackupDirectory)': $err" }
        Write-AgLog "  [$($Plan.PrimaryReplica)] can write to '$($Plan.RepairBackupDirectory)'." SUCCESS
    }
    #endregion

    #region Manual seeding prerequisites
    if ($Plan.SeedingMode -eq 'MANUAL' -and $Plan.Databases.Count -gt 0 -and $Plan.SecondaryReplicas.Count -gt 0) {
        $shares = @(Get-AgPlanShareRoots -Plan $Plan)
        Write-AgLog "Validating $($shares.Count) backup share(s) from every replica..." INFO
        foreach ($share in $shares) {
            foreach ($r in $replicas) {
                $err = Test-AgShareWritable -Instance $r -Path $share
                if ($err) {
                    throw @"
Replica '$r' cannot write to '$share'.

  $err

The SQL Server service account on every replica needs read and write access (full control is
simplest) to the backup share: the primary writes the backups, every secondary reads them.
"@
                }
                Write-AgLog "  [$r] '$share' is readable and writable." SUCCESS
            }
        }

        foreach ($r in $replicas) {
            if ($instanceInfo[$r].AgentStatus -ne 'Running') {
                throw "SQL Server Agent is '$($instanceInfo[$r].AgentStatus)' on '$r'. Manual seeding schedules a log backup job on every replica."
            }
        }

        Test-AgFileLayoutTarget -Plan $Plan -InstanceInfo $instanceInfo

        $competing = @(Get-AgCompetingLogBackup -Instance $Plan.PrimaryReplica -Databases $Plan.Databases -ShareRoot $Plan.ShareRoot)
        if ($competing.Count -gt 0) {
            Write-Host ''
            Write-AgLog 'Another process is taking transaction log backups of these databases to a different location:' WARN
            foreach ($c in $competing) {
                Write-AgLog ("  {0}: {1} log backup(s) in the last 24h, most recently {2}" -f $c.DatabaseName, $c.BackupCount, $c.LastBackup) WARN
                Write-AgLog ("      e.g. {0}" -f $c.SampleDevice) WARN
            }
            Write-AgLog 'Those backups take log records the secondaries need. Unless they are paused while each' WARN
            Write-AgLog 'database seeds, the restore will fail with a log chain gap (error 4305).' WARN
            $warnings.Add('Competing transaction log backup jobs were detected on the primary.')
        }
    }
    #endregion

    #region Listener
    if ($Plan.Operation -eq 'CREATE' -and $Plan.Listener -and $Plan.Listener.Create) {
        foreach ($a in $Plan.Listener.Addresses) {
            if (Test-AgIpInUse -Address $a.IpAddress) {
                $already = $agExists -and @((Get-AgTopology -Instance $Plan.PrimaryReplica -AgName $Plan.AgName -AllowNoPrimary).Listeners |
                            ForEach-Object { $_.Addresses } | Where-Object { $_.IpAddress -eq $a.IpAddress }).Count -gt 0
                if (-not $already) { $warnings.Add("Listener address $($a.IpAddress) answers a ping — it looks like it is in use.") }
            }
        }
    }
    #endregion

    #region Summary
    Write-Host ''
    if ($warnings.Count -gt 0) {
        Write-AgLog "Preflight completed with $($warnings.Count) warning(s):" WARN
        $warnings | ForEach-Object { Write-AgLog "  - $_" WARN }
        Write-Host ''
        if (-not (Read-AgYesNo -Question 'Continue anyway?' -DefaultYes $false)) {
            throw 'Aborted by operator after preflight warnings.'
        }
    } else {
        Write-AgLog 'Preflight passed with no warnings.' SUCCESS
    }
    #endregion

    return $instanceInfo
}
