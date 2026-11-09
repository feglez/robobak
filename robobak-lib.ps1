# robobak-lib.ps1 - Shared functions for RoboBak.
# Dot-sourced by robobak.ps1 and by the tests (tests\run-tests.ps1).
# It only defines functions: loading it changes nothing on any drive.

# --- TEST MODE ---

# Test mode lets the tests run RoboBak against temporary folders instead of
# real drives. It is on only while the ROBOBAK_TEST environment variable is set.
# Format: entries separated by ";":
#   <letter>=<folder>|<label>   a fake drive: the letter maps to a folder and a label
#   local=<folder>              the folder used instead of the repo's local\ folder
#   health=<folder>             recorded disk-health data (see "DISK HEALTH" below)
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
    $map = @{ Drives = @{}; Local = $null; Health = $null }
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
        } elseif ($key -ieq 'health') {
            $map.Health = $folder
        } elseif ($key -match '^[A-Za-z]$') {
            $label = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
            $map.Drives[$key.ToUpper()] = @{ Folder = $folder; Label = $label }
        } else {
            throw "ROBOBAK_TEST: '$key' is not a drive letter, 'local' or 'health'."
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
#   healthWarnHours  yellow disk-health warning above this many power-on hours (default 20000)
#   healthWarnYears  yellow disk-health warning for a disk older than this (default 5)
#   healthWarnTempC  yellow disk-health warning above this temperature in C (default 50)
function Read-RoboBakSettings {
    param([string]$LocalDir)
    $result = [pscustomobject]@{ DeleteWarnFiles = 500; DeleteWarnGB = 5; HealthWarnHours = 20000; HealthWarnYears = 5; HealthWarnTempC = 50; Warning = $null }
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
    foreach ($pair in @(@('deleteWarnFiles', 'DeleteWarnFiles'), @('deleteWarnGB', 'DeleteWarnGB'), @('healthWarnHours', 'HealthWarnHours'), @('healthWarnYears', 'HealthWarnYears'), @('healthWarnTempC', 'HealthWarnTempC'))) {
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
#   health        ok | yellow | red | not approved | not checked (no tool, or no disk could be read)
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

# --- TIME ESTIMATES (backup_times.txt and backup_history.txt) ---

# How long each step took before is read from the source drive's
# backup_logs\backup_times.txt, which keeps the last 10 runs. Each entry starts
# with "[yyyy-MM-dd HH:mm:ss] SOURCE -> DEST (STATUS)", followed by indented
# "Key: value" lines. Older entries lack some lines (no "Dry run duration"
# before the dry run existed, no "Copied (dry run)" before the estimates
# existed): a missing line, "not performed" or "unknown" reads as $null.

$script:DefaultCopySpeed = 50MB   # bytes per second when no large copy was measured
$script:MinCopyForSpeed  = 10GB   # smaller copies are too short to measure a reliable speed

# ConvertFrom-TimesDuration: "hh:mm:ss" -> TimeSpan; anything else -> $null.
function ConvertFrom-TimesDuration {
    param([string]$Text)
    if ($Text -match '^\s*(\d+):(\d{2}):(\d{2})\s*$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]; $s = [int]$Matches[3]
        return [TimeSpan]::new($h, $m, $s)
    }
    return $null
}

# Format-TimesBytes: bytes as written in backup_times.txt ("462.84 GB",
# invariant culture so it reads back on any system), or "unknown".
function Format-TimesBytes {
    param($Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2} GB', ($Bytes / 1GB))
}

# Read-TimesLogEntries: the entries of backup_times.txt, oldest first, as
# objects: Date, Source, Dest, Status, DryRun, Copy, Verify (TimeSpan or $null)
# and CopiedBytes (or $null). A missing or unreadable file gives no entries.
function Read-TimesLogEntries {
    param([string]$Path)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $content) { return @() }
    foreach ($block in ($content.Trim() -split '(?:\r?\n){2,}')) {
        $lines = @($block.Trim() -split '\r?\n')
        if ($lines[0] -notmatch '^\[(?<date>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (?<src>.*?) -> (?<dst>.*?) \((?<status>(?:OK|FAILED).*)\)$') { continue }
        $date = [datetime]::ParseExact($Matches['date'], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $src = $Matches['src']; $dst = $Matches['dst']; $status = $Matches['status']
        $values = @{}
        foreach ($l in ($lines | Select-Object -Skip 1)) {
            if ($l -match '^\s*(?<key>[^:]+):\s*(?<val>.*)$') { $values[$Matches['key'].Trim()] = $Matches['val'].Trim() }
        }
        $copied = $null
        if ($values['Copied (dry run)'] -match '^(?<n>\d+(?:\.\d+)?) GB$') {
            $copied = [int64]([double]::Parse($Matches['n'], [System.Globalization.CultureInfo]::InvariantCulture) * 1GB)
        }
        $entries.Add([pscustomobject]@{
            Date        = $date
            Source      = $src
            Dest        = $dst
            Status      = $status
            DryRun      = ConvertFrom-TimesDuration $values['Dry run duration']
            Copy        = ConvertFrom-TimesDuration $values['Copy duration']
            Verify      = ConvertFrom-TimesDuration $values['Verification duration']
            CopiedBytes = $copied
        })
    }
    return $entries.ToArray()
}

# Read-HistoryLabels: every drive label in backup_history.txt (which keeps every
# drive ever backed up to, unlike backup_times.txt). Empty if there is no file.
function Read-HistoryLabels {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match ' \| ' } | ForEach-Object { ($_ -split ' \| ')[0].Trim() })
}

# Format-ApproxDuration: "less than a minute", "about N min" or "about H h M min".
function Format-ApproxDuration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalSeconds -lt 60) { return 'less than a minute' }
    $minutes = [int][math]::Round($Duration.TotalMinutes)
    if ($minutes -lt 60) { return "about $minutes min" }
    $h = [int][math]::Floor($minutes / 60)
    $m = $minutes % 60
    if ($m -eq 0) { return "about $h h" }
    return "about $h h $m min"
}

# Get-EntrySpeed: the copy speed (bytes per second) one past run measured, or
# $null if it can't tell: only successful runs ("OK...") that copied at least
# 10 GB count. The dry run's time isn't taken out: the copy starts right after
# the dry run has read the folders, so going through them again takes seconds.
function Get-EntrySpeed {
    param($Entry)
    if ($Entry.Status -notmatch '^OK') { return $null }
    if ($null -eq $Entry.CopiedBytes -or $Entry.CopiedBytes -lt $script:MinCopyForSpeed) { return $null }
    if ($null -eq $Entry.Copy) { return $null }
    $seconds = $Entry.Copy.TotalSeconds
    if ($seconds -le 0) { return $null }
    return ($Entry.CopiedBytes / $seconds)
}

# Get-CopySpeed: the speed to estimate with, and where it comes from (Basis):
# "pair" (the most recent large copy to the same drive), "source" (the most
# recent large copy from the same source to another drive) or "default".
function Get-CopySpeed {
    param($Entries, [string]$Source, [string]$Dest)
    $list = @($Entries)
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $e = $list[$i]
        if ($e.Source -eq $Source -and $e.Dest -eq $Dest) {
            $s = Get-EntrySpeed $e
            if ($s) { return [pscustomobject]@{ BytesPerSecond = $s; Basis = 'pair'; Dest = $Dest } }
        }
    }
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $e = $list[$i]
        if ($e.Source -eq $Source) {
            $s = Get-EntrySpeed $e
            if ($s) { return [pscustomobject]@{ BytesPerSecond = $s; Basis = 'source'; Dest = $e.Dest } }
        }
    }
    return [pscustomobject]@{ BytesPerSecond = [double]$script:DefaultCopySpeed; Basis = 'default'; Dest = $null }
}

# Get-CopyEstimateText: the confirmation screen's estimate of the copy time:
# the bytes to copy at the speed from Get-CopySpeed.
function Get-CopyEstimateText {
    param($Stats, $Entries, [string]$Source, [string]$Dest, [bool]$FirstBackup)
    $prefix = if ($FirstBackup) { "First backup to $Dest. " } else { '' }
    if ($null -eq $Stats) {
        return $prefix + "The copy time can't be estimated: the dry run's counts are unknown."
    }
    $speed = Get-CopySpeed $Entries $Source $Dest
    $estimate = [TimeSpan]::FromSeconds($Stats.CopyBytes / $speed.BytesPerSecond)
    $size = Format-Size $Stats.CopyBytes
    $rate = ('{0:N1}' -f ($speed.BytesPerSecond / 1MB)) + ' MB/s'
    switch ($speed.Basis) {
        'pair'   { $basis = "$size at $rate, measured on the last large copy to $Dest" }
        'source' { $basis = "$size at $rate, measured on a copy to $($speed.Dest)" }
        default  { $basis = "$size at " + ('{0:N0}' -f ($speed.BytesPerSecond / 1MB)) + " MB/s, a default: no large copy measured yet" }
    }
    return "${prefix}Estimated copy time: $(Format-ApproxDuration $estimate) ($basis)"
}

# Get-DryRunHintText: how long the last dry run took, shown before it starts.
function Get-DryRunHintText {
    param($Entries, [string]$Source, [string]$Dest)
    $list = @($Entries)
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $e = $list[$i]
        if ($e.Source -eq $Source -and $e.Dest -eq $Dest -and $null -ne $e.DryRun) {
            return "Last time to $Dest it took $($e.DryRun.ToString('hh\:mm\:ss'))."
        }
    }
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $e = $list[$i]
        if ($e.Source -eq $Source -and $null -ne $e.DryRun) {
            return "No previous dry run to $Dest; to $($e.Dest) it took $($e.DryRun.ToString('hh\:mm\:ss'))."
        }
    }
    return "First dry run from this drive: no previous time to compare."
}

# Get-VerifyHintText: how long the last verification to the same drive took.
function Get-VerifyHintText {
    param($Entries, [string]$Source, [string]$Dest)
    $list = @($Entries)
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $e = $list[$i]
        if ($e.Source -eq $Source -and $e.Dest -eq $Dest -and $null -ne $e.Verify) {
            return "Last time to $Dest it took $($e.Verify.ToString('hh\:mm\:ss'))."
        }
    }
    return "First verification to ${Dest}: no previous time."
}

# --- DISK HEALTH ---

# At the end of a run, RoboBak can log the health of the disks it used. Reading
# SMART needs admin rights, so an elevated helper (robobak-health.ps1) reads every
# connected disk once and hands the result back through a temporary file. It uses
# smartmontools (smartctl -a -j); the disks smartctl can't read come from
# CrystalDiskInfo (/CopyExit) instead. These functions do the reading, the parsing
# and the comparison; the prompts and the screen are in robobak.ps1.
#
# Each drive keeps its own history, one line per check, never wiped:
#   data drive (the source):            backup_logs\disk_health.txt
#   backup drives, image partition:     robobak_health\disk_health.txt
# robobak_health\ is excluded from the mirror and the verification.
#
# A plain partition is matched to its disk through Windows (letter, then
# Get-Partition's disk number, then /dev/pdN). Windows can't do that for a
# VeraCrypt volume, so the first time RoboBak asks which disk holds it and saves
# smartctl's serial in disk_link.json, on the drive, next to disk_health.txt.
#
# In test mode (a "health=<folder>" entry in ROBOBAK_TEST), the folder replaces
# the tools and Windows:
#   pd<N>.json, pd<N>.sat.json  what smartctl would print for /dev/pd<N> (without
#                               and with "-d sat")
#   DiskInfo.txt                what CrystalDiskInfo would write
#   disk_of_<LETTER>.txt        the disk number of a plain partition
#   cancel_elevation.txt        the admin prompt is cancelled

$script:SmartctlPath        = 'C:\Program Files\smartmontools\bin\smartctl.exe'
$script:CrystalDiskInfoPath = 'C:\Program Files\CrystalDiskInfo\DiskInfo64.exe'
$script:HealthDirName       = 'robobak_health'

# Get-HealthDir: the folder that holds a drive's health history and disk link.
# Role: source (the data drive), destination or image (the system image partition).
function Get-HealthDir {
    param([string]$Root, [string]$Role)
    if ($Role -eq 'source') { return (Join-Path $Root 'backup_logs') }
    return (Join-Path $Root $script:HealthDirName)
}

# Test-HealthToolAvailable: is there anything to read SMART with?
function Test-HealthToolAvailable {
    $map = Get-RoboBakTestMap
    if ($map) {
        if (-not $map.Health) { return $false }
        return (@(Get-ChildItem -LiteralPath $map.Health -Filter 'pd*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) -or (Test-Path -LiteralPath (Join-Path $map.Health 'DiskInfo.txt'))
    }
    return (Test-Path -LiteralPath $script:SmartctlPath) -or (Test-Path -LiteralPath $script:CrystalDiskInfoPath)
}

# New-HealthReading: one disk as read by a tool. A value the tool doesn't give
# is $null. Number is the Windows disk number (smartctl only).
function New-HealthReading {
    param($Number, [string]$Model, [string]$Serial, $CapacityBytes, $Passed, $A05, $AC5, $AC6, $AC7, $Hours, $TempC, [string]$Tool, [string]$DriveLetters)
    return [pscustomobject][ordered]@{
        Number = $Number; Model = $Model; Serial = $Serial; CapacityBytes = $CapacityBytes
        Passed = $Passed; A05 = $A05; AC5 = $AC5; AC6 = $AC6; AC7 = $AC7
        Hours = $Hours; TempC = $TempC; Tool = $Tool; DriveLetters = $DriveLetters
    }
}

# ConvertFrom-SmartctlJson: the output of "smartctl -a -j" -> a reading, or $null
# if it doesn't identify a disk. It reads smart_status and the attribute table,
# not smartctl's exit code, which is a bitmask that can be non-zero on a healthy
# disk. NVMe disks have no attribute table, so their 05, C5, C6 and C7 are $null.
function ConvertFrom-SmartctlJson {
    param([string]$Text, $Number = $null)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $json = $Text | ConvertFrom-Json } catch { return $null }
    if ($null -eq $json -or [string]::IsNullOrEmpty($json.serial_number)) { return $null }
    $passed = $null
    if ($null -ne $json.smart_status -and $null -ne $json.smart_status.passed) { $passed = [bool]$json.smart_status.passed }
    $raw = @{}
    foreach ($row in @($json.ata_smart_attributes.table)) {
        if ($null -ne $row -and $null -ne $row.id -and $null -ne $row.raw -and $null -ne $row.raw.value) { $raw[[int]$row.id] = [int64]$row.raw.value }
    }
    $capacity = $null
    if ($null -ne $json.user_capacity -and $null -ne $json.user_capacity.bytes) { $capacity = [int64]$json.user_capacity.bytes }
    elseif ($null -ne $json.nvme_total_capacity) { $capacity = [int64]$json.nvme_total_capacity }
    $hours = $null
    if ($null -ne $json.power_on_time -and $null -ne $json.power_on_time.hours) { $hours = [int64]$json.power_on_time.hours }
    $temp = $null
    if ($null -ne $json.temperature -and $null -ne $json.temperature.current) { $temp = [int]$json.temperature.current }
    return (New-HealthReading -Number $Number -Model $json.model_name -Serial $json.serial_number -CapacityBytes $capacity -Passed $passed -A05 $raw[5] -AC5 $raw[197] -AC6 $raw[198] -AC7 $raw[199] -Hours $hours -TempC $temp -Tool 'smartctl')
}

# ConvertFrom-CrystalDiskInfoText: the contents of DiskInfo.txt -> a reading per
# disk. The headings ("Serial Number :") are fixed English text. The attribute
# names are translated, so attributes are matched on the ID column, and the raw
# values are hexadecimal. The health word can be translated too: only "Good" and
# "Bad" are understood, and anything else reads as unknown.
function ConvertFrom-CrystalDiskInfoText {
    param([string]$Text)
    $readings = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $current = $null
    $flush = {
        if ($null -ne $current -and $current.Serial) {
            $readings.Add((New-HealthReading -Model $current.Model -Serial $current.Serial -CapacityBytes $current.Capacity -Passed $current.Passed -A05 $current.Raw[5] -AC5 $current.Raw[197] -AC6 $current.Raw[198] -AC7 $current.Raw[199] -Hours $current.Hours -TempC $current.TempC -Tool 'crystaldiskinfo' -DriveLetters $current.Letters))
        }
    }
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*Model\s*:\s*(?<v>.*?)\s*$') {
            . $flush
            $current = @{ Model = $Matches['v']; Serial = ''; Capacity = $null; Passed = $null; Hours = $null; TempC = $null; Letters = ''; Raw = @{} }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*Serial Number\s*:\s*(?<v>.*?)\s*$') { $current.Serial = $Matches['v'] }
        elseif ($line -match '^\s*Disk Size\s*:\s*(?<v>\d+(?:\.\d+)?)\s*GB') { $current.Capacity = [int64]([double]::Parse($Matches['v'], [System.Globalization.CultureInfo]::InvariantCulture) * 1000000000) }
        elseif ($line -match '^\s*Power On Hours\s*:\s*(?<v>\d+)') { $current.Hours = [int64]$Matches['v'] }
        elseif ($line -match '^\s*Temperature\s*:\s*(?<v>\d+)') { $current.TempC = [int]$Matches['v'] }
        elseif ($line -match '^\s*Health Status\s*:\s*(?<v>\S+)') {
            if ($Matches['v'] -eq 'Good') { $current.Passed = $true }
            elseif ($Matches['v'] -eq 'Bad') { $current.Passed = $false }
        }
        elseif ($line -match '^\s*Drive Letter\s*:\s*(?<v>.*?)\s*$') { $current.Letters = $Matches['v'] }
        elseif ($line -match '^(?<id>[0-9A-Fa-f]{2})\s+\S+\s+\S+\s+\S+\s+(?<raw>[0-9A-Fa-f]{12})\b') {
            $current.Raw[[Convert]::ToInt32($Matches['id'], 16)] = [Convert]::ToInt64($Matches['raw'], 16)
        }
    }
    . $flush
    return $readings.ToArray()
}

# Get-HealthDiskNumbers: the Windows numbers of the connected disks.
function Get-HealthDiskNumbers {
    $map = Get-RoboBakTestMap
    if ($map) {
        return @(Get-ChildItem -LiteralPath $map.Health -Filter 'pd*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Name -match '^pd(\d+)\.') { [int]$Matches[1] } } | Sort-Object -Unique)
    }
    return @(Get-CimInstance Win32_DiskDrive | ForEach-Object { [int]$_.Index } | Sort-Object)
}

# Invoke-Smartctl: what "smartctl -a -j" prints for a disk, as one string, or an
# empty string. -Sat adds "-d sat", which some USB enclosures need.
function Invoke-Smartctl {
    param([int]$Number, [switch]$Sat)
    $map = Get-RoboBakTestMap
    if ($map) {
        $name = if ($Sat) { "pd$Number.sat.json" } else { "pd$Number.json" }
        $file = Join-Path $map.Health $name
        if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8) }
        return ''
    }
    $smartArgs = @('-a', '-j')
    if ($Sat) { $smartArgs += @('-d', 'sat') }
    $smartArgs += "/dev/pd$Number"
    return ((& $script:SmartctlPath @smartArgs 2>$null) -join "`n")
}

# Get-CrystalDiskInfoText: runs CrystalDiskInfo and returns its report, or an
# empty string if it isn't there. It writes DiskInfo.txt next to its executable.
# An old report is deleted first, so a run that fails can't pass for today's.
function Get-CrystalDiskInfoText {
    $map = Get-RoboBakTestMap
    if ($map) {
        $file = Join-Path $map.Health 'DiskInfo.txt'
    } else {
        if (-not (Test-Path -LiteralPath $script:CrystalDiskInfoPath)) { return '' }
        $file = Join-Path (Split-Path -Parent $script:CrystalDiskInfoPath) 'DiskInfo.txt'
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath $script:CrystalDiskInfoPath -ArgumentList '/CopyExit' -Wait -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
}

# Get-HealthReadings: reads every connected disk, in the elevated helper. Disks
# smartctl can't read, even with "-d sat", come from CrystalDiskInfo.
function Get-HealthReadings {
    $disks = New-Object System.Collections.Generic.List[object]
    $map = Get-RoboBakTestMap
    $needFallback = $false
    $numbers = @(Get-HealthDiskNumbers)
    $hasSmartctl = if ($map) { $numbers.Count -gt 0 } else { Test-Path -LiteralPath $script:SmartctlPath }
    if ($hasSmartctl) {
        foreach ($n in $numbers) {
            $reading = ConvertFrom-SmartctlJson (Invoke-Smartctl $n) $n
            if ($null -eq $reading) { $reading = ConvertFrom-SmartctlJson (Invoke-Smartctl $n -Sat) $n }
            if ($null -ne $reading) { $disks.Add($reading) } else { $needFallback = $true }
        }
    } else {
        $needFallback = $true
    }
    if ($needFallback) {
        foreach ($reading in @(ConvertFrom-CrystalDiskInfoText (Get-CrystalDiskInfoText))) {
            if (-not ($disks | Where-Object { $_.Serial -eq $reading.Serial })) { $disks.Add($reading) }
        }
    }
    return [pscustomobject]@{ Disks = $disks.ToArray(); Error = $null }
}

# Get-DiskNumberForLetter: the disk number of a plain partition, or $null for a
# volume Windows has no partition for, such as a mounted VeraCrypt volume.
function Get-DiskNumberForLetter {
    param([string]$Letter)
    $map = Get-RoboBakTestMap
    if ($map) {
        $file = Join-Path $map.Health "disk_of_$($Letter.ToUpper()).txt"
        if (Test-Path -LiteralPath $file) { return [int](Get-Content -LiteralPath $file -Raw).Trim() }
        return $null
    }
    $partition = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($null -eq $partition) { return $null }
    return [int]@($partition)[0].DiskNumber
}

# Find-DiskByLetter: the reading of a plain partition's disk: by disk number, or
# for a CrystalDiskInfo reading (which has none) by the letters it lists.
function Find-DiskByLetter {
    param($Disks, [string]$Letter, $Number)
    foreach ($d in @($Disks)) { if ($null -ne $d.Number -and $d.Number -eq $Number) { return $d } }
    foreach ($d in @($Disks)) { if ($d.DriveLetters -match "(^|\s)$Letter`:") { return $d } }
    return $null
}

# Read-DiskLink / Write-DiskLink: disk_link.json, which remembers on the drive
# which disk holds it (serial) and the year it was bought (or $null).
function Read-DiskLink {
    param([string]$HealthDir)
    $file = Join-Path $HealthDir 'disk_link.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-DiskLink {
    param([string]$HealthDir, [string]$Serial, [string]$Model, $Year)
    if (-not (Test-Path -LiteralPath $HealthDir)) { New-Item -ItemType Directory -Path $HealthDir -Force | Out-Null }
    $text = [pscustomobject][ordered]@{ serial = $Serial; model = $Model; year = $Year } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $HealthDir 'disk_link.json'), $text, (New-Object System.Text.UTF8Encoding($true)))
}

# Format-HealthValue: a value as written in disk_health.txt.
function Format-HealthValue {
    param($Value)
    if ($null -eq $Value) { return 'unknown' }
    return (([string]$Value) -replace '\|', '/').Trim()
}

# ConvertTo-HealthLine: one line of disk_health.txt. Without a reading, the line
# only says why: level is "not approved" or "not checked".
function ConvertTo-HealthLine {
    param([string]$Kind, [string]$Level, $Reading, [int]$CopyErrors, [string]$Verification, $Date = $null)
    if ($null -eq $Date) { $Date = Get-Date }
    $fields = @($Date.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $Kind, "level=$Level")
    if ($null -ne $Reading) {
        $smart = if ($null -eq $Reading.Passed) { 'unknown' } elseif ($Reading.Passed) { 'passed' } else { 'failed' }
        $fields += "smart=$smart"
        $fields += "05=$(Format-HealthValue $Reading.A05)"
        $fields += "C5=$(Format-HealthValue $Reading.AC5)"
        $fields += "C6=$(Format-HealthValue $Reading.AC6)"
        $fields += "C7=$(Format-HealthValue $Reading.AC7)"
        $fields += "hours=$(Format-HealthValue $Reading.Hours)"
        $fields += "tempC=$(Format-HealthValue $Reading.TempC)"
        $fields += "serial=$(Format-HealthValue $Reading.Serial)"
        $fields += "model=$(Format-HealthValue $Reading.Model)"
        $fields += "tool=$(Format-HealthValue $Reading.Tool)"
    }
    $fields += "copyErrors=$CopyErrors"
    $fields += "verification=$Verification"
    return ($fields -join ' | ')
}

# ConvertFrom-HealthLine: a line of disk_health.txt -> a hashtable, or $null for
# the header and blank lines.
function ConvertFrom-HealthLine {
    param([string]$Line)
    if ($Line -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| ') { return $null }
    $parts = @($Line -split ' \| ')
    $values = @{ date = $parts[0]; kind = $parts[1] }
    foreach ($p in ($parts | Select-Object -Skip 2)) {
        $eq = $p.IndexOf('=')
        if ($eq -gt 0) { $values[$p.Substring(0, $eq)] = $p.Substring($eq + 1) }
    }
    return $values
}

# Read-PreviousHealthReading: the newest line of a history with a reading of the
# same disk, as numbers ($null for "unknown"), or $null if there is none. Lines
# that only say "not approved" or "not checked" are skipped.
function Read-PreviousHealthReading {
    param([string]$Path, [string]$Serial)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    $wanted = Format-HealthValue $Serial
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $v = ConvertFrom-HealthLine $lines[$i]
        if ($null -eq $v -or -not $v.ContainsKey('smart') -or $v['serial'] -ne $wanted) { continue }
        $number = { param($t) if ($t -match '^\d+$') { [int64]$t } else { $null } }
        return [pscustomobject]@{ A05 = (& $number $v['05']); AC5 = (& $number $v['C5']); AC6 = (& $number $v['C6']); AC7 = (& $number $v['C7']) }
    }
    return $null
}

# Add-HealthLine: appends a line to a drive's disk_health.txt, creating the
# folder and the file (UTF-8 with a BOM, with its header) if needed.
function Add-HealthLine {
    param([string]$HealthDir, [string]$Line)
    if (-not (Test-Path -LiteralPath $HealthDir)) { New-Item -ItemType Directory -Path $HealthDir -Force | Out-Null }
    $file = Join-Path $HealthDir 'disk_health.txt'
    if (-not (Test-Path -LiteralPath $file)) {
        $header = "# Generated by RoboBak. Disk health history of this drive, one line per check, never wiped.`r`n`r`n"
        [System.IO.File]::WriteAllText($file, $header, (New-Object System.Text.UTF8Encoding($true)))
    }
    [System.IO.File]::AppendAllText($file, $Line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# Get-HealthWarnings: the warnings for one disk, compared with the previous line
# of the same drive's history ($null on a first reading). Red:
#   SMART status not OK; 05, C5 or C6 rising, or above zero for the first time;
#   copy errors or a failed verification in this run.
# Yellow:
#   05, C5 or C6 above zero but not rising; C7 rising; power-on hours, age or
#   temperature above the thresholds in $Settings.
function Get-HealthWarnings {
    param($Reading, $Previous, [int]$CopyErrors, [string]$Result, [string]$Verification, $Settings, $Year = $null, [int]$CurrentYear = (Get-Date).Year)
    $warnings = New-Object System.Collections.Generic.List[object]
    $add = { param($level, $text) $warnings.Add([pscustomobject]@{ Level = $level; Text = $text }) }

    if ($Reading.Passed -eq $false) { & $add 'red' 'SMART status is not OK.' }
    foreach ($a in @(@('A05', '05', 'reallocated sectors'), @('AC5', 'C5', 'pending sectors'), @('AC6', 'C6', 'uncorrectable sectors'))) {
        $now = $Reading.($a[0])
        if ($null -eq $now -or $now -le 0) { continue }
        $before = if ($null -ne $Previous) { $Previous.($a[0]) } else { $null }
        if ($null -eq $before -or $before -eq 0) { & $add 'red' "$($a[1]) ($($a[2])) is above zero for the first time: $now." }
        elseif ($now -gt $before) { & $add 'red' "$($a[1]) ($($a[2])) rose from $before to $now." }
        else { & $add 'yellow' "$($a[1]) ($($a[2])) is above zero but not rising: $now." }
    }
    if ($Result -eq 'failed' -or $CopyErrors -gt 0) { & $add 'red' "Copy errors in this run: $CopyErrors (result: $Result)." }
    if ($Verification -eq 'differences') { & $add 'red' 'The verification found differences in this run.' }

    if ($null -ne $Previous -and $null -ne $Previous.AC7 -and $null -ne $Reading.AC7 -and $Reading.AC7 -gt $Previous.AC7) {
        & $add 'yellow' "C7 (CRC errors, usually the enclosure or the cable) rose from $($Previous.AC7) to $($Reading.AC7)."
    }
    if ($null -ne $Reading.Hours -and $Reading.Hours -gt $Settings.HealthWarnHours) { & $add 'yellow' "Power-on hours are above $($Settings.HealthWarnHours): $($Reading.Hours)." }
    if ($null -ne $Year -and ($CurrentYear - [int]$Year) -gt $Settings.HealthWarnYears) { & $add 'yellow' "The disk is older than $($Settings.HealthWarnYears) years (from $Year)." }
    if ($null -ne $Reading.TempC -and $Reading.TempC -gt $Settings.HealthWarnTempC) { & $add 'yellow' "Temperature at the end is above $($Settings.HealthWarnTempC) C: $($Reading.TempC) C." }
    return $warnings.ToArray()
}

# Get-HealthLevel: red if any warning is red, yellow if any is yellow, else ok.
function Get-HealthLevel {
    param($Warnings)
    $list = @($Warnings)
    if (@($list | Where-Object { $_.Level -eq 'red' }).Count -gt 0) { return 'red' }
    if (@($list | Where-Object { $_.Level -eq 'yellow' }).Count -gt 0) { return 'yellow' }
    return 'ok'
}

# Get-OverallHealth: the worst of the levels of the disks in a run, for the
# health column of runs.csv. "not approved" and "not checked" only count when no
# disk was read.
function Get-OverallHealth {
    param([string[]]$Levels)
    foreach ($level in @('red', 'yellow', 'ok', 'not approved')) {
        if ($Levels -contains $level) { return $level }
    }
    return 'not checked'
}

# --- REMINDERS ---

# The reminders read local\runs.csv and work out what's due. Two scripts use
# these functions: robobak-reminders.ps1 (the window, and -Check, which a
# scheduled task runs) and install-reminders.ps1. The settings are the
# "reminders" section of local\settings.json; only the window writes it.
# local\state.json keeps when the last notification was shown.
#
# In test mode, -Check prints what it would notify instead of showing a
# notification, a file named locked.txt in the "local=" folder means the screen
# is locked, and nothing is registered with Task Scheduler.

$script:ReminderTaskName     = 'RoboBak reminders'
$script:ReminderAppId        = 'RoboBak.Reminders'
$script:ReminderShortcutName = 'RoboBak.lnk'

# Read-ReminderSettings: the "reminders" section of local\settings.json. A
# missing file, section or key means the default; a value that can't be read is
# reported in .Warning and replaced by its default.
#   enabled                                     reminders on or off (default on)
#   systemDays, mirrorDays                      interval in days (default 14)
#   gapHours                                    at most one notification per this many hours (default 24, 0 = no limit)
#   triggerLogon, triggerUnlock, triggerDaily   when the check runs (default all on)
#   dailyTime                                   HH:mm for the daily check (default 12:00)
function Read-ReminderSettings {
    param([string]$LocalDir)
    $result = [pscustomobject][ordered]@{
        Enabled = $true; SystemDays = 14; MirrorDays = 14; GapHours = 24
        TriggerLogon = $true; TriggerUnlock = $true; TriggerDaily = $true; DailyTime = '12:00'
        Warning = $null
    }
    if (-not $LocalDir) { return $result }
    $file = Join-Path $LocalDir 'settings.json'
    if (-not (Test-Path -LiteralPath $file)) { return $result }
    try {
        $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $result.Warning = "Could not read `"$file`" (invalid JSON). Using the default reminder settings."
        return $result
    }
    $section = $json.reminders
    if ($null -eq $section) { return $result }
    $bad = @()
    foreach ($pair in @(@('enabled', 'Enabled'), @('triggerLogon', 'TriggerLogon'), @('triggerUnlock', 'TriggerUnlock'), @('triggerDaily', 'TriggerDaily'))) {
        $value = $section.($pair[0])
        if ($null -eq $value) { continue }
        if ($value -is [bool]) { $result.($pair[1]) = $value } else { $bad += $pair[0] }
    }
    foreach ($pair in @(@('systemDays', 'SystemDays', 1), @('mirrorDays', 'MirrorDays', 1), @('gapHours', 'GapHours', 0))) {
        $value = $section.($pair[0])
        if ($null -eq $value) { continue }
        $number = 0.0
        if ([double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge $pair[2]) {
            $result.($pair[1]) = $number
        } else {
            $bad += $pair[0]
        }
    }
    $time = $section.dailyTime
    if ($null -ne $time) {
        if (([string]$time) -match '^([01]\d|2[0-3]):[0-5]\d$') { $result.DailyTime = [string]$time } else { $bad += 'dailyTime' }
    }
    if ($bad.Count -gt 0) {
        $result.Warning = "Ignored invalid value(s) in `"$file`": $($bad -join ', '). Using the default for those."
    }
    return $result
}

# Save-ReminderSettings: writes the "reminders" section of local\settings.json,
# leaving every other section as it is. Throws, without touching the file, if
# the file exists but isn't valid JSON.
function Save-ReminderSettings {
    param([string]$LocalDir, $Settings)
    if (-not $LocalDir) { throw 'There is no local folder to save the settings to.' }
    if (-not (Test-Path -LiteralPath $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null }
    $file = Join-Path $LocalDir 'settings.json'
    $json = $null
    if (Test-Path -LiteralPath $file) {
        $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        if ($text -and $text.Trim()) {
            try { $json = $text | ConvertFrom-Json } catch { throw "`"$file`" isn't valid JSON, so it was left as it is. Fix or delete it, then save again." }
        }
    }
    if ($null -eq $json) { $json = [pscustomobject]@{} }
    $section = [pscustomobject][ordered]@{
        enabled       = [bool]$Settings.Enabled
        systemDays    = $Settings.SystemDays
        mirrorDays    = $Settings.MirrorDays
        gapHours      = $Settings.GapHours
        triggerLogon  = [bool]$Settings.TriggerLogon
        triggerUnlock = [bool]$Settings.TriggerUnlock
        triggerDaily  = [bool]$Settings.TriggerDaily
        dailyTime     = [string]$Settings.DailyTime
    }
    $json | Add-Member -NotePropertyName 'reminders' -NotePropertyValue $section -Force
    [System.IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
}

# ConvertFrom-RecordDate: "yyyy-MM-dd HH:mm:ss" -> a date, or $null.
function ConvertFrom-RecordDate {
    param([string]$Text)
    $date = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) { return $date }
    return $null
}

# Read-ReminderState: when the last notification was shown, or $null.
function Read-ReminderState {
    param([string]$LocalDir)
    if (-not $LocalDir) { return $null }
    $file = Join-Path $LocalDir 'state.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        return (ConvertFrom-RecordDate (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).lastNotification)
    } catch {
        return $null
    }
}

# Save-ReminderState: remembers when the last notification was shown. Does
# nothing without a local folder (test mode without "local=").
function Save-ReminderState {
    param([string]$LocalDir, [datetime]$When)
    if (-not $LocalDir) { return }
    if (-not (Test-Path -LiteralPath $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null }
    $text = [pscustomobject]@{ lastNotification = $When.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $LocalDir 'state.json'), $text, (New-Object System.Text.UTF8Encoding($true)))
}

# Get-DatedRecords: the records of one kind with their dates parsed, oldest
# first. Lines whose date can't be read are left out.
function Get-DatedRecords {
    param($Records, [string]$Kind)
    $dated = foreach ($r in @($Records)) {
        if ($null -eq $r -or $r.kind -ne $Kind) { continue }
        $date = ConvertFrom-RecordDate $r.date
        if ($null -eq $date) { continue }
        [pscustomobject]@{ Date = $date; Source = $r.source; Destination = $r.destination; Result = $r.result }
    }
    return @($dated | Sort-Object Date)
}

# Get-SuggestedDrive: the backup drive whose last successful copy is oldest,
# among the drives that have one in the records, or $null. Failed and skipped
# lines don't count, so a drive whose last copy failed stays the oldest.
function Get-SuggestedDrive {
    param($Records)
    $last = @{}
    foreach ($r in (Get-DatedRecords $Records 'mirror')) {
        if ($r.Result -eq 'ok') { $last[[string]$r.Destination] = $r.Date }
    }
    if ($last.Count -eq 0) { return $null }
    return @($last.GetEnumerator() | Sort-Object Value, Name)[0].Name
}

# Get-ReminderItem: the state of one kind of backup: the last time it was done
# (result "ok") and skipped, when the next one is due, and whether it's due now.
# The interval counts from the last done-or-skipped record, and a backup is due
# from the start of the resulting date, which is what the window shows. A backup
# with no record is due. AgeDays is always the age of the last backup actually done, in
# calendar days, so yesterday evening is "1 day ago" even under 24 hours later.
function Get-ReminderItem {
    param($Records, [string]$Kind, [double]$IntervalDays, [datetime]$Now)
    $list = @(Get-DatedRecords $Records $Kind)
    $done = @($list | Where-Object { $_.Result -eq 'ok' })
    $skipped = @($list | Where-Object { $_.Result -eq 'skipped' })
    $lastDone = if ($done.Count -gt 0) { $done[$done.Count - 1].Date } else { $null }
    $lastSkipped = if ($skipped.Count -gt 0) { $skipped[$skipped.Count - 1].Date } else { $null }
    $base = $lastDone
    if ($null -ne $lastSkipped -and ($null -eq $base -or $lastSkipped -gt $base)) { $base = $lastSkipped }
    $nextDue = if ($null -ne $base) { $base.AddDays($IntervalDays) } else { $null }
    $age = if ($null -ne $lastDone) { [int][math]::Max(0, ($Now.Date - $lastDone.Date).Days) } else { $null }
    return [pscustomobject][ordered]@{
        Kind = $Kind; LastDone = $lastDone; LastSkipped = $lastSkipped; NextDue = $nextDue
        Due = ($null -eq $nextDue -or $Now.Date -ge $nextDue.Date); AgeDays = $age; SuggestedDrive = $null
    }
}

# Get-ReminderStatus: .System and .Mirror, each as from Get-ReminderItem. Only
# .Mirror has a suggested drive.
function Get-ReminderStatus {
    param($Records, $Settings, [datetime]$Now = (Get-Date))
    $system = Get-ReminderItem $Records 'system' $Settings.SystemDays $Now
    $mirror = Get-ReminderItem $Records 'mirror' $Settings.MirrorDays $Now
    $mirror.SuggestedDrive = Get-SuggestedDrive $Records
    return [pscustomobject]@{ System = $system; Mirror = $mirror }
}

# Test-ReminderGapPassed: is it long enough since the last notification?
function Test-ReminderGapPassed {
    param($LastNotification, [double]$GapHours, [datetime]$Now = (Get-Date))
    if ($null -eq $LastNotification) { return $true }
    return (($Now - $LastNotification).TotalHours -ge $GapHours)
}

# Format-ReminderAge: "today", "1 day ago" or "N days ago".
function Format-ReminderAge {
    param([int]$Days)
    if ($Days -le 0) { return 'today' }
    if ($Days -eq 1) { return '1 day ago' }
    return "$Days days ago"
}

# Format-ReminderLine: one line of the notification, with the real age of the
# last backup actually done, and for a mirror the drive to use.
function Format-ReminderLine {
    param($Item)
    $name = if ($Item.Kind -eq 'system') { 'System backup' } else { 'Mirror' }
    if ($null -ne $Item.LastDone) { $when = "last done $(Format-ReminderAge $Item.AgeDays)" }
    elseif ($null -ne $Item.LastSkipped) { $when = 'never done' }
    else { $when = 'never recorded' }
    $line = "${name}: $when."
    if ($Item.Kind -eq 'mirror' -and $Item.SuggestedDrive) { $line += " Next drive: $($Item.SuggestedDrive)." }
    return $line
}

# Get-ReminderDecision: what -Check should do, in the design's order: exit if
# the reminders are off, if the screen is locked, if the last notification is
# too recent, or if nothing is due; otherwise notify. .Action is disabled,
# locked, gap, nothing or notify.
function Get-ReminderDecision {
    param($Settings, $Status, [bool]$Locked, $LastNotification, [datetime]$Now = (Get-Date))
    $result = [pscustomobject]@{ Action = 'nothing'; Title = 'Backups due'; Lines = @() }
    if (-not $Settings.Enabled) { $result.Action = 'disabled'; return $result }
    if ($Locked) { $result.Action = 'locked'; return $result }
    if (-not (Test-ReminderGapPassed $LastNotification $Settings.GapHours $Now)) { $result.Action = 'gap'; return $result }
    $lines = @()
    foreach ($item in @($Status.System, $Status.Mirror)) {
        if ($item.Due) { $lines += (Format-ReminderLine $item) }
    }
    if ($lines.Count -gt 0) { $result.Action = 'notify'; $result.Lines = $lines }
    return $result
}

# Get-ReminderToastXml: the notification's XML, with its text escaped.
function Get-ReminderToastXml {
    param([string]$Title, [string[]]$Lines)
    $texts = @($Title) + @($Lines) | ForEach-Object { '<text>' + [System.Security.SecurityElement]::Escape($_) + '</text>' }
    return '<toast><visual><binding template="ToastGeneric">' + ($texts -join '') + '</binding></visual></toast>'
}

# Add-SkipRecord: a "skipped" line in local\runs.csv. A system line uses the
# computer's name and the last partition recorded. A mirror line uses the last
# source recorded and the suggested drive. Either can be empty with no records.
function Add-SkipRecord {
    param([string]$LocalDir, [string]$Kind, $Records, [string]$ComputerName = $env:COMPUTERNAME, $Date = $null)
    $list = @(Get-DatedRecords $Records $Kind)
    $newest = if ($list.Count -gt 0) { $list[$list.Count - 1] } else { $null }
    if ($Kind -eq 'system') {
        $source = $ComputerName
        $destination = if ($null -ne $newest) { [string]$newest.Destination } else { '' }
    } else {
        $source = if ($null -ne $newest) { [string]$newest.Source } else { '' }
        $destination = [string](Get-SuggestedDrive $Records)
    }
    return (Add-RunRecord -LocalDir $LocalDir -Kind $Kind -Source $source -Destination $destination -Result 'skipped' -Verification 'not performed' -Health 'not checked' -Date $Date)
}

# Test-ReminderLocked: is the screen locked? Windows' lock screen process,
# LogonUI.exe, runs while it is. In test mode: a locked.txt in the local folder.
function Test-ReminderLocked {
    param([string]$LocalDir)
    if (Test-RoboBakTestMode) {
        return [bool]($LocalDir -and (Test-Path -LiteralPath (Join-Path $LocalDir 'locked.txt')))
    }
    return ($null -ne (Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue))
}

# Get-ReminderCommand: how the shortcut (the window) and the task (-Check) start
# robobak-reminders.ps1: through conhost.exe --headless, so no console window
# appears, whatever the default terminal is.
function Get-ReminderCommand {
    param([string]$ScriptPath, [switch]$Check)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    if ($Check) { $argument += ' -Check' }
    return [pscustomobject]@{ Execute = (Join-Path $env:SystemRoot 'System32\conhost.exe'); Argument = $argument }
}

# New-ReminderTriggers: the task's triggers, as chosen in the settings. The
# sign-in and unlock triggers wait a minute, so LogonUI.exe has closed by the
# time the check looks for it. These objects exist only in memory.
function New-ReminderTriggers {
    param($Settings, [string]$User)
    $triggers = @()
    if ($Settings.TriggerLogon) {
        $logon = New-ScheduledTaskTrigger -AtLogOn -User $User
        $logon.Delay = 'PT1M'
        $triggers += $logon
    }
    if ($Settings.TriggerUnlock) {
        $class = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
        $triggers += New-CimInstance -CimClass $class -ClientOnly -Property @{ StateChange = [uint32]8; UserId = $User; Delay = 'PT1M'; Enabled = $true }
    }
    if ($Settings.TriggerDaily) {
        $triggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($Settings.DailyTime, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return $triggers
}

# New-ReminderTaskDefinition: the parts of the scheduled task, only in memory:
# it runs -Check as the user, one at a time, and is disabled when the reminders
# are off.
function New-ReminderTaskDefinition {
    param($Settings, [string]$ScriptPath, [string]$User)
    $command = Get-ReminderCommand -ScriptPath $ScriptPath -Check
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $taskSettings.Enabled = [bool]$Settings.Enabled
    return [pscustomobject]@{
        Action    = New-ScheduledTaskAction -Execute $command.Execute -Argument $command.Argument
        Triggers  = @(New-ReminderTriggers $Settings $User)
        Settings  = $taskSettings
        Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    }
}

# Test-AccessDeniedError: did a scheduled-task cmdlet fail for lack of rights?
# Judged by the error's category and code, not its text, which is translated.
function Test-AccessDeniedError {
    param($ErrorRecord)
    if ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied) { return $true }
    return ([string]$ErrorRecord.FullyQualifiedErrorId -match '0x80070005')
}

# Register-ReminderTask: creates or rewrites the scheduled task. Returns .Ok,
# .AccessDenied and .Message. Whether Windows allows this without administrator
# rights can only be known on the computer, so a refusal says what to do.
# Test mode never touches Task Scheduler.
function Register-ReminderTask {
    param($Settings, [string]$ScriptPath)
    if (Test-RoboBakTestMode) {
        return [pscustomobject]@{ Ok = $false; AccessDenied = $false; Message = 'TEST MODE: the scheduled task was not touched.' }
    }
    try {
        $definition = New-ReminderTaskDefinition -Settings $Settings -ScriptPath $ScriptPath -User "$env:USERDOMAIN\$env:USERNAME"
        $register = @{ TaskName = $script:ReminderTaskName; Action = $definition.Action; Settings = $definition.Settings; Principal = $definition.Principal; Force = $true; ErrorAction = 'Stop' }
        if ($definition.Triggers.Count -gt 0) { $register['Trigger'] = $definition.Triggers }
        Register-ScheduledTask @register | Out-Null
        return [pscustomobject]@{ Ok = $true; AccessDenied = $false; Message = 'The scheduled task was updated.' }
    } catch {
        if (Test-AccessDeniedError $_) {
            return [pscustomobject]@{ Ok = $false; AccessDenied = $true; Message = "Windows refused to change the scheduled task (access denied). Open PowerShell as administrator, go to the RoboBak folder and run .\install-reminders.ps1." }
        }
        return [pscustomobject]@{ Ok = $false; AccessDenied = $false; Message = "Could not change the scheduled task: $($_.Exception.Message)" }
    }
}

# The Start menu shortcut needs an application ID for notifications to show
# "RoboBak" as their sender, and only the Windows Shell can write one. This small
# class does that through the shortcut's property store.
$script:ShortcutAppIdSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace RoboBakInterop {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid FormatId; public uint PropertyId; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant { public ushort Type; public ushort Reserved1; public ushort Reserved2; public ushort Reserved3; public IntPtr Value; public IntPtr Value2; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }
    public static class ShortcutAppId {
        public static void Set(string path, string appId) {
            object link = new ShellLink();
            PropVariant value = new PropVariant();
            value.Type = 31; // VT_LPWSTR
            value.Value = Marshal.StringToCoTaskMemUni(appId);
            try {
                IPersistFile file = (IPersistFile)link;
                file.Load(path, 2); // STGM_READWRITE
                PropertyKey key = new PropertyKey();
                key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); // PKEY_AppUserModel_ID
                key.PropertyId = 5;
                IPropertyStore store = (IPropertyStore)link;
                store.SetValue(ref key, ref value);
                store.Commit();
                file.Save(path, true);
            } finally {
                Marshal.FreeCoTaskMem(value.Value);
                Marshal.ReleaseComObject(link);
            }
        }
    }
}
'@

# New-ReminderShortcut: the "RoboBak" Start menu shortcut. It opens the window
# and carries the application ID. Never used in test mode.
function New-ReminderShortcut {
    param([string]$ShortcutPath, [string]$ScriptPath)
    if (Test-RoboBakTestMode) { throw 'TEST MODE: no shortcut is created.' }
    $command = Get-ReminderCommand -ScriptPath $ScriptPath
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($ShortcutPath)
    $link.TargetPath = $command.Execute
    $link.Arguments = $command.Argument
    $link.WorkingDirectory = Split-Path -Parent $ScriptPath
    $link.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',7'
    $link.Description = 'RoboBak: backup status and reminder settings'
    $link.Save()
    if (-not ('RoboBakInterop.ShortcutAppId' -as [type])) { Add-Type -TypeDefinition $script:ShortcutAppIdSource }
    [RoboBakInterop.ShortcutAppId]::Set($ShortcutPath, $script:ReminderAppId)
}
