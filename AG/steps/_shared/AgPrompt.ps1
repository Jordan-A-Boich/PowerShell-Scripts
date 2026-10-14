#Requires -Version 5.1
<#
.SYNOPSIS
    AG toolkit — interactive prompt helpers.

    Everything the user picks is chosen by NUMBER wherever a set of valid answers
    can be discovered. Free text is reserved for the few values that cannot be
    enumerated (a seed instance name, the backup share UNC, the AG and listener names, IP addresses).
#>

Set-StrictMode -Version Latest

function Read-AgLine {
    <#
    .SYNOPSIS
        One line of operator input, or a stop that says why there is none.
    .DESCRIPTION
        Read-Host returns $null — not '' — when its input ends: a redirected answer file
        that ran out, or a console that is not interactive. Every caller then calls
        .Trim() on it and the run dies with "You cannot call a method on a null-valued
        expression", which says nothing about the actual problem. An empty line is still
        '' and remains a legitimate answer meaning "take the default".
    #>
    param([Parameter(Mandatory)][string]$Prompt)

    $raw = Read-Host $Prompt
    if ($null -eq $raw) {
        throw @"
Ran out of input while asking: $Prompt

The interview reached a question with nothing left to read, which means either the input
being piped in ended early or this session is not interactive. Every prompt has to be
answered; run the script interactively, or supply an answer for this question too.
"@
    }
    return $raw
}

function Read-AgChoice {
    <#
    .SYNOPSIS
        Numbered single-select menu. Returns the chosen item from -Items.
    .PARAMETER Display
        Scriptblock rendering each item's label. Defaults to the item itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [scriptblock]$Display = { param($i) "$i" },
        [int]$DefaultIndex = -1,
        [string]$Hint
    )

    if ($Items.Count -eq 0) { throw "Read-AgChoice: no items to choose from for '$Title'." }

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor DarkGray }

    # The index is right-aligned to the widest one in the list, so that a menu long
    # enough to reach [10] does not shift every label after it one column across. Lists
    # of fewer than ten are unaffected.
    $numFormat = '  {0}[{1,' + ([string]$Items.Count).Length + '}] {2}'
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $label = & $Display $Items[$i]
        $mark  = if ($i -eq $DefaultIndex) { '*' } else { ' ' }
        Write-Host ($numFormat -f $mark, ($i + 1), $label)
    }

    # A single option is not a decision. Announce it and move on.
    if ($Items.Count -eq 1) {
        Write-Host '  -> only one option; selected automatically.' -ForegroundColor DarkGray
        return $Items[0]
    }

    while ($true) {
        $suffix = if ($DefaultIndex -ge 0) { " [default $($DefaultIndex + 1)]" } else { '' }
        $raw = (Read-AgLine -Prompt "Enter number (1-$($Items.Count))$suffix").Trim()

        if (-not $raw -and $DefaultIndex -ge 0) { return $Items[$DefaultIndex] }

        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            return $Items[$n - 1]
        }
        Write-Host "  Please enter a number between 1 and $($Items.Count)." -ForegroundColor Yellow
    }
}

function Read-AgNumberSet {
    <#
    .SYNOPSIS
        Parses "1,3,5-7" style input into distinct 1-based indexes within [1..Max].
    .OUTPUTS
        int[] of 1-based indexes, or $null when the input is malformed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Max
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return ,@() }

    $result = New-Object System.Collections.Generic.List[int]
    foreach ($tokenRaw in ($Text -split ',')) {
        $token = $tokenRaw.Trim()
        if (-not $token) { continue }

        if ($token -match '^(\d+)\s*-\s*(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -lt 1 -or $hi -gt $Max -or $lo -gt $hi) { return $null }
            for ($i = $lo; $i -le $hi; $i++) { if (-not $result.Contains($i)) { $result.Add($i) } }
        } elseif ($token -match '^\d+$') {
            $n = [int]$token
            if ($n -lt 1 -or $n -gt $Max) { return $null }
            if (-not $result.Contains($n)) { $result.Add($n) }
        } else {
            return $null
        }
    }
    return ,($result.ToArray())
}

function Read-AgExclusion {
    <#
    .SYNOPSIS
        Shows a numbered list and asks which entries to EXCLUDE.
        Empty input excludes nothing (the common case).
    .OUTPUTS
        The retained items, in the original order.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [scriptblock]$Display = { param($i) "$i" }
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('   [{0}] {1}' -f ($i + 1), (& $Display $Items[$i]))
    }
    Write-Host '  Enter the numbers to EXCLUDE (e.g. 2 or 1,3 or 2-4).' -ForegroundColor DarkGray
    Write-Host '  Press ENTER to include everything listed above.' -ForegroundColor DarkGray

    while ($true) {
        $raw = (Read-AgLine -Prompt 'Exclude').Trim()
        $idx = Read-AgNumberSet -Text $raw -Max $Items.Count
        if ($null -eq $idx) {
            Write-Host "  Could not parse that. Use numbers, commas and ranges within 1-$($Items.Count)." -ForegroundColor Yellow
            continue
        }

        $keep = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($idx -notcontains ($i + 1)) { $keep += $Items[$i] }
        }

        if ($keep.Count -eq 0) {
            Write-Host '  That would exclude every database, leaving nothing to do. Try again.' -ForegroundColor Yellow
            continue
        }
        return ,$keep
    }
}

function Read-AgSelection {
    <#
    .SYNOPSIS
        Shows a numbered list and asks which entries to INCLUDE.
    .DESCRIPTION
        ENTER takes -Default: 'all' (every entry), 'none' (nothing — only when -AllowNone),
        or an explicit number set such as '1,2'. The word 'none' is always accepted when
        -AllowNone is set, so "create the AG empty" is one word rather than a workaround.
    .OUTPUTS
        The chosen items, in the original order, unrolled onto the pipeline (nothing at all
        for an empty choice). Collect with @(Read-AgSelection ...).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [scriptblock]$Display = { param($i) "$i" },
        [string]$Default = 'all',
        [switch]$AllowNone,
        [int]$Max = 0,
        [string]$Hint
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor DarkGray }
    $numFormat = '   [{0,' + ([string]$Items.Count).Length + '}] {1}'
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ($numFormat -f ($i + 1), (& $Display $Items[$i]))
    }
    $defaultText = switch ($Default) { 'all' { 'ENTER = all of them.' } 'none' { 'ENTER = none.' } '' { 'There is no default: type the numbers.' } default { "ENTER = $Default." } }
    Write-Host "  Enter the numbers to INCLUDE (e.g. 2 or 1,3 or 2-4). $defaultText" -ForegroundColor DarkGray
    if ($AllowNone -and $Default -ne 'none') { Write-Host "  Type 'none' to include nothing." -ForegroundColor DarkGray }

    while ($true) {
        $raw = (Read-AgLine -Prompt 'Include').Trim()
        if (-not $raw) { $raw = $Default }

        if ($raw -eq 'none') {
            if ($AllowNone) { return }
            Write-Host '  At least one entry is required.' -ForegroundColor Yellow
            continue
        }
        if ($raw -eq 'all') { $raw = "1-$($Items.Count)" }

        $idx = Read-AgNumberSet -Text $raw -Max $Items.Count
        if ($null -eq $idx -or $idx.Count -eq 0) {
            Write-Host "  Could not parse that. Use numbers, commas and ranges within 1-$($Items.Count)." -ForegroundColor Yellow
            continue
        }
        if ($Max -gt 0 -and $idx.Count -gt $Max) {
            Write-Host "  At most $Max can be chosen here." -ForegroundColor Yellow
            continue
        }
        $keep = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($idx -contains ($i + 1)) { $keep += $Items[$i] }
        }
        # Plain return, so it unrolls: every caller collects the result with @(...).
        return $keep
    }
}

function Read-AgYesNo {
    <#
    .SYNOPSIS
        Numbered yes/no. Returns [bool].
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$DefaultYes = $true
    )
    $items  = @('Yes', 'No')
    $defIdx = if ($DefaultYes) { 0 } else { 1 }
    return ((Read-AgChoice -Title $Question -Items $items -DefaultIndex $defIdx) -eq 'Yes')
}

function Read-AgText {
    <#
    .SYNOPSIS
        Free-text prompt with optional default and validation scriptblock.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ValidationMessage = 'That value is not valid.'
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $raw = (Read-AgLine -Prompt "$Prompt$suffix").Trim()
        if (-not $raw -and $Default) { $raw = $Default }
        if (-not $raw) { Write-Host '  A value is required.' -ForegroundColor Yellow; continue }
        if ($Validate -and -not (& $Validate $raw)) {
            Write-Host "  $ValidationMessage" -ForegroundColor Yellow
            continue
        }
        return $raw
    }
}

function Read-AgCredential {
    <#
    .SYNOPSIS
        Chooses the authentication used for every replica connection.
    #>
    $mode = Read-AgChoice -Title 'How should this script authenticate to the SQL Server replicas?' -Items @(
        'Windows integrated (run as the current user)'
        'SQL Server login (prompt for username and password)'
        'Windows account other than the current user'
    ) -DefaultIndex 0

    switch -Wildcard ($mode) {
        'Windows integrated*' {
            Set-AgConnectionContext -Credential $null
            Write-AgLog "Authentication: Windows integrated as $env:USERDOMAIN\$env:USERNAME" INFO
        }
        'SQL Server login*' {
            $cred = Get-Credential -Message 'SQL Server login (sysadmin on all replicas)'
            if (-not $cred) { throw 'A credential is required.' }
            Set-AgConnectionContext -Credential $cred
            Write-AgLog "Authentication: SQL login '$($cred.UserName)'" INFO
        }
        default {
            # Invoke-Sqlcmd -Credential performs SQL auth only. Windows auth as a
            # different principal must come from the process token, so the honest
            # answer is to tell the user to re-launch rather than silently degrade.
            throw @'
Invoke-Sqlcmd cannot pass an alternate Windows identity.
Re-launch PowerShell as that account, for example:

    runas /user:DOMAIN\dbaadmin powershell.exe

then run the script again and choose "Windows integrated".
'@
        }
    }
}
