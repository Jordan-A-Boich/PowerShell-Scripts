#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — removing databases from an availability group.

.DESCRIPTION
    Two scopes:
      ENTIRE     ALTER AVAILABILITY GROUP ... REMOVE DATABASE on the primary. The primary copy
                 stays ONLINE and in use; every secondary copy drops to RESTORING.
      SECONDARY  ALTER DATABASE ... SET HADR OFF on chosen secondaries only. The database stays
                 in the AG everywhere else (a secondary being rebuilt, or one short of disk).

    What happens to each secondary copy afterwards is the operator's choice: leave it in
    RESTORING (it can rejoin quickly, as long as the primary's log has not been truncated
    past it), drop it, or recover it as an independent read-write database.

    The primary copy is never dropped — that would be deleting the data, not removing it from
    an availability group.
#>

Set-StrictMode -Version Latest

function Get-AgRemovalCandidates {
    param(
        [Parameter(Mandatory)][string]$PrimaryInstance,
        [Parameter(Mandatory)][string]$AgName,
        [bool]$IsContained
    )
    $health = @(Get-AgDatabaseHealth -Instance $PrimaryInstance -AgName $AgName)
    $sysDbs = if ($IsContained) { @(Get-AgContainedSystemDatabaseNames -AgName $AgName) } else { @() }
    $sizes = @{}
    foreach ($r in (Invoke-AgSql -Instance $PrimaryInstance -Retry -Activity 'database sizes' -Query @'
SELECT d.name AS DatabaseName, SUM(CAST(mf.size AS bigint)) * 8192 AS SizeBytes
FROM sys.databases AS d JOIN sys.master_files AS mf ON mf.database_id = d.database_id
GROUP BY d.name
'@)) { $sizes[[string]$r.DatabaseName] = [long]$r.SizeBytes }

    return @($health | Group-Object DatabaseName | Where-Object { $sysDbs -notcontains $_.Name } | ForEach-Object {
        $rows = $_.Group
        $secs = @($rows | Where-Object { -not $_.IsPrimary })
        [pscustomobject]@{
            DatabaseName = $_.Name
            SizeBytes    = if ($sizes.ContainsKey($_.Name)) { $sizes[$_.Name] } else { 0 }
            Summary      = if ($secs.Count) { ($secs | ForEach-Object { "$($_.Replica): $($_.SyncState)" }) -join ', ' } else { 'no secondaries' }
            JoinedOn     = @($secs | Where-Object { $_.SyncState -ne 'NOT JOINED' } | ForEach-Object { $_.Replica })
        }
    })
}

function Get-AgRemovalSql {
    <#
    .SYNOPSIS
        The statements a removal will run, in order, as (Instance, Sql) pairs — shown to the
        operator before anything executes, and what -WhatIf prints.
    #>
    param([Parameter(Mandatory)][psobject]$Removal)

    $out = New-Object System.Collections.Generic.List[psobject]
    $ag  = ConvertTo-AgQuotedName $Removal.AgName
    foreach ($db in $Removal.Databases) {
        $q = ConvertTo-AgQuotedName $db
        if ($Removal.Scope -eq 'ENTIRE') {
            $out.Add([pscustomobject]@{ Instance = $Removal.PrimaryReplica; Sql = "ALTER AVAILABILITY GROUP $ag REMOVE DATABASE $q;" })
        } else {
            foreach ($s in $Removal.Secondaries) {
                $out.Add([pscustomobject]@{ Instance = $s; Sql = "ALTER DATABASE $q SET HADR OFF;" })
            }
        }
        foreach ($s in $Removal.Secondaries) {
            switch ($Removal.CopyAction) {
                'DROP'    { $out.Add([pscustomobject]@{ Instance = $s; Sql = "DROP DATABASE $q;" }) }
                'RECOVER' { $out.Add([pscustomobject]@{ Instance = $s; Sql = "RESTORE DATABASE $q WITH RECOVERY;" }) }
            }
        }
    }
    return @($out.ToArray())
}

function Wait-AgCopyDetached {
    <#
    .SYNOPSIS
        Waits until a secondary's copy has left the AG (group_database_id cleared).
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$DatabaseName
    )
    return Wait-AgCondition -Activity "[$DatabaseName] leaving the AG on $Instance" -TimeoutSeconds 120 -PollSeconds 3 -Condition {
        $st = Get-AgDatabaseState -Instance $Instance -DatabaseName $DatabaseName
        (-not $st) -or (-not $st.IsJoinedToAg)
    }
}

function Invoke-AgRemoveDatabase {
    <#
    .OUTPUTS
        [bool] $true when every database ended up where the operator asked.
    #>
    param([Parameter(Mandatory)][psobject]$Removal)

    $ag  = ConvertTo-AgQuotedName $Removal.AgName
    $allOk = $true

    foreach ($db in $Removal.Databases) {
        Write-AgLog "[$db]" STEP
        $q = ConvertTo-AgQuotedName $db

        #region Out of the AG
        if ($Removal.Scope -eq 'ENTIRE') {
            if (Test-AgDatabaseInAg -Instance $Removal.PrimaryReplica -AgName $Removal.AgName -DatabaseName $db) {
                Invoke-AgSql -Instance $Removal.PrimaryReplica -QueryTimeout 300 -Activity 'remove database' `
                    -Query "ALTER AVAILABILITY GROUP $ag REMOVE DATABASE $q;" | Out-Null
                Write-AgLog "  [$($Removal.PrimaryReplica)] removed [$db] from [$($Removal.AgName)] — it stays ONLINE here." SUCCESS
            } else {
                Write-AgLog "  [$db] is no longer in [$($Removal.AgName)]." SUCCESS
            }
        } else {
            foreach ($s in $Removal.Secondaries) {
                if (Test-AgDatabaseJoinedOnReplica -Instance $s -AgName $Removal.AgName -DatabaseName $db) {
                    Invoke-AgSql -Instance $s -QueryTimeout 300 -Activity 'set hadr off' -Query "ALTER DATABASE $q SET HADR OFF;" | Out-Null
                    Write-AgLog "  [$s] [$db] taken out of [$($Removal.AgName)] on this replica." SUCCESS
                }
            }
        }
        #endregion

        #region Secondary copies
        foreach ($s in $Removal.Secondaries) {
            $st = Get-AgDatabaseState -Instance $s -DatabaseName $db
            if (-not $st) { Write-AgLog "  [$s] has no copy of [$db]." INFO; continue }
            if (-not (Wait-AgCopyDetached -Instance $s -DatabaseName $db)) {
                Write-AgLog "  [$s] [$db] still reports AG membership after 2 minutes; leaving it as it is." WARN
                $allOk = $false; continue
            }
            switch ($Removal.CopyAction) {
                'LEAVE' {
                    $st = Get-AgDatabaseState -Instance $s -DatabaseName $db
                    Write-AgLog "  [$s] [$db] left in $($st.StateDesc)." SUCCESS
                }
                'DROP' {
                    try { Remove-AgDatabaseCopy -Instance $s -DatabaseName $db }
                    catch { Write-AgLog "  [$s] $($_.Exception.Message)" ERROR; $allOk = $false }
                }
                'RECOVER' {
                    try {
                        $st = Get-AgDatabaseState -Instance $s -DatabaseName $db
                        if ($st.StateDesc -ne 'ONLINE') {
                            Invoke-AgLongOp -Instance $s -Activity "RESTORE [$db] WITH RECOVERY on $s" -Query "RESTORE DATABASE $q WITH RECOVERY;"
                        }
                        Write-AgLog "  [$s] [$db] recovered — ONLINE as an independent read-write database." SUCCESS
                    } catch { Write-AgLog "  [$s] could not recover [$db]: $($_.Exception.Message.Split("`n")[0])" ERROR; $allOk = $false }
                }
            }
        }
        #endregion
    }

    #region The manual-seeding log backup job
    if ($Removal.UpdateLogJob) {
        foreach ($r in $Removal.ReplicaNames) {
            $scope = @(Get-AgTLogJobScope -Instance $r -AgName $Removal.AgName)
            if ($scope.Count -eq 0) { continue }
            $remaining = @($scope | Where-Object { $Removal.Databases -notcontains $_ })
            if ($remaining.Count -eq $scope.Count) { continue }
            if ($remaining.Count -eq 0) {
                Uninstall-AgTLogJob -Instances @($r) -AgName $Removal.AgName
            } else {
                $setting = Get-AgTLogJobSetting -Instance $r -AgName $Removal.AgName
                if ($setting -and $setting.ShareRoot) {
                    Install-AgTLogJob -Instance $r -AgName $Removal.AgName -ShareRoot $setting.ShareRoot -Databases $remaining `
                        -IntervalMinutes $setting.IntervalMinutes -ReplaceScope
                } else {
                    Write-AgLog "  [$r] could not read the job's share; leaving its scope as it is." WARN
                }
            }
        }
    }
    #endregion

    return $allOk
}
