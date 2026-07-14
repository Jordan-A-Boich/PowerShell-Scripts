#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 01: gather every decision up front and produce the plan.

.DESCRIPTION
    All user interaction lives here. Once this step returns, the rest of the run is
    unattended: no step below this one prompts. Wherever the set of valid answers can
    be discovered from the servers, the operator picks a number rather than typing.
#>

Set-StrictMode -Version Latest

function Get-DagDomainCandidate {
    <#
    .SYNOPSIS
        Infers the DNS domain from the replicas' endpoint URLs
        (e.g. TCP://NODE1.CONTOSO.COM:5022 -> CONTOSO.COM).
    #>
    param([Parameter(Mandatory)][psobject[]]$Topologies)

    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Topologies) {
        foreach ($r in $t.Replicas) {
            if ($r.EndpointUrl -match '^TCP://([^:/]+)') {
                $hostName = $Matches[1]
                $dot = $hostName.IndexOf('.')
                if ($dot -gt 0) {
                    $d = $hostName.Substring($dot + 1)
                    if ($d -and -not $domains.Contains($d)) { $domains.Add($d) }
                }
            }
        }
    }
    return @($domains.ToArray())
}

function Select-DagSeedInstance {
    param(
        [Parameter(Mandatory)][string]$RoleLabel,
        [Parameter(Mandatory)][string]$Hint
    )
    while ($true) {
        $inst = Read-DagText -Prompt "Enter ANY replica of the $RoleLabel availability group (server or SERVER\INSTANCE)"
        Write-Host "  Connecting to $inst ..." -ForegroundColor DarkGray
        if (-not (Test-DagConnection -Instance $inst)) {
            Write-Host "  Could not connect to '$inst'. Check the name, that SQL Server is running, and that your credentials are valid." -ForegroundColor Yellow
            continue
        }
        $info = Get-DagInstanceInfo -Instance $inst
        if (-not $info.IsHadrEnabled) {
            Write-Host "  '$inst' does not have Always On availability groups enabled." -ForegroundColor Yellow
            continue
        }
        if (-not $info.IsSysadmin) {
            Write-Host "  The connected login is not a sysadmin on '$inst'. Distributed AG configuration requires sysadmin." -ForegroundColor Yellow
            continue
        }
        Write-DagLog ("  Connected to {0} — {1} ({2}), domain {3}" -f $info.ServerName, (Get-DagSqlVersionName $info.MajorVersion), $info.ProductVersion, $info.NetbiosDomain) SUCCESS
        Write-Host "  $Hint" -ForegroundColor DarkGray
        return $info
    }
}

function Select-DagAvailabilityGroup {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$RoleLabel,
        [string]$ExcludeAgName
    )
    $ags = @(Get-DagLocalAvailabilityGroups -Instance $Instance)
    if ($ExcludeAgName) { $ags = @($ags | Where-Object { $_.AgName -ne $ExcludeAgName }) }
    if ($ags.Count -eq 0) {
        throw "No (non-distributed) availability groups with a local replica were found on '$Instance'."
    }

    $chosen = Read-DagChoice -Title "Which availability group is the ${RoleLabel}?" -Items $ags -Display {
        param($a) '{0}  ({1} replicas, {2} database(s), this node is {3})' -f $a.AgName, $a.ReplicaCount, $a.DatabaseCount, $a.LocalRole
    }
    return $chosen.AgName
}

function Select-DagListener {
    param(
        [Parameter(Mandatory)][psobject]$Topology,
        [Parameter(Mandatory)][string]$RoleLabel
    )
    if ($Topology.Listeners.Count -eq 0) {
        throw @"
Availability group '$($Topology.AgName)' has no listener.
A distributed availability group addresses each member AG through its listener, so both
availability groups must have one before they can be joined. Create a listener on
'$($Topology.AgName)' and re-run.
"@
    }
    if ($Topology.Listeners.Count -eq 1) { return $Topology.Listeners[0] }

    return Read-DagChoice -Title "Which listener should the distributed AG use to reach the $RoleLabel AG '$($Topology.AgName)'?" `
        -Items $Topology.Listeners -Display { param($l) '{0} (port {1})' -f $l.DnsName, $l.Port } -DefaultIndex 0
}

function New-DagPlan {
    <#
    .OUTPUTS
        The fully-populated plan object.
    #>

    Write-DagBanner 'STEP 1 of 7 — BUILD THE PLAN'
    Write-Host 'Everything is asked now. Once the plan is confirmed the run is unattended.' -ForegroundColor DarkGray

    #region Global primary side
    $gpInfo = Select-DagSeedInstance -RoleLabel 'GLOBAL PRIMARY (the AG that owns the read/write databases today)' `
                                     -Hint 'This is the side your databases live on now.'
    $gpAgName = Select-DagAvailabilityGroup -Instance $gpInfo.Instance -RoleLabel 'GLOBAL PRIMARY availability group'
    $gpTopo   = Get-DagAgTopology -Instance $gpInfo.Instance -AgName $gpAgName

    # Re-anchor on the actual primary: DAG creation must run there, not on whichever
    # replica the operator happened to name.
    $gpPrimary = $gpTopo.PrimaryReplica
    if ($gpPrimary -ne $gpInfo.Instance) {
        Write-DagLog "  Primary replica of '$gpAgName' is $gpPrimary — using it for all primary-side operations." INFO
    }
    $gpPrimaryInfo = Get-DagInstanceInfo -Instance $gpPrimary
    #endregion

    #region Forwarder side
    $fwInfo = Select-DagSeedInstance -RoleLabel 'FORWARDER (the AG that will receive the databases)' `
                                     -Hint 'This is the destination side.'
    $fwAgName = Select-DagAvailabilityGroup -Instance $fwInfo.Instance -RoleLabel 'FORWARDER availability group' -ExcludeAgName $gpAgName
    $fwTopo   = Get-DagAgTopology -Instance $fwInfo.Instance -AgName $fwAgName
    $fwPrimary = $fwTopo.PrimaryReplica
    $fwPrimaryInfo = Get-DagInstanceInfo -Instance $fwPrimary
    #endregion

    if ($gpAgName -eq $fwAgName) { throw 'The global primary and forwarder must be two different availability groups.' }

    #region Version direction
    $gMajor = $gpPrimaryInfo.MajorVersion
    $fMajor = $fwPrimaryInfo.MajorVersion

    if ($fMajor -lt $gMajor) {
        throw @"
Unsupported version direction.

  Global primary AG '$gpAgName' runs $(Get-DagSqlVersionName $gMajor).
  Forwarder AG     '$fwAgName' runs $(Get-DagSqlVersionName $fMajor).

A distributed availability group moves databases from the global primary to the forwarder,
and a SQL Server database can never be restored or seeded onto an OLDER major version.
The forwarder must be the same major version as the global primary, or newer.

If you meant to migrate in the other direction, re-run and nominate '$fwAgName' as the
global primary.
"@
    }

    $crossVersion = $fMajor -gt $gMajor
    if ($crossVersion) {
        Write-Host ''
        Write-Host 'Cross-version distributed availability group' -ForegroundColor Yellow
        Write-Host "  Global primary '$gpAgName': $(Get-DagSqlVersionName $gMajor)" -ForegroundColor DarkGray
        Write-Host "  Forwarder      '$fwAgName': $(Get-DagSqlVersionName $fMajor)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  What to expect once seeding finishes:' -ForegroundColor DarkGray
        Write-Host '    - Databases on the forwarder show as Recovering / Synchronizing (or Synchronized)' -ForegroundColor DarkGray
        Write-Host '      and are not readable, because they have not been upgraded yet.' -ForegroundColor DarkGray
        Write-Host '    - The distributed AG may report as less than fully healthy for the same reason.' -ForegroundColor DarkGray
        Write-Host '    - With AUTOMATIC seeding the forwarder''s own SECONDARY replicas stay empty until' -ForegroundColor DarkGray
        Write-Host '      failover: the forwarder primary cannot seed a database it cannot bring online.' -ForegroundColor DarkGray
        Write-Host '      Choose MANUAL seeding if they must hold the databases beforehand.' -ForegroundColor DarkGray
        Write-Host '    - Data keeps flowing. These states resolve when you fail the DAG over to the' -ForegroundColor DarkGray
        Write-Host "      newer version, at which point the databases are upgraded to $(Get-DagSqlVersionName $fMajor)." -ForegroundColor DarkGray
        Write-Host '    - Failing back to the older version will not be possible after that.' -ForegroundColor DarkGray
        Write-Host ''
    }
    #endregion

    #region Domain + listeners
    $domains = @(Get-DagDomainCandidate -Topologies @($gpTopo, $fwTopo))
    $domainItems = @($domains) + @('Enter a different domain manually')
    $domain = Read-DagChoice -Title 'Which DNS domain should be used to build fully-qualified listener names?' `
                -Items $domainItems -DefaultIndex 0 `
                -Hint 'Discovered from the availability group endpoint URLs.'
    if ($domain -eq 'Enter a different domain manually') {
        $domain = Read-DagText -Prompt 'DNS domain (e.g. contoso.com)' -Validate { param($v) $v -match '^[A-Za-z0-9.-]+$' } `
                    -ValidationMessage 'Enter a DNS domain such as contoso.com.'
    }

    $gpListener = Select-DagListener -Topology $gpTopo -RoleLabel 'GLOBAL PRIMARY'
    $fwListener = Select-DagListener -Topology $fwTopo -RoleLabel 'FORWARDER'

    $gpEndpoint = Get-DagEndpointInfo -Instance $gpPrimary
    $fwEndpoint = Get-DagEndpointInfo -Instance $fwPrimary
    if (-not $gpEndpoint) { throw "No database mirroring (Hadr) endpoint exists on '$gpPrimary'." }
    if (-not $fwEndpoint) { throw "No database mirroring (Hadr) endpoint exists on '$fwPrimary'." }

    # A distributed AG's LISTENER_URL targets the endpoint port, not the listener's TDS port.
    $gpListenerUrl = 'TCP://{0}.{1}:{2}' -f $gpListener.DnsName, $domain, $gpEndpoint.Port
    $fwListenerUrl = 'TCP://{0}.{1}:{2}' -f $fwListener.DnsName, $domain, $fwEndpoint.Port
    #endregion

    #region DAG name
    $defaultDagName = 'DistAG_{0}_{1}' -f $gpAgName, $fwAgName
    $dagName = Read-DagText -Prompt 'Name for the distributed availability group' -Default $defaultDagName `
                -Validate { param($v) $v.Length -le 128 -and $v -notmatch '^\s*$' } `
                -ValidationMessage 'Enter a name of 128 characters or fewer.'
    #endregion

    #region Seeding mode
    $seedChoice = Read-DagChoice -Title 'How should the databases be moved to the forwarder?' -Items @(
        'AUTOMATIC seeding - SQL Server streams each database over the endpoints. No backup share required.'
        'MANUAL seeding - backup to a share, restore on the forwarder, then join. Better for very large databases or slow links.'
    ) -DefaultIndex 0
    $seedingMode = if ($seedChoice -like 'AUTOMATIC*') { 'AUTOMATIC' } else { 'MANUAL' }

    $shareRoot = $null; $stripeCount = 4; $tlogInterval = 15
    if ($seedingMode -eq 'MANUAL') {
        $shareRoot = Read-DagText -Prompt 'UNC path of the backup share (readable and writable by the SQL service account on BOTH sides)' `
                        -Validate { param($v) $v -match '^\\\\[^\\]+\\[^\\]+' } `
                        -ValidationMessage 'Enter a UNC path such as \\fileserver\SQLBackups.'
        $shareRoot = $shareRoot.TrimEnd('\')

        $stripeCount = [int](Read-DagChoice -Title 'How many files should the FULL backup be striped across?' `
                        -Items @(2, 4, 8, 16) -DefaultIndex 1 -Hint 'More stripes usually means faster backup and restore for large databases.')

        $tlogInterval = [int](Read-DagChoice -Title 'How often should transaction logs be backed up while seeding runs?' `
                        -Items @(5, 10, 15, 30) -DefaultIndex 2 -Hint 'A log backup job is created on the global primary AG for the duration of the seed.')
    }
    #endregion

    #region Database selection
    Write-Host ''
    Write-Host "Discovering databases on the global primary ($gpPrimary)..." -ForegroundColor DarkGray
    $candidates = @(Get-DagCandidateDatabases -Instance $gpPrimary -AgName $gpAgName)

    if ($candidates.Count -eq 0) { throw "No user databases were found on '$gpPrimary'." }

    $ineligible = @($candidates | Where-Object { -not $_.IsEligible })
    if ($ineligible.Count -gt 0) {
        Write-Host ''
        Write-Host 'These databases cannot participate and are excluded automatically:' -ForegroundColor Yellow
        foreach ($d in $ineligible) {
            Write-Host ("   {0,-40} {1}" -f $d.DatabaseName, $d.IneligibleWhy) -ForegroundColor DarkGray
        }
    }

    $eligible = @($candidates | Where-Object { $_.IsEligible })
    if ($eligible.Count -eq 0) {
        throw "None of the user databases on '$gpPrimary' are eligible to join an availability group."
    }

    $selected = Read-DagExclusion -Title 'Databases to include in the distributed availability group:' -Items $eligible -Display {
        param($d)
        $where = if ($d.InThisAg) { "already in $gpAgName" } else { "will be ADDED to $gpAgName" }
        '{0,-40} {1,10}  {2}' -f $d.DatabaseName, (Format-DagBytes $d.SizeBytes), $where
    }
    #endregion

    #region File layout on the restore targets
    <#
        Only manual seeding restores anything, so only manual seeding has a say in where
        the files land: automatic seeding is SQL Server streaming the database, and it
        places the files itself.

        The forwarder replicas are always restored onto. A global secondary joins them
        only when a selected database has yet to be added to the global primary AG, since
        manual seeding has to restore it there first.
    #>
    $fileLayoutMode = 'SOURCE'
    $fileLayout     = @()
    if ($seedingMode -eq 'MANUAL') {
        $restoreTargets = @($fwTopo.Replicas | ForEach-Object { $_.ReplicaServerName })
        if (@($selected | Where-Object { -not $_.InThisAg }).Count -gt 0) {
            $restoreTargets += @($gpTopo.SecondaryReplicas)
        }
        $restoreTargets = @($restoreTargets | Select-Object -Unique)

        $layout = New-DagFileLayoutPlan -SourceInstance $gpPrimary `
                    -Databases @($selected | ForEach-Object { $_.DatabaseName }) `
                    -RestoreTargets $restoreTargets
        $fileLayoutMode = $layout.Mode
        $fileLayout     = @($layout.Entries)
    }
    #endregion

    $plan = [pscustomobject]@{
        DagName                 = $dagName
        Domain                  = $domain
        CreatedUtc              = (Get-Date).ToUniversalTime().ToString('o')

        GlobalAgName            = $gpAgName
        GlobalPrimaryReplica    = $gpPrimary
        GlobalReplicas          = @($gpTopo.Replicas | ForEach-Object { $_.ReplicaServerName })
        GlobalSecondaries       = @($gpTopo.SecondaryReplicas)
        GlobalListenerUrl       = $gpListenerUrl
        GlobalMajorVersion      = $gMajor

        ForwarderAgName         = $fwAgName
        ForwarderPrimaryReplica = $fwPrimary
        ForwarderReplicas       = @($fwTopo.Replicas | ForEach-Object { $_.ReplicaServerName })
        ForwarderSecondaries    = @($fwTopo.SecondaryReplicas)
        ForwarderListenerUrl    = $fwListenerUrl
        ForwarderMajorVersion   = $fMajor

        IsCrossVersion          = $crossVersion
        SeedingMode             = $seedingMode
        ShareRoot               = $shareRoot
        StripeCount             = $stripeCount
        TLogIntervalMinutes     = $tlogInterval
        FileLayoutMode          = $fileLayoutMode
        FileLayout              = @($fileLayout)

        Databases               = @($selected | ForEach-Object { $_.DatabaseName })
        Progress                = @()
    }

    $plan.Progress = @($plan.Databases | ForEach-Object { New-DagProgressRecord -DatabaseName $_ })
    return $plan
}

function Show-DagPlanSummary {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-DagBanner 'PLAN'

    Write-Host 'Distributed availability group' -ForegroundColor White
    Write-Host "  Name                : $($Plan.DagName)"
    Write-Host "  Seeding             : $($Plan.SeedingMode)"
    Write-Host "  DNS domain          : $($Plan.Domain)"
    Write-Host ''
    Write-Host "Global primary AG '$($Plan.GlobalAgName)'  [$(Get-DagSqlVersionName $Plan.GlobalMajorVersion)]" -ForegroundColor White
    Write-Host "  Primary replica     : $($Plan.GlobalPrimaryReplica)"
    Write-Host "  Replicas            : $($Plan.GlobalReplicas -join ', ')"
    Write-Host "  Listener URL        : $($Plan.GlobalListenerUrl)"
    Write-Host ''
    Write-Host "Forwarder AG '$($Plan.ForwarderAgName)'  [$(Get-DagSqlVersionName $Plan.ForwarderMajorVersion)]" -ForegroundColor White
    Write-Host "  Primary replica     : $($Plan.ForwarderPrimaryReplica)"
    Write-Host "  Replicas            : $($Plan.ForwarderReplicas -join ', ')"
    Write-Host "  Listener URL        : $($Plan.ForwarderListenerUrl)"

    if ($Plan.SeedingMode -eq 'MANUAL') {
        Write-Host ''
        Write-Host 'Manual seeding' -ForegroundColor White
        Write-Host "  Backup share        : $($Plan.ShareRoot)"
        Write-Host "  FULL backup stripes : $($Plan.StripeCount)"
        Write-Host "  Log backup interval : every $($Plan.TLogIntervalMinutes) minutes"
        Show-DagFileLayoutSummary -Plan $Plan
    }

    Write-Host ''
    Write-Host "Databases ($($Plan.Databases.Count))" -ForegroundColor White
    foreach ($d in $Plan.Databases) { Write-Host "  - $d" }
    Write-Host ''
}
