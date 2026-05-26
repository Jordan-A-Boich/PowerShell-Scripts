#Requires -Version 5.1
<#
.SYNOPSIS
    Step 02 - Acquire ISOs needed to build the lab VMs.

STRATEGY:
    Windows Server 2025  - direct ISO download via BITS from Microsoft Evaluation Center.
    SQL Server 2022/2025 - download the small (~4 MB) evaluation bootstrapper EXE, then
                           run it silently with /ACTION=Download /MEDIATYPE=ISO so it pulls
                           the full ISO straight to $ISOPath with no interactive GUI.
                           The bootstrapper output file is renamed to the expected name.

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
    $sqlISOName = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
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

$sqlISOName         = if ($global:SQLVersion -eq "2025") { $SQL2025ISOName } else { $SQL2022ISOName }
$sqlDestPath        = Join-Path $ISOPath $sqlISOName
$sqlBootstrapperUrl = if ($global:SQLVersion -eq "2025") { $SQL2025BootstrapperUrl } else { $SQL2022BootstrapperUrl }
$sqlEvalPageUrl     = "https://www.microsoft.com/en-us/evalcenter/evaluate-sql-server-$($global:SQLVersion)"

if ((Test-Path $sqlDestPath) -and (Get-Item $sqlDestPath).Length -gt 0) {
    $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
    Write-Log "SQL Server $($global:SQLVersion) ISO already present ($sizeGB GB) - skipping." SUCCESS
} else {
    Write-Log "Acquiring SQL Server $($global:SQLVersion) evaluation ISO via bootstrapper..." INFO

    $bootstrapperPath       = Join-Path $ISOPath "SQLBootstrapper-$($global:SQLVersion).exe"
    $bootstrapperDownloaded = Invoke-FileDownload -Url $sqlBootstrapperUrl -Destination $bootstrapperPath `
        -DisplayName "SQL Server $($global:SQLVersion) Bootstrapper"

    $bootstrapperSucceeded = $false

    if ($bootstrapperDownloaded) {
        Write-Log "Running bootstrapper silently - downloading full ISO to: $ISOPath" INFO
        Write-Log "  This transfers ~1.5 GB; allow 10-30 min depending on connection speed." WARN

        try {
            # Snapshot existing ISOs so we can identify which file the bootstrapper creates
            $isosBefore = Get-ChildItem -Path $ISOPath -Filter "*.iso" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name

            $proc = Start-Process -FilePath $bootstrapperPath `
                -ArgumentList "/ACTION=Download /QUIET /IACCEPTSQLSERVERLICENSETERMS /MEDIAPATH=`"$ISOPath`" /MEDIATYPE=ISO" `
                -Wait -PassThru

            if ($proc.ExitCode -ne 0) {
                throw "Bootstrapper exited with code $($proc.ExitCode)."
            }

            # Locate the newly created ISO (not in the before-snapshot, non-zero size)
            $newISO = Get-ChildItem -Path $ISOPath -Filter "*.iso" -ErrorAction SilentlyContinue |
                Where-Object { ($isosBefore -notcontains $_.Name) -and ($_.Length -gt 0) } |
                Select-Object -First 1

            # Secondary search: any SQLServerYEAR*.iso that is not already our target name
            if (-not $newISO) {
                $newISO = Get-ChildItem -Path $ISOPath -Filter "SQLServer$($global:SQLVersion)*.iso" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne $sqlISOName -and $_.Length -gt 0 } |
                    Select-Object -First 1
            }

            if ($newISO) {
                if ($newISO.FullName -ne $sqlDestPath) {
                    Rename-Item -Path $newISO.FullName -NewName $sqlISOName -Force
                    Write-Log "Renamed '$($newISO.Name)' to '$sqlISOName'." INFO
                }
                $sizeGB = [math]::Round((Get-Item $sqlDestPath).Length / 1GB, 2)
                Write-Log "SQL Server $($global:SQLVersion) ISO ready ($sizeGB GB)." SUCCESS
                $bootstrapperSucceeded = $true
            } else {
                throw "Bootstrapper exited 0 but no new ISO was found in: $ISOPath"
            }

        } catch {
            Write-Log "Bootstrapper approach failed: $_" WARN
        } finally {
            if (Test-Path $bootstrapperPath) {
                Remove-Item $bootstrapperPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $bootstrapperSucceeded) {
        Write-Host ""
        Write-Host "  Automated download failed for SQL Server $($global:SQLVersion)." -ForegroundColor Yellow
        Write-Host "  Download the ISO manually:" -ForegroundColor Yellow
        Write-Host "    1. Go to: $sqlEvalPageUrl" -ForegroundColor Cyan
        Write-Host "    2. Fill out the evaluation form and download the installer EXE." -ForegroundColor White
        Write-Host "    3. Run the EXE and choose 'Download Media'." -ForegroundColor White
        Write-Host "    4. Select ISO format and set the download path to:" -ForegroundColor White
        Write-Host "       $ISOPath" -ForegroundColor Cyan
        Write-Host "    5. After download, rename the ISO file to exactly: $sqlISOName" -ForegroundColor White
        Write-Host "    6. The build will auto-continue once the file is detected." -ForegroundColor White
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
