$config = Get-Content ".\ServerAudit\Config\Servers.json" | ConvertFrom-Json
$Servers = $config.Servers

. .\ServerAudit\Modules\New-CheckResult.ps1

$checkFiles = Get-ChildItem ".\ServerAudit\Checks" -Recurse -Filter "*.ps1"

$CheckRegistry = @()

foreach($check in $CheckFiles){

    . $check.FullName

    if ($CheckMetadata) {

        $CheckRegistry += [PSCustomObject]@{
            Name = $CheckMetadata.Name
            Category = $CheckMetadata.Category
            Function = "Test-" + ($CheckMetadata.Name -replace " ","")
        }

        $CheckMetadata = $null
    }
}

$serversForOSChecks = $Servers | Select-Object -ExpandProperty Name -Unique

$Results = @()

foreach ($check in $CheckRegistry) {

    if ($check.Category -eq "OS") {

        foreach ($server in $serversForOSChecks) {
            $Results += & $check.Function -Server $server
        }
    }

    elseif ($check.Category -eq "SQL") {

        foreach ($entry in $Servers) {

            $name = $entry.Name
            $instance = $entry.Instance

            if ($instance) {
                $sqlInstance = "$name\$instance"
            }
            else {
                $sqlInstance = $name
            }

            $Results += & $check.Function -Server $sqlInstance
        }
    }
}

$Results | Format-Table