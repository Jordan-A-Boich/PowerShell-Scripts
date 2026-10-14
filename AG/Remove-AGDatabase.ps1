#Requires -Version 5.1
<#
.SYNOPSIS
    Remove-AGDatabase — take one or more databases out of an availability group.

.DESCRIPTION
    Connect to any replica, pick the availability group and the databases by number, and
    choose what happens to the secondary copies. The primary copy always stays ONLINE.

      * Scope: the whole availability group (REMOVE DATABASE on the primary), or only chosen
        secondary replicas (SET HADR OFF there; the database stays in the AG elsewhere).
      * Secondary copies: leave them RESTORING (quick to re-join), drop them, or recover
        them as independent read-write databases.
      * Warns when the AG is part of a distributed AG (removal flows on to the forwarder) or
        is contained (listener connections to the database lose the contained logins).
      * Takes the databases out of the toolkit's manual-seeding log backup job, if it has one.
      * Shows the exact statements before running them; -WhatIf stops there.

    Every parameter can be supplied for unattended use; anything left out is asked.

.PARAMETER Instance
    Any replica of the availability group.

.PARAMETER AgName
    The availability group.

.PARAMETER Database
    The database(s) to remove.

.PARAMETER SecondaryReplica
    Remove only from these secondary replicas, leaving the database in the AG elsewhere.

.PARAMETER SecondaryCopies
    LEAVE (default when asked), DROP or RECOVER the secondary copies.

.PARAMETER Credential
    A SQL Server login used for every connection.

.PARAMETER Force
    Skip the final confirmation.

.EXAMPLE
    .\Remove-AGDatabase.ps1

.EXAMPLE
    .\Remove-AGDatabase.ps1 -Instance SQLLAB-SQL3 -AgName AG1 -Database Sales01,Sales02 -SecondaryCopies DROP -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Instance,
    [string]$AgName,
    [string[]]$Database,
    [string[]]$SecondaryReplica,
    [ValidateSet('LEAVE','DROP','RECOVER')]
    [string]$SecondaryCopies,
    [pscredential]$Credential,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$SharedDir  = Join-Path $ScriptRoot 'steps\_shared'
$StepsDir   = Join-Path $ScriptRoot 'steps'

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw @'
The SqlServer PowerShell module is required and was not found.

    Install-Module -Name SqlServer -Scope CurrentUser
'@
}
Import-Module SqlServer -DisableNameChecking -ErrorAction Stop

foreach ($file in @(
        'AgCommon.ps1', 'AgSql.ps1', 'AgPrompt.ps1', 'AgDiscovery.ps1', 'AgCluster.ps1', 'AgDatabase.ps1',
        'AgFileOps.ps1', 'AgAgentJob.ps1', 'AgHealth.ps1'
    )) { . (Join-Path $SharedDir $file) }
. (Join-Path $StepsDir '01Interview.ps1')
. (Join-Path $StepsDir '09RemoveDatabase.ps1')

try {
    Initialize-AgLog -LogDirectory (Join-Path $ScriptRoot 'logs') -NamePrefix 'Remove-AGDatabase' | Out-Null
    Write-AgBanner 'REMOVE DATABASES FROM AN AVAILABILITY GROUP'

    if ($Credential) {
        Set-AgConnectionContext -Credential $Credential
        Write-AgLog "Authentication: SQL login '$($Credential.UserName)' (supplied by -Credential)" INFO
    } else {
        Read-AgCredential
    }

    $sel  = Select-AgExistingAg -Instance $Instance -AgName $AgName -Purpose 'remove databases from'
    $topo = $sel.Topology
    $p    = $topo.PrimaryReplica

    #region Which databases
    $candidates = @(Get-AgRemovalCandidates -PrimaryInstance $p -AgName $topo.AgName -IsContained $topo.IsContained)
    if ($candidates.Count -eq 0) { throw "[$($topo.AgName)] holds no user databases." }

    if ($Database) {
        $missing = @($Database | Where-Object { @($candidates | ForEach-Object { $_.DatabaseName }) -notcontains $_ })
        if ($missing.Count -gt 0) { throw "Not in [$($topo.AgName)]: $($missing -join ', '). It holds: $(($candidates | ForEach-Object { $_.DatabaseName }) -join ', ')." }
        $chosen = @($candidates | Where-Object { $Database -contains $_.DatabaseName })
    } else {
        $width = [math]::Max(16, (@($candidates | ForEach-Object { $_.DatabaseName.Length }) | Measure-Object -Maximum).Maximum + 2)
        $chosen = @(Read-AgSelection -Title "Which databases should be removed from [$($topo.AgName)]?" -Items $candidates -Default '' -Display {
            param($d) ('{0,-' + $width + '} {1,10}  {2}') -f $d.DatabaseName, (Format-AgBytes $d.SizeBytes), $d.Summary
        })
    }
    $dbs = @($chosen | ForEach-Object { $_.DatabaseName })
    #endregion

    #region Scope
    $scope = 'ENTIRE'
    $secs  = @($topo.SecondaryReplicas)
    if ($SecondaryReplica) {
        $bad = @($SecondaryReplica | Where-Object { $topo.SecondaryReplicas -notcontains $_ })
        if ($bad.Count -gt 0) { throw "Not a secondary replica of [$($topo.AgName)]: $($bad -join ', ')." }
        $scope = 'SECONDARY'; $secs = @($SecondaryReplica)
    } elseif (-not $Database -and $topo.SecondaryReplicas.Count -gt 0) {
        $s = Read-AgChoice -Title 'Remove them from where?' -DefaultIndex 0 -Items @(
            'The whole availability group — the primary copy stays ONLINE, the secondaries stop receiving changes'
            'Only specific SECONDARY replicas — the database stays in the AG on the others'
        )
        if ($s -like 'Only*') {
            $scope = 'SECONDARY'
            $secs = @(Read-AgSelection -Title 'From which secondary replicas?' -Items @($topo.SecondaryReplicas) -Default '')
        }
    }
    #endregion

    #region Secondary copies
    $action = $SecondaryCopies
    if (-not $action -and $secs.Count -gt 0) {
        if ($Database) { $action = 'LEAVE' }
        else {
            $a = Read-AgChoice -Title 'What should happen to the copies on the secondary replicas?' -DefaultIndex 0 -Items @(
                'LEAVE them in RESTORING — they can rejoin quickly while the primary still has the log they need'
                'DROP them — frees the disk space; adding the database back means seeding it again'
                'RECOVER them — each becomes an independent, read-write database (a point-in-time copy)'
            )
            $action = ($a -split ' ')[0]
        }
    }
    if (-not $action) { $action = 'LEAVE' }
    #endregion

    #region Warnings
    $dags = @(Get-AgDistributedParent -Instance $p -AgName $topo.AgName)
    if ($dags.Count -gt 0 -and $scope -eq 'ENTIRE') {
        Write-Host ''
        Write-AgLog "[$($topo.AgName)] is a member of distributed AG(s) $($dags -join ', '). Removing a database from the global primary AG removes it from the forwarder AG as well." WARN
    }
    if ($topo.IsContained -and $scope -eq 'ENTIRE') {
        Write-AgLog "[$($topo.AgName)] is a contained AG: once removed, these databases are no longer reachable through its listener with the contained AG's logins." WARN
    }
    $jobScope = @()
    foreach ($r in $topo.Replicas) { $jobScope += @(Get-AgTLogJobScope -Instance $r.ReplicaServerName -AgName $topo.AgName) }
    $updateJob = (@($jobScope | Where-Object { $dbs -contains $_ }).Count -gt 0) -and $scope -eq 'ENTIRE'
    #endregion

    $removal = [pscustomobject]@{
        AgName         = $topo.AgName
        PrimaryReplica = $p
        ReplicaNames   = @($topo.Replicas | ForEach-Object { $_.ReplicaServerName })
        Databases      = $dbs
        Scope          = $scope
        Secondaries    = $secs
        CopyAction     = $action
        UpdateLogJob   = $updateJob
    }

    #region Show, confirm, run
    Write-AgBanner 'PLAN'
    Write-Host "Availability group : [$($topo.AgName)]   primary $p" -ForegroundColor White
    Write-Host "Databases          : $($dbs -join ', ')"
    Write-Host "Scope              : $(if ($scope -eq 'ENTIRE') { 'the whole availability group' } else { 'only ' + ($secs -join ', ') })"
    Write-Host "Secondary copies   : $action$(if ($secs.Count) { ' on ' + ($secs -join ', ') } else { '' })"
    if ($updateJob) { Write-Host "Log backup job     : these databases are taken out of '$(Get-AgTLogJobName -AgName $topo.AgName)'" }
    Write-Host ''
    Write-Host 'Statements, in order:' -ForegroundColor White
    foreach ($s in (Get-AgRemovalSql -Removal $removal)) { Write-Host ("  [{0}]  {1}" -f $s.Instance, $s.Sql) -ForegroundColor DarkGray }
    Write-Host ''

    if ($WhatIfPreference) { Write-AgLog 'WhatIf: nothing was changed.' INFO; return }
    if (-not $Force -and -not (Read-AgYesNo -Question 'Remove these databases now?' -DefaultYes $false)) {
        Write-AgLog 'Aborted by operator.' WARN
        return
    }

    $ok = Invoke-AgRemoveDatabase -Removal $removal

    if ($scope -eq 'ENTIRE') {
        foreach ($db in $dbs) {
            if (Test-AgDatabaseInAg -Instance $p -AgName $topo.AgName -DatabaseName $db) { $ok = $false; Write-AgLog "[$db] is still in [$($topo.AgName)]." ERROR }
            $st = Get-AgDatabaseState -Instance $p -DatabaseName $db
            if (-not $st -or $st.StateDesc -ne 'ONLINE') { $ok = $false; Write-AgLog "[$db] is not ONLINE on the primary $p." ERROR }
        }
    }
    $expected = if ($scope -eq 'SECONDARY') { @(foreach ($db in $dbs) { foreach ($s in $secs) { "$db|$s" } }) } else { @() }
    $healthy = Show-AgHealthRollup -PrimaryInstance $p -AgName $topo.AgName -SettleSeconds 60 -ExpectedNotJoined $expected
    #endregion

    if (-not $ok -or -not $healthy) {
        Write-AgLog 'Finished with problems (see above).' WARN
        exit 1
    }
    Write-AgLog "Removed $($dbs.Count) database(s) from [$($topo.AgName)]." SUCCESS
}
catch {
    Write-Host ''
    Write-AgLog $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-AgLog $_.ScriptStackTrace DEBUG }
    exit 1
}
