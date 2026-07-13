#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — Step 04: create the distributed availability group and join the forwarder.

.DESCRIPTION
    Created ASYNCHRONOUS_COMMIT / FAILOVER_MODE = MANUAL, which is what the product
    documentation recommends until you are ready to fail over: synchronous commit across
    two clusters makes every commit on the global primary wait for the forwarder.

    Both statements are guarded by a live check, so re-running after an interruption
    neither re-creates nor re-joins anything.
#>

Set-StrictMode -Version Latest

function Get-DagAvailabilityGroupOnClause {
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][ValidateSet('ASYNCHRONOUS_COMMIT','SYNCHRONOUS_COMMIT')][string]$AvailabilityMode
    )
    @"
AVAILABILITY GROUP ON
    $(ConvertTo-DagQuotedString $Plan.GlobalAgName) WITH
    (
        LISTENER_URL      = $(ConvertTo-DagQuotedString $Plan.GlobalListenerUrl),
        AVAILABILITY_MODE = $AvailabilityMode,
        FAILOVER_MODE     = MANUAL,
        SEEDING_MODE      = $($Plan.SeedingMode)
    ),
    $(ConvertTo-DagQuotedString $Plan.ForwarderAgName) WITH
    (
        LISTENER_URL      = $(ConvertTo-DagQuotedString $Plan.ForwarderListenerUrl),
        AVAILABILITY_MODE = $AvailabilityMode,
        FAILOVER_MODE     = MANUAL,
        SEEDING_MODE      = $($Plan.SeedingMode)
    )
"@
}

function Test-DagJoinedOnForwarder {
    param([Parameter(Mandatory)][psobject]$Plan)
    if (-not (Test-DagIsDistributed -Instance $Plan.ForwarderPrimaryReplica -DagName $Plan.DagName)) { return $false }
    # The DAG row exists on the forwarder only once the JOIN has been executed there.
    $members = @(Get-DagDistributedAgState -Instance $Plan.ForwarderPrimaryReplica -DagName $Plan.DagName)
    return ($members.Count -ge 2)
}

function Set-DagMemberOptions {
    <#
    .SYNOPSIS
        Enforces availability + seeding mode on both member AGs.
        MODIFY AVAILABILITY GROUP ON must be executed on BOTH sides to take effect.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][ValidateSet('ASYNCHRONOUS_COMMIT','SYNCHRONOUS_COMMIT')][string]$AvailabilityMode,
        [switch]$IncludeSeedingMode
    )

    $seedClause = if ($IncludeSeedingMode) { ", SEEDING_MODE = $($Plan.SeedingMode)" } else { '' }

    $sql = @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.DagName)
MODIFY
AVAILABILITY GROUP ON
    $(ConvertTo-DagQuotedString $Plan.GlobalAgName) WITH
    (
        AVAILABILITY_MODE = $AvailabilityMode$seedClause
    ),
    $(ConvertTo-DagQuotedString $Plan.ForwarderAgName) WITH
    (
        AVAILABILITY_MODE = $AvailabilityMode$seedClause
    );
"@

    foreach ($i in @($Plan.GlobalPrimaryReplica, $Plan.ForwarderPrimaryReplica)) {
        Invoke-DagSql -Instance $i -QueryTimeout 300 -Activity 'modify distributed AG' -Query $sql | Out-Null
        Write-DagLog "  [$i] set $AvailabilityMode$(if ($IncludeSeedingMode) { " / SEEDING_MODE = $($Plan.SeedingMode)" }) on [$($Plan.DagName)]" SUCCESS
    }
}

function Invoke-DagCreate {
    param([Parameter(Mandatory)][psobject]$Plan)

    Write-DagBanner 'STEP 4 of 7 — CREATE THE DISTRIBUTED AVAILABILITY GROUP'

    #region Create on the global primary
    if (Test-DagIsDistributed -Instance $Plan.GlobalPrimaryReplica -DagName $Plan.DagName) {
        Write-DagLog "  [$($Plan.GlobalPrimaryReplica)] distributed AG [$($Plan.DagName)] already exists — skipping CREATE." SUCCESS
    } else {
        Write-DagLog "  [$($Plan.GlobalPrimaryReplica)] creating distributed AG [$($Plan.DagName)]..." INFO
        Invoke-DagSql -Instance $Plan.GlobalPrimaryReplica -QueryTimeout 600 -Activity 'create distributed AG' -Query @"
CREATE AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.DagName)
WITH (DISTRIBUTED)
$(Get-DagAvailabilityGroupOnClause -Plan $Plan -AvailabilityMode 'ASYNCHRONOUS_COMMIT');
"@ | Out-Null
        Write-DagLog "  Created [$($Plan.DagName)] on $($Plan.GlobalPrimaryReplica)." SUCCESS
    }
    #endregion

    #region Join from the forwarder
    if (Test-DagJoinedOnForwarder -Plan $Plan) {
        Write-DagLog "  [$($Plan.ForwarderPrimaryReplica)] already joined to [$($Plan.DagName)] — skipping JOIN." SUCCESS
    } else {
        Write-DagLog "  [$($Plan.ForwarderPrimaryReplica)] joining [$($Plan.DagName)]..." INFO
        Invoke-DagSql -Instance $Plan.ForwarderPrimaryReplica -QueryTimeout 600 -Activity 'join distributed AG' -Query @"
ALTER AVAILABILITY GROUP $(ConvertTo-DagQuotedName $Plan.DagName)
JOIN
$(Get-DagAvailabilityGroupOnClause -Plan $Plan -AvailabilityMode 'ASYNCHRONOUS_COMMIT');
"@ | Out-Null
        Write-DagLog "  Joined [$($Plan.ForwarderAgName)] to [$($Plan.DagName)]." SUCCESS
    }
    #endregion

    #region Converge options on both sides
    Set-DagMemberOptions -Plan $Plan -AvailabilityMode 'ASYNCHRONOUS_COMMIT' -IncludeSeedingMode
    #endregion

    #region Wait for the two sides to connect
    $connected = Wait-DagCondition -Activity "distributed AG [$($Plan.DagName)] connecting" -TimeoutSeconds 600 -PollSeconds 10 `
        -Condition {
            $s = @(Get-DagDistributedAgState -Instance $Plan.GlobalPrimaryReplica -DagName $Plan.DagName)
            $fw = @($s | Where-Object { $_.MemberAg -eq $Plan.ForwarderAgName })
            return ($fw.Count -eq 1 -and $fw[0].ConnectedState -eq 'CONNECTED')
        } `
        -ProgressMessage {
            $s = @(Get-DagDistributedAgState -Instance $Plan.GlobalPrimaryReplica -DagName $Plan.DagName)
            ($s | ForEach-Object { "$($_.MemberAg)=$($_.ConnectedState)" }) -join ' '
        }

    if (-not $connected) {
        throw @"
The forwarder availability group did not reach CONNECTED within the timeout.

Most common causes, in order:
  * The listener URL '$($Plan.ForwarderListenerUrl)' does not resolve, or the endpoint port is wrong.
    The LISTENER_URL must use the DATABASE MIRRORING endpoint port (usually 5022), not the listener's TDS port.
  * The SQL Server service accounts do not have CONNECT on the peer endpoints.
  * A firewall is blocking the endpoint port between the two clusters.

Inspect the SQL Server error log on $($Plan.GlobalPrimaryReplica) and $($Plan.ForwarderPrimaryReplica) for detail.
"@
    }
    #endregion

    Write-DagLog "Distributed availability group [$($Plan.DagName)] is created and connected." SUCCESS
}
