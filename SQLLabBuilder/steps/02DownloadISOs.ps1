#Requires -Version 5.1
<#
.SYNOPSIS
    Step 02 — Copy ISOs from the SQLLabBuilder\ISOs source folder to the lab drive.

IDEMPOTENCY CHECKS:
    - Each ISO is copied only if the destination does not already exist with matching size.
    - Checkpoint step-02.done skips the entire step if all expected ISOs are present.

SOURCE:
    ISOs are read from $SourceISOPath (SQLLabBuilder\ISOs\ in the script directory).
    Expected files:
        WinServer2025.iso
        SQLServer2022-eval.iso   (if -SqlVersion 2022)
        SQLServer2025-eval.iso   (if -SqlVersion 2025)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-02.done"
if (Test-Path $cpFile) {
    Write-Log "Step 02 checkpoint found — verifying ISO files are present..." INFO
    $sqlISOName = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
    $missingISO = $false
    foreach ($isoFile in @($WinServerISOName, $sqlISOName)) {
        $isoFullPath = Join-Path $ISOPath $isoFile
        if (-not (Test-Path $isoFullPath) -or (Get-Item $isoFullPath).Length -eq 0) {
            $missingISO = $true
            Write-Log "Missing ISO: $isoFullPath — will re-copy." WARN
        }
    }
    if (-not $missingISO) {
        Write-Log "All ISOs present — skipping copy." SUCCESS
        return
    }
}
#endregion

#region Validate source folder
if (-not $SourceISOPath -or -not (Test-Path $SourceISOPath)) {
    throw "Source ISO folder not found: '$SourceISOPath'. Ensure the ISOs\ folder exists in the SQLLabBuilder directory."
}
Write-Log "Source ISO folder: $SourceISOPath" INFO
#endregion

if (-not (Test-Path $ISOPath)) {
    New-Item -ItemType Directory -Path $ISOPath -Force | Out-Null
}

#region Copy helper
function Copy-ISO {
    param(
        [string]$SourceDir,
        [string]$FileName,
        [string]$DestDir,
        [string]$DisplayName
    )

    $srcPath  = Join-Path $SourceDir $FileName
    $destPath = Join-Path $DestDir   $FileName

    if (-not (Test-Path $srcPath)) {
        throw "Source ISO not found: $srcPath`nPlace '$FileName' in the ISOs\ folder alongside StartLabBuild.ps1."
    }

    $srcSize = (Get-Item $srcPath).Length

    if (Test-Path $destPath) {
        $destSize = (Get-Item $destPath).Length
        if ($destSize -eq $srcSize) {
            Write-Log "$DisplayName already at destination ($([math]::Round($destSize/1GB,2)) GB) — skipping." SUCCESS
            return
        }
        Write-Log "$DisplayName at destination has wrong size ($destSize vs $srcSize bytes) — re-copying." WARN
        Remove-Item $destPath -Force
    }

    Write-Log "Copying $DisplayName ($([math]::Round($srcSize/1GB,2)) GB)..." INFO
    Write-Log "  From: $srcPath" INFO
    Write-Log "  To:   $destPath" INFO
    Copy-Item -Path $srcPath -Destination $destPath -ErrorAction Stop
    Write-Log "$DisplayName copied successfully." SUCCESS
}
#endregion

#region Copy Windows Server ISO
Copy-ISO -SourceDir $SourceISOPath -FileName $WinServerISOName -DestDir $ISOPath -DisplayName "Windows Server 2025"
#endregion

#region Copy SQL Server ISO
$sqlISOName = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
Copy-ISO -SourceDir $SourceISOPath -FileName $sqlISOName -DestDir $ISOPath -DisplayName "SQL Server $($global:SQLVersion)"
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-02.done" SUCCESS
#endregion

Write-Log "ISO copy step complete." SUCCESS
