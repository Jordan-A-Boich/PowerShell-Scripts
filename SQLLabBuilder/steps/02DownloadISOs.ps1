#Requires -Version 5.1
<#
.SYNOPSIS
    Step 02 — ISO download.

IDEMPOTENCY CHECKS:
    - Each ISO file is downloaded only if it does not already exist at $ISOPath.
    - File size is verified after download. If the file exists and has non-zero size,
      the download is skipped.
    - Checkpoint step-02.done skips the entire step if all expected ISOs are present.
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
            Write-Log "Missing ISO: $isoFullPath — will re-download." WARN
        }
    }
    if (-not $missingISO) {
        Write-Log "All ISOs present — skipping download." SUCCESS
        return
    }
}
#endregion

#region Download helper with retry
function Invoke-ISODownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName
    )

    if (Test-Path $Destination) {
        $existingSize = (Get-Item $Destination).Length
        if ($existingSize -gt 100MB) {
            Write-Log "$DisplayName already exists ($([math]::Round($existingSize/1GB,2)) GB) — skipping download." SUCCESS
            return
        } else {
            Write-Log "$DisplayName exists but appears incomplete ($existingSize bytes) — re-downloading." WARN
            Remove-Item $Destination -Force
        }
    }

    $maxAttempts = 3
    $waitSeconds = 10

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Log "Downloading $DisplayName (attempt $attempt/$maxAttempts)..." INFO
        Write-Log "Source URL: $Url" INFO
        Write-Log "Destination: $Destination" INFO
        try {
            Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName $DisplayName -ErrorAction Stop
            $downloadedSize = (Get-Item $Destination).Length
            if ($downloadedSize -lt 100MB) {
                throw "Downloaded file is unexpectedly small ($downloadedSize bytes) — likely a redirect/error page."
            }
            Write-Log "$DisplayName downloaded successfully. Size: $([math]::Round($downloadedSize/1GB,2)) GB" SUCCESS
            return
        } catch {
            Write-Log "Download attempt $attempt failed: $_" WARN
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt $maxAttempts) {
                Write-Log "Waiting $waitSeconds seconds before retry..." INFO
                Start-Sleep -Seconds $waitSeconds
                $waitSeconds *= 2
            }
        }
    }

    Write-Log "All $maxAttempts download attempts failed for $DisplayName." ERROR
    Write-Log "Manual recovery steps:" ERROR
    Write-Log "  1. Download the ISO manually from the evaluation center." ERROR
    Write-Log "  2. Place it at: $Destination" ERROR
    Write-Log "  3. Re-run Start-LabBuild.ps1" ERROR
    throw "ISO download failed: $DisplayName"
}
#endregion

if (-not (Test-Path $ISOPath)) {
    New-Item -ItemType Directory -Path $ISOPath -Force | Out-Null
}

#region Windows Server 2025 ISO
$winISOPath = Join-Path $ISOPath $WinServerISOName
Invoke-ISODownload `
    -Url         $WinServerISOUrl `
    -Destination $winISOPath `
    -DisplayName "Windows Server 2025 Evaluation"
#endregion

#region SQL Server ISO
$sqlISOName = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
$sqlISOUrl  = if ($global:SQLVersion -eq "2025") { $SQL2025ISOUrl  } else { $SQL2022ISOUrl  }
$sqlISOPath = Join-Path $ISOPath $sqlISOName

Invoke-ISODownload `
    -Url         $sqlISOUrl `
    -Destination $sqlISOPath `
    -DisplayName "SQL Server $($global:SQLVersion) Evaluation"
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-02.done" SUCCESS
#endregion

Write-Log "ISO download step complete." SUCCESS
