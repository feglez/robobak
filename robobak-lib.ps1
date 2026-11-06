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

# --- TIME ESTIMATES (backup_times.txt and backup_history.txt) ---

# How long each step took before is read from the source drive's
# backup_logs\backup_times.txt, which keeps the last 10 runs. Each entry starts
# with "[yyyy-MM-dd HH:mm:ss] SOURCE -> DEST (STATUS)", followed by indented
# "Key: value" lines. Older entries lack some lines (no "Dry run duration"
# before the dry run existed, no "Copied (dry run)" before the estimates
# existed): a missing line, "not performed" or "unknown" reads as $null.

$script:DefaultCopySpeed = 50MB   # bytes per second when no large copy was measured
$script:MinCopyForSpeed  = 10GB   # smaller copies don't measure the speed: listing the folders dominates them

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
# 10 GB count, and the dry run's time (an approximation of the time robocopy
# spends listing the folders) is taken out of the copy's time.
function Get-EntrySpeed {
    param($Entry)
    if ($Entry.Status -notmatch '^OK') { return $null }
    if ($null -eq $Entry.CopiedBytes -or $Entry.CopiedBytes -lt $script:MinCopyForSpeed) { return $null }
    if ($null -eq $Entry.Copy) { return $null }
    $seconds = $Entry.Copy.TotalSeconds
    if ($null -ne $Entry.DryRun) { $seconds -= $Entry.DryRun.TotalSeconds }
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
# this run's dry-run time (the listing) plus the bytes to copy at the speed
# from Get-CopySpeed.
function Get-CopyEstimateText {
    param($Stats, [TimeSpan]$DryRunDuration, $Entries, [string]$Source, [string]$Dest, [bool]$FirstBackup)
    $prefix = if ($FirstBackup) { "First backup to $Dest. " } else { '' }
    if ($null -eq $Stats) {
        return $prefix + "The copy time can't be estimated: the dry run's counts are unknown."
    }
    $speed = Get-CopySpeed $Entries $Source $Dest
    $estimate = [TimeSpan]::FromSeconds($DryRunDuration.TotalSeconds + ($Stats.CopyBytes / $speed.BytesPerSecond))
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
