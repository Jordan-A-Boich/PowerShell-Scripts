$CheckMetadata = @{
    Name = "Disk Space"
    Category = "OS"
}

function Test-DiskSpace {

    param(
        [string]$Server
    )

    # Use dbatools disk space command (OS-level, so instance not required)
    $disks = Get-DbaDiskSpace -ComputerName $Server

    foreach ($disk in $disks) {

        $percentFree = $disk.PercentFree
        $spaceLeft = $disk.FreeInGB

        if ($percentFree -ge 20 && $percentFree -le 50) {

            New-CheckResult `
                -Server $Server `
                -Check "Disk Space" `
                -Category "OS" `
                -Status "Warning" `
                -Severity "Medium" `
                -Message "Low disk space" `
                -Details "$($disk.Name) - $percentFree% free | $spaceLeft\GB remaining"
        }
        elseif ($percentFree -lt 20) {

            New-CheckResult `
                -Server $Server `
                -Check "Disk Space" `
                -Category "OS" `
                -Status "Alert" `
                -Severity "Critical" `
                -Message "Disk space unhealthy" `
                -Details "$($disk.Name) - $percentFree% free | $spaceLeft\GB remaining"
        }
        else {

            New-CheckResult `
                -Server $Server `
                -Check "Disk Space" `
                -Category "OS" `
                -Status "Pass" `
                -Severity "Info" `
                -Message "Disk space healthy" `
                -Details "$($disk.Name) - $percentFree% free | $spaceLeft\GB remaining"
        }
    }
}