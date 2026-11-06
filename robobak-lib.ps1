# robobak-lib.ps1 - Shared functions for RoboBak.
# Dot-sourced by robobak.ps1 and by the tests (tests\run-tests.ps1).
# It only defines functions: loading it changes nothing on any drive.

# --- TEST MODE ---

# Test mode lets the tests run RoboBak against temporary folders instead of
# real drives. It is on only while the ROBOBAK_TEST environment variable is set.
# Format: entries separated by ";":
#   <letter>=<folder>|<label>   a fake drive: the letter maps to a folder and a label
#   local=<folder>              the folder used instead of the repo's local\ folder
# Example:
#   F=C:\Temp\rb\src|DATA;E=C:\Temp\rb\dst|BACKUP_TEST;local=C:\Temp\rb\local
# In test mode, letters resolve ONLY through this map: an unmapped letter is an
# error, never a real drive. Folders must not contain spaces, because robocopy
# misreads a quoted path that ends in a backslash ("C:\a b\" becomes C:\a b").

function Test-RoboBakTestMode {
    return -not [string]::IsNullOrWhiteSpace($env:ROBOBAK_TEST)
}

# Get-RoboBakTestMap: parses ROBOBAK_TEST. Returns $null when test mode is off.
# Throws on a malformed entry, so a typo never falls back to a real drive.
function Get-RoboBakTestMap {
    if (-not (Test-RoboBakTestMode)) { return $null }
    $map = @{ Drives = @{}; Local = $null }
    foreach ($entry in ($env:ROBOBAK_TEST -split ';')) {
        $e = $entry.Trim()
        if (-not $e) { continue }
        $eq = $e.IndexOf('=')
        if ($eq -lt 1) { throw "ROBOBAK_TEST: invalid entry '$e' (expected <letter>=<folder>|<label> or local=<folder>)." }
        $key = $e.Substring(0, $eq).Trim()
        $value = $e.Substring($eq + 1).Trim()
        $parts = $value -split '\|', 2
        $folder = $parts[0].Trim().TrimEnd('\')
        if (-not $folder -or -not [System.IO.Path]::IsPathRooted($folder)) {
            throw "ROBOBAK_TEST: '$key' needs a full folder path, got '$($parts[0])'."
        }
        if ($folder -match '\s') {
            throw "ROBOBAK_TEST: folder '$folder' contains spaces, which robocopy misreads. Use a folder without spaces."
        }
        if ($key -ieq 'local') {
            $map.Local = $folder
        } elseif ($key -match '^[A-Za-z]$') {
            $label = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
            $map.Drives[$key.ToUpper()] = @{ Folder = $folder; Label = $label }
        } else {
            throw "ROBOBAK_TEST: '$key' is not a drive letter or 'local'."
        }
    }
    return $map
}

# --- DRIVES ---

# Get-DriveRoot: the root path for a drive letter ("F:\"), or in test mode the
# mapped folder with a trailing backslash. Returns $null for an unmapped letter
# in test mode.
function Get-DriveRoot {
    param([string]$Letter)
    $map = Get-RoboBakTestMap
    if ($map) {
        $drive = $map.Drives[$Letter.ToUpper()]
        if (-not $drive) { return $null }
        return $drive.Folder + '\'
    }
    return "${Letter}:\"
}

# Get-DriveLabel: the volume label (drive name).
# Primary method: Get-Volume (CIM/WMI). -ErrorAction SilentlyContinue suppresses
# the red error message it can produce if Windows hasn't finished updating volume
# metadata (e.g., right after renaming a drive with admin privileges).
# Fallback: [System.IO.DriveInfo] (.NET). Some volumes (e.g., VeraCrypt-mounted
# drives) don't expose their label through CIM but do through .NET's DriveInfo.
# In test mode the label comes from ROBOBAK_TEST.
function Get-DriveLabel {
    param([string]$Letter)
    $map = Get-RoboBakTestMap
    if ($map) {
        $drive = $map.Drives[$Letter.ToUpper()]
        if (-not $drive) { return $null }
        return $drive.Label
    }
    $label = (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue).FileSystemLabel
    if ([string]::IsNullOrEmpty($label)) {
        $label = [System.IO.DriveInfo]::new("${Letter}:").VolumeLabel
    }
    return $label
}

# Get-DriveSpace: total size and free space of the drive, through
# [System.IO.DriveInfo], which works with all volume types including
# VeraCrypt-mounted drives. In test mode: the volume that holds the folder.
function Get-DriveSpace {
    param([string]$Letter)
    $map = Get-RoboBakTestMap
    if ($map) {
        $info = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot((Get-DriveRoot $Letter)))
    } else {
        $info = [System.IO.DriveInfo]::new("${Letter}:")
    }
    return [pscustomobject]@{ TotalSize = [int64]$info.TotalSize; TotalFreeSpace = [int64]$info.TotalFreeSpace }
}

# --- SETTINGS (local\settings.json) ---

# Get-RoboBakLocalDir: the Git-ignored local\ folder next to the scripts.
# In test mode: the "local=" folder from ROBOBAK_TEST, or $null (defaults only),
# so tests never read the real local\ folder.
function Get-RoboBakLocalDir {
    param([string]$ScriptRoot)
    $map = Get-RoboBakTestMap
    if ($map) { return $map.Local }
    return (Join-Path $ScriptRoot 'local')
}

# Read-RoboBakSettings: reads the "robobak" section of local\settings.json.
# RoboBak only reads this file and never creates it. A missing file, section
# or key means the default. A value that can't be read is reported in .Warning
# and replaced by its default.
#   deleteWarnFiles  red warning above this many files to delete (default 500)
#   deleteWarnGB     red warning above this many GB to delete (default 5)
function Read-RoboBakSettings {
    param([string]$LocalDir)
    $result = [pscustomobject]@{ DeleteWarnFiles = 500; DeleteWarnGB = 5; Warning = $null }
    if (-not $LocalDir) { return $result }
    $file = Join-Path $LocalDir 'settings.json'
    if (-not (Test-Path -LiteralPath $file)) { return $result }
    try {
        $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $result.Warning = "Could not read `"$file`" (invalid JSON). Using the default thresholds."
        return $result
    }
    $section = $json.robobak
    if ($null -eq $section) { return $result }
    $bad = @()
    foreach ($pair in @(@('deleteWarnFiles', 'DeleteWarnFiles'), @('deleteWarnGB', 'DeleteWarnGB'))) {
        $value = $section.($pair[0])
        if ($null -eq $value) { continue }
        $number = 0.0
        if ([double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge 0) {
            $result.($pair[1]) = $number
        } else {
            $bad += $pair[0]
        }
    }
    if ($bad.Count -gt 0) {
        $result.Warning = "Ignored invalid value(s) in `"$file`": $($bad -join ', '). Using the default for those."
    }
    return $result
}

# --- FORMATTING ---

# Format-Size: bytes as a short text, in the current culture (e.g. "3,2 GB" in
# Spanish). Units are binary (1 GB = 1024^3 bytes), like the disk space check.
function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

# --- DRY RUN ---

# The dry run is robocopy in list-only mode (/L) with the same /MIR and the same
# exclusions as the real copy: it reports what the copy would delete and copy,
# and changes nothing. Its output is parsed in a language-independent way:
#
# - The summary table is read BY POSITION. Its labels are translated (e.g.
#   "Archivos", "Copiado" in Spanish), but its layout isn't: after the LAST line
#   of dashes come a header row, then the Dirs, Files, Bytes and Times rows. Each
#   row is split on its first ":" into 6 columns: Total, Copied, Skipped,
#   Mismatch, Failed, Extras. With /MIR, the Extras column is what gets deleted.
#   /BYTES keeps the Bytes row as plain integers (no "1.2 g" units).
# - File lines look like: TAB label TAB TAB size TAB full-path (with /FP).
#   Lines tagged "EXTRA" (a robocopy constant, never translated, matched
#   case-sensitively) are deletions; every other file line is a copy (new or
#   changed). Files inside a deleted folder are listed one by one, under a
#   "*EXTRA Dir" line ("*Directorio EXTRA" in Spanish) ending in a backslash.

$script:RoboFileLineRegex  = '^\t(?<label>[^\t]*)\t\t\s*(?<size>\d+)\t(?<path>.*[^\\])$'
$script:RoboExtraDirRegex  = '^\t(?<label>[^\t]*EXTRA[^\t]*?)\s+-?\d+\t(?<path>.*\\)$'

# ConvertFrom-RoboStatsRow: one row of the summary table -> 6 numbers, or $null.
function ConvertFrom-RoboStatsRow {
    param([string]$Line)
    if ($null -eq $Line) { return $null }
    $colon = $Line.IndexOf(':')
    if ($colon -lt 0) { return $null }
    $tokens = $Line.Substring($colon + 1).Trim() -split '\s+'
    if ($tokens.Count -ne 6) { return $null }
    $values = New-Object 'int64[]' 6
    for ($i = 0; $i -lt 6; $i++) {
        if ($tokens[$i] -notmatch '^\d+$') { return $null }
        $values[$i] = [int64]$tokens[$i]
    }
    return , $values
}

# Get-LastRoboSeparator: index of the last line of dashes in a robocopy log
# (the one just above the summary table), or -1.
function Get-LastRoboSeparator {
    param([string[]]$Lines)
    if (-not $Lines) { return -1 }
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        if ($Lines[$i] -match '^\s*-{10,}\s*$') { return $i }
    }
    return -1
}

# Get-RoboSummaryLines: the summary table at the end of a robocopy log, for the
# screen: the lines after the last line of dashes, without the leading blank
# lines, and at most 15 (the table and the lines after it are about 10).
# Without a line of dashes, the last 8 lines.
function Get-RoboSummaryLines {
    param([string[]]$Lines)
    if (-not $Lines) { return @() }
    $sep = Get-LastRoboSeparator $Lines
    if ($sep -lt 0) { return @($Lines | Select-Object -Last 8) }
    $start = $sep + 1
    while ($start -lt $Lines.Count -and -not $Lines[$start].Trim()) { $start++ }
    if ($start -ge $Lines.Count) { return @() }
    return @($Lines[$start..($Lines.Count - 1)] | Select-Object -First 15)
}

# Read-RoboStats: the Files and Bytes rows of the summary table, or $null if
# the table is missing or doesn't have the expected layout.
function Read-RoboStats {
    param([string[]]$Lines)
    if (-not $Lines) { return $null }
    $sep = Get-LastRoboSeparator $Lines
    if ($sep -lt 0) { return $null }
    # Skip blank lines, then: header, Dirs, Files, Bytes.
    $rows = @()
    for ($i = $sep + 1; $i -lt $Lines.Count -and $rows.Count -lt 4; $i++) {
        if ($Lines[$i].Trim()) { $rows += $Lines[$i] }
    }
    if ($rows.Count -lt 4) { return $null }
    $dirs  = ConvertFrom-RoboStatsRow $rows[1]
    $files = ConvertFrom-RoboStatsRow $rows[2]
    $bytes = ConvertFrom-RoboStatsRow $rows[3]
    if ($null -eq $dirs -or $null -eq $files -or $null -eq $bytes) { return $null }
    return [pscustomobject]@{
        DeleteFiles = $files[5]
        DeleteBytes = $bytes[5]
        CopyFiles   = $files[1]
        CopyBytes   = $bytes[1]
        FailedFiles = $files[4]
    }
}

# Read-RoboDryRunLog: parses a dry-run log written with /UNILOG (UTF-16).
# Returns the summary counts (Stats, $null if unreadable) and the list lines:
# deletions (folders and files) and copies, already formatted for the list file.
function Read-RoboDryRunLog {
    param([string]$LogPath)
    $deleteLines = New-Object System.Collections.Generic.List[string]
    $copyLines   = New-Object System.Collections.Generic.List[string]
    $lines = @()
    if (Test-Path -LiteralPath $LogPath) {
        $lines = [System.IO.File]::ReadAllLines($LogPath, [System.Text.Encoding]::Unicode)
    }
    $deleteFiles = 0; $copyFiles = 0
    foreach ($line in $lines) {
        if ($line -match $script:RoboFileLineRegex) {
            $entry = '{0,12}  {1}' -f (Format-Size ([int64]$Matches['size'])), $Matches['path']
            if ($Matches['label'] -cmatch 'EXTRA') { $deleteLines.Add($entry); $deleteFiles++ }
            else { $copyLines.Add($entry); $copyFiles++ }
        } elseif ($line -cmatch $script:RoboExtraDirRegex) {
            $deleteLines.Add('    [folder]  ' + $Matches['path'])
        }
    }
    return [pscustomobject]@{
        Stats             = Read-RoboStats $lines
        DeleteLines       = $deleteLines
        CopyLines         = $copyLines
        ListedDeleteFiles = $deleteFiles
        ListedCopyFiles   = $copyFiles
    }
}

# Invoke-RoboDryRun: runs the list-only robocopy and parses its log.
# Nothing is written to the source or the destination: the log goes to $LogPath,
# which the caller places in %TEMP%. No /MT: with several threads robocopy's
# lines can get mixed up, which the list can't tolerate.
function Invoke-RoboDryRun {
    param(
        [string]$Source,
        [string]$Dest,
        [string[]]$ExcludeDirs,
        [string]$LogPath
    )
    $roboArgs = @($Source, $Dest, "/MIR", "/L", "/BYTES", "/FP", "/R:3", "/W:5", "/XD") + $ExcludeDirs + @("/UNILOG:$LogPath")
    $start = Get-Date
    # Redirect stdout to $null to suppress robocopy's "Log file:" console notice
    & robocopy @roboArgs > $null
    $exitCode = $LASTEXITCODE
    $duration = (Get-Date) - $start
    $parsed = Read-RoboDryRunLog $LogPath
    return [pscustomobject]@{
        ExitCode          = $exitCode
        Duration          = $duration
        Stats             = $parsed.Stats
        DeleteLines       = $parsed.DeleteLines
        CopyLines         = $parsed.CopyLines
        ListedDeleteFiles = $parsed.ListedDeleteFiles
        ListedCopyFiles   = $parsed.ListedCopyFiles
    }
}

# Format-DryRunCounts: "delete N files (X) and copy M files (Y)", or $null if
# the counts are unknown.
function Format-DryRunCounts {
    param($Stats)
    if ($null -eq $Stats) { return $null }
    return ('delete {0} files ({1}) and copy {2} files ({3})' -f $Stats.DeleteFiles.ToString('N0'), (Format-Size $Stats.DeleteBytes), $Stats.CopyFiles.ToString('N0'), (Format-Size $Stats.CopyBytes))
}

# Test-LargeDeletion: true when the deletion is above either threshold.
function Test-LargeDeletion {
    param($Stats, $Settings)
    if ($null -eq $Stats) { return $false }
    return (($Stats.DeleteFiles -gt $Settings.DeleteWarnFiles) -or ($Stats.DeleteBytes -gt ($Settings.DeleteWarnGB * 1GB)))
}

# Write-DryRunList: the human-readable list (deletions first, then copies),
# UTF-8 with BOM so accented paths show correctly in Notepad.
function Write-DryRunList {
    param($DryRun, [string]$Path, [string]$SourceText, [string]$DestText)
    $writer = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($true)))
    try {
        $writer.WriteLine("# Generated by RoboBak. Dry-run list: what the mirror would delete from the destination, then what it would copy.")
        $writer.WriteLine("")
        $writer.WriteLine("Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $writer.WriteLine("Source: $SourceText")
        $writer.WriteLine("Destination: $DestText")
        $writer.WriteLine("Robocopy exit code (dry run): $($DryRun.ExitCode)")
        $counts = Format-DryRunCounts $DryRun.Stats
        if ($counts) { $writer.WriteLine("Summary: would $counts") }
        else { $writer.WriteLine("Summary: counts unknown (robocopy's summary table could not be read)") }
        if ($DryRun.ExitCode -ge 8) { $writer.WriteLine("WARNING: the dry run reported errors, so this list may be incomplete.") }
        $writer.WriteLine("")
        $writer.WriteLine("==== WILL DELETE from the destination ($($DryRun.ListedDeleteFiles) files) ====")
        $writer.WriteLine("Lines marked [folder] are folders deleted with everything in them; their files are listed after them.")
        $writer.WriteLine("")
        foreach ($l in $DryRun.DeleteLines) { $writer.WriteLine($l) }
        $writer.WriteLine("")
        $writer.WriteLine("==== WILL COPY from the source, new or changed ($($DryRun.ListedCopyFiles) files) ====")
        $writer.WriteLine("")
        foreach ($l in $DryRun.CopyLines) { $writer.WriteLine($l) }
    } finally {
        $writer.Close()
    }
}

# --- RUN RECORDS (local\runs.csv) ---

# One line per backup event, appended and never rewritten. RoboBak writes a
# line at the end of every mirror run that ran the copy, and --system-done
# writes one per system backup. The reminders window will read the file (and
# add "skipped" lines). Columns:
#   date          local time, yyyy-MM-dd HH:mm:ss
#   kind          mirror | system
#   source        source label (for a system backup: the computer's name)
#   destination   destination label
#   result        ok | failed | skipped
#   verification  passed | differences | not performed
#   health        not checked (until disk health exists) | ok | yellow | red | not approved
# The header is written unquoted when the file is created; rows are quoted by
# ConvertTo-Csv, so labels with commas, quotes or accents round-trip. UTF-8 with
# a BOM, so PowerShell 5.1 and Excel read accents correctly.

$script:RunsCsvHeader = 'date,kind,source,destination,result,verification,health'

# Get-RunsCsvPath: local\runs.csv, or $null when there is no local folder
# (test mode without "local=").
function Get-RunsCsvPath {
    param([string]$LocalDir)
    if (-not $LocalDir) { return $null }
    return (Join-Path $LocalDir 'runs.csv')
}

# Add-RunRecord: appends one line to local\runs.csv, creating the folder and the
# file (with its header) if needed. Returns the file's path, or $null if there
# is no local folder to write to.
function Add-RunRecord {
    param(
        [string]$LocalDir,
        [string]$Kind,
        [string]$Source,
        [string]$Destination,
        [string]$Result,
        [string]$Verification,
        [string]$Health = 'not checked',
        $Date = $null
    )
    $path = Get-RunsCsvPath $LocalDir
    if (-not $path) { return $null }
    if ($null -eq $Date) { $Date = Get-Date }
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }
    $record = [pscustomobject][ordered]@{
        date         = $Date.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        kind         = $Kind
        source       = $Source
        destination  = $Destination
        result       = $Result
        verification = $Verification
        health       = $Health
    }
    # ConvertTo-Csv returns the quoted header, then the row: keep the row only.
    $row = @($record | ConvertTo-Csv -NoTypeInformation)[1]
    $isNew = (-not (Test-Path -LiteralPath $path)) -or ((Get-Item -LiteralPath $path).Length -eq 0)
    if ($isNew) {
        [System.IO.File]::WriteAllText($path, $script:RunsCsvHeader + "`r`n" + $row + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    } else {
        [System.IO.File]::AppendAllText($path, $row + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    return $path
}

# Read-RunRecords: every line of local\runs.csv as objects (empty if the file
# doesn't exist).
function Read-RunRecords {
    param([string]$LocalDir)
    $path = Get-RunsCsvPath $LocalDir
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    return @(Import-Csv -LiteralPath $path -Encoding UTF8)
}
