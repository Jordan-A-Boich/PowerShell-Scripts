#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Failover — Step 1: work out which distributed AG to fail over, and which way round.

.DESCRIPTION
    A saved plan from Initialize-DAG.ps1 is used only as a source of instance NAMES. Which
    member availability group currently holds the primary role is always re-derived from the
    servers, because that is precisely the thing a failover changes: run this script twice
    against a plan written before the first failover and a tool that trusted the file would
    fail the DAG over in the direction it has already gone.
#>

Set-StrictMode -Version Latest

function Get-DagListenerDnsName {
    <#
    .SYNOPSIS
        The DNS name out of a member AG's listener URL ('TCP://name.domain:5022' -> 'name.domain').
    .DESCRIPTION
        Offered as the default when the user must name an instance on the far side: the
        listener resolves to whichever replica currently holds that AG's primary role, which
        is exactly the instance we want to talk to.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ListenerUrl)
    if ($ListenerUrl -match '^\s*(?:TCP://)?([^:/]+)') { return $Matches[1] }
    return ''
}

function Select-DagFailoverTarget {
    <#
    .SYNOPSIS
        Returns @{ DagName; CandidateInstances[] } — enough for New-DagFailoverContext to
        resolve the live topology itself.
    #>
    param([string]$StateDirectory)

    $saved = @()
    if ($StateDirectory -and (Test-Path $StateDirectory)) {
        foreach ($f in (Get-ChildItem -Path $StateDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $p = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ($p -and $p.PSObject.Properties.Name -contains 'DagName') { $saved += $p }
        }
    }

    $items = @()
    foreach ($p in $saved) { $items += $p }
    $items += 'Specify the servers myself'

    $pick = Read-DagChoice -Title 'Which distributed availability group do you want to fail over?' -Items $items -Display {
        param($p)
        if ($p -is [string]) { return $p }
        '{0}   (members: {1} and {2})' -f $p.DagName, $p.GlobalAgName, $p.ForwarderAgName
    } -Hint 'Saved plans supply the server names only. Which side is currently primary is read from the servers.' `
      -DefaultIndex $(if ($saved.Count -gt 0) { 0 } else { -1 })

    if ($pick -isnot [string]) {
        $candidates = @()
        foreach ($prop in 'GlobalReplicas','ForwarderReplicas') {
            if ($pick.PSObject.Properties.Name -contains $prop -and $pick.$prop) { $candidates += @($pick.$prop) }
        }
        $candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)
        if ($candidates.Count -eq 0) { throw "The saved plan for [$($pick.DagName)] lists no replicas." }
        return [pscustomobject]@{ DagName = [string]$pick.DagName; CandidateInstances = $candidates }
    }

    #region Manual: seed instance -> discover its DAGs -> find the far side
    $seed = Read-DagText -Prompt 'Name of ANY SQL Server instance that is part of the distributed availability group' `
        -Validate { param($v) Test-DagConnection -Instance $v } `
        -ValidationMessage 'Could not connect to that instance with the credentials supplied.'

    $dags = @(Get-DagDistributedAgNames -Instance $seed)
    if ($dags.Count -eq 0) { throw "No distributed availability group exists on '$seed'." }

    $dagName = Read-DagChoice -Title "Which distributed availability group on '$seed'?" -Items $dags -DefaultIndex 0

    # The far side's member AG and its listener are both readable from here, even though its
    # role is not. The listener DNS name is the best default we can offer for "an instance
    # over there": it resolves to that AG's current primary.
    $local  = Get-DagMemberRoleOnInstance -Instance $seed -DagName $dagName
    $state  = @(Get-DagDistributedAgState -Instance $seed -DagName $dagName)
    $far    = @($state | Where-Object { $_.MemberAg -ne $local.MemberAg })
    if ($far.Count -ne 1) { throw "[$dagName] on '$seed' does not have exactly two member availability groups." }

    $suggest = Get-DagListenerDnsName -ListenerUrl $far[0].ListenerUrl
    Write-Host ''
    Write-Host ("'{0}' hosts member AG '{1}'. The other member is '{2}'." -f $seed, $local.MemberAg, $far[0].MemberAg) -ForegroundColor DarkGray

    $other = Read-DagText -Prompt "Name of any SQL Server instance in '$($far[0].MemberAg)'" `
        -Default $(if ($suggest) { $suggest } else { $null }) `
        -Validate { param($v) Test-DagConnection -Instance $v } `
        -ValidationMessage 'Could not connect to that instance with the credentials supplied.'

    return [pscustomobject]@{ DagName = $dagName; CandidateInstances = @($seed, $other) }
    #endregion
}

function Show-DagFailoverContext {
    param([Parameter(Mandatory)][psobject]$Context)

    Write-Host ''
    Write-Host 'This is the failover that will be performed:' -ForegroundColor White
    Write-Host ''
    Write-Host ("  Distributed AG    : {0}" -f $Context.DagName)
    Write-Host ''
    Write-Host ("  FROM (primary now): {0}" -f $Context.SourceAgName) -ForegroundColor Yellow
    Write-Host ("      primary replica: {0}  ({1})" -f $Context.SourcePrimary, (Get-DagSqlVersionName $Context.SourceMajorVersion))
    Write-Host ("      replicas       : {0}" -f ($Context.SourceReplicas -join ', '))
    Write-Host ''
    Write-Host ("  TO   (forwarder)  : {0}" -f $Context.TargetAgName) -ForegroundColor Green
    Write-Host ("      primary replica: {0}  ({1})" -f $Context.TargetPrimary, (Get-DagSqlVersionName $Context.TargetMajorVersion))
    Write-Host ("      replicas       : {0}" -f ($Context.TargetReplicas -join ', '))
    Write-Host ''
    Write-Host ("  Databases ({0})    : {1}" -f $Context.Databases.Count, ($Context.Databases -join ', '))
    Write-Host ''
}

function Select-DagResumeTarget {
    <#
    .SYNOPSIS
        Asks which member availability group should take the primary role, when none does.

    .DESCRIPTION
        Reached only when a previous run stopped between the demotion and the failover. In
        that state both members report SECONDARY from their own side and NULL for the remote
        one — nothing anywhere records which of them was demoted, so the script cannot know
        which way the operator was going. It has to ask.

        Both answers are legitimate, and neither loses data: no databases have been upgraded,
        because the upgrade happens when they come ONLINE on the new primary and that never
        happened. Promoting the forwarder finishes the failover; promoting the original
        primary abandons it and puts things back.
    #>
    param(
        [Parameter(Mandatory)][string]$DagName,
        [Parameter(Mandatory)][psobject[]]$Members
    )

    Write-Host ''
    Write-DagBanner 'THIS DISTRIBUTED AVAILABILITY GROUP HAS NO PRIMARY'
    Write-Host ''
    Write-Host '  Both member availability groups report SECONDARY. That is what a failover interrupted' -ForegroundColor Yellow
    Write-Host '  between the demotion and the failover statement leaves behind — and until one of them' -ForegroundColor Yellow
    Write-Host '  takes the primary role, the databases are offline on BOTH sides.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Nothing has been lost. No database has been upgraded, because that only happens when' -ForegroundColor DarkGray
    Write-Host '  they come online on a new primary, and that never happened. Either choice below is safe.' -ForegroundColor DarkGray
    Write-Host ''

    $items = foreach ($m in $Members) {
        $topo = Get-DagAgTopology -Instance $m.Instances[0] -AgName $m.MemberAg
        $info = Get-DagInstanceInfo -Instance $topo.PrimaryReplica
        [pscustomobject]@{
            MemberAg = $m.MemberAg
            Primary  = $topo.PrimaryReplica
            Version  = Get-DagSqlVersionName $info.MajorVersion
        }
    }

    $pick = Read-DagChoice -Title 'Which member availability group should take the PRIMARY role?' -Items @($items) -Display {
        param($i) '{0}   ({1}, primary replica {2})' -f $i.MemberAg, $i.Version, $i.Primary
    } -Hint 'Promoting the forwarder completes the failover. Promoting the original primary abandons it.'

    return $pick.MemberAg
}

function Invoke-DagFailoverContext {
    param([string]$StateDirectory)

    Write-DagBanner 'STEP 1 of 6 — IDENTIFY THE DISTRIBUTED AVAILABILITY GROUP'

    $sel = Select-DagFailoverTarget -StateDirectory $StateDirectory

    Write-DagLog "Reading the live topology of [$($sel.DagName)] from: $($sel.CandidateInstances -join ', ')" INFO
    $inventory = @(Get-DagMemberInventory -DagName $sel.DagName -CandidateInstances $sel.CandidateInstances)

    $target = $null
    if (@($inventory | Where-Object { $_.DagRole -eq 'PRIMARY' }).Count -eq 0) {
        $target = Select-DagResumeTarget -DagName $sel.DagName -Members $inventory
    }

    $ctx = New-DagFailoverContext -DagName $sel.DagName -CandidateInstances $sel.CandidateInstances `
                -Inventory $inventory -TargetAgName $target

    if ($ctx.IsResume) {
        Write-DagLog "Resuming an interrupted failover: [$($ctx.TargetAgName)] will take the PRIMARY role." WARN
    } else {
        Write-DagLog "[$($ctx.SourceAgName)] currently holds the PRIMARY role; [$($ctx.TargetAgName)] is the forwarder." SUCCESS
    }
    Show-DagFailoverContext -Context $ctx
    return $ctx
}
