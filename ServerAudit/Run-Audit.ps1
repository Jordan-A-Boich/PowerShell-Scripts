$config = Get-Content ".\ServerAudit\Config\Servers.json" | ConvertFrom-Json
$Servers = $config.Servers

#Load helper modules

. .\ServerAudit\Modules\New-CheckResult.ps1

$checkFiles = Get-ChildItem ".\ServerAudit\Checks\*.ps1"

foreach($check in $CheckFiles){
    .$check.FullName
}

#Build a unique list for OS related checks so named instances aren't checked twice.
$serversForOSChecks = $Servers | Select-Object -ExpandProperty Name -Unique

$Results = @()


<#
    OS RELATED CHECKS
#>
foreach ($server in $serversForOSChecks) {

    #If OS related, check once, if named instance, run SQL checks per instance.
    $Results += Test-DiskSpace -Server $server
}


<#
    SQL RELATED CHECKS
#>
foreach ($entry in $Servers) {

    $name = $entry.Name
    $instance = $entry.Instance

    # Build instance string
    if ($instance) {
        $sqlInstance = "$name\$instance"
    }
    else {
        $sqlInstance = $name  # default instance
    }

    # SQL checks
    #$Results += Test-SQLBackups -Server $sqlInstance
}

$Results | Format-Table