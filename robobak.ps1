# robobak.ps1 - Automated drive backup script using Robocopy
# Mirrors a source drive onto a destination drive with safety checks,
# progress tracking, error logging, history management, and verification.

# Force UTF-8 output for special characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- HELPER FUNCTIONS ---

# Update-TimesLog: Appends a timing entry to the rolling backup_times.txt on the source drive.
# Keeps at most 10 entries (deletes the oldest when adding the 11th).
# Each entry is a block of 5 lines separated by a blank line.
function Update-TimesLog {
    param(
        [string]$SrcLabel,
        [string]$DstLabel,
        $CountDuration,   # TimeSpan or $null (only with --show-progress)
        [TimeSpan]$CopyDuration,
        $VerifyDuration,  # TimeSpan or $null
        [string]$Flags,
        [string]$Status
    )

    $countStr  = if ($null -eq $CountDuration)  { "not performed" } else { $CountDuration.ToString('hh\:mm\:ss') }
    $verifyStr = if ($null -eq $VerifyDuration) { "not performed" } else { $VerifyDuration.ToString('hh\:mm\:ss') }

    $newEntry = @(
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $SrcLabel -> $DstLabel ($Status)"
        "  File count duration:   $countStr"
        "  Copy duration:         $($CopyDuration.ToString('hh\:mm\:ss'))"
        "  Verification duration: $verifyStr"
        "  Flags:                 $Flags"
    )

    # Read existing entries (blocks separated by blank lines)
    $entries = @()
    if (Test-Path $TimesLog) {
        $content = Get-Content $TimesLog -Raw
        if ($content -and $content.Trim()) {
            # Split on double newlines to get individual entry blocks
            $blocks = $content.Trim() -split '(\r?\n){2,}'
            foreach ($block in $blocks) {
                $trimmed = $block.Trim()
                if ($trimmed) { $entries += , $trimmed }
            }
        }
    }

    # Keep only the last 9 entries, then add the new one (max 10 total)
    if ($entries.Count -ge 10) {
        $entries = $entries[($entries.Count - 9)..($entries.Count - 1)]
    }

    # Build the output: existing entries + new entry, separated by blank lines
    $output = @()
    foreach ($entry in $entries) {
        $output += $entry
        $output += ""
    }
    $output += ($newEntry -join "`n")
    $output += ""

    ($output -join "`n") | Set-Content -Path $TimesLog -Encoding UTF8 -NoNewline
}

# --- 1. HELP AND PARAMETER VALIDATION ---

function Show-Help {
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "   HELP: ROBOBAK"
    Write-Host "================================================================="
    Write-Host ""
    Write-Host "   Usage:"
    Write-Host "      .\robobak.ps1 [SourceLetter] [DestLetter] [flags...]"
    Write-Host ""
    Write-Host "   Flags (can be combined in any order):"
    Write-Host "      --verify         Automatically verify the backup after completion"
    Write-Host "      --no-verify      Skip verification without asking"
    Write-Host "      --show-progress  Show a progress bar during the backup"
    Write-Host "      --verbose        Show every file operation on the terminal (/TEE)"
    Write-Host ""
    Write-Host "   NOTE: --show-progress and --verbose cannot be used together."
    Write-Host ""
    Write-Host "   Examples:"
    Write-Host "      .\robobak.ps1 F E"
    Write-Host "      .\robobak.ps1 F E --verify"
    Write-Host "      .\robobak.ps1 F E --no-verify"
    Write-Host "      .\robobak.ps1 F E --show-progress"
    Write-Host "      .\robobak.ps1 F E --verbose --verify"
    Write-Host "      .\robobak.ps1 F E --show-progress --no-verify"
    Write-Host ""
    Write-Host "   Requirements:"
    Write-Host "    - The Destination drive must have a volume label (name)"
    Write-Host "      starting with `"BACKUP_`" (e.g.: BACKUP_1)."
    Write-Host ""
    Write-Host "   Generated artifacts:"
    Write-Host "    1. On Source (backup_logs\):"
    Write-Host "       - `"backup_history.txt`" (List of all backup drives,"
    Write-Host "         sorted by name, with NEWEST/OLDEST tags)."
    Write-Host "       - `"backup_times.txt`" (Rolling log of the last 10"
    Write-Host "         backups with timing information)."
    Write-Host "    2. On Destination (current_backup_logs\):"
    Write-Host "       - `"robocopy_log.txt`" (Full technical report)."
    Write-Host "       - `"backup_summary.txt`" (Status, date, details,"
    Write-Host "         errors, timing, and verification result)."
    Write-Host "       - `"verify_log.txt`" (Only if verification is"
    Write-Host "         requested. Logs differences found)."
    Write-Host ""
    Read-Host "Press Enter to continue..."
    exit
}

# Check for help flags or missing parameters
if ($args.Count -eq 0 -or $args[0] -eq '/?' -or $args[0] -eq '-h') {
    Show-Help
}
if ($args.Count -lt 2) {
    Show-Help
}

# Drive letters (first two positional arguments)
$SourceLetter = $args[0]
$DestLetter = $args[1]

# Parse optional flags (any order after the two drive letters)
$VerifyMode = "ask"
$ShowProgress = $false
$VerboseMode = $false

for ($i = 2; $i -lt $args.Count; $i++) {
    switch ($args[$i].ToLower()) {
        "--verify"        { $VerifyMode = "yes" }
        "--no-verify"     { $VerifyMode = "no" }
        "--show-progress" { $ShowProgress = $true }
        "--verbose"       { $VerboseMode = $true }
    }
}

# --show-progress and --verbose are mutually exclusive:
# --verbose floods the terminal with every file line, which would break the progress bar
if ($ShowProgress -and $VerboseMode) {
    Write-Host "[ERROR] --show-progress and --verbose cannot be used together."
    Read-Host "Press Enter to continue..."
    exit
}

# Ensure source and destination are not the same drive
if ($SourceLetter -eq $DestLetter) {
    Write-Host "[ERROR] Source and destination cannot be the same drive."
    Read-Host "Press Enter to continue..."
    exit
}

$Source = "${SourceLetter}:\"
$Dest = "${DestLetter}:\"

# Log folders and files
$SourceLogsDir = Join-Path $Source "backup_logs"
$DestLogsDir   = Join-Path $Dest   "current_backup_logs"

$LogRobo    = Join-Path $DestLogsDir "robocopy_log.txt"
$LogSummary = Join-Path $DestLogsDir "backup_summary.txt"
$LogVerify  = Join-Path $DestLogsDir "verify_log.txt"
$History    = Join-Path $SourceLogsDir "backup_history.txt"
$TimesLog   = Join-Path $SourceLogsDir "backup_times.txt"

# --- 2. PHYSICAL EXISTENCE CHECK ---

if (-not (Test-Path $Source)) {
    Write-Host "[ERROR] Source drive $Source is not available."
    Read-Host "Press Enter to continue..."
    exit
}
if (-not (Test-Path $Dest)) {
    Write-Host "[ERROR] Destination drive $Dest is not available."
    Read-Host "Press Enter to continue..."
    exit
}

# --- 3. VOLUME LABEL CHECK ---

# Get the volume labels (drive names).
# Primary method: Get-Volume (CIM/WMI). -ErrorAction SilentlyContinue suppresses
# the red error message it can produce if Windows hasn't finished updating volume
# metadata (e.g., right after renaming a drive with admin privileges).
# Fallback: [System.IO.DriveInfo] (.NET). Some volumes (e.g., VeraCrypt-mounted
# drives) don't expose their label through CIM but do through .NET's DriveInfo.
$SourceLabel = (Get-Volume -DriveLetter $SourceLetter -ErrorAction SilentlyContinue).FileSystemLabel
if ([string]::IsNullOrEmpty($SourceLabel)) {
    $SourceLabel = [System.IO.DriveInfo]::new("${SourceLetter}:").VolumeLabel
}
$DestLabel = (Get-Volume -DriveLetter $DestLetter -ErrorAction SilentlyContinue).FileSystemLabel
if ([string]::IsNullOrEmpty($DestLabel)) {
    $DestLabel = [System.IO.DriveInfo]::new("${DestLetter}:").VolumeLabel
}

# Warn if the source label is blank. After both Get-Volume and DriveInfo
# fallback, this should only happen if the drive genuinely has no label
# (unnamed drive). This is not an error, but the logs and confirmation
# screen will show a blank label.
# No check needed for the destination label: the BACKUP_ check below will
# catch it anyway (a blank label doesn't start with BACKUP_).
if ([string]::IsNullOrEmpty($SourceLabel)) {
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "   WARNING: Source drive ${SourceLetter}:\ has no label"
    Write-Host "================================================================="
    Write-Host ""
    Write-Host "   The source drive has no volume label (no name)."
    Write-Host "   If you continue, the label will appear blank in the"
    Write-Host "   confirmation screen and in the logs."
    Write-Host ""
    Write-Host "   To add a label: cancel now, right-click the drive in"
    Write-Host "   File Explorer, select Properties, type a name at the"
    Write-Host "   top, then run the script again."
    Write-Host ""
    Write-Host "================================================================="
    $continueChoice = Read-Host "Type Y to continue anyway, any other key to cancel"
    if ($continueChoice -ne 'Y') {
        Read-Host "Press Enter to continue..."
        exit
    }
}

# Verify destination label starts with "BACKUP_" (case-insensitive)
if ($DestLabel -notmatch '^BACKUP_') {
    Write-Host ""
    Write-Host ""
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "   SAFETY ERROR: INVALID DISK"
    Write-Host "================================================================="
    Write-Host ""
    Write-Host "   The drive connected at $Dest is named: `"$DestLabel`""
    Write-Host ""
    Write-Host "   REQUIREMENT: To prevent accidents, the destination drive"
    Write-Host "   must have a name starting with: BACKUP_"
    Write-Host "   (Examples: BACKUP_1, BACKUP_OFFICE, BACKUP_DISK2)"
    Write-Host ""
    Write-Host "   Please rename the drive or verify the drive letter."
    Write-Host ""
    Write-Host "================================================================="
    Read-Host "Press Enter to continue..."
    exit
}

# --- 4. USER CONFIRMATION ---

Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "================================================================="
Write-Host "                   COPY CONFIRMATION"
Write-Host "================================================================="
Write-Host ""
Write-Host "   SOURCE (DATA THAT IS KEPT):       $Source  (Label: $SourceLabel)"
Write-Host "   DESTINATION (DATA THAT IS WIPED): $Dest  (Label: $DestLabel)"
Write-Host ""
Write-Host "   WARNING: A MIRROR sync (/MIR) will be performed."
Write-Host "   Any file on $Dest ($DestLabel) that does NOT exist on $Source ($SourceLabel)"
Write-Host "   will be PERMANENTLY DELETED. $Dest ($DestLabel) will become an"
Write-Host "   exact copy of $Source ($SourceLabel)."
Write-Host ""
Write-Host "================================================================="
$Confirm = Read-Host "Type Y to confirm and continue, any other key to cancel"
if ($Confirm -ne 'Y') {
    Write-Host "Operation cancelled by user."
    Read-Host "Press Enter to continue..."
    exit
}

# --- 5. DISK SPACE CHECK ---

# Compare source used space against destination total size to warn the user
# before robocopy fails mid-copy with ERROR 112 (not enough space).
# We compare against total size (not free space) because /MIR makes the
# destination an exact copy of the source - extras on the destination are
# deleted during the process, freeing space. Robocopy deletes extras before
# copying new files within each directory, though with /MT:16 multiple
# directories are processed in parallel, so theoretically a large new file
# could be written before extras in other directories are deleted, causing
# a transient space shortage even if the final result would fit.
# Uses [System.IO.DriveInfo] which works reliably with all volume types
# including VeraCrypt-mounted drives.
$SourceDrive = [System.IO.DriveInfo]::new("${SourceLetter}:")
$DestDrive   = [System.IO.DriveInfo]::new("${DestLetter}:")
$SourceUsed  = $SourceDrive.TotalSize - $SourceDrive.TotalFreeSpace
$DestTotal   = $DestDrive.TotalSize

if ($SourceUsed -gt $DestTotal) {
    $usedGB  = [math]::Round($SourceUsed / 1GB, 2)
    $totalGB = [math]::Round($DestTotal / 1GB, 2)
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "   WARNING: DESTINATION DRIVE IS TOO SMALL"
    Write-Host "================================================================="
    Write-Host ""
    Write-Host "   Source used space:        $usedGB GB"
    Write-Host "   Destination total space:  $totalGB GB"
    Write-Host ""
    Write-Host "   The destination drive is not large enough to hold all the"
    Write-Host "   data from the source. If you continue, the backup will be"
    Write-Host "   incomplete - Robocopy will fail when the destination runs"
    Write-Host "   out of space."
    Write-Host ""
    Write-Host "================================================================="
    $spaceChoice = Read-Host "Type Y to continue anyway (incomplete backup), any other key to cancel"
    if ($spaceChoice -ne 'Y') {
        Write-Host "Operation cancelled by user."
        Read-Host "Press Enter to continue..."
        exit
    }
}

# --- 6. PREPARE LOG FOLDERS ---

# Ensure the source logs folder exists. On the very first backup, this creates an
# empty backup_logs\ folder on the source. Robocopy will copy it to the destination
# as an empty folder (no logs exist in it yet). Subsequent backups will copy the
# folder with its contents (backup_history.txt, backup_times.txt).
New-Item -Path $SourceLogsDir -ItemType Directory -Force | Out-Null

# Delete and recreate the destination logs folder to clear stale logs.
# If the backup fails partway through, no previous logs remain that could
# give a misleading impression of success.
if (Test-Path $DestLogsDir) {
    Remove-Item -Path $DestLogsDir -Recurse -Force
}
New-Item -Path $DestLogsDir -ItemType Directory -Force | Out-Null

# --- 7. ROBOCOPY EXECUTION ---

Write-Host ""
Write-Host "Starting backup from $SourceLabel ($Source) to $DestLabel ($Dest)..."
Write-Host ""

# Build the flags string for logging (empty string if no flags were set)
$flagsUsed = @()
if ($ShowProgress) { $flagsUsed += "--show-progress" }
if ($VerboseMode)  { $flagsUsed += "--verbose" }
$flagsStr = if ($flagsUsed.Count -gt 0) { $flagsUsed -join ", " } else { "(none)" }


# Common robocopy flags used across all three modes:
#   /MIR       Mirror mode: destination becomes an exact copy of source, extra files are deleted
#   /MT:16     Use 16 threads for faster parallel copying.
#              Empirically observed side effects: suppresses directory listing
#              in the output (as if /NDL were active), uses full absolute paths
#              for files instead of relative names, and adds per-file progress
#              percentages (e.g. "100%") after each file line
#   /DCOPY:DAT Copy directory timestamps and attributes
#   /R:3       Retry failed copies up to 3 times
#   /W:5       Wait 5 seconds between retries
#   /V         Verbose: log all files including skipped ones
#   /LOG:file  Write full output to robocopy_log.txt on the destination
#   /XD        Exclude directories:
#              - $RECYCLE.BIN and System Volume Information: protected system folders
#                that cannot be copied and would produce access-denied errors
#              - $DestLogsDir (current_backup_logs): destination-only folder containing
#                robocopy_log.txt (being written to during the copy) and other script-generated
#                logs. Uses the full path to avoid excluding user folders with the same name

$RoboCommon = @(
    "/MIR", "/MT:16", "/DCOPY:DAT", "/R:3", "/W:5", "/V",
    "/LOG:$LogRobo",
    "/XD", '$RECYCLE.BIN', "System Volume Information", $DestLogsDir
)

$countDuration = $null

if ($ShowProgress) {
    # --show-progress mode: pipe robocopy output through a progress bar.
    # Mode-specific flags:
    #   /TEE  Send output to both the log file and stdout so we can read it
    #   /NP   Suppress per-file copy percentages (0%..100%) that /MT:16 adds to each
    #         file line (empirically confirmed). Without /NP, these percentages would
    #         inflate the file line count used by the progress bar

    Write-Host "Counting files on source drive..."
    $countStart = Get-Date
    # Note: this counts all files on the source drive. It does not explicitly exclude
    # $RECYCLE.BIN or System Volume Information, but those folders are protected by
    # Windows and Get-ChildItem cannot enumerate them (access denied). The errors are
    # silently suppressed, so those files are not included in the count in practice.
    $TotalFiles = (Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue).Count
    $countDuration = (Get-Date) - $countStart
    Write-Host "Found $($TotalFiles.ToString('N0')) files (counted in $($countDuration.ToString('hh\:mm\:ss'))). Starting backup..."
    Write-Host "Note: the progress bar is an approximation and may not reflect exact progress."
    Write-Host ""

    # File line detection regex (language-independent):
    #   '\s\d[\d.]*(\s+[a-z])?\s+[A-Za-z]:\\'  matches a file size followed by a drive path (E:\)
    #     - \d[\d.]*       matches plain bytes (217915) or decimal sizes (138.7)
    #     - (\s+[a-z])?    optionally matches a unit suffix (k, m, g, t) for large files
    #     - \s+[A-Za-z]:\\ matches the drive path after the size
    #     - Excludes headers, stats table, and footer (no size-then-drive-path pattern)
    #     - Excluded directory lines (size -1) are not matched since \d won't match
    #       the minus sign. Regular directory lines are suppressed by /MT:16
    #       (empirically confirmed), so they are not a concern
    #   '\*.*EXTRA'  excludes extra files on dest being deleted (*Archivo EXTRA / *File EXTRA)
    #     - "EXTRA" is a robocopy constant, not translated across locales
    #     - These files aren't in the source count, so counting them would inflate progress
    #
    # Accuracy note: /MT:16 makes robocopy output non-thread-safe. Multiple threads
    # write to stdout simultaneously, which can interleave or split lines (e.g., a
    # file's size on one line and its path on the next, or two file entries merged
    # into one line). The regex will miss these garbled lines, causing a small
    # undercount. This is acceptable for a progress indicator - removing /MT would
    # give clean output but could slow down the copy.

    $count = 0
    $barLen = 30
    $copyStart = Get-Date

    & robocopy $Source $Dest @RoboCommon /TEE /NP 2>&1 | ForEach-Object {
        $line = $_
        if ($line -match '\s\d[\d.]*(\s+[a-z])?\s+[A-Za-z]:\\' -and $line -notmatch '\*.*EXTRA') {
            $count++
        }
        $pct = if ($TotalFiles -gt 0) { [math]::Min(100, [math]::Floor($count / $TotalFiles * 100)) } else { 0 }
        $filled = [math]::Floor($pct / 100 * $barLen)
        $empty = $barLen - $filled
        $bar = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty
        $countFmt = $count.ToString('N0')
        $totalFmt = $TotalFiles.ToString('N0')
        Write-Host "`r[$bar] $pct% ($countFmt / $totalFmt files)" -NoNewline
    }
    Write-Host ""
    $RoboExit = $LASTEXITCODE

} elseif ($VerboseMode) {
    # --verbose mode
    # Mode-specific flag:
    #   /TEE  Send output to both the log file and the terminal, showing every
    #         file operation in real-time
    $copyStart = Get-Date
    & robocopy $Source $Dest @RoboCommon /TEE
    $RoboExit = $LASTEXITCODE

} else {
    # Default mode: no extra flags. Output goes only to the log file, keeping
    # the terminal clean while the copy runs. Redirect stdout to $null to
    # suppress robocopy's "Log file:" console notice.
    $copyStart = Get-Date
    & robocopy $Source $Dest @RoboCommon > $null
    $RoboExit = $LASTEXITCODE
}

$copyEnd = Get-Date
$copyDuration = $copyEnd - $copyStart

# Display the summary statistics from the log.
# The stats table is always the last 8 lines: the "----" separator, a blank line,
# the column header, 4 data rows (Dirs, Files, Bytes, Time), and the "Finished" timestamp.
# A fixed count works here because this layout is constant across locales and flags.
Write-Host ""
Write-Host ""
Write-Host "-----------------------------------------------------------------"
Write-Host "   ROBOCOPY SUMMARY"
Write-Host "-----------------------------------------------------------------"
Get-Content $LogRobo | Select-Object -Last 8
Write-Host "-----------------------------------------------------------------"
Write-Host "   Copy duration: $($copyDuration.ToString('hh\:mm\:ss'))"
Write-Host "-----------------------------------------------------------------"

# --- 8. SUMMARY GENERATION (DESTINATION) ---

# Check for robocopy errors (exit code 8+ means errors occurred)
if ($RoboExit -ge 8) {
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "   [ERROR] ROBOCOPY REPORTED ERRORS (exit code: $RoboExit)"
    Write-Host "   Check `"$LogRobo`" for details."
    Write-Host "================================================================="

    $countSummary = if ($null -eq $countDuration) { "not performed" } else { $countDuration.ToString('hh\:mm\:ss') }
    $summaryLines = @(
        "STATUS: BACKUP FAILED"
        "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Source: $Source ($SourceLabel)"
        "Destination: $Dest ($DestLabel)"
        "Robocopy exit code: $RoboExit"
        "File count duration: $countSummary"
        "Copy duration: $($copyDuration.ToString('hh\:mm\:ss'))"
        "Flags: $flagsStr"
        ""
        "---- ERRORS ----"
    )
    # Pattern "ERROR \d" matches actual robocopy error lines (e.g. "ERROR 32 (0x00000020)")
    # while avoiding false matches on the stats table column header which is just "ERROR" with spaces.
    $errors = Select-String -Path $LogRobo -Pattern 'ERROR \d' | ForEach-Object { $_.Line }
    $summaryLines += $errors
    $summaryLines += @("", "Verification: not performed (backup failed)")
    $summaryLines | Set-Content -Path $LogSummary -Encoding UTF8

    # Write timing entry to source rolling log even on failure
    Update-TimesLog -SrcLabel $SourceLabel -DstLabel $DestLabel -CountDuration $countDuration -CopyDuration $copyDuration -VerifyDuration $null -Flags $flagsStr -Status "FAILED"

    Read-Host "Press Enter to continue..."
    exit
}

$countSummary = if ($null -eq $countDuration) { "not performed" } else { $countDuration.ToString('hh\:mm\:ss') }
$summaryLines = @(
    "STATUS: BACKUP COMPLETED SUCCESSFULLY"
    "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Source: $Source ($SourceLabel)"
    "Destination: $Dest ($DestLabel)"
    "Robocopy exit code: $RoboExit"
    "File count duration: $countSummary"
    "Copy duration: $($copyDuration.ToString('hh\:mm\:ss'))"
    "Flags: $flagsStr"
)
$summaryLines | Set-Content -Path $LogSummary -Encoding UTF8

# Append errors to the summary if any were found (even on a successful run).
$errors = Select-String -Path $LogRobo -Pattern 'ERROR \d' -ErrorAction SilentlyContinue
if ($errors) {
    $errorLines = @("", "---- ERRORS ----") + ($errors | ForEach-Object { $_.Line })
    $errorLines | Add-Content -Path $LogSummary -Encoding UTF8
}

# --- 9. HISTORY UPDATE (SOURCE) ---

Write-Host ""
Write-Host ""
Write-Host "Updating smart history on the source drive..."

# Read existing history, update the current drive entry, sort and tag NEWEST/OLDEST.
$data = @{}
if (Test-Path $History) {
    Get-Content $History | ForEach-Object {
        if ($_ -match '\|') {
            $parts = $_ -split ' \| '
            $label = $parts[0].Trim()
            $dateStr = $parts[1] -replace ' \[.*\]', ''
            $data[$label] = [DateTime]::ParseExact($dateStr.Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
        }
    }
}
$data[$DestLabel] = Get-Date

$sortedByDate = $data.GetEnumerator() | Sort-Object Value
$oldestDate = $sortedByDate[0].Value
$newestDate = $sortedByDate[$sortedByDate.Count - 1].Value

$outputLines = @()
$data.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $tag = ''
    if ($_.Value -eq $newestDate) { $tag = ' [NEWEST]' }
    if ($_.Value -eq $oldestDate -and $data.Count -gt 1) { $tag = ' [OLDEST]' }
    $outputLines += ('{0} | {1:yyyy-MM-dd HH:mm:ss}{2}' -f $_.Name, $_.Value, $tag)
}
$outputLines | Out-File -FilePath $History -Encoding UTF8

Write-Host ""
Write-Host "================================================================="
Write-Host "   BACKUP COMPLETED SUCCESSFULLY"
Write-Host "   $SourceLabel ($Source) -> $DestLabel ($Dest)"
Write-Host "================================================================="
Write-Host ""

# --- 10. OPTIONAL VERIFICATION ---

if ($VerifyMode -eq "no") {
    # No verification - finalize summary and times log, then exit
    Add-Content -Path $LogSummary -Value "`nVerification: not performed" -Encoding UTF8

    # Write timing entry to source rolling log
    Update-TimesLog -SrcLabel $SourceLabel -DstLabel $DestLabel -CountDuration $countDuration -CopyDuration $copyDuration -VerifyDuration $null -Flags $flagsStr -Status "OK"

    Read-Host "Press Enter to continue..."
    exit
}
if ($VerifyMode -eq "ask") {
    $verifyInput = Read-Host "Do you want to verify the backup matches the source? (Y/N)"
    if ($verifyInput -ne 'Y') {
        Add-Content -Path $LogSummary -Value "`nVerification: not performed" -Encoding UTF8

        # Write timing entry to source rolling log
        Update-TimesLog -SrcLabel $SourceLabel -DstLabel $DestLabel -CountDuration $countDuration -CopyDuration $copyDuration -VerifyDuration $null -Flags $flagsStr -Status "OK"

        Read-Host "Press Enter to continue..."
        exit
    }
}

Write-Host ""
Write-Host "Verifying backup integrity..."
Write-Host ""

# Run Robocopy in verification mode to compare source and destination.
# Flags:
#   /MIR   Compare as mirror (same logic as the backup, so the comparison is accurate)
#   /L     List-only: report what WOULD be copied/deleted, without actually modifying anything
#   /MT:16 Use 16 threads for faster directory traversal and comparison
#   /R:3   Retry up to 3 times on locked files (default is 1,000,000 which would hang)
#   /W:5   Wait 5 seconds between retries
#   /LOG   Write the full comparison report to verify_log.txt on the destination
#   /XD    Exclude directories (full paths to avoid excluding user folders with the same name):
#          - $RECYCLE.BIN, System Volume Information: same system folders as the backup
#          - $DestLogsDir (current_backup_logs): destination-only folder with script-generated logs
#          - $SourceLogsDir (backup_logs on source): updated AFTER the copy (step 9),
#            so its contents are newer on the source than the destination copy
#          - backup_logs on destination: must also be excluded because /XD only matches
#            exact paths - excluding the source path doesn't exclude the destination copy.
#            Without this, robocopy would see the destination's backup_logs as "EXTRA"
#            (since the source's backup_logs was skipped by the exclusion)
#          Without /XD, these expected differences would cause a false verification failure.
#
# Robocopy exit code caveat: /XD excludes a directory from being logged and from
# file-level comparison, but robocopy still counts the excluded destination-only
# directory as 1 "EXTRA" in its stats table. This makes the exit code 2 (extras
# detected) even when the backup is a perfect match. This is a known robocopy
# behaviour that cannot be suppressed.
#
# Workaround: verification is considered successful when either:
#   1. Exit code is 0 (perfect match, no extras at all), or
#   2. Exit code is 2 (extras detected in stats) but no actual "EXTRA" lines appear
#      in the log. "EXTRA" is case-sensitive - it is a robocopy constant not translated
#      across locales. The stats table header uses "Extras" (lowercase 's'), so it
#      won't produce a false match.

$DestBackupLogsDir = Join-Path $Dest "backup_logs"
$verifyStart = Get-Date
# Redirect stdout to $null to suppress robocopy's "Log file:" console notice
& robocopy $Source $Dest /MIR /L /MT:16 /R:3 /W:5 /LOG:$LogVerify /XD '$RECYCLE.BIN' "System Volume Information" $DestLogsDir $SourceLogsDir $DestBackupLogsDir > $null
$VerifyExit = $LASTEXITCODE
$verifyEnd = Get-Date
$verifyDuration = $verifyEnd - $verifyStart

# Check if verification passed: exit code 0 (perfect match) or exit code 2
# with no actual EXTRA lines in the log (phantom extras from /XD exclusion)
$extraCount = if ($VerifyExit -eq 2) { (Select-String -Path $LogVerify -Pattern 'EXTRA' -CaseSensitive).Count } else { -1 }
$verifyPassed = ($VerifyExit -eq 0) -or ($VerifyExit -eq 2 -and $extraCount -eq 0)

if ($verifyPassed) {
    Write-Host "================================================================="
    Write-Host "   VERIFICATION PASSED: Backup is an exact match of the source."
    Write-Host "================================================================="
    Write-Host "   Verification duration: $($verifyDuration.ToString('hh\:mm\:ss'))"
    Write-Host "================================================================="
    Add-Content -Path $LogSummary -Value "`nVerification: PASSED`nVerification duration: $($verifyDuration.ToString('hh\:mm\:ss'))" -Encoding UTF8

    # Write timing entry to source rolling log
    Update-TimesLog -SrcLabel $SourceLabel -DstLabel $DestLabel -CountDuration $countDuration -CopyDuration $copyDuration -VerifyDuration $verifyDuration -Flags $flagsStr -Status "OK"
} else {
    Write-Host "================================================================="
    Write-Host "   VERIFICATION WARNING: Differences found."
    Write-Host "   Check `"$LogVerify`" for details."
    Write-Host "================================================================="
    Write-Host ""
    Get-Content $LogVerify | Select-Object -Last 8
    Write-Host ""
    Write-Host "   Verification duration: $($verifyDuration.ToString('hh\:mm\:ss'))"
    Write-Host "================================================================="
    Add-Content -Path $LogSummary -Value "`nVerification: Differences found. See `"verify_log.txt`".`nVerification duration: $($verifyDuration.ToString('hh\:mm\:ss'))" -Encoding UTF8

    # Write timing entry to source rolling log
    Update-TimesLog -SrcLabel $SourceLabel -DstLabel $DestLabel -CountDuration $countDuration -CopyDuration $copyDuration -VerifyDuration $verifyDuration -Flags $flagsStr -Status "OK (verify: differences)"
}
Write-Host ""

Read-Host "Press Enter to continue..."
