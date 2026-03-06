$CheckMetadata = @{
    Name = "Database Inventory"
    Category = "SQL"
    Type = "Inventory"
}

function Test-DatabaseInventory {

param(
    [string]$Server,
    [string]$OutputPath
)

$dbs = Get-DbaDatabase -SqlInstance $Server -ExcludeSystem

$total = $dbs.Count
$encrypted = ($dbs | Where-Object {$_.Encrypted -eq $true -and $_.Name -ne "tempdb"}).Count
$offline = ($dbs | Where-Object Status -ne "Normal").Count

# ----------------------------------------------------
# SAVE INVENTORY INSIDE REPORT FOLDER
# ----------------------------------------------------

$outputFolder = Join-Path $OutputPath "DatabaseInventory"

New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null

$inventory = foreach ($db in $dbs) {

    [PSCustomObject]@{
        Name            = $db.Name
        SizeMB           = $db.SizeMB
        RecoveryModel    = $db.RecoveryModel
        Status            = $db.Status
        Encrypted         = $db.Encrypted
        LastFullBackup     = $db.LastFullBackup
        LastDiffBackup      = $db.LastDiffBackup
        LastLogBackup        = $db.LastLogBackup
    }
}

$inventory |
ConvertTo-Json -Depth 5 |
Out-File (Join-Path $outputFolder "$($Server.Replace('\','_')).json")

# ----------------------------------------------------
# RETURN CHECK RESULT
# ----------------------------------------------------

New-CheckResult `
    -Server $Server `
    -Check "Database Inventory" `
    -Category "SQL" `
    -Status "Info" `
    -Severity "Info" `
    -Message "$total User DBs detected" `
    -Details "$encrypted encrypted | $offline non-normal"
}