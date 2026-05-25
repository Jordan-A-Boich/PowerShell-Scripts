#Requires -Version 5.1
<#
.SYNOPSIS
    Step 01 — Drive selection.

IDEMPOTENCY CHECKS:
    - If checkpoint step-01.done exists AND $LabRoot is already set in config.ps1,
      the step is skipped and the stored value is used.
    - If LabRoot folder already exists on the selected drive, it is reused.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "..\config.ps1"

#region Checkpoint check
if ($CheckpointPath -and (Test-Path (Join-Path $CheckpointPath "step-01.done"))) {
    # Reload config to get LabRoot
    . $configPath
    if ($LabRoot -and (Test-Path $LabRoot)) {
        Write-Log "Step 01 checkpoint found — LabRoot: $LabRoot — skipping drive selection." SUCCESS
        return
    }
}
#endregion

#region Enumerate fixed NTFS volumes
Write-Log "Enumerating fixed NTFS drives..." INFO

$volumes = Get-Volume | Where-Object {
    $_.DriveType -eq 'Fixed' -and
    $_.FileSystem -eq 'NTFS' -and
    $_.DriveLetter -ne $null -and
    $_.SizeRemaining -gt 0
} | Sort-Object DriveLetter

if ($volumes.Count -eq 0) {
    Write-Log "No fixed NTFS drives found." ERROR
    throw "No eligible drives for LabRoot."
}

Write-Host ""
Write-Host "Available drives for the lab:" -ForegroundColor Cyan
Write-Host ("-" * 60) -ForegroundColor DarkGray
$i = 1
$driveList = @()
foreach ($vol in $volumes) {
    $totalGB = [math]::Round($vol.Size / 1GB, 1)
    $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 1)
    $label   = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "(no label)" }
    Write-Host ("  [{0}] {1}:\  {2,-20}  Total: {3,6} GB   Free: {4,6} GB" -f $i, $vol.DriveLetter, $label, $totalGB, $freeGB)
    $driveList += [PSCustomObject]@{ Index = $i; Letter = $vol.DriveLetter; FreeGB = $freeGB }
    $i++
}
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Minimum recommended free space: 250 GB" -ForegroundColor Yellow
Write-Host ""
#endregion

#region Prompt user
$selectedDrive = $null
while ($null -eq $selectedDrive) {
    $choice = Read-Host "Enter the number of the drive to use for the lab"
    $parsed = 0
    if ([int]::TryParse($choice, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $driveList.Count) {
        $selectedDrive = $driveList[$parsed - 1]
    } else {
        Write-Host "Invalid selection. Enter a number between 1 and $($driveList.Count)." -ForegroundColor Red
    }
}

if ($selectedDrive.FreeGB -lt 250) {
    Write-Log ("Selected drive {0}:\ has only {1} GB free. Minimum recommended is 250 GB." -f $selectedDrive.Letter, $selectedDrive.FreeGB) WARN
    $proceed = Read-Host "Continue anyway? (Y/N)"
    if ($proceed -ne 'Y' -and $proceed -ne 'y') {
        throw "Drive selection cancelled by user — insufficient free space."
    }
}

$newLabRoot = "$($selectedDrive.Letter):\SQLLabBuilder"
Write-Log "LabRoot selected: $newLabRoot" SUCCESS
#endregion

#region Create folder structure
foreach ($dir in @($newLabRoot, "$newLabRoot\ISOs", "$newLabRoot\VMs", "$newLabRoot\logs", "$newLabRoot\logs\checkpoints")) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir" INFO
    } else {
        Write-Log "Directory exists: $dir" INFO
    }
}
#endregion

#region Patch config.ps1 with resolved paths
Write-Log "Writing path variables to config.ps1..." INFO

$configContent = Get-Content -Path $configPath -Raw -ErrorAction Stop

$pathMap = @{
    'LabRoot'        = $newLabRoot
    'ISOPath'        = "$newLabRoot\ISOs"
    'VMPath'         = "$newLabRoot\VMs"
    'LogPath'        = "$newLabRoot\logs"
    'CheckpointPath' = "$newLabRoot\logs\checkpoints"
}

foreach ($varName in $pathMap.Keys) {
    $val = $pathMap[$varName] -replace '\\', '\\'
    $configContent = $configContent -replace "(\`$$varName\s*=\s*`")([^`"]*?)(`")", "`${1}$($pathMap[$varName])`""
}

Set-Content -Path $configPath -Value $configContent -Encoding UTF8 -ErrorAction Stop

# Re-dot-source so caller has live values
. $configPath
Write-Log "config.ps1 updated with path variables." SUCCESS
#endregion

#region Checkpoint
if ($CheckpointPath -and -not (Test-Path $CheckpointPath)) {
    New-Item -ItemType Directory -Path $CheckpointPath -Force | Out-Null
}
if ($CheckpointPath) {
    New-Item -ItemType File -Path (Join-Path $CheckpointPath "step-01.done") -Force | Out-Null
    Write-Log "Checkpoint written: step-01.done" SUCCESS
}
#endregion

Write-Log "Drive selection complete. Lab root: $LabRoot" SUCCESS
