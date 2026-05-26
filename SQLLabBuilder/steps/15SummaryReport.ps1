#Requires -Version 5.1
<#
.SYNOPSIS
    Step 15 — Generate build summary report.

IDEMPOTENCY: Safe to run multiple times — always overwrites lab-summary.txt.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$summaryFile = Join-Path $LogPath "lab-summary.txt"

$sqlVersionLabel = "SQL Server $($global:SQLVersion) Evaluation"

$summary = @"
╔══════════════════════════════════════════════════════════╗
║              SQL LAB BUILD COMPLETE                      ║
╚══════════════════════════════════════════════════════════╝

ENVIRONMENT
  Domain:              $DomainName
  Cluster:             $ClusterName ($ClusterIP)
  AG Name:             $AGName
  AG Listener:         ${ListenerName} ($ListenerIP`:$ListenerPort)
  SQL Version:         $sqlVersionLabel
  Lab Root:            $LabRoot

VIRTUAL MACHINES
  $DCComputerName    $DCStaticIP   Domain Controller
  $SQL1ComputerName  $SQL1StaticIP   SQL Primary Replica
  $SQL2ComputerName  $SQL2StaticIP   SQL Secondary Replica

CREDENTIALS
  Windows Admin:       Administrator / $AdminPassword
  Domain Admin:        $NetBIOSName\Administrator / $AdminPassword
  SQL Service Acct:    $SQLSvcAccount / $SQLServiceAccountPassword
  SQL SA Login:        sa / $SAPassword
  SQL Lab Login:       labadmin / $LabAdminPassword

CONNECTING FROM YOUR HOST MACHINE
  SQL Auth (works everywhere — listener and both nodes):
    Server:    $ListenerName,1433  (or $SQL1ComputerName / $SQL2ComputerName for direct)
    Login:     labadmin
    Password:  $LabAdminPassword

  Windows Auth to individual nodes (NTLM via virtual switch):
    Connect directly to $SQL1ComputerName or $SQL2ComputerName.
    NTLM works if SSMS is running as your current Windows user and the host
    can reach the VM over the Hyper-V internal switch (192.168.100.x).

  Windows Auth to the AG Listener:
    The listener requires Kerberos, which needs a domain-joined client.
    From a non-domain host, use SQL auth (labadmin) as shown above.

  Read-intent secondary routing (SQL auth):
    Server: $ListenerName,1433  ApplicationIntent=ReadOnly
    Login:  labadmin   Password: $LabAdminPassword

  No databases are pre-added to the AG — add your own via the primary replica.

HOSTS FILE ENTRIES (already added to $env:SystemRoot\System32\drivers\etc\hosts)
  $DCStaticIP   SQLLAB-DC       SQLLAB-DC.sqllab.local
  $SQL1StaticIP SQLLAB-SQL1     SQLLAB-SQL1.sqllab.local
  $SQL2StaticIP SQLLAB-SQL2     SQLLAB-SQL2.sqllab.local
  $ClusterIP    SQLLabCluster   SQLLabCluster.sqllab.local
  $ListenerIP   SQLLabListener  SQLLabListener.sqllab.local

TEARDOWN
  Run:  .\Start-LabBuild.ps1 -Teardown
  Or:   .\Start-LabBuild.ps1 -Teardown -Force

LOG FILE
  $global:LogFile

GENERATED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

#region Print to console
Write-Host ""
Write-Host $summary -ForegroundColor Cyan
Write-Host ""
#endregion

#region Save to file
$summary | Set-Content -Path $summaryFile -Encoding UTF8 -ErrorAction SilentlyContinue
Write-Log "Summary saved to: $summaryFile" SUCCESS
#endregion

#region Also write passwords to a separate credential file for safe-keeping
$credFile = Join-Path $LogPath "lab-credentials.txt"
$credContent = @"
SQLLabBuilder — Lab Credentials
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
========================================
Windows Admin:         Administrator / $AdminPassword
Domain Admin:          $NetBIOSName\Administrator / $AdminPassword
SQL Service Account:   $SQLSvcAccount / $SQLServiceAccountPassword
SQL SA:                sa / $SAPassword
SQL labadmin login:    labadmin / $LabAdminPassword
========================================
KEEP THIS FILE SECURE — DELETE WHEN LAB IS TORN DOWN
"@
$credContent | Set-Content -Path $credFile -Encoding UTF8 -ErrorAction SilentlyContinue
Write-Log "Credentials also saved to: $credFile" WARN
Write-Log "SECURITY REMINDER: Delete $credFile when the lab is decommissioned." WARN
#endregion

Write-Log "Step 15 complete." SUCCESS
