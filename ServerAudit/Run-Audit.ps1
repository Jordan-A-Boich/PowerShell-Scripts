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
            Type = $CheckMetadata.Type
            Function = "Test-" + ($CheckMetadata.Name -replace " ","")
        }

        $CheckMetadata = $null
    }
}

$serversForOSChecks = $Servers | Select-Object -ExpandProperty Name -Unique

$Results = @()

# -----------------------------
# REPORT SETUP (MUST BE BEFORE SQL)
# -----------------------------

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"

$ReportPath = ".\Reports\$timestamp"

New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null

# -----------------------------
# CHECK EXECUTION
# -----------------------------

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

            $Results += & $check.Function `
                -Server $sqlInstance `
                -OutputPath $ReportPath
        }
    }
}

$ServerSummary = $Results | Group-Object Server | ForEach-Object {

    $status = "Healthy"

    if ($_.Group.Status -contains "Critical") {
        $status = "Critical"
    }
    elseif ($_.Group.Status -contains "Warning") {
        $status = "Warning"
    }

    [PSCustomObject]@{
        Server = $_.Name
        Status = $status
    }

}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"

$ReportPath = ".\Reports\$timestamp"

New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null

# -----------------------------
# EXPORT RAW DATA
# -----------------------------

$Results | ConvertTo-Json -Depth 10 | Out-File "$ReportPath\AuditResults.json"

# -----------------------------
# BUILD HTML REPORT
# -----------------------------

. .\ServerAudit\Modules\Write-HtmlReport.ps1

Write-HtmlReport `
    -Results $Results `
    -ServerSummary $ServerSummary `
    -OutputPath $ReportPath