#Requires -Version 5.1
<#
.SYNOPSIS
    DAG Initializer — file operations executed *by the SQL Server engine*, not by this host.

.DESCRIPTION
    The orchestrating workstation frequently cannot see the backup share at all: the
    share is ACL'd for the SQL Server service accounts, and the operator may be running
    from a machine outside the domain. Every directory create, existence check and
    file enumeration is therefore issued as T-SQL against the relevant replica, so the
    identity doing the I/O is exactly the identity that will do the BACKUP or RESTORE.
#>

Set-StrictMode -Version Latest

function New-DagRemoteDirectory {
    <#
    .SYNOPSIS
        Creates a directory (and any missing parents) on the target server's behalf.
        xp_create_subdir is a no-op when the directory already exists, so this is idempotent.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Path
    )
    Invoke-DagSql -Instance $Instance -Retry -Activity 'create directory' -QueryTimeout 120 `
        -Query "EXEC master.dbo.xp_create_subdir $(ConvertTo-DagQuotedString $Path)" | Out-Null
    Write-DagLog "  [$Instance] ensured directory: $Path" DEBUG
}

function Test-DagRemotePath {
    <#
    .OUTPUTS
        pscustomobject with FileExists / IsDirectory / ParentExists.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Path
    )
    $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'path check' -QueryTimeout 60 `
        -Query "EXEC master.dbo.xp_fileexist $(ConvertTo-DagQuotedString $Path)"

    [pscustomobject]@{
        FileExists   = ([int]$rows[0].'File Exists' -eq 1)
        IsDirectory  = ([int]$rows[0].'File is a Directory' -eq 1)
        ParentExists = ([int]$rows[0].'Parent Directory Exists' -eq 1)
    }
}

function Get-DagRemoteFile {
    <#
    .SYNOPSIS
        Lists files (not directories) directly inside $Path, as seen by $Instance.

    .DESCRIPTION
        Prefers sys.dm_os_enumerate_filesystem (SQL 2017+, gives sizes) and falls back
        to xp_dirtree on older builds. Returns an empty array when the directory does
        not exist — an absent log folder is a normal state on a first run, not an error.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Path,
        [string]$Pattern = '*'
    )

    $exists = Test-DagRemotePath -Instance $Instance -Path $Path
    if (-not $exists.FileExists -and -not $exists.IsDirectory) { return @() }

    $pathLit = ConvertTo-DagQuotedString $Path
    $patLit  = ConvertTo-DagQuotedString $Pattern

    try {
        $rows = Invoke-DagSql -Instance $Instance -Retry -Activity 'enumerate files' -QueryTimeout 300 -Query @"
SELECT full_filesystem_path AS FullPath,
       [file_or_directory_name] AS Name,
       CAST(size_in_bytes AS bigint) AS SizeBytes,
       last_write_time AS LastWriteTime
FROM sys.dm_os_enumerate_filesystem($pathLit, $patLit)
WHERE is_directory = 0
"@
    } catch {
        Write-DagLog "  sys.dm_os_enumerate_filesystem unavailable on $Instance; falling back to xp_dirtree" DEBUG
        $tree = Invoke-DagSql -Instance $Instance -Retry -Activity 'enumerate files (xp_dirtree)' -QueryTimeout 300 `
            -Query "EXEC master.dbo.xp_dirtree $pathLit, 1, 1"
        if (-not $tree) { return @() }

        $rows = foreach ($t in $tree) {
            if ([int]$t.file -ne 1) { continue }
            $name = [string]$t.subdirectory
            if ($Pattern -ne '*' -and $name -notlike $Pattern) { continue }
            [pscustomobject]@{
                FullPath      = (Join-DagPath -Path $Path -ChildPath @($name))
                Name          = $name
                SizeBytes     = [long]0
                LastWriteTime = $null
            }
        }
    }

    if (-not $rows) { return @() }
    $out = foreach ($r in $rows) {
        [pscustomobject]@{
            FullPath      = [string]$r.FullPath
            Name          = [string]$r.Name
            SizeBytes     = [long]$r.SizeBytes
            LastWriteTime = $r.LastWriteTime
        }
    }
    return @($out)
}

function Test-DagShareWritable {
    <#
    .SYNOPSIS
        Proves the SQL Server service account on $Instance can create directories AND
        write files under $Path, by doing exactly that.

    .DESCRIPTION
        A directory create alone is not proof of file-write permission on every ACL
        shape, so this also writes a real (tiny, COPY_ONLY) backup of master and then
        verifies it is readable. Returns $null on success, or the failure message.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Path
    )

    $probeDir  = Join-DagPath -Path $Path -ChildPath @('_dagprobe')
    $probeFile = Join-DagPath -Path $probeDir -ChildPath @("write_test_$(Get-DagSafeFileToken $Instance).bak")

    try {
        New-DagRemoteDirectory -Instance $Instance -Path $probeDir
        Invoke-DagSql -Instance $Instance -QueryTimeout 300 -Activity 'share write probe' -Query @"
BACKUP DATABASE [master] TO DISK = $(ConvertTo-DagQuotedString $probeFile)
WITH COPY_ONLY, INIT, FORMAT, COMPRESSION, DESCRIPTION = N'Initialize-DAG write probe';
"@ | Out-Null

        Invoke-DagSql -Instance $Instance -QueryTimeout 120 -Activity 'share read probe' `
            -Query "RESTORE HEADERONLY FROM DISK = $(ConvertTo-DagQuotedString $probeFile)" | Out-Null

        Remove-DagRemoteFile -Instance $Instance -Path $probeFile
        return $null
    } catch {
        return $_.Exception.Message.Split("`n")[0]
    }
}

function Remove-DagRemoteFile {
    <#
    .SYNOPSIS
        Best-effort delete of a file via xp_delete_files (2019+) / xp_delete_file.
        Used only for cleaning up probe artifacts; failure is never fatal.
    #>
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        Invoke-DagSql -Instance $Instance -QueryTimeout 60 -Activity 'delete probe file' `
            -Query "EXEC master.sys.xp_delete_files $(ConvertTo-DagQuotedString $Path)" | Out-Null
    } catch {
        Write-DagLog "  could not remove probe file $Path (harmless): $($_.Exception.Message.Split("`n")[0])" DEBUG
    }
}
