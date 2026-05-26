#Requires -Version 5.1
<#
.SYNOPSIS
    Step 02 - Acquire ISOs needed to build the lab VMs.

STRATEGY:
    Windows Server 2025  - direct ISO download via BITS from Microsoft Evaluation Center.
    SQL Server 2019/2022/2025 - download the small (~5 MB) Developer edition setup EXE
                           directly from download.microsoft.com via BITS, then launch it
                           so the user can click Download Media > ISO in the UI.
                           The script polls for the resulting ISO, renames it to the
                           expected filename, and continues automatically.

FALLBACK:
    If any automated download fails the script prints clear manual instructions and enters
    a 30-second polling loop. Drop the file at the expected path and the build continues
    automatically. Press Ctrl+C to abort.

IDEMPOTENCY:
    - Each ISO is skipped if already present with non-zero size.
    - Checkpoint step-02.done skips the entire step when all expected ISOs are present.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Checkpoint check
$cpFile = Join-Path $CheckpointPath "step-02.done"
if (Test-Path $cpFile) {
    Write-Log "Step 02 checkpoint found - verifying ISO files are present..." INFO
    $sqlISOName = switch ($global:SQLVersion) { "2019" { $SQL2019ISOName } "2025" { $SQL2025ISOName } default { $SQL2022ISOName } }
    $missingISO = $false
    foreach ($isoFile in @($WinServerISOName, $sqlISOName)) {
        $isoFullPath = Join-Path $ISOPath $isoFile
        if (-not (Test-Path $isoFullPath) -or (Get-Item $isoFullPath).Length -eq 0) {
            $missingISO = $true
            Write-Log "Missing ISO: $isoFullPath - will re-download." WARN
        }
    }
    if (-not $missingISO) {
        Write-Log "All ISOs present - skipping download." SUCCESS
        return
    }
    Write-Log "Re-entering ISO download step due to missing files." WARN
}
#endregion

#region Ensure ISO folder exists
if (-not (Test-Path $ISOPath)) {
    New-Item -ItemType Directory -Path $ISOPath -Force | Out-Null
    Write-Log "Created ISO folder: $ISOPath" INFO
}
#endregion

#region Helpers

function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName,
        [long]$MinSizeBytes = 200MB
    )
    if (Test-Path $Destination) { Remove-Item $Destination -Force }
    Write-Log "Downloading $DisplayName..." INFO
    Write-Log "  URL: $Url" INFO
    Write-Log "  To:  $Destination" INFO

    # Attempt 1: BITS (shows a progress bar in interactive sessions)
    $bitsOk = $false
    try {
        Start-BitsTransfer -Source $Url -Destination $Destination `
            -Description "Downloading $DisplayName" -DisplayName $DisplayName `
            -ErrorAction Stop
        if ((Test-Path $Destination) -and (Get-Item $Destination).Length -ge $MinSizeBytes) {
            $bitsOk = $true
        } else {
            $got = if (Test-Path $Destination) { (Get-Item $Destination).Length } else { 0 }
            Write-Log "BITS returned $got bytes (expected >= $MinSizeBytes) - URL may redirect to a form page. Trying WebRequest..." WARN
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Log "BITS attempt failed: $_ - falling back to WebRequest..." WARN
        if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
    }

    if ($bitsOk) {
        $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
        Write-Log "$DisplayName downloaded via BITS ($sizeMB MB)." SUCCESS
        return $true
    }

    # Attempt 2: Invoke-WebRequest with browser User-Agent (handles some redirect chains BITS misses)
    try {
        Write-Log "Attempting download via WebRequest..." INFO
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36' }
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers $headers -ErrorAction Stop
        if ((Test-Path $Destination) -and (Get-Item $Destination).Length -ge $MinSizeBytes) {
            $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
            Write-Log "$DisplayName downloaded via WebRequest ($sizeMB MB)." SUCCESS
            return $true
        }
        $got = if (Test-Path $Destination) { (Get-Item $Destination).Length } else { 0 }
        Write-Log "WebRequest returned $got bytes (expected >= $MinSizeBytes) - URL likely requires a form or login." WARN
    } catch {
        Write-Log "WebRequest attempt failed: $_" WARN
    }

    if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
    return $false
}

function Wait-ForFile {
    param(
        [string]$Path,
        [string]$DisplayName,
        [int]$PollSeconds = 30
    )
    $divider = "  " + ("-" * 64)
    Write-Host ""
    Write-Host $divider -ForegroundColor Yellow
    Write-Host "  WAITING FOR MANUAL FILE PLACEMENT" -ForegroundColor Yellow
    Write-Host $divider -ForegroundColor Yellow
    Write-Host "  Expected file : $DisplayName" -ForegroundColor White
    Write-Host "  Place it at   : $Path" -ForegroundColor Cyan
    Write-Host "  Script will auto-continue once the file is detected." -ForegroundColor White
    Write-Host "  Press Ctrl+C to abort the build." -ForegroundColor DarkGray
    Write-Host $divider -ForegroundColor Yellow
    Write-Host ""
    while (-not (Test-Path $Path) -or (Get-Item $Path -ErrorAction SilentlyContinue).Length -eq 0) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Waiting for $DisplayName ..." -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    }
    $sizeGB = [math]::Round((Get-Item $Path).Length / 1GB, 2)
    Write-Log "File detected: $Path ($sizeGB GB)" SUCCESS
}

#endregion

#region Windows Server 2025 ISO

$wsDestPath = Join-Path $ISOPath $WinServerISOName

if ((Test-Path $wsDestPath) -and (Get-Item $wsDestPath).Length -gt 0) {
    $sizeGB = [math]::Round((Get-Item $wsDestPath).Length / 1GB, 2)
    Write-Log "Windows Server 2025 ISO already present ($sizeGB GB) - skipping." SUCCESS
} else {
    Write-Log "Acquiring Windows Server 2025 ISO..." INFO
    $wsDownloaded = Invoke-FileDownload -Url $WinServer2025ISOUrl -Destination $wsDestPath `
        -DisplayName "Windows Server 2025 ISO"

    if (-not $wsDownloaded) {
        Write-Host ""
        Write-Host "  Automated download failed for Windows Server 2025." -ForegroundColor Yellow
        Write-Host "  Download the ISO manually:" -ForegroundColor Yellow
        Write-Host "    1. Go to: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025" -ForegroundColor Cyan
        Write-Host "    2. Select 'ISO Downloads' then '64-bit edition'." -ForegroundColor White
        Write-Host "    3. Complete the short form, then download the ISO." -ForegroundColor White
        Write-Host "    4. Save / rename the file to exactly: $WinServerISOName" -ForegroundColor White
        Write-Host "    5. Place it at: $wsDestPath" -ForegroundColor Cyan
        Write-Host ""
        Wait-ForFile -Path $wsDestPath -DisplayName $WinServerISOName
    }
}
#endregion

#region SQL Server ISO

$sqlISOName         = switch ($global:SQLVersion) { "2019" { $SQL2019ISOName } "2025" { $SQL2025ISOName } default { $SQL2022ISOName } }
$sqlDestPath        = Join-Path $ISOPath $sqlISOName
$sqlBootstrapperUrl = switch ($global:SQLVersion) { "2019" { $SQL2019BootstrapperUrl } "2025" { $SQL2025BootstrapperUrl } default { $SQL2022BootstrapperUrl } }
$sqlDownloadPageUrl = "https://www.microsoft.com/en-us/sql-server/sql-server-downloads"

if ((Test-Path $sqlDestPath) -and (Get-Item $sqlDestPath).Length -gt 0) {
    $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
    Write-Log "SQL Server $($global:SQLVersion) Developer ISO already present ($sizeGB GB) - skipping." SUCCESS
} else {
    Write-Log "Acquiring SQL Server $($global:SQLVersion) Developer setup EXE..." INFO

    $setupExePath       = Join-Path $ISOPath "SQL$($global:SQLVersion)-SSEI-Dev.exe"
    $setupExeDownloaded = Invoke-FileDownload -Url $sqlBootstrapperUrl -Destination $setupExePath `
        -DisplayName "SQL Server $($global:SQLVersion) Developer setup EXE" -MinSizeBytes 1MB

    $bootstrapperSucceeded = $false

    if ($setupExeDownloaded) {
        # Attempt 1: silent unattended download — bootstrapper supports /ACTION=Download /QUIET
        Write-Log "Attempting silent ISO download (no GUI)..." INFO
        $silentArgs = "/ACTION=Download /QUIET /IACCEPTSQLSERVERLICENSETERMS /MEDIATYPE=ISO /MEDIAPATH=`"$ISOPath`""
        try {
            $proc = Start-Process -FilePath $setupExePath -ArgumentList $silentArgs -Wait -PassThru -ErrorAction Stop
            Write-Log "Bootstrapper exited (code $($proc.ExitCode)) - checking for ISO..." INFO
        } catch {
            Write-Log "Silent launch failed: $_ - will try interactive." WARN
        }

        # Check if silent download produced the ISO (either at target path or needs rename)
        if ((Test-Path $sqlDestPath) -and (Get-Item $sqlDestPath -ErrorAction SilentlyContinue).Length -gt 100MB) {
            $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
            Write-Log "Silent download succeeded: $sqlDestPath ($sizeGB GB)" SUCCESS
            $bootstrapperSucceeded = $true
        } else {
            $newISO = Get-ChildItem -Path $ISOPath -Filter "*.iso" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $sqlISOName -and $_.Name -ne $WinServerISOName -and $_.Length -gt 100MB } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newISO) {
                Rename-Item -Path $newISO.FullName -NewName $sqlISOName -Force -ErrorAction Stop
                Write-Log "Silent download: renamed '$($newISO.Name)' to '$sqlISOName'." INFO
                $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
                Write-Log "SQL Server $($global:SQLVersion) Developer ISO ready ($sizeGB GB)." SUCCESS
                $bootstrapperSucceeded = $true
            }
        }

        # Attempt 2: interactive — open the GUI and wait for user to click 'Download Media'
        if (-not $bootstrapperSucceeded) {
            Write-Log "Silent download did not produce an ISO - launching interactive setup..." WARN
            Start-Process -FilePath $setupExePath

            $divider = "  " + ("-" * 64)
            Write-Host ""
            Write-Host $divider -ForegroundColor Yellow
            Write-Host "  COMPLETE THE DOWNLOAD IN THE SETUP WINDOW" -ForegroundColor Yellow
            Write-Host $divider -ForegroundColor Yellow
            Write-Host "  The SQL Server $($global:SQLVersion) Developer setup has launched." -ForegroundColor White
            Write-Host "  Follow these steps in the window:" -ForegroundColor White
            Write-Host "    1. Click 'Download Media'" -ForegroundColor Cyan
            Write-Host "    2. Under Format, select 'ISO'" -ForegroundColor White
            Write-Host "    3. Set the download location to:" -ForegroundColor White
            Write-Host "       $ISOPath" -ForegroundColor Cyan
            Write-Host "    4. Click Download and wait for it to complete" -ForegroundColor White
            Write-Host "  The script detects the ISO and renames it automatically." -ForegroundColor DarkGray
            Write-Host "  Press Ctrl+C to abort the build." -ForegroundColor DarkGray
            Write-Host $divider -ForegroundColor Yellow
            Write-Host ""

            while (-not $bootstrapperSucceeded) {
                if ((Test-Path $sqlDestPath) -and (Get-Item $sqlDestPath -ErrorAction SilentlyContinue).Length -gt 100MB) {
                    $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
                    Write-Log "ISO detected: $sqlDestPath ($sizeGB GB)" SUCCESS
                    $bootstrapperSucceeded = $true
                    break
                }
                $newISO = Get-ChildItem -Path $ISOPath -Filter "*.iso" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne $sqlISOName -and $_.Name -ne $WinServerISOName -and $_.Length -gt 100MB } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newISO) {
                    Rename-Item -Path $newISO.FullName -NewName $sqlISOName -Force -ErrorAction Stop
                    Write-Log "Renamed '$($newISO.Name)' to '$sqlISOName'." INFO
                    $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
                    Write-Log "SQL Server $($global:SQLVersion) Developer ISO ready ($sizeGB GB)." SUCCESS
                    $bootstrapperSucceeded = $true
                    break
                }
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Waiting for ISO download to complete..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 30
            }
        }

        if (Test-Path $setupExePath) {
            Remove-Item $setupExePath -Force -ErrorAction SilentlyContinue
            Write-Log "Setup EXE cleaned up." INFO
        }
    }

    if (-not $bootstrapperSucceeded) {
        Write-Host ""
        Write-Host "  Setup EXE download failed. Complete the steps below manually:" -ForegroundColor Yellow
        Write-Host "    1. Go to: $sqlDownloadPageUrl" -ForegroundColor Cyan
        Write-Host "    2. Under 'Free specialized edition', click 'Download now' next to Developer." -ForegroundColor White
        Write-Host "    3. Run the downloaded EXE." -ForegroundColor White
        Write-Host "    4. Click 'Download Media', select ISO, set the location to:" -ForegroundColor White
        Write-Host "       $ISOPath" -ForegroundColor Cyan
        Write-Host "    5. Click Download and wait for it to complete." -ForegroundColor White
        Write-Host "    6. Rename the ISO file to exactly: $sqlISOName" -ForegroundColor White
        Write-Host "    7. The build will auto-continue once the file is detected." -ForegroundColor White
        Write-Host ""
        Wait-ForFile -Path $sqlDestPath -DisplayName $sqlISOName
    }
}
#endregion

#region Checkpoint
New-Item -ItemType File -Path $cpFile -Force | Out-Null
Write-Log "Checkpoint written: step-02.done" SUCCESS
Write-Log "ISO acquisition complete." SUCCESS
#endregion
