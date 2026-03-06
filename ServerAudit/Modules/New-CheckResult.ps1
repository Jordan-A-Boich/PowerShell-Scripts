function New-CheckResult {

    param(
        $Server,
        $Instance,
        $Check,
        $Category,
        $Status,
        $Severity,
        $Message,
        $Details
    )

    [PSCustomObject]@{
        Server    = $Server
        Instance  = $Instance
        Check     = $Check
        Category  = $Category
        Status    = $Status
        Severity  = $Severity
        Message   = $Message
        Details   = $Details
        Timestamp = Get-Date
    }

}