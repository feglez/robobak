# run-tests.ps1 - Tests for RoboBak, run on temporary folders in test mode.
#
# Run from PowerShell in the repo folder:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#
# It never touches a real drive: every test works under
# %TEMP%\robobak_tests_<id>, which is deleted at the end. The end-to-end tests
# run robobak.ps1 with the ROBOBAK_TEST environment variable set (test mode)
# and answer its prompts through piped input. Exits with code 1 if any test
# fails.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RoboBak  = Join-Path $RepoRoot 'robobak.ps1'
. (Join-Path $RepoRoot 'robobak-lib.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    $ok = ($Expected -eq $Actual)
    if (-not $ok) { $Name = "$Name (expected [$Expected], got [$Actual])" }
    Assert-True $ok $Name
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Name)
    Assert-True ($null -ne $Text -and $Text.Contains($Needle)) $Name
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Name)
    Assert-True ($null -eq $Text -or -not $Text.Contains($Needle)) $Name
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title" -ForegroundColor Cyan
}

# Accented names, written with [char] codes so this file stays ASCII-only.
$Accent1 = "Canci" + [char]0xF3 + "n " + [char]0xF1 + ".txt"   # new on the source
$Accent2 = "Borrado " + [char]0xE1 + ".txt"                    # only on the destination

$TestRoot = Join-Path $env:TEMP ("robobak_tests_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$SavedTestEnv = $env:ROBOBAK_TEST
$env:ROBOBAK_TEST = $null

# The repo's own local\runs.csv must never be touched by the tests: its state
# is compared at the end.
$RealRunsCsv = Join-Path $RepoRoot 'local\runs.csv'
$RealRunsBefore = if (Test-Path -LiteralPath $RealRunsCsv) { (Get-FileHash -LiteralPath $RealRunsCsv).Hash } else { 'absent' }

# Write-TestFile: a file of exactly $Size bytes with a given modification time.
function Write-TestFile {
    param([string]$Path, [int]$Size, [datetime]$Time)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, [byte[]](@(65) * $Size))
    (Get-Item -LiteralPath $Path).LastWriteTime = $Time
}

# New-Fixture: a source and a destination with every kind of difference.
#   same.txt         same on both sides           -> skipped
#   changed.txt      newer and bigger on source   -> copied (20 bytes)
#   <Accent1>        only on source               -> copied (12 bytes)
#   sub dir\new.txt  only on source               -> copied (7 bytes)
#   extra file.txt   only on destination          -> deleted (1 byte)
#   <Accent2>        only on destination          -> deleted (9 bytes)
#   Carpeta borrada\ only on destination, 3 files of 100 bytes and
#                    nested\deep.txt of 1000      -> deleted (1300 bytes)
# Expected: delete 6 files (1310 bytes), copy 3 files (39 bytes).
function New-Fixture {
    param([string]$Name)
    $root = Join-Path $TestRoot $Name
    $src = Join-Path $root 'src'
    $dst = Join-Path $root 'dst'
    New-Item -ItemType Directory -Path $src, $dst -Force | Out-Null
    $old = (Get-Date).AddDays(-10)
    $new = (Get-Date).AddDays(-1)
    Write-TestFile (Join-Path $src 'same.txt') 50 $old
    Write-TestFile (Join-Path $dst 'same.txt') 50 $old
    Write-TestFile (Join-Path $src 'changed.txt') 20 $new
    Write-TestFile (Join-Path $dst 'changed.txt') 3 $old
    Write-TestFile (Join-Path $src $Accent1) 12 $new
    Write-TestFile (Join-Path $src 'sub dir\new.txt') 7 $new
    Write-TestFile (Join-Path $dst 'extra file.txt') 1 $old
    Write-TestFile (Join-Path $dst $Accent2) 9 $old
    foreach ($i in 1..3) { Write-TestFile (Join-Path $dst "Carpeta borrada\f$i.txt") 100 $old }
    Write-TestFile (Join-Path $dst 'Carpeta borrada\nested\deep.txt') 1000 $old
    return [pscustomobject]@{ Root = $root; Src = $src; Dst = $dst }
}

# Get-TreeSnapshot: every folder and file (path, size, time, hash) under a root.
function Get-TreeSnapshot {
    param([string]$Root)
    $items = Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length)
        if ($_.PSIsContainer) { "D $rel" }
        else { "F $rel $($_.Length) $($_.LastWriteTimeUtc.Ticks) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    }
    return ($items -join "`n")
}

# Get-FileSet: relative path and size of every file, skipping RoboBak's log folders.
function Get-FileSet {
    param([string]$Root)
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $rel = $_.FullName.Substring($Root.Length)
        -not ($rel.StartsWith('\backup_logs\') -or $rel.StartsWith('\current_backup_logs\'))
    } | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Root.Length)) $($_.Length)" }
    return ($items -join "`n")
}

function Get-DryRunTempFiles {
    return @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'robobak_dry_run_*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

# Invoke-RoboBakTest: runs robobak.ps1 in a new PowerShell in test mode, with
# the given answers piped to its prompts. Returns everything it printed.
function Invoke-RoboBakTest {
    param([string]$TestEnv, [string[]]$Arguments, [string[]]$InputLines)
    $env:ROBOBAK_TEST = $TestEnv
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $inputText = ($InputLines -join "`r`n")
        $output = $inputText | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RoboBak @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $previous
        $env:ROBOBAK_TEST = $null
    }
    return (($output | ForEach-Object { "$_" }) -join "`n")
}

try {
    # ------------------------------------------------------------------
    Write-Section "Test mode map (ROBOBAK_TEST)"

    $env:ROBOBAK_TEST = "s=C:\T\src|DATA_T; D=C:\T\dst\|BACKUP_T ;local=C:\T\local"
    $map = Get-RoboBakTestMap
    Assert-Equal 'C:\T\src' $map.Drives['S'].Folder "lower-case letter maps to its folder"
    Assert-Equal 'BACKUP_T' $map.Drives['D'].Label "label is read"
    Assert-Equal 'C:\T\local' $map.Local "local folder is read"
    Assert-Equal 'C:\T\dst\' (Get-DriveRoot 'D') "drive root has one trailing backslash"
    Assert-Equal 'DATA_T' (Get-DriveLabel 'S') "Get-DriveLabel uses the map"
    Assert-True ($null -eq (Get-DriveRoot 'Q')) "unmapped letter gives no root (never a real drive)"
    Assert-True ($null -eq (Get-DriveLabel 'Q')) "unmapped letter gives no label"
    Assert-Equal 'C:\T\local' (Get-RoboBakLocalDir $RepoRoot) "test mode uses the local= folder"

    $env:ROBOBAK_TEST = "S=C:\T\src|DATA_T"
    Assert-True ($null -eq (Get-RoboBakLocalDir $RepoRoot)) "test mode without local= never uses the repo's local folder"

    foreach ($bad in @("S=C:\with space\src|DATA", "S=relative\path|DATA", "SS=C:\T|X", "nonsense")) {
        $env:ROBOBAK_TEST = $bad
        $threw = $false
        try { $null = Get-RoboBakTestMap } catch { $threw = $true }
        Assert-True $threw "malformed entry is rejected: '$bad'"
    }
    $env:ROBOBAK_TEST = $null
    Assert-True (-not (Test-RoboBakTestMode)) "test mode is off when the variable is unset"
    Assert-Equal 'F:\' (Get-DriveRoot 'F') "outside test mode the root is the drive letter"
    Assert-Equal (Join-Path $RepoRoot 'local') (Get-RoboBakLocalDir $RepoRoot) "outside test mode local\ sits next to the scripts"

    # ------------------------------------------------------------------
    Write-Section "Summary table parsing (by position)"

    $row = ConvertFrom-RoboStatsRow " Archivos:         4         3         1         0         0         5"
    Assert-Equal "4 3 1 0 0 5" ($row -join ' ') "Spanish Files row"
    $row = ConvertFrom-RoboStatsRow "    Files :         4         3         1         0         0         5"
    Assert-Equal "4 3 1 0 0 5" ($row -join ' ') "English Files row"
    $row = ConvertFrom-RoboStatsRow "    Bytes:         0         0         0         0         0 6442463289"
    Assert-Equal 6442463289 $row[5] "Bytes row with a 10-digit value"
    Assert-True ($null -eq (ConvertFrom-RoboStatsRow "    Bytes :   1.2 m   0   0   0   0   0")) "row with units (no /BYTES) is rejected"
    Assert-True ($null -eq (ConvertFrom-RoboStatsRow "   Tiempo:   0:00:00   0:00:00                       0:00:00   0:00:00")) "Times row is not mistaken for numbers"
    Assert-True ($null -eq (Read-RoboStats @("header", "-----------------------", "", "   just a file line"))) "missing table gives unknown counts"

    # The end of a real copy's log: two "Speed" lines follow the table, which
    # pushed the header, Dirs and Files rows out of the old "last 8 lines".
    $realTail = @(
        "------------------------------------------------------------------------------",
        "",
        "               Total   Copiado   OmitidoNo coincidencia     ERROR    Extras",
        "Director.:     10376     10374      9773         0         0       312",
        " Archivos:    194517      1667    192850         0         0       805",
        "    Bytes: 462.836 g  42.082 g 420.754 g         0         0   4.982 g",
        "   Tiempo:   2:39:58   0:15:06                       0:00:00   0:01:47",
        "",
        "",
        "Velocidad:           49.822.023 Bytes/s",
        "Velocidad:             2850,839 Megabytes/min",
        "   Finalizado: viernes, 6 de noviembre de 2026 12:04:52",
        ""
    )
    $shown = Get-RoboSummaryLines (@("header", "------------------------------------------------------------------------------", "file lines") + $realTail)
    Assert-True ($shown[0] -match 'Total') "summary display starts at the column header"
    Assert-Contains ($shown -join "`n") " Archivos:    194517" "summary display keeps the Files row when Speed lines follow"
    Assert-Contains ($shown -join "`n") "Finalizado" "summary display keeps the lines after the table"
    Assert-Equal 8 @(Get-RoboSummaryLines @(1..20 | ForEach-Object { "line $_" })).Count "without a line of dashes, the last 8 lines"

    # ------------------------------------------------------------------
    Write-Section "Sizes and thresholds"

    Assert-Equal "0 bytes" (Format-Size 0) "0 bytes"
    Assert-Equal "35 bytes" (Format-Size 35) "35 bytes"
    Assert-Equal ('{0:N1} KB' -f 1.5) (Format-Size 1536) "1536 bytes in KB, current culture"
    Assert-Equal ('{0:N1} GB' -f 5) (Format-Size (5 * 1GB)) "5 GB uses 1024^3"

    $defaults = Read-RoboBakSettings $null
    Assert-Equal 500 $defaults.DeleteWarnFiles "default file threshold"
    Assert-Equal 5 $defaults.DeleteWarnGB "default GB threshold"
    $stats = { param($files, $bytes) [pscustomobject]@{ DeleteFiles = $files; DeleteBytes = $bytes } }
    Assert-True (-not (Test-LargeDeletion (& $stats 500 0) $defaults)) "500 files is not above the threshold"
    Assert-True (Test-LargeDeletion (& $stats 501 0) $defaults) "501 files is above the threshold"
    Assert-True (-not (Test-LargeDeletion (& $stats 1 (5 * 1GB)) $defaults)) "exactly 5 GB is not above the threshold"
    Assert-True (Test-LargeDeletion (& $stats 1 (5 * 1GB + 1)) $defaults) "5 GB + 1 byte is above the threshold"
    Assert-True (-not (Test-LargeDeletion $null $defaults)) "unknown counts never trigger the red warning"

    $localDir = Join-Path $TestRoot 'local'
    New-Item -ItemType Directory -Path $localDir | Out-Null
    $settingsFile = Join-Path $localDir 'settings.json'
    Set-Content -LiteralPath $settingsFile -Value '{ "robobak": { "deleteWarnFiles": 1000, "deleteWarnGB": 0.5 }, "reminders": { "enabled": true } }' -Encoding UTF8
    $s = Read-RoboBakSettings $localDir
    Assert-Equal 1000 $s.DeleteWarnFiles "file threshold read from settings.json"
    Assert-Equal 0.5 $s.DeleteWarnGB "decimal GB threshold read from settings.json"
    Assert-True ($null -eq $s.Warning) "valid settings give no warning"
    Set-Content -LiteralPath $settingsFile -Value '{ "reminders": { "enabled": true } }' -Encoding UTF8
    Assert-Equal 500 (Read-RoboBakSettings $localDir).DeleteWarnFiles "missing robobak section gives defaults"
    Set-Content -LiteralPath $settingsFile -Value '{ "robobak": { "deleteWarnFiles": -3, "deleteWarnGB": "lots" } }' -Encoding UTF8
    $s = Read-RoboBakSettings $localDir
    Assert-True ($s.DeleteWarnFiles -eq 500 -and $s.DeleteWarnGB -eq 5 -and $s.Warning) "invalid values fall back to defaults with a warning"
    Set-Content -LiteralPath $settingsFile -Value '{ not json' -Encoding UTF8
    $s = Read-RoboBakSettings $localDir
    Assert-True ($s.DeleteWarnFiles -eq 500 -and $s.Warning) "invalid JSON falls back to defaults with a warning"
    Remove-Item -LiteralPath $settingsFile

    # ------------------------------------------------------------------
    Write-Section "Dry run on test folders (real robocopy, list-only)"

    $fx = New-Fixture 'dryrun'
    $srcBefore = Get-TreeSnapshot $fx.Src
    $dstBefore = Get-TreeSnapshot $fx.Dst
    $log = Join-Path $TestRoot 'dryrun_log.txt'
    $exclude = @('$RECYCLE.BIN', 'System Volume Information', (Join-Path $fx.Dst 'current_backup_logs'))
    $dry = Invoke-RoboDryRun -Source ($fx.Src + '\') -Dest ($fx.Dst + '\') -ExcludeDirs $exclude -LogPath $log
    Write-Host "  (dry run on the test folders took $([math]::Round($dry.Duration.TotalMilliseconds)) ms, exit code $($dry.ExitCode))" -ForegroundColor DarkGray
    Assert-True ($dry.ExitCode -lt 8) "dry run exit code below 8"
    Assert-True ($null -ne $dry.Stats) "summary table was read"
    Assert-Equal 6 $dry.Stats.DeleteFiles "table: 6 files to delete (including the 4 inside the deleted folder)"
    Assert-Equal 1310 $dry.Stats.DeleteBytes "table: 1310 bytes to delete"
    Assert-Equal 3 $dry.Stats.CopyFiles "table: 3 files to copy"
    Assert-Equal 39 $dry.Stats.CopyBytes "table: 39 bytes to copy"
    Assert-Equal 6 $dry.ListedDeleteFiles "list: 6 deletion lines, one per file"
    Assert-Equal 3 $dry.ListedCopyFiles "list: 3 copy lines"
    $deleteText = $dry.DeleteLines -join "`n"
    $copyText = $dry.CopyLines -join "`n"
    Assert-Contains $deleteText "[folder]  $($fx.Dst)\Carpeta borrada\" "deleted folder is shown as a folder line"
    Assert-Contains $deleteText "$($fx.Dst)\Carpeta borrada\nested\deep.txt" "file in a nested deleted folder is listed"
    Assert-Contains $deleteText "$($fx.Dst)\$Accent2" "accented deletion survives /UNILOG"
    Assert-Contains $copyText "$($fx.Src)\$Accent1" "accented copy survives /UNILOG"
    Assert-Contains $copyText "$($fx.Src)\changed.txt" "changed file is a copy"
    Assert-NotContains $copyText "same.txt" "unchanged file is not listed"
    Assert-Equal $srcBefore (Get-TreeSnapshot $fx.Src) "dry run left the source untouched"
    Assert-Equal $dstBefore (Get-TreeSnapshot $fx.Dst) "dry run left the destination untouched"

    $listFile = Join-Path $TestRoot 'dryrun_list.txt'
    Write-DryRunList -DryRun $dry -Path $listFile -SourceText 'S' -DestText 'D'
    $bytes = [System.IO.File]::ReadAllBytes($listFile)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "list file is UTF-8 with BOM"
    $listText = [System.IO.File]::ReadAllText($listFile, [System.Text.Encoding]::UTF8)
    Assert-True ($listText.IndexOf('WILL DELETE') -ge 0 -and $listText.IndexOf('WILL DELETE') -lt $listText.IndexOf('WILL COPY')) "list shows deletions before copies"
    Assert-Contains $listText $Accent1 "list keeps the accented name"

    # ------------------------------------------------------------------
    Write-Section "End to end (a): answering N changes nothing"

    $fx = New-Fixture 'e2e_cancel'
    $srcBefore = Get-TreeSnapshot $fx.Src
    $dstBefore = Get-TreeSnapshot $fx.Dst
    $tempBefore = Get-DryRunTempFiles
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D') @('N')
    Assert-Contains $out "TEST MODE" "test mode banner is shown"
    Assert-Contains $out "Will delete 6 files (" "confirmation shows the deletion count"
    Assert-Contains $out "and copy 3 files (" "confirmation shows the copy count"
    Assert-NotContains $out "LARGE DELETION" "no red warning for a small deletion"
    Assert-Contains $out "Operation cancelled by user." "N cancels"
    Assert-Equal $srcBefore (Get-TreeSnapshot $fx.Src) "source untouched (no backup_logs created)"
    Assert-Equal $dstBefore (Get-TreeSnapshot $fx.Dst) "destination byte-identical"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Dst 'current_backup_logs'))) "no current_backup_logs created"
    Assert-Equal ($tempBefore -join '|') ((Get-DryRunTempFiles) -join '|') "dry-run temp files removed"
    $m = [regex]::Match($out, 'Dry run finished in (\d\d:\d\d:\d\d)')
    if ($m.Success) { Write-Host "  (robobak.ps1 reported: dry run finished in $($m.Groups[1].Value))" -ForegroundColor DarkGray }

    # ------------------------------------------------------------------
    Write-Section "End to end (b): L, then Y, with --no-verify"

    $fx = New-Fixture 'e2e_mirror'
    $tempBefore = Get-DryRunTempFiles
    $testEnv = "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T"
    $out = Invoke-RoboBakTest $testEnv @('S', 'D', '--no-verify') @('L', 'Y')
    Assert-Contains $out "TEST MODE: the list is at" "L shows the list (its path, in test mode)"
    Assert-Contains $out "BACKUP COMPLETED SUCCESSFULLY" "mirror completed"
    Assert-Equal (Get-FileSet $fx.Src) (Get-FileSet $fx.Dst) "destination now mirrors the source"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Dst 'Carpeta borrada'))) "deleted folder is gone"
    $logsDir = Join-Path $fx.Dst 'current_backup_logs'
    $listPath = Join-Path $logsDir 'dry_run_list.txt'
    $logPath = Join-Path $logsDir 'dry_run_log.txt'
    Assert-True (Test-Path -LiteralPath $listPath) "dry_run_list.txt kept on the destination"
    Assert-True (Test-Path -LiteralPath $logPath) "dry_run_log.txt kept on the destination"
    if (Test-Path -LiteralPath $listPath) {
        $listText = [System.IO.File]::ReadAllText($listPath, [System.Text.Encoding]::UTF8)
        Assert-Contains $listText $Accent2 "kept list has the accented deletion"
        Assert-True ($listText.IndexOf('WILL DELETE') -lt $listText.IndexOf('WILL COPY')) "kept list shows deletions first"
    }
    if (Test-Path -LiteralPath $logPath) {
        $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8)
        Assert-True ($logText.StartsWith('# Generated by RoboBak.')) "kept log starts with the RoboBak header"
        Assert-Contains $logText $Accent1 "kept log has the accented name after conversion to UTF-8"
        Assert-True ($logText -cmatch 'EXTRA') "kept log has the EXTRA lines"
    }
    $summary = Get-Content -LiteralPath (Join-Path $logsDir 'backup_summary.txt') -Raw -Encoding UTF8
    Assert-Contains $summary "Dry run: would delete 6 files (" "summary has the dry-run counts"
    Assert-Contains $summary "and copy 3 files (" "summary has the copy count"
    Assert-Contains $summary "Dry run duration: " "summary has the dry-run duration"
    $times = Get-Content -LiteralPath (Join-Path $fx.Src 'backup_logs\backup_times.txt') -Raw -Encoding UTF8
    Assert-Contains $times "  Dry run duration:      " "backup_times.txt has the dry-run duration"
    Assert-Equal ($tempBefore -join '|') ((Get-DryRunTempFiles) -join '|') "dry-run temp files moved away"

    # ------------------------------------------------------------------
    Write-Section "End to end (b3): the screen shows the whole summary table"

    # A copy that takes measurable time makes robocopy print two "Speed" lines
    # after its table (with the tiny fixture above it prints none). Robocopy
    # doesn't always print them for a fast copy, so their presence is only
    # reported; the unit test above checks that layout deterministically.
    $bigRoot = Join-Path $TestRoot 'e2e_summary'
    $bigSrc = Join-Path $bigRoot 'src'
    $bigDst = Join-Path $bigRoot 'dst'
    New-Item -ItemType Directory -Path $bigSrc, $bigDst -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $bigSrc 'big.bin'), (New-Object byte[] (100MB)))
    $out = Invoke-RoboBakTest "S=$bigSrc|DATA_T;D=$bigDst|BACKUP_T" @('S', 'D', '--no-verify') @('Y')
    $roboLog = @(Get-Content -LiteralPath (Join-Path $bigDst 'current_backup_logs\robocopy_log.txt'))
    $sep = Get-LastRoboSeparator $roboLog
    $tableRows = @($roboLog[($sep + 1)..($roboLog.Count - 1)] | Where-Object { $_.Trim() })
    Assert-True ($tableRows.Count -ge 5) "the copy's log has a summary table (header and 4 rows)"
    Write-Host ("  INFO  robocopy printed {0} line(s) after the table this time" -f [math]::Max(0, $tableRows.Count - 5)) -ForegroundColor DarkGray
    $screen = $out.Substring([math]::Max(0, $out.IndexOf('ROBOCOPY SUMMARY')))
    $missing = @($tableRows | Where-Object { $screen.IndexOf($_) -lt 0 })
    Assert-Equal 0 $missing.Count "the screen shows every row of the copy's summary table"

    # ------------------------------------------------------------------
    Write-Section "End to end (b2): second run with --verify"

    $out = Invoke-RoboBakTest $testEnv @('S', 'D', '--verify') @('Y')
    Assert-Contains $out "Will delete 0 files (0 bytes)" "nothing left to delete"
    Assert-Contains $out "VERIFICATION PASSED" "verification still passes"
    $times = Get-Content -LiteralPath (Join-Path $fx.Src 'backup_logs\backup_times.txt') -Raw -Encoding UTF8
    Assert-Equal 2 ([regex]::Matches($times, 'Dry run duration:').Count) "backup_times.txt keeps both 6-line entries"

    # ------------------------------------------------------------------
    Write-Section "End to end (c): large deletions"

    $root = Join-Path $TestRoot 'e2e_large'
    $src = Join-Path $root 'src'; $dst = Join-Path $root 'dst'
    New-Item -ItemType Directory -Path $src, $dst -Force | Out-Null
    foreach ($i in 1..501) { [System.IO.File]::WriteAllBytes((Join-Path $dst "old_$i.txt"), [byte[]]@(65)) }
    $dstBefore = Get-TreeSnapshot $dst
    $out = Invoke-RoboBakTest "S=$src|DATA_T;D=$dst|BACKUP_T" @('S', 'D') @('N')
    Assert-Contains $out "LARGE DELETION" "501 files to delete shows the red warning"
    Assert-Contains $out ("Will delete {0} files" -f (501).ToString('N0')) "the count is 501"
    Assert-Equal $dstBefore (Get-TreeSnapshot $dst) "cancelled: destination unchanged"

    Set-Content -LiteralPath $settingsFile -Value '{ "robobak": { "deleteWarnFiles": 1000 } }' -Encoding UTF8
    $out = Invoke-RoboBakTest "S=$src|DATA_T;D=$dst|BACKUP_T;local=$localDir" @('S', 'D') @('N')
    Assert-NotContains $out "LARGE DELETION" "a higher file threshold in settings.json removes the warning"

    $fx = New-Fixture 'e2e_bytes'
    Set-Content -LiteralPath $settingsFile -Value '{ "robobak": { "deleteWarnGB": 0.000001 } }' -Encoding UTF8
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$localDir" @('S', 'D') @('N')
    Assert-Contains $out "LARGE DELETION" "a tiny GB threshold triggers the warning on 1310 bytes"

    Set-Content -LiteralPath $settingsFile -Value '{ broken' -Encoding UTF8
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$localDir" @('S', 'D') @('N')
    Assert-Contains $out "invalid JSON" "unreadable settings.json is reported"
    Assert-Contains $out "Will delete 6 files (" "and the run still shows the counts"
    Remove-Item -LiteralPath $settingsFile

    # ------------------------------------------------------------------
    Write-Section "End to end (d): refusals before any robocopy"

    $fx = New-Fixture 'e2e_refuse'
    $dstBefore = Get-TreeSnapshot $fx.Dst
    $tempBefore = Get-DryRunTempFiles
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'Q') @('Y', 'Y')
    Assert-Contains $out "not mapped in ROBOBAK_TEST" "unmapped letter is an error in test mode"
    Assert-NotContains $out "Checking what the mirror would change" "no dry run for an unmapped letter"

    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|NOT_A_BACKUP" @('S', 'D') @('Y', 'Y')
    Assert-Contains $out "SAFETY ERROR" "destination without a BACKUP_ label is refused"
    Assert-NotContains $out "Checking what the mirror would change" "no dry run before the label check passes"

    $out = Invoke-RoboBakTest "S=C:\has space\src|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D') @('Y', 'Y')
    Assert-Contains $out "contains spaces" "a test folder with spaces is refused"

    Assert-Equal $dstBefore (Get-TreeSnapshot $fx.Dst) "destination unchanged after the refusals"
    Assert-Equal ($tempBefore -join '|') ((Get-DryRunTempFiles) -join '|') "no dry-run temp files left by the refusals"

    # ------------------------------------------------------------------
    Write-Section "End to end (e): behaviour kept from the original script"

    # Get-RoboOptionsBlock: the part of a robocopy log that echoes the command
    # (source, destination, file filter, excluded folders, options), between the
    # 2nd and 3rd lines of dashes, without the start time, and with the test
    # folder replaced by <ROOT>, so two runs on different folders compare.
    function Get-RoboOptionsBlock {
        param([string]$LogPath, [string]$Root)
        $lines = [System.IO.File]::ReadAllLines($LogPath, [System.Text.Encoding]::Default)
        $seps = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*-{10,}\s*$') { $i } })
        if ($seps.Count -lt 3) { return "(no options block in $LogPath)" }
        $block = @($lines[($seps[1] + 1)..($seps[2] - 1)] | Where-Object { $_.Trim() } | Select-Object -Skip 1)
        return (($block | ForEach-Object { $_.Replace($Root, '<ROOT>').TrimEnd() }) -join "`n")
    }

    # The original script's copy and verification commands (commit c99c724),
    # run directly on a twin fixture to get the reference logs. The one deliberate
    # change since then: robobak_health (the disk health history) is excluded too.
    function Invoke-OriginalCommands {
        param($Fx, [string[]]$ModeFlags, [switch]$Verify)
        $Source = $Fx.Src + '\'
        $Dest = $Fx.Dst + '\'
        $DestLogsDir = Join-Path $Dest 'current_backup_logs'
        $DestHealthDir = Join-Path $Dest 'robobak_health'
        $SourceLogsDir = Join-Path $Source 'backup_logs'
        $DestBackupLogsDir = Join-Path $Dest 'backup_logs'
        New-Item -ItemType Directory -Path $DestLogsDir, $SourceLogsDir -Force | Out-Null
        $LogRobo = Join-Path $DestLogsDir 'robocopy_log.txt'
        $LogVerify = Join-Path $DestLogsDir 'verify_log.txt'
        $RoboCommon = @(
            "/MIR", "/MT:16", "/DCOPY:DAT", "/R:3", "/W:5", "/V",
            "/LOG+:$LogRobo",
            "/XD", '$RECYCLE.BIN', "System Volume Information", $DestLogsDir, $DestHealthDir
        )
        & robocopy $Source $Dest @RoboCommon @ModeFlags > $null
        if ($Verify) {
            & robocopy $Source $Dest /MIR /L /MT:16 /R:3 /W:5 /LOG+:$LogVerify /XD '$RECYCLE.BIN' "System Volume Information" $DestLogsDir $DestHealthDir $SourceLogsDir $DestBackupLogsDir > $null
        }
        return @{ Copy = $LogRobo; Verify = $LogVerify }
    }

    $modes = @(
        @{ Name = 'default mode';    Args = @();                  Flags = @() },
        @{ Name = '--show-progress'; Args = @('--show-progress'); Flags = @('/TEE', '/NP') },
        @{ Name = '--verbose';       Args = @('--verbose');       Flags = @('/TEE') }
    )
    foreach ($m in $modes) {
        $tag = ($m.Name -replace '[^a-z]', '')
        $fxNew = New-Fixture "e_$($tag)_new"
        $fxOld = New-Fixture "e_$($tag)_orig"
        $verifyArg = if ($m.Name -eq 'default mode') { '--verify' } else { '--no-verify' }
        $out = Invoke-RoboBakTest "S=$($fxNew.Src)|DATA_T;D=$($fxNew.Dst)|BACKUP_T" (@('S', 'D') + $m.Args + @($verifyArg)) @('Y')
        $ref = Invoke-OriginalCommands $fxOld $m.Flags -Verify:($verifyArg -eq '--verify')
        Assert-Contains $out "BACKUP COMPLETED SUCCESSFULLY" "$($m.Name): mirror completed"
        Assert-Equal (Get-FileSet $fxNew.Src) (Get-FileSet $fxNew.Dst) "$($m.Name): destination mirrors the source"
        $newBlock = Get-RoboOptionsBlock (Join-Path $fxNew.Dst 'current_backup_logs\robocopy_log.txt') $fxNew.Root
        $oldBlock = Get-RoboOptionsBlock $ref.Copy $fxOld.Root
        Assert-Equal $oldBlock $newBlock "$($m.Name): the copy passes robocopy exactly the original options and exclusions"
        Assert-Contains $out "1 or 2 Extra dirs are expected" "$($m.Name): the expected-extra-dirs note is shown"
        if ($verifyArg -eq '--verify') {
            $newV = Get-RoboOptionsBlock (Join-Path $fxNew.Dst 'current_backup_logs\verify_log.txt') $fxNew.Root
            $oldV = Get-RoboOptionsBlock $ref.Verify $fxOld.Root
            Assert-Equal $oldV $newV "$($m.Name): the verification passes robocopy exactly the original options and exclusions"
            Assert-Contains $out "VERIFICATION PASSED" "$($m.Name): verification passes (phantom extra dir still handled)"
        }
        if ($m.Name -eq '--show-progress') {
            Assert-Contains $out "Counting files on source drive" "--show-progress: counts the files first"
            Assert-True ($out -match '\] \d+% \(') "--show-progress: shows the progress bar"
            $times = Get-Content -LiteralPath (Join-Path $fxNew.Src 'backup_logs\backup_times.txt') -Raw -Encoding UTF8
            Assert-Contains $times "Flags:                 --show-progress" "--show-progress: the flag is logged in backup_times.txt"
        }
        if ($m.Name -eq '--verbose') {
            Assert-Contains $out "new.txt" "--verbose: file operations are printed on the terminal"
        }
        $history = Get-Content -LiteralPath (Join-Path $fxNew.Src 'backup_logs\backup_history.txt') -Raw -Encoding UTF8
        Assert-True ($history -match 'BACKUP_T \| \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[NEWEST\]') "$($m.Name): backup_history.txt records the drive as NEWEST"
    }

    # No verify flag: RoboBak asks after the copy.
    $fx = New-Fixture 'e_ask_no'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D') @('Y', 'N')
    $summary = Get-Content -LiteralPath (Join-Path $fx.Dst 'current_backup_logs\backup_summary.txt') -Raw -Encoding UTF8
    Assert-Contains $summary "Verification: not performed" "no flag, answer N to the verify question: not verified"
    $fx = New-Fixture 'e_ask_yes'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D') @('Y', 'Y')
    $summary = Get-Content -LiteralPath (Join-Path $fx.Dst 'current_backup_logs\backup_summary.txt') -Raw -Encoding UTF8
    Assert-Contains $summary "Verification: PASSED" "no flag, answer Y to the verify question: verified"

    # Refusals and warnings that come before the dry run.
    $fx = New-Fixture 'e_refusals'
    $dstBefore = Get-TreeSnapshot $fx.Dst
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D', '--show-progress', '--verbose') @('Y')
    Assert-Contains $out "cannot be used together" "--show-progress with --verbose is refused"
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'S') @('Y')
    Assert-Contains $out "cannot be the same drive" "the same letter twice is refused"
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('/?') @()
    Assert-Contains $out "HELP: ROBOBAK" "/? shows the help"
    $out = Invoke-RoboBakTest "S=$($fx.Src)|;D=$($fx.Dst)|BACKUP_T" @('S', 'D') @('N')
    Assert-Contains $out "has no label" "a source without a label shows the warning"
    Assert-NotContains $out "Checking what the mirror would change" "answering N to that warning stops before the dry run"
    Assert-Equal $dstBefore (Get-TreeSnapshot $fx.Dst) "destination unchanged by these refusals"

    # A copy error (exit code 8 or more): a source file locked by this test.
    # Robocopy retries 3 times, 5 s apart, so this takes about 15 s.
    $fx = New-Fixture 'e_failure'
    $failLocal = Join-Path $TestRoot 'e_failure_local'
    $lock = [System.IO.File]::Open((Join-Path $fx.Src 'changed.txt'), 'Open', 'Read', 'None')
    try {
        $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$failLocal" @('S', 'D', '--verify') @('Y')
    } finally {
        $lock.Close()
    }
    $failRecords = @(Read-RunRecords $failLocal)
    Assert-Equal 1 $failRecords.Count "failure: the run is recorded once in runs.csv"
    if ($failRecords.Count -ge 1) {
        Assert-Equal 'mirror|failed|not performed' "$($failRecords[0].kind)|$($failRecords[0].result)|$($failRecords[0].verification)" "failure: recorded as a failed mirror, not verified"
    }
    Assert-Contains $out "ROBOCOPY REPORTED ERRORS" "a locked file makes the copy report errors"
    $summary = Get-Content -LiteralPath (Join-Path $fx.Dst 'current_backup_logs\backup_summary.txt') -Raw -Encoding UTF8
    Assert-Contains $summary "STATUS: BACKUP FAILED" "failure: the summary says BACKUP FAILED"
    Assert-True ($summary -match 'ERROR \d+') "failure: the summary lists the robocopy error"
    Assert-Contains $summary "Dry run: would delete 6 files (" "failure: the summary still has the dry-run counts"
    Assert-Contains $summary "Verification: not performed (backup failed)" "failure: no verification"
    $times = Get-Content -LiteralPath (Join-Path $fx.Src 'backup_logs\backup_times.txt') -Raw -Encoding UTF8
    Assert-Contains $times "(FAILED)" "failure: backup_times.txt records the failed run"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Src 'backup_logs\backup_history.txt'))) "failure: backup_history.txt is not updated"

    # ------------------------------------------------------------------
    Write-Section "Run records (local\runs.csv): the library"

    $dateRx = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
    Assert-True ($null -eq (Add-RunRecord -LocalDir $null -Kind 'mirror' -Source 'A' -Destination 'BACKUP_B' -Result 'ok' -Verification 'passed')) "no local folder: nothing is written"
    $unitLocal = Join-Path $TestRoot 'unit_local'
    $unitPath = Add-RunRecord -LocalDir $unitLocal -Kind 'mirror' -Source 'A' -Destination 'BACKUP_B' -Result 'ok' -Verification 'differences' -Date ([datetime]'2026-01-02 03:04:05')
    Assert-True ($unitPath -and (Test-Path -LiteralPath $unitPath)) "Add-RunRecord creates local\ and runs.csv"
    $unit = @(Read-RunRecords $unitLocal)
    Assert-Equal 1 $unit.Count "one record read back"
    if ($unit.Count -ge 1) {
        $values = ($unit[0].PSObject.Properties | ForEach-Object { $_.Value }) -join '|'
        Assert-Equal '2026-01-02 03:04:05|mirror|A|BACKUP_B|ok|differences|not checked' $values "a record round-trips with every column, in order (verification: differences)"
    }
    Assert-Equal 0 @(Read-RunRecords (Join-Path $TestRoot 'no_such_local')).Count "no runs.csv: no records"

    # ------------------------------------------------------------------
    Write-Section "End to end (f): every mirror run is recorded once"

    $runsLocal = Join-Path $TestRoot 'f_local'
    $fx = New-Fixture 'f_passed'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$runsLocal" @('S', 'D', '--verify') @('Y')
    Assert-Contains $out "Recorded in" "a mirror run says it was recorded"
    $records = @(Read-RunRecords $runsLocal)
    Assert-Equal 1 $records.Count "one mirror run, one line"
    if ($records.Count -ge 1) {
        $r = $records[0]
        Assert-True ($r.date -match $dateRx) "date is yyyy-MM-dd HH:mm:ss"
        $age = (Get-Date) - [datetime]::ParseExact($r.date, 'yyyy-MM-dd HH:mm:ss', $null)
        Assert-True ($age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt 10) "date is the time of the run"
        Assert-Equal 'mirror' $r.kind "kind is mirror"
        Assert-Equal 'DATA_T' $r.source "source is the source label"
        Assert-Equal 'BACKUP_T' $r.destination "destination is the destination label"
        Assert-Equal 'ok' $r.result "result is ok"
        Assert-Equal 'passed' $r.verification "verification passed"
        Assert-Equal 'not checked' $r.health "health is not checked (no disk health yet)"
    }

    $fx = New-Fixture 'f_noverify'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$runsLocal" @('S', 'D', '--no-verify') @('Y')
    $fx = New-Fixture 'f_askno'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$runsLocal" @('S', 'D') @('Y', 'N')
    $records = @(Read-RunRecords $runsLocal)
    Assert-Equal 3 $records.Count "three runs, three lines"
    if ($records.Count -ge 3) {
        Assert-Equal 'ok|not performed' "$($records[1].result)|$($records[1].verification)" "--no-verify: ok, not performed"
        Assert-Equal 'ok|not performed' "$($records[2].result)|$($records[2].verification)" "verify question answered N: ok, not performed"
    }

    # Cancelled and refused runs write nothing
    $fx = New-Fixture 'f_cancel'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$runsLocal" @('S', 'D', '--verify') @('N')
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|NOT_A_BACKUP;local=$runsLocal" @('S', 'D', '--verify') @('Y')
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$runsLocal" @('S', 'S') @('Y')
    Assert-Equal 3 @(Read-RunRecords $runsLocal).Count "cancelled and refused runs write no line"

    # The file: header once (unquoted), one line per run, UTF-8 with a BOM
    $runsFile = Join-Path $runsLocal 'runs.csv'
    $raw = [System.IO.File]::ReadAllLines($runsFile, [System.Text.Encoding]::UTF8)
    Assert-Equal 'date,kind,source,destination,result,verification,health' $raw[0] "the first line is the header"
    Assert-Equal 1 @($raw | Where-Object { $_ -like 'date,kind,*' }).Count "the header is written only once across runs"
    Assert-Equal 4 @($raw | Where-Object { $_.Trim() }).Count "the header plus one line per run"
    $bytes = [System.IO.File]::ReadAllBytes($runsFile)
    Assert-True ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "runs.csv starts with a UTF-8 BOM"

    # Labels with quotes, commas and accents round-trip through Import-Csv
    $oddLocal = Join-Path $TestRoot 'f_odd_local'
    $oddSource = 'DATOS "' + [char]0xF1 + '", 1'
    $oddDest = 'BACKUP_' + [char]0xC1 + ',2'
    $fx = New-Fixture 'f_odd'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|$oddSource;D=$($fx.Dst)|$oddDest;local=$oddLocal" @('S', 'D', '--no-verify') @('Y')
    $records = @(Read-RunRecords $oddLocal)
    Assert-Equal 1 $records.Count "odd labels: one line"
    if ($records.Count -ge 1) {
        Assert-Equal $oddSource $records[0].source "a label with quotes, a comma and an accent round-trips"
        Assert-Equal $oddDest $records[0].destination "a BACKUP_ label with an accent and a comma round-trips"
    }

    # Test mode without local= records nothing
    $fx = New-Fixture 'f_nolocal'
    $out = Invoke-RoboBakTest "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T" @('S', 'D', '--no-verify') @('Y')
    Assert-Contains $out "isn't recorded in runs.csv" "test mode without local= says the run isn't recorded"
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $fx.Root -Recurse -Filter 'runs.csv' -ErrorAction SilentlyContinue).Count "test mode without local= writes no runs.csv"

    # ------------------------------------------------------------------
    Write-Section "End to end (f2): verification finds differences"

    # The answers are typed one at a time: Y to the confirmation; once the copy
    # is done (backup_history.txt is written just before the verify question),
    # a new file is added to the source; then Y to the verify question, so the
    # verification finds a difference.
    $fx = New-Fixture 'f2_diff'
    $diffLocal = Join-Path $TestRoot 'f2_local'
    $env:ROBOBAK_TEST = "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$diffLocal"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$RoboBak`" S D"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $env:ROBOBAK_TEST = $null
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine('Y')
    $historyFile = Join-Path $fx.Src 'backup_logs\backup_history.txt'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path -LiteralPath $historyFile) -and -not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 500
    Write-TestFile (Join-Path $fx.Src 'added after the copy.txt') 5 (Get-Date)
    $proc.StandardInput.WriteLine('Y')
    $proc.StandardInput.Close()
    $finished = $proc.WaitForExit(60000)
    if (-not $finished) { $proc.Kill() }
    Assert-True $finished "the run finished"
    $out = $stdoutTask.Result + $stderrTask.Result
    Assert-Contains $out "VERIFICATION WARNING: Differences found." "the screen reports the differences"
    $summary = Get-Content -LiteralPath (Join-Path $fx.Dst 'current_backup_logs\backup_summary.txt') -Raw -Encoding UTF8
    Assert-Contains $summary "Verification: Differences found." "the summary reports the differences"
    $times = Get-Content -LiteralPath (Join-Path $fx.Src 'backup_logs\backup_times.txt') -Raw -Encoding UTF8
    Assert-Contains $times "(OK (verify: differences))" "backup_times.txt records OK with differences"
    $records = @(Read-RunRecords $diffLocal)
    Assert-Equal 1 $records.Count "the run is recorded once"
    if ($records.Count -ge 1) {
        Assert-Equal 'ok|differences' "$($records[0].result)|$($records[0].verification)" "differences: ok, differences"
    }

    # ------------------------------------------------------------------
    Write-Section "End to end (g): --system-done"

    $sysLocal = Join-Path $TestRoot 'g_local'
    $sysPart = Join-Path $TestRoot 'g_sysimg'
    Write-TestFile (Join-Path $sysPart 'image.bin') 1000 ((Get-Date).AddDays(-1))
    $fx = New-Fixture 'g_mirror'
    $sysBefore = Get-TreeSnapshot $sysPart
    $dstBefore = Get-TreeSnapshot $fx.Dst
    $tempBefore = Get-DryRunTempFiles
    $sysEnv = "S=$sysPart|SYSIMG_T;X=$($fx.Dst)|BACKUP_T;local=$sysLocal"

    $out = Invoke-RoboBakTest $sysEnv @('--system-done', 'S') @('Y')
    Assert-Contains $out "SYSTEM BACKUP RECORDED" "--system-done S, answer Y: recorded"
    $records = @(Read-RunRecords $sysLocal)
    Assert-Equal 1 $records.Count "one system backup, one line"
    if ($records.Count -ge 1) {
        $r = $records[0]
        Assert-True ($r.date -match $dateRx) "the system line has a date"
        Assert-Equal 'system' $r.kind "kind is system"
        Assert-Equal $env:COMPUTERNAME $r.source "source is the computer's name"
        Assert-Equal 'SYSIMG_T' $r.destination "destination is the partition's label"
        Assert-Equal 'ok|not performed|not checked' "$($r.result)|$($r.verification)|$($r.health)" "result ok, verification not performed, health not checked"
    }

    $out = Invoke-RoboBakTest $sysEnv @('--system-done', 'S') @('N')
    Assert-Contains $out "Nothing was recorded" "answer N: cancelled, nothing recorded"
    $out = Invoke-RoboBakTest $sysEnv @('--system-done', 'Q') @('Y')
    Assert-Contains $out "not mapped" "an unmapped letter is refused"
    $out = Invoke-RoboBakTest $sysEnv @('--system-done', 'X') @('Y')
    Assert-Contains $out "NOT A SYSTEM IMAGE PARTITION" "a partition labeled BACKUP_ is refused"
    $out = Invoke-RoboBakTest $sysEnv @('--system-done') @('Y')
    Assert-Contains $out "needs the drive letter" "--system-done without a letter is refused"
    $out = Invoke-RoboBakTest $sysEnv @('--SYSTEM-DONE', 'S') @('Y')
    Assert-Contains $out "SYSTEM BACKUP RECORDED" "the option is case-insensitive"
    Assert-Equal 2 @(Read-RunRecords $sysLocal).Count "only the two Y answers wrote lines (N and the refusals wrote none)"

    Assert-NotContains $out "Checking what the mirror would change" "--system-done runs no dry run"
    Assert-Equal $sysBefore (Get-TreeSnapshot $sysPart) "--system-done changes nothing on the partition"
    Assert-Equal $dstBefore (Get-TreeSnapshot $fx.Dst) "--system-done changes nothing on the BACKUP_ drive it refused"
    Assert-Equal ($tempBefore -join '|') ((Get-DryRunTempFiles) -join '|') "--system-done leaves no dry-run temp files"

    # ------------------------------------------------------------------
    Write-Section "Time estimates: the library"

    $estDir = Join-Path $TestRoot 'h_lib'
    New-Item -ItemType Directory -Path $estDir -Force | Out-Null
    $timesFile = Join-Path $estDir 'backup_times.txt'
    $timesText = @(
        '# Generated by RoboBak. Rolling log of the last 10 backups with timing information.', '',
        '[2026-01-10 10:00:00] DATA -> BACKUP_1 (OK)',
        '  File count duration:   not performed',
        '  Copy duration:         01:00:00',
        '  Verification duration: 00:02:00',
        '  Flags:                 (none)', '',
        '[2026-01-20 10:00:00] DATA -> BACKUP_2 (OK)',
        '  Dry run duration:      00:01:00',
        '  File count duration:   not performed',
        '  Copy duration:         00:10:00',
        '  Verification duration: not performed',
        '  Flags:                 (none)', '',
        '[2026-02-01 10:00:00] DATA -> BACKUP_1 (OK)',
        '  Dry run duration:      00:02:00',
        '  File count duration:   not performed',
        '  Copy duration:         01:42:00',
        '  Copied (dry run):      200.00 GB',
        '  Verification duration: 00:03:00',
        '  Flags:                 (none)', '',
        '[2026-02-05 10:00:00] DATA -> BACKUP_2 (FAILED)',
        '  Dry run duration:      00:01:00',
        '  File count duration:   not performed',
        '  Copy duration:         00:30:00',
        '  Copied (dry run):      300.00 GB',
        '  Verification duration: not performed',
        '  Flags:                 (none)', '',
        '[2026-02-10 10:00:00] DATA -> BACKUP_2 (OK (verify: differences))',
        '  Dry run duration:      00:01:00',
        '  File count duration:   not performed',
        '  Copy duration:         00:03:00',
        '  Copied (dry run):      2.50 GB',
        '  Verification duration: 00:01:30',
        '  Flags:                 (none)', '',
        '[2026-02-12 10:00:00] DATA -> BACKUP_2 (OK)',
        '  Dry run duration:      00:01:00',
        '  File count duration:   not performed',
        '  Copy duration:         00:01:00',
        '  Copied (dry run):      unknown',
        '  Verification duration: 00:01:10',
        '  Flags:                 (none)', ''
    ) -join "`n"
    [System.IO.File]::WriteAllText($timesFile, $timesText, (New-Object System.Text.UTF8Encoding($true)))
    $entries = @(Read-TimesLogEntries $timesFile)
    Assert-Equal 6 $entries.Count "backup_times.txt: 6 entries read, old and new"
    Assert-True ($null -eq $entries[0].DryRun -and $null -eq $entries[0].CopiedBytes) "an old 5-line entry has no dry run and no copied size"
    Assert-Equal 3600 $entries[0].Copy.TotalSeconds "an old entry's copy duration is read"
    Assert-True ($null -eq $entries[1].Verify) "'not performed' reads as no duration"
    Assert-Equal (200 * 1GB) $entries[2].CopiedBytes "'Copied (dry run): 200.00 GB' reads back as bytes"
    Assert-Equal 'FAILED' $entries[3].Status "a FAILED status is read"
    Assert-Equal 'OK (verify: differences)|BACKUP_2' "$($entries[4].Status)|$($entries[4].Dest)" "a status with parentheses keeps the right label"
    Assert-True ($null -eq $entries[5].CopiedBytes) "'unknown' reads as no copied size"
    Assert-Equal 0 @(Read-TimesLogEntries (Join-Path $estDir 'missing.txt')).Count "no backup_times.txt, no entries"
    Assert-Equal '462.84 GB' (Format-TimesBytes ([int64](462.84 * 1GB))) "copied size is written with a point (invariant culture)"
    Assert-Equal 'unknown' (Format-TimesBytes $null) "unknown copied size is written as 'unknown'"

    $historyFile = Join-Path $estDir 'backup_history.txt'
    [System.IO.File]::WriteAllText($historyFile, "# Generated by RoboBak.`n`nBACKUP_1 | 2026-02-01 10:00:00 [NEWEST]`nBACKUP_2 | 2026-01-20 10:00:00 [OLDEST]`n", (New-Object System.Text.UTF8Encoding($true)))
    Assert-Equal 'BACKUP_1|BACKUP_2' ((Read-HistoryLabels $historyFile) -join '|') "backup_history.txt labels are read"
    Assert-Equal 0 @(Read-HistoryLabels (Join-Path $estDir 'missing.txt')).Count "no backup_history.txt, no labels (so: first backup)"

    $speed = Get-CopySpeed $entries 'DATA' 'BACKUP_1'
    Assert-Equal 'pair' $speed.Basis "speed: the last large copy to the same drive"
    Assert-Equal ([math]::Round(200 * 1GB / 6120)) ([math]::Round($speed.BytesPerSecond)) "speed = copied bytes / copy time, with the dry run's time left in"
    $speed = Get-CopySpeed $entries 'DATA' 'BACKUP_2'
    Assert-Equal 'source|BACKUP_1' "$($speed.Basis)|$($speed.Dest)" "speed: FAILED, small (< 10 GB) and unknown copies are skipped, so another drive's copy is used"
    $speed = Get-CopySpeed $entries 'OTHER' 'BACKUP_1'
    Assert-Equal ('default|' + (50 * 1MB)) "$($speed.Basis)|$($speed.BytesPerSecond)" "speed: no large copy from this source, so the 50 MB/s default"
    $shortCopy = [pscustomobject]@{ Status = 'OK'; CopiedBytes = 20GB; Copy = [TimeSpan]::FromMinutes(1); DryRun = [TimeSpan]::FromMinutes(2) }
    Assert-Equal ([math]::Round(20GB / 60)) ([math]::Round((Get-EntrySpeed $shortCopy))) "speed: a copy shorter than its dry run still measures a speed"
    $zeroCopy = [pscustomobject]@{ Status = 'OK'; CopiedBytes = 20GB; Copy = [TimeSpan]::Zero; DryRun = [TimeSpan]::FromMinutes(2) }
    Assert-True ($null -eq (Get-EntrySpeed $zeroCopy)) "speed: a copy with no recorded time measures nothing"
    $noDry = [pscustomobject]@{ Status = 'OK'; CopiedBytes = 20GB; Copy = [TimeSpan]::FromMinutes(10); DryRun = $null }
    Assert-Equal ([math]::Round(20GB / 600)) ([math]::Round((Get-EntrySpeed $noDry))) "speed: without a dry run, the whole copy time"

    Assert-Equal 'less than a minute' (Format-ApproxDuration ([TimeSpan]::FromSeconds(59))) "59 s: less than a minute"
    Assert-Equal 'about 2 min' (Format-ApproxDuration ([TimeSpan]::FromSeconds(90))) "90 s: about 2 min"
    Assert-Equal 'about 1 h' (Format-ApproxDuration ([TimeSpan]::FromSeconds(3580))) "59 min 40 s: about 1 h"
    Assert-Equal 'about 2 h 35 min' (Format-ApproxDuration ([TimeSpan]::FromMinutes(155))) "155 min: about 2 h 35 min"

    $stats = [pscustomobject]@{ DeleteFiles = 0; DeleteBytes = 0; CopyFiles = 10; CopyBytes = 200 * 1GB; FailedFiles = 0 }
    $text = Get-CopyEstimateText -Stats $stats -Entries $entries -Source 'DATA' -Dest 'BACKUP_1' -FirstBackup $false
    Assert-Contains $text "Estimated copy time: about 1 h 42 min (" "estimate = bytes / speed"
    Assert-Contains $text "measured on the last large copy to BACKUP_1)" "estimate names the copy it measured"
    Assert-NotContains $text "First backup" "no first-backup prefix for a known drive"
    $tiny = [pscustomobject]@{ DeleteFiles = 0; DeleteBytes = 0; CopyFiles = 2; CopyBytes = 2253; FailedFiles = 0 }
    $text = Get-CopyEstimateText -Stats $tiny -Entries $entries -Source 'DATA' -Dest 'BACKUP_1' -FirstBackup $false
    Assert-Contains $text "Estimated copy time: less than a minute (" "a tiny copy is estimated at less than a minute (a real 2.2 KB run took 4 s)"
    $text = Get-CopyEstimateText -Stats $stats -Entries $entries -Source 'DATA' -Dest 'BACKUP_3' -FirstBackup $true
    Assert-True ($text.StartsWith('First backup to BACKUP_3. Estimated copy time: ')) "first backup to a drive is said first"
    Assert-Contains $text "measured on a copy to BACKUP_1)" "a new drive borrows another drive's speed"
    $text = Get-CopyEstimateText -Stats $stats -Entries $entries -Source 'OTHER' -Dest 'BACKUP_1' -FirstBackup $false
    Assert-Contains $text "at 50 MB/s, a default: no large copy measured yet)" "without measurements, the default speed is said"
    $text = Get-CopyEstimateText -Stats $null -Entries $entries -Source 'DATA' -Dest 'BACKUP_1' -FirstBackup $false
    Assert-Contains $text "can't be estimated" "unknown counts: no estimate"

    Assert-Equal 'Last time to BACKUP_2 it took 00:01:00.' (Get-DryRunHintText $entries 'DATA' 'BACKUP_2') "dry-run hint: the last dry run to the same drive"
    Assert-Equal 'No previous dry run to BACKUP_3; to BACKUP_2 it took 00:01:00.' (Get-DryRunHintText $entries 'DATA' 'BACKUP_3') "dry-run hint: another drive's when there's none"
    Assert-Equal 'First dry run from this drive: no previous time to compare.' (Get-DryRunHintText $entries 'OTHER' 'BACKUP_1') "dry-run hint: the first ever"
    Assert-Equal 'Last time to BACKUP_2 it took 00:01:10.' (Get-VerifyHintText $entries 'DATA' 'BACKUP_2') "verify hint: the last verification to the same drive"
    Assert-Equal 'First verification to BACKUP_3: no previous time.' (Get-VerifyHintText $entries 'DATA' 'BACKUP_3') "verify hint: the first one"

    # ------------------------------------------------------------------
    Write-Section "End to end (h): time estimates"

    $fx = New-Fixture 'h_e2e'
    $dst2 = Join-Path $fx.Root 'dst2'
    New-Item -ItemType Directory -Path $dst2 -Force | Out-Null
    $hEnv = "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;U=$dst2|BACKUP_U"

    $out = Invoke-RoboBakTest $hEnv @('S', 'D', '--verify') @('Y')
    Assert-Contains $out "First dry run from this drive: no previous time to compare." "1st run: no previous dry run"
    Assert-Contains $out "First backup to BACKUP_T. Estimated copy time: " "1st run: first backup to the drive, with an estimate"
    Assert-Contains $out "a default: no large copy measured yet" "1st run: the default speed is used"
    Assert-Contains $out "First verification to BACKUP_T: no previous time." "1st run: no previous verification"
    $timesPath = Join-Path $fx.Src 'backup_logs\backup_times.txt'
    $times = Get-Content -LiteralPath $timesPath -Raw -Encoding UTF8
    Assert-True ($times -match '  Copied \(dry run\):      \d+\.\d{2} GB') "backup_times.txt gets the 'Copied (dry run)' line"

    $out = Invoke-RoboBakTest $hEnv @('S', 'D', '--verify') @('Y')
    Assert-Equal 2 ([regex]::Matches($out, 'Last time to BACKUP_T it took \d{2}:\d{2}:\d{2}\.').Count) "2nd run: last time shown for the dry run and the verification"
    Assert-NotContains $out "First backup to BACKUP_T" "2nd run: no longer the first backup"
    Assert-Contains $out "Estimated copy time: " "2nd run: an estimate is shown"

    $out = Invoke-RoboBakTest $hEnv @('S', 'U', '--no-verify') @('Y')
    Assert-Contains $out "No previous dry run to BACKUP_U; to BACKUP_T it took " "a new drive: the dry-run time to another drive"
    Assert-Contains $out "First backup to BACKUP_U. " "a new drive: first backup"

    $out = Invoke-RoboBakTest $hEnv @('S', 'D') @('Y', 'N')
    Assert-Contains $out "Verification: Last time to BACKUP_T it took " "the verify question shows the last verification's time"

    $back = @(Read-TimesLogEntries $timesPath)
    Assert-Equal 4 $back.Count "the four runs read back from backup_times.txt"
    Assert-Equal 'BACKUP_T|BACKUP_T|BACKUP_U|BACKUP_T' (($back | ForEach-Object { $_.Dest }) -join '|') "each run's destination reads back"
    Assert-Equal 0 @($back | Where-Object { $null -eq $_.CopiedBytes -or $null -eq $_.DryRun }).Count "each new entry reads back its dry run and copied size"

    # ------------------------------------------------------------------
    Write-Section "Disk health: reading the tools' output"

    # New-SmartJson: what "smartctl -a -j" prints for an ATA disk, with the
    # fields RoboBak reads (names from smartmontools' source; phase 8 checks them
    # against the real program).
    function New-SmartJson {
        param([string]$Serial, [string]$Model = 'DISK MODEL', $Passed = $true, [int64]$A05 = 0, [int64]$AC5 = 0, [int64]$AC6 = 0, [int64]$AC7 = 0, [int64]$Hours = 1000, [int]$Temp = 35, [int]$ExitStatus = 0)
        $rows = @()
        foreach ($p in @(@(5, $A05), @(197, $AC5), @(198, $AC6), @(199, $AC7))) {
            $rows += @{ id = $p[0]; name = 'attr'; value = 100; worst = 100; thresh = 0; raw = @{ value = $p[1]; string = "$($p[1])" } }
        }
        return (@{
            smartctl = @{ exit_status = $ExitStatus }; model_name = $Model; serial_number = $Serial
            user_capacity = @{ bytes = 1000000000000 }; smart_status = @{ passed = $Passed }
            ata_smart_attributes = @{ table = $rows }; power_on_time = @{ hours = $Hours }; temperature = @{ current = $Temp }
        } | ConvertTo-Json -Depth 6)
    }
    function Set-FakeDisk { param([string]$Dir, [string]$Name, [string]$Text) [System.IO.File]::WriteAllText((Join-Path $Dir $Name), $Text, (New-Object System.Text.UTF8Encoding($false))) }

    $r = ConvertFrom-SmartctlJson (New-SmartJson 'SER1' 'MODEL X' -A05 2 -AC5 3 -AC6 4 -AC7 5 -Hours 777 -Temp 41) 3
    Assert-Equal 'MODEL X|SER1|3' "$($r.Model)|$($r.Serial)|$($r.Number)" "smartctl: model, serial and disk number"
    Assert-Equal '2|3|4|5' "$($r.A05)|$($r.AC5)|$($r.AC6)|$($r.AC7)" "smartctl: raw values of 05, C5, C6 and C7"
    Assert-Equal '777|41|1000000000000' "$($r.Hours)|$($r.TempC)|$($r.CapacityBytes)" "smartctl: hours, temperature and capacity"
    Assert-True ($r.Passed -eq $true) "smartctl: smart_status.passed is read"
    $r = ConvertFrom-SmartctlJson (New-SmartJson 'SER2' -Passed $false -ExitStatus 0)
    Assert-True ($r.Passed -eq $false) "smartctl: a failing status is read"
    $r = ConvertFrom-SmartctlJson (New-SmartJson 'SER3' -ExitStatus 192)
    Assert-True ($r.Passed -eq $true) "smartctl: a non-zero exit code alone doesn't mean failing (it's a bitmask)"
    $nvme = '{"model_name":"NVME X","serial_number":"N1","nvme_total_capacity":1024,"smart_status":{"passed":true},"power_on_time":{"hours":5},"temperature":{"current":30}}'
    $r = ConvertFrom-SmartctlJson $nvme 0
    Assert-Equal 'N1|1024' "$($r.Serial)|$($r.CapacityBytes)" "smartctl NVMe: serial and capacity"
    Assert-True ($null -eq $r.A05 -and $null -eq $r.AC7) "smartctl NVMe: no attribute table, so no attribute values"
    Assert-True ($null -eq (ConvertFrom-SmartctlJson '{"smartctl":{"exit_status":2}}')) "smartctl: a reply with no serial identifies no disk"
    Assert-True ($null -eq (ConvertFrom-SmartctlJson 'not json')) "smartctl: invalid JSON is no reading"
    Assert-True ($null -eq (ConvertFrom-SmartctlJson '')) "smartctl: empty output is no reading"

    $cdi = @'
----------------------------------------------------------------------------
CrystalDiskInfo
-- Disk List ---------------------------------------------------------------
 (1) USB DISK : 5000.9 GB [1/0/0, sa1]

----------------------------------------------------------------------------
 (1) USB DISK
----------------------------------------------------------------------------
           Model : USB DISK
   Serial Number : CDI111
       Disk Size : 5000.9 GB (8.4/137.4/5000.9/5000.9)
  Power On Hours : 2345 horas
     Temperature : 34 C (93 F)
   Health Status : Bueno
    Drive Letter : P: Q:

-- S.M.A.R.T. --------------------------------------------------------------
ID Cur Wor Thr RawValues(6) Attribute Name
01 200 200 _51 000000000000 Tasa de errores
05 200 200 140 00000000000A Sectores reasignados
C5 200 200 _0 000000000001 Sectores pendientes
C6 100 253 _0 000000000000 Sectores incorregibles
C7 200 200 _0 0000000000FF Errores CRC

----------------------------------------------------------------------------
 (2) OTHER DISK
----------------------------------------------------------------------------
           Model : OTHER DISK
   Serial Number : CDI222
  Power On Hours : ----
     Temperature : ----
   Health Status : Good

----------------------------------------------------------------------------
 (3) BAD DISK
----------------------------------------------------------------------------
           Model : BAD DISK
   Serial Number : CDI333
   Health Status : Bad
'@
    $list = @(ConvertFrom-CrystalDiskInfoText $cdi)
    Assert-Equal 3 $list.Count "CrystalDiskInfo: one reading per disk block, not the disk list"
    Assert-Equal '10|1|0|255' "$($list[0].A05)|$($list[0].AC5)|$($list[0].AC6)|$($list[0].AC7)" "CrystalDiskInfo: raw values are read as hexadecimal, matched on the ID column"
    Assert-Equal '2345|34|P: Q:' "$($list[0].Hours)|$($list[0].TempC)|$($list[0].DriveLetters)" "CrystalDiskInfo: hours, temperature and drive letters"
    Assert-True ($null -eq $list[0].Passed) "CrystalDiskInfo: a translated health word reads as unknown"
    Assert-True ($list[1].Passed -eq $true -and $list[2].Passed -eq $false) "CrystalDiskInfo: Good and Bad are understood"
    Assert-True ($null -eq $list[1].Hours -and $null -eq $list[1].TempC) "CrystalDiskInfo: '----' reads as unknown"
    Assert-Equal 'crystaldiskinfo' $list[0].Tool "CrystalDiskInfo: the tool is recorded"

    $d = Join-Path $TestRoot 'health_readings'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-FakeDisk $d 'pd0.json' (New-SmartJson 'SAME')
    Set-FakeDisk $d 'pd1.json' '{"smartctl":{"exit_status":2}}'
    Set-FakeDisk $d 'pd1.sat.json' (New-SmartJson 'NEEDSSAT')
    Set-FakeDisk $d 'pd2.json' '{"smartctl":{"exit_status":2}}'
    Set-FakeDisk $d 'DiskInfo.txt' "Model : DUPLICATE`nSerial Number : SAME`n`nModel : FROM CDI`nSerial Number : ONLYCDI`n"
    $env:ROBOBAK_TEST = "health=$d"
    Assert-Equal $d (Get-RoboBakTestMap).Health "ROBOBAK_TEST: health= is read"
    Assert-True (Test-HealthToolAvailable) "a health folder with data counts as a tool"
    $disks = @((Get-HealthReadings).Disks)
    Assert-Equal 'SAME|NEEDSSAT|ONLYCDI' (($disks | ForEach-Object { $_.Serial }) -join '|') "readings: smartctl, then -d sat, then CrystalDiskInfo for what's left, with no duplicates"
    Assert-Equal 'smartctl|smartctl|crystaldiskinfo' (($disks | ForEach-Object { $_.Tool }) -join '|') "readings: each disk says which tool read it"
    $env:ROBOBAK_TEST = $null

    # ------------------------------------------------------------------
    Write-Section "Disk health: the history file"

    Assert-Equal 'C:\T\backup_logs' (Get-HealthDir 'C:\T\' 'source') "the data drive's history is in backup_logs"
    Assert-Equal 'C:\T\robobak_health' (Get-HealthDir 'C:\T\' 'destination') "a backup drive's history is in robobak_health"
    Assert-Equal 'C:\T\robobak_health' (Get-HealthDir 'C:\T\' 'image') "the image partition's history is in robobak_health"

    $r = ConvertFrom-SmartctlJson (New-SmartJson 'A|B' 'MO|DEL' -A05 2 -AC5 3 -AC6 4 -AC7 5 -Hours 9 -Temp 40)
    $line = ConvertTo-HealthLine -Kind 'mirror' -Level 'ok' -Reading $r -CopyErrors 1 -Verification 'passed' -Date ([datetime]'2026-02-01 10:00:00')
    Assert-Contains $line '2026-02-01 10:00:00 | mirror | level=ok | smart=passed | 05=2 | C5=3 | C6=4 | C7=5 | hours=9 | tempC=40' "the line has the date, the kind and the readings"
    Assert-Contains $line 'copyErrors=1 | verification=passed' "the line has the run's copy errors and verification"
    Assert-Contains $line 'serial=A/B | model=MO/DEL' "a | inside a value can't break the columns"
    $v = ConvertFrom-HealthLine $line
    Assert-Equal 'mirror|ok|5' "$($v['kind'])|$($v['level'])|$($v['C7'])" "a line reads back"
    Assert-True ($null -eq (ConvertFrom-HealthLine '# Generated by RoboBak.')) "the header is not a line"
    $none = ConvertTo-HealthLine -Kind 'system' -Level 'not approved' -CopyErrors 0 -Verification 'not performed'
    Assert-Contains $none 'level=not approved' "a line without a reading says why"
    Assert-NotContains $none 'smart=' "a line without a reading has no readings"

    $hd = Join-Path $TestRoot 'health_history'
    $hf = Join-Path $hd 'disk_health.txt'
    Assert-True ($null -eq (Read-PreviousHealthReading $hf 'X')) "no history file, no previous reading"
    $old = ConvertFrom-SmartctlJson (New-SmartJson 'X' -A05 7)
    Add-HealthLine $hd (ConvertTo-HealthLine -Kind 'mirror' -Level 'ok' -Reading $old -CopyErrors 0 -Verification 'passed')
    Add-HealthLine $hd (ConvertTo-HealthLine -Kind 'mirror' -Level 'not approved' -CopyErrors 0 -Verification 'passed')
    $bytes = [System.IO.File]::ReadAllBytes($hf)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "the history is UTF-8 with a BOM"
    Assert-Equal 7 (Read-PreviousHealthReading $hf 'X').A05 "the previous reading skips lines without a reading"
    Assert-True ($null -eq (Read-PreviousHealthReading $hf 'OTHER')) "a line of another disk isn't its previous reading"
    Assert-Equal 3 @([System.IO.File]::ReadAllLines($hf) | Where-Object { $_ -match '^\d{4}|^#' }).Count "lines are appended under one header"

    # ------------------------------------------------------------------
    Write-Section "Disk health: the warning rules"

    $ds = Read-RoboBakSettings $null
    Assert-Equal '20000|5|50' "$($ds.HealthWarnHours)|$($ds.HealthWarnYears)|$($ds.HealthWarnTempC)" "default thresholds: 20,000 hours, 5 years, 50 C"
    $setDir = Join-Path $TestRoot 'health_settings'
    New-Item -ItemType Directory -Path $setDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $setDir 'settings.json'), '{"robobak":{"healthWarnHours":100,"healthWarnYears":1,"healthWarnTempC":-3}}')
    $cs = Read-RoboBakSettings $setDir
    Assert-Equal '100|1|50' "$($cs.HealthWarnHours)|$($cs.HealthWarnYears)|$($cs.HealthWarnTempC)" "thresholds are read from settings.json, and an invalid one keeps its default"
    Assert-Contains $cs.Warning 'healthWarnTempC' "an invalid threshold is reported"

    # New-R: a healthy reading with some fields replaced. Check-W: runs the rules
    # and asserts the level and that one warning contains a given text.
    function New-R {
        param([hashtable]$Set = @{})
        $base = @{ Passed = $true; A05 = 0; AC5 = 0; AC6 = 0; AC7 = 0; Hours = 100; TempC = 30 }
        foreach ($k in $Set.Keys) { $base[$k] = $Set[$k] }
        return [pscustomobject]$base
    }
    function Check-W {
        param($Reading, $Previous, [string]$Level, [string]$Text, [string]$Name, [int]$CopyErrors = 0, [string]$Result = 'ok', [string]$Verification = 'passed', $Year = $null)
        $w = @(Get-HealthWarnings -Reading $Reading -Previous $Previous -CopyErrors $CopyErrors -Result $Result -Verification $Verification -Settings $ds -Year $Year -CurrentYear 2026)
        Assert-Equal $Level (Get-HealthLevel $w) "$Name (level)"
        if ($Text) { Assert-Contains (($w | ForEach-Object { $_.Text }) -join ' / ') $Text "$Name (message)" }
    }
    $prevClean = [pscustomobject]@{ A05 = 0; AC5 = 0; AC6 = 0; AC7 = 0 }

    Check-W (New-R) $prevClean 'ok' '' "a healthy disk with a clean history is ok"
    Check-W (New-R) $null 'ok' '' "a first reading of a healthy disk is ok"
    Check-W (New-R @{ Passed = $null }) $null 'ok' '' "an unknown SMART status raises nothing by itself"
    Check-W (New-R @{ Passed = $false }) $prevClean 'red' 'SMART status is not OK' "RED: SMART status not OK"
    foreach ($a in @(@('A05', '05'), @('AC5', 'C5'), @('AC6', 'C6'))) {
        $key = $a[0]; $id = $a[1]
        $p = [pscustomobject]@{ A05 = 0; AC5 = 0; AC6 = 0; AC7 = 0 }
        Check-W (New-R @{ $key = 3 }) $p 'red' "$id" "RED: $id above zero for the first time (previous 0)"
        Check-W (New-R @{ $key = 3 }) $null 'red' "for the first time" "RED: $id above zero on a first reading"
        $p.$key = 3
        Check-W (New-R @{ $key = 8 }) $p 'red' "rose from 3 to 8" "RED: $id rising"
        Check-W (New-R @{ $key = 3 }) $p 'yellow' "above zero but not rising" "YELLOW: $id above zero but unchanged"
        Check-W (New-R @{ $key = 0 }) $p 'ok' '' "$id back to zero raises nothing"
    }
    Check-W (New-R) $prevClean 'red' 'Copy errors in this run: 2' "RED: copy errors in this run" -CopyErrors 2
    Check-W (New-R) $prevClean 'red' 'Copy errors' "RED: a failed copy" -Result 'failed'
    Check-W (New-R) $prevClean 'red' 'found differences' "RED: failed verification" -Verification 'differences'
    Check-W (New-R @{ AC7 = 4 }) ([pscustomobject]@{ A05 = 0; AC5 = 0; AC6 = 0; AC7 = 1 }) 'yellow' 'C7' "YELLOW: C7 rising"
    Check-W (New-R @{ AC7 = 4 }) ([pscustomobject]@{ A05 = 0; AC5 = 0; AC6 = 0; AC7 = 4 }) 'ok' '' "C7 above zero but unchanged raises nothing"
    Check-W (New-R @{ AC7 = 4 }) $null 'ok' '' "C7 on a first reading can't be rising"
    Check-W (New-R @{ Hours = 20001 }) $prevClean 'yellow' 'Power-on hours' "YELLOW: power-on hours above 20,000"
    Check-W (New-R @{ Hours = 20000 }) $prevClean 'ok' '' "exactly 20,000 hours is not above"
    Check-W (New-R) $prevClean 'yellow' 'older than 5 years' "YELLOW: older than 5 years" -Year 2020
    Check-W (New-R) $prevClean 'ok' '' "exactly 5 years is not older" -Year 2021
    Check-W (New-R @{ TempC = 51 }) $prevClean 'yellow' 'Temperature' "YELLOW: temperature above 50 C"
    Check-W (New-R @{ TempC = 50 }) $prevClean 'ok' '' "exactly 50 C is not above"
    Check-W (New-R @{ Passed = $false; TempC = 60 }) $prevClean 'red' '' "a red and a yellow together are red"

    Assert-Equal 'red' (Get-OverallHealth @('ok', 'red', 'yellow')) "overall: the worst disk"
    Assert-Equal 'yellow' (Get-OverallHealth @('ok', 'yellow')) "overall: yellow"
    Assert-Equal 'ok' (Get-OverallHealth @('ok', 'not checked')) "overall: a disk read beats one that couldn't be"
    Assert-Equal 'not checked' (Get-OverallHealth @('not checked', 'not checked')) "overall: nothing read"

    # ------------------------------------------------------------------
    Write-Section "End to end (i): disk health"

    # The helper is started through Start-Process with the same quoting as the
    # real elevated run. These tests only prove that quoting when the repo's
    # own path has spaces (the helper's -File argument).
    function Get-LastRun { param([string]$LocalDir) return @(Read-RunRecords $LocalDir)[-1] }
    function Get-HealthLines { param([string]$Dir) $f = Join-Path $Dir 'disk_health.txt'; if (Test-Path -LiteralPath $f) { return @([System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8) | Where-Object { $_ -match '^\d{4}-' }) } return @() }
    function Get-HelperTempFiles { return @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'robobak_health_*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }

    $fx = New-Fixture 'i_health'
    $hDir = Join-Path $fx.Root 'fake'
    $iLocal = Join-Path $fx.Root 'local'
    New-Item -ItemType Directory -Path $hDir -Force | Out-Null
    Set-FakeDisk $hDir 'pd0.json' (New-SmartJson 'SRC111' 'SOURCE DISK')
    Set-FakeDisk $hDir 'pd1.json' (New-SmartJson 'DST222' 'BACKUP DISK' -AC7 1)
    $iEnv = "S=$($fx.Src)|DATA_T;D=$($fx.Dst)|BACKUP_T;local=$iLocal;health=$hDir"
    $srcHealth = Join-Path $fx.Src 'backup_logs'
    $dstHealth = Join-Path $fx.Dst 'robobak_health'
    $thisYear = (Get-Date).Year
    $tempBefore = Get-HelperTempFiles

    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--verify') @('Y', 'Y', '1', "$thisYear", '2', '')
    Assert-Contains $out "Log disk health? This needs admin rights." "the question is asked"
    Assert-Contains $out "First health check of" "the first time, it asks which disk holds each volume"
    Assert-Contains $out "1. SOURCE DISK, serial SRC111" "the disks are listed as the tool reports them"
    Assert-Contains $out "VERIFICATION PASSED" "verification still passes with the health folder present"
    Assert-Equal 1 @(Get-HealthLines $srcHealth).Count "1st run: one line on the data drive"
    Assert-Equal 1 @(Get-HealthLines $dstHealth).Count "1st run: one line on the backup drive"
    Assert-Contains (@(Get-HealthLines $srcHealth)[0]) "level=ok" "1st run: the data drive reads ok"
    Assert-Contains (@(Get-HealthLines $srcHealth)[0]) "serial=SRC111" "1st run: the data drive's line is its own disk"
    Assert-Contains (@(Get-HealthLines $dstHealth)[0]) "serial=DST222" "1st run: the backup drive's line is its own disk"
    Assert-Contains (@(Get-HealthLines $dstHealth)[0]) "copyErrors=0 | verification=passed" "the line has the run's result"
    $lnk = Read-DiskLink $srcHealth
    Assert-Equal "SRC111|$thisYear" "$($lnk.serial)|$($lnk.year)" "the disk and the year are saved on the data drive"
    $lnk = Read-DiskLink $dstHealth
    Assert-Equal 'DST222|' "$($lnk.serial)|$($lnk.year)" "the year is optional, and the disk is saved on the backup drive"
    Assert-Equal 'ok' (Get-LastRun $iLocal).health "1st run: runs.csv has health ok"
    Assert-Equal ($tempBefore -join '|') ((Get-HelperTempFiles) -join '|') "the helper's temporary result is removed"

    Set-FakeDisk $hDir 'pd1.json' (New-SmartJson 'DST222' 'BACKUP DISK' -AC5 2 -AC7 1)
    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--verify') @('Y', 'Y')
    Assert-NotContains $out "First health check of" "2nd run: the saved disk is used, without asking"
    Assert-Contains $out "Will delete 0 files" "2nd run: the health history isn't counted as something to delete"
    Assert-Contains $out "VERIFICATION PASSED" "2nd run: the health folder isn't a difference"
    Assert-Equal 2 @(Get-HealthLines $dstHealth).Count "2nd run: the mirror kept the history, and one line was added"
    Assert-Contains (@(Get-HealthLines $dstHealth)[1]) "level=red" "2nd run: C5 above zero for the first time is red"
    Assert-Contains $out "RED: C5" "2nd run: the warning is on screen"
    Assert-Equal 'red' (Get-LastRun $iLocal).health "2nd run: runs.csv has the worst disk's level"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Src 'robobak_health'))) "the health folder never reaches the source"

    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--no-verify', '--no-health') @('Y')
    Assert-NotContains $out "Log disk health?" "--no-health doesn't ask"
    Assert-Contains (@(Get-HealthLines $srcHealth)[-1]) "level=not approved" "--no-health logs 'not approved' on the data drive"
    Assert-Contains (@(Get-HealthLines $dstHealth)[-1]) "level=not approved" "--no-health logs 'not approved' on the backup drive"
    Assert-Equal 'not approved' (Get-LastRun $iLocal).health "--no-health: runs.csv has 'not approved'"

    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--no-verify') @('Y', 'N')
    Assert-Contains $out "Disk health not logged (not approved)." "answering N logs nothing but 'not approved'"
    Assert-Equal 'not approved' (Get-LastRun $iLocal).health "answering N: runs.csv has 'not approved'"

    Set-FakeDisk $hDir 'cancel_elevation.txt' 'x'
    $before = @(Get-HealthLines $dstHealth).Count
    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--no-verify', '--health') @('Y')
    Assert-NotContains $out "Log disk health?" "--health doesn't ask"
    Assert-Contains $out "the admin prompt was cancelled" "a cancelled admin prompt is said on screen"
    Assert-Equal ($before + 1) @(Get-HealthLines $dstHealth).Count "a cancelled admin prompt still adds a line"
    Assert-Contains (@(Get-HealthLines $dstHealth)[-1]) "level=not approved" "a cancelled admin prompt is logged as 'not approved'"
    Assert-Equal 'not approved' (Get-LastRun $iLocal).health "a cancelled admin prompt: runs.csv has 'not approved'"
    Remove-Item -LiteralPath (Join-Path $hDir 'cancel_elevation.txt') -Force

    $saved = Get-Content -LiteralPath (Join-Path $dstHealth 'disk_link.json') -Raw -Encoding UTF8
    Write-DiskLink $dstHealth 'GONE999' 'OLD DISK' $null
    $out = Invoke-RoboBakTest $iEnv @('S', 'D', '--no-verify', '--health') @('Y')
    Assert-Contains $out "wasn't found among the disks read" "a saved disk that isn't connected is said on screen"
    Assert-Contains (@(Get-HealthLines $dstHealth)[-1]) "level=not checked" "a saved disk that isn't connected is logged as 'not checked'"
    Assert-Equal 'ok' (Get-LastRun $iLocal).health "the disk that could be read decides runs.csv"
    [System.IO.File]::WriteAllText((Join-Path $dstHealth 'disk_link.json'), $saved)

    $fx2 = New-Fixture 'i_health_skip'
    $i2Local = Join-Path $fx2.Root 'local'
    $out = Invoke-RoboBakTest "S=$($fx2.Src)|DATA_T;D=$($fx2.Dst)|BACKUP_T;local=$i2Local;health=$hDir" @('S', 'D', '--no-verify', '--health') @('Y', 'x', 'x')
    Assert-Contains (@(Get-HealthLines (Join-Path $fx2.Dst 'robobak_health'))[0]) "level=not checked" "skipping the disk choice logs 'not checked'"
    Assert-True ($null -eq (Read-DiskLink (Join-Path $fx2.Dst 'robobak_health'))) "skipping the disk choice saves nothing, so it asks again next time"
    Assert-Equal 'not checked' (Get-LastRun $i2Local).health "skipping every disk: runs.csv has 'not checked'"

    $fx3 = New-Fixture 'i_health_notool'
    $i3Local = Join-Path $fx3.Root 'local'
    $emptyHealth = Join-Path $fx3.Root 'fake_empty'
    New-Item -ItemType Directory -Path $emptyHealth -Force | Out-Null
    $out = Invoke-RoboBakTest "S=$($fx3.Src)|DATA_T;D=$($fx3.Dst)|BACKUP_T;local=$i3Local;health=$emptyHealth" @('S', 'D', '--no-verify', '--health') @('Y')
    Assert-Contains $out "neither smartmontools nor CrystalDiskInfo is installed" "no tool: it's said on screen"
    Assert-NotContains $out "Log disk health?" "no tool: it doesn't ask"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx3.Dst 'robobak_health'))) "no tool: nothing is written on the drive"
    Assert-Equal 'not checked' (Get-LastRun $i3Local).health "no tool: runs.csv has 'not checked'"

    $fx4 = New-Fixture 'i_health_system'
    $i4Local = Join-Path $fx4.Root 'local'
    $sysHealth = Join-Path $fx4.Root 'fake_sys'
    New-Item -ItemType Directory -Path $sysHealth -Force | Out-Null
    Set-FakeDisk $sysHealth 'pd1.json' (New-SmartJson 'IMG333' 'IMAGE DISK' -A05 2)
    Set-FakeDisk $sysHealth 'disk_of_P.txt' '1'
    $pEnv = "P=$($fx4.Dst)|SYSIMG_T;local=$i4Local;health=$sysHealth"
    $out = Invoke-RoboBakTest $pEnv @('--system-done', 'P', '--health') @('Y')
    Assert-NotContains $out "First health check of" "--system-done: a plain partition is matched without asking"
    Assert-Contains (@(Get-HealthLines (Join-Path $fx4.Dst 'robobak_health'))[0]) "serial=IMG333" "--system-done: the line is on the partition, for its disk"
    Assert-Contains (@(Get-HealthLines (Join-Path $fx4.Dst 'robobak_health'))[0]) "| system | " "--system-done: the line says it's a system backup"
    Assert-Equal 'red' (Get-LastRun $i4Local).health "--system-done: runs.csv gets the health"
    $out = Invoke-RoboBakTest $pEnv @('--system-done', 'P', '--no-health') @('Y')
    Assert-Equal 'not approved' (Get-LastRun $i4Local).health "--system-done --no-health: runs.csv has 'not approved'"

    $fx5 = New-Fixture 'i_health_cdi'
    $i5Local = Join-Path $fx5.Root 'local'
    $cdiHealth = Join-Path $fx5.Root 'fake_cdi'
    New-Item -ItemType Directory -Path $cdiHealth -Force | Out-Null
    Set-FakeDisk $cdiHealth 'DiskInfo.txt' $cdi
    Set-FakeDisk $cdiHealth 'disk_of_P.txt' '1'
    $out = Invoke-RoboBakTest "P=$($fx5.Dst)|SYSIMG_T;local=$i5Local;health=$cdiHealth" @('--system-done', 'P', '--health') @('Y')
    Assert-Contains (@(Get-HealthLines (Join-Path $fx5.Dst 'robobak_health'))[0]) "tool=crystaldiskinfo" "CrystalDiskInfo fallback: the line says which tool read it"
    Assert-Contains (@(Get-HealthLines (Join-Path $fx5.Dst 'robobak_health'))[0]) "serial=CDI111" "CrystalDiskInfo fallback: found by the partition's letter"

    $fx6 = New-Fixture 'i_health_off'
    $i6Local = Join-Path $fx6.Root 'local'
    $out = Invoke-RoboBakTest "S=$($fx6.Src)|DATA_T;D=$($fx6.Dst)|BACKUP_T;local=$i6Local" @('S', 'D', '--no-verify') @('Y')
    Assert-NotContains $out "isk health" "test mode without health= says nothing about disk health"
    Assert-Equal 'not checked' (Get-LastRun $i6Local).health "test mode without health=: runs.csv has 'not checked'"

    # ------------------------------------------------------------------
    Write-Section "Reminders: the scripts and the interop code"

    # install-reminders.ps1 is only parsed: running it creates a shortcut and a
    # task, so it's for the user to run.
    foreach ($name in @('robobak-reminders.ps1', 'install-reminders.ps1')) {
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $name), [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count "$name has no syntax errors"
        Assert-True ((Get-Content -LiteralPath (Join-Path $RepoRoot $name) -Raw) -cnotmatch '[^\x00-\x7F]') "$name is ASCII-only"
    }
    Add-Type -TypeDefinition $script:ShortcutAppIdSource
    Assert-True ([bool]('RoboBakInterop.ShortcutAppId' -as [type])) "the shortcut's application ID code compiles"

    # ------------------------------------------------------------------
    Write-Section "Reminders: settings and state"

    function Write-RemFile {
        param([string]$Dir, [string]$Name, [string]$Text)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Dir $Name), $Text, (New-Object System.Text.UTF8Encoding($false)))
    }

    $remDir = Join-Path $TestRoot 'rem_settings'
    $def = Read-ReminderSettings $remDir
    Assert-Equal 'True|14|14|24|True|True|True|12:00' "$($def.Enabled)|$($def.SystemDays)|$($def.MirrorDays)|$($def.GapHours)|$($def.TriggerLogon)|$($def.TriggerUnlock)|$($def.TriggerDaily)|$($def.DailyTime)" "no settings file: the defaults"
    Assert-True ($null -eq $def.Warning) "no settings file: no warning"
    Assert-Equal 14 (Read-ReminderSettings '').SystemDays "no local folder: the defaults"

    Write-RemFile $remDir 'settings.json' '{"reminders":{"enabled":false,"systemDays":7,"mirrorDays":21,"gapHours":0,"triggerLogon":false,"triggerUnlock":false,"triggerDaily":false,"dailyTime":"08:30"}}'
    $set = Read-ReminderSettings $remDir
    Assert-Equal 'False|7|21|0|False|False|False|08:30' "$($set.Enabled)|$($set.SystemDays)|$($set.MirrorDays)|$($set.GapHours)|$($set.TriggerLogon)|$($set.TriggerUnlock)|$($set.TriggerDaily)|$($set.DailyTime)" "every setting is read, and a gap of 0 is valid"
    Assert-True ($null -eq $set.Warning) "valid settings: no warning"

    Write-RemFile $remDir 'settings.json' '{"robobak":{"deleteWarnFiles":9}}'
    $set = Read-ReminderSettings $remDir
    Assert-True ($set.SystemDays -eq 14 -and $null -eq $set.Warning) "no reminders section: the defaults, no warning"

    Write-RemFile $remDir 'settings.json' '{"reminders":{"enabled":"yes","systemDays":0,"mirrorDays":"x","gapHours":-1,"triggerDaily":1,"dailyTime":"25:00"}}'
    $set = Read-ReminderSettings $remDir
    Assert-Equal 'True|14|14|24|True|12:00' "$($set.Enabled)|$($set.SystemDays)|$($set.MirrorDays)|$($set.GapHours)|$($set.TriggerDaily)|$($set.DailyTime)" "invalid values fall back to their defaults"
    foreach ($key in @('enabled', 'systemDays', 'mirrorDays', 'gapHours', 'triggerDaily', 'dailyTime')) { Assert-Contains $set.Warning $key "the warning names $key" }

    Write-RemFile $remDir 'settings.json' '{ not json'
    $set = Read-ReminderSettings $remDir
    Assert-True ($set.SystemDays -eq 14 -and $set.Warning -match 'invalid JSON') "broken JSON: the defaults and a warning"

    $saveDir = Join-Path $TestRoot 'rem_save'
    $toSave = [pscustomobject]@{ Enabled = $false; SystemDays = 10; MirrorDays = 20; GapHours = 12; TriggerLogon = $false; TriggerUnlock = $true; TriggerDaily = $false; DailyTime = '09:15' }
    Save-ReminderSettings $saveDir $toSave
    $back = Read-ReminderSettings $saveDir
    Assert-Equal 'False|10|20|12|False|True|False|09:15' "$($back.Enabled)|$($back.SystemDays)|$($back.MirrorDays)|$($back.GapHours)|$($back.TriggerLogon)|$($back.TriggerUnlock)|$($back.TriggerDaily)|$($back.DailyTime)" "saving creates the folder and the file, and reads back"

    Write-RemFile $saveDir 'settings.json' '{"robobak":{"deleteWarnFiles":7,"healthWarnHours":123},"other":{"x":1},"reminders":{"systemDays":99}}'
    Save-ReminderSettings $saveDir $toSave
    $json = Get-Content -LiteralPath (Join-Path $saveDir 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal '7|123|1|10' "$($json.robobak.deleteWarnFiles)|$($json.robobak.healthWarnHours)|$($json.other.x)|$($json.reminders.systemDays)" "saving keeps the other sections and replaces only its own"
    Assert-Equal 7 (Read-RoboBakSettings $saveDir).DeleteWarnFiles "robobak.ps1 still reads its own section after a save"

    Write-RemFile $saveDir 'settings.json' '{ not json'
    $threw = $false
    try { Save-ReminderSettings $saveDir $toSave } catch { $threw = $true }
    Assert-True $threw "saving over broken JSON is refused"
    Assert-Equal '{ not json' (Get-Content -LiteralPath (Join-Path $saveDir 'settings.json') -Raw -Encoding UTF8) "and the broken file is left as it was"
    $threw = $false
    try { Save-ReminderSettings '' $toSave } catch { $threw = $true }
    Assert-True $threw "saving without a local folder is refused"

    $stateDir = Join-Path $TestRoot 'rem_state'
    Assert-True ($null -eq (Read-ReminderState $stateDir)) "no state file: no last notification"
    $when = [datetime]'2026-06-15 09:30:05'
    Save-ReminderState $stateDir $when
    Assert-Equal $when (Read-ReminderState $stateDir) "the last notification's time reads back"
    Write-RemFile $stateDir 'state.json' 'garbage'
    Assert-True ($null -eq (Read-ReminderState $stateDir)) "a broken state file counts as no last notification"
    Save-ReminderState '' $when
    Assert-True ($null -eq (Read-ReminderState '')) "no local folder: the state is neither saved nor read"

    # ------------------------------------------------------------------
    Write-Section "Reminders: what's due"

    function New-Rec {
        param([string]$Date, [string]$Kind, [string]$Dest = 'BACKUP_1', [string]$Result = 'ok', [string]$Source = 'DATA')
        return [pscustomobject]@{ date = $Date; kind = $Kind; source = $Source; destination = $Dest; result = $Result; verification = 'passed'; health = 'ok' }
    }
    $now = [datetime]'2026-06-15 12:00:00'
    $rs = Read-ReminderSettings ''

    $st = Get-ReminderStatus -Records @() -Settings $rs -Now $now
    Assert-True ($st.System.Due -and $st.Mirror.Due) "no records: both are due"
    Assert-True ($null -eq $st.System.LastDone -and $null -eq $st.System.NextDue -and $null -eq $st.System.AgeDays) "no records: no dates and no age"

    $st = Get-ReminderStatus -Records @(New-Rec '2026-06-10 12:00:00' 'system') -Settings $rs -Now $now
    Assert-True (-not $st.System.Due) "done 5 days ago: not due"
    Assert-Equal 5 $st.System.AgeDays "the age of the last backup done"
    Assert-Equal ([datetime]'2026-06-24 12:00:00') $st.System.NextDue "next due is the interval after it"
    Assert-True ($st.Mirror.Due) "the two kinds are independent"

    $st = Get-ReminderStatus -Records @(New-Rec '2026-06-14 21:39:39' 'system') -Settings $rs -Now ([datetime]'2026-06-15 20:42:00')
    Assert-Equal 1 $st.System.AgeDays "the age counts calendar days: yesterday evening is 1 day ago, even less than 24 hours later"
    $st = Get-ReminderStatus -Records @(New-Rec '2026-06-15 01:00:00' 'system') -Settings $rs -Now ([datetime]'2026-06-15 23:00:00')
    Assert-Equal 0 $st.System.AgeDays "earlier the same day has age 0"

    $st = Get-ReminderStatus -Records @(New-Rec '2026-06-01 12:00:00' 'system') -Settings $rs -Now $now
    Assert-True ($st.System.Due) "exactly the interval: due"
    $st = Get-ReminderStatus -Records @(New-Rec '2026-06-01 12:00:01' 'system') -Settings $rs -Now $now
    Assert-True (-not $st.System.Due) "one second short of the interval: not due"

    $custom = [pscustomobject]@{ SystemDays = 3; MirrorDays = 30 }
    $st = Get-ReminderStatus -Records @((New-Rec '2026-06-10 12:00:00' 'system'), (New-Rec '2026-06-01 12:00:00' 'mirror')) -Settings $custom -Now $now
    Assert-True ($st.System.Due -and -not $st.Mirror.Due) "each kind uses its own interval"

    $st = Get-ReminderStatus -Records @((New-Rec '2026-05-01 12:00:00' 'system'), (New-Rec '2026-06-10 12:00:00' 'system' 'SYSIMG_1' 'skipped')) -Settings $rs -Now $now
    Assert-True (-not $st.System.Due) "a skip postpones the next reminder by one interval"
    Assert-Equal 45 $st.System.AgeDays "the age is still that of the last backup actually done"
    Assert-Equal ([datetime]'2026-06-10 12:00:00') $st.System.LastSkipped "the last skip is reported"

    $st = Get-ReminderStatus -Records @((New-Rec '2026-06-10 12:00:00' 'system'), (New-Rec '2026-05-01 12:00:00' 'system' 'SYSIMG_1' 'skipped')) -Settings $rs -Now $now
    Assert-Equal ([datetime]'2026-06-24 12:00:00') $st.System.NextDue "an older skip doesn't move the date back"

    $st = Get-ReminderStatus -Records @((New-Rec '2026-05-01 12:00:00' 'mirror'), (New-Rec '2026-06-14 12:00:00' 'mirror' 'BACKUP_1' 'failed')) -Settings $rs -Now $now
    Assert-True ($st.Mirror.Due) "a failed mirror isn't a done one: still due"
    Assert-Equal ([datetime]'2026-05-01 12:00:00') $st.Mirror.LastDone "a failed mirror doesn't count as the last done"

    $st = Get-ReminderStatus -Records @((New-Rec 'not a date' 'system'), (New-Rec '2026-06-10 12:00:00' 'system')) -Settings $rs -Now $now
    Assert-Equal ([datetime]'2026-06-10 12:00:00') $st.System.LastDone "a line with a bad date is ignored"

    Assert-True ($null -eq (Get-SuggestedDrive @())) "no records: no suggested drive"
    Assert-True ($null -eq (Get-SuggestedDrive @(New-Rec '2026-06-10 12:00:00' 'system' 'SYSIMG_1'))) "system lines don't suggest a drive"
    $recs = @((New-Rec '2026-06-01 12:00:00' 'mirror' 'BACKUP_1'), (New-Rec '2026-06-10 12:00:00' 'mirror' 'BACKUP_2'))
    Assert-Equal 'BACKUP_1' (Get-SuggestedDrive $recs) "the drive whose last copy is oldest"
    Assert-Equal 'BACKUP_2' (Get-SuggestedDrive ($recs + @(New-Rec '2026-06-12 12:00:00' 'mirror' 'BACKUP_1'))) "a new copy to it moves the suggestion to the other drive"
    Assert-Equal 'BACKUP_1' (Get-SuggestedDrive ($recs + @(New-Rec '2026-06-12 12:00:00' 'mirror' 'BACKUP_1' 'failed'))) "a failed copy doesn't count: the drive stays the oldest"
    Assert-Equal 'BACKUP_1' (Get-SuggestedDrive ($recs + @(New-Rec '2026-06-12 12:00:00' 'mirror' 'BACKUP_1' 'skipped'))) "a skipped copy doesn't count either"
    Assert-True ($null -eq (Get-SuggestedDrive @(New-Rec '2026-06-12 12:00:00' 'mirror' 'BACKUP_9' 'failed'))) "a drive with no successful copy isn't suggested"
    Assert-Equal 'BACKUP_A' (Get-SuggestedDrive @((New-Rec '2026-06-01 12:00:00' 'mirror' 'BACKUP_B'), (New-Rec '2026-06-01 12:00:00' 'mirror' 'BACKUP_A'))) "a tie goes to the first name, every time"
    $st = Get-ReminderStatus -Records $recs -Settings $rs -Now $now
    Assert-Equal 'BACKUP_1' $st.Mirror.SuggestedDrive "the mirror's status names the suggested drive"
    Assert-True ($null -eq $st.System.SuggestedDrive) "the system backup's status names none"

    # ------------------------------------------------------------------
    Write-Section "Reminders: the decision and the notification"

    Assert-True (Test-ReminderGapPassed $null 24 $now) "no previous notification: the gap has passed"
    Assert-True (Test-ReminderGapPassed $now.AddHours(-24) 24 $now) "exactly the gap: passed"
    Assert-True (-not (Test-ReminderGapPassed $now.AddHours(-23) 24 $now)) "less than the gap: not passed"
    Assert-True (Test-ReminderGapPassed $now 0 $now) "a gap of 0 never blocks"

    Assert-Equal 'today' (Format-ReminderAge 0) "age 0 reads 'today'"
    Assert-Equal '1 day ago' (Format-ReminderAge 1) "age 1 is singular"
    Assert-Equal '20 days ago' (Format-ReminderAge 20) "age 20 is plural"

    $both = Get-ReminderStatus -Records @((New-Rec '2026-05-26 12:00:00' 'system' 'SYSIMG_1'), (New-Rec '2026-05-20 12:00:00' 'mirror' 'BACKUP_2')) -Settings $rs -Now $now
    $d = Get-ReminderDecision -Settings $rs -Status $both -Locked $false -LastNotification $null -Now $now
    Assert-Equal 'notify' $d.Action "both due: notify"
    Assert-Equal 'System backup: last done 20 days ago.' $d.Lines[0] "the system line has the real age"
    Assert-Equal 'Mirror: last done 26 days ago. Next drive: BACKUP_2.' $d.Lines[1] "the mirror line also names the drive"
    Assert-Equal 2 @($d.Lines).Count "one line per backup due"

    $onlySystem = Get-ReminderStatus -Records @((New-Rec '2026-05-26 12:00:00' 'system'), (New-Rec '2026-06-14 12:00:00' 'mirror')) -Settings $rs -Now $now
    $d = Get-ReminderDecision -Settings $rs -Status $onlySystem -Locked $false -LastNotification $null -Now $now
    Assert-True (@($d.Lines).Count -eq 1 -and $d.Lines[0] -like 'System backup:*') "only what's due is listed"

    $none = Get-ReminderStatus -Records @((New-Rec '2026-06-14 12:00:00' 'system'), (New-Rec '2026-06-14 12:00:00' 'mirror')) -Settings $rs -Now $now
    Assert-Equal 'nothing' (Get-ReminderDecision -Settings $rs -Status $none -Locked $false -LastNotification $null -Now $now).Action "nothing due: no notification"

    Assert-Equal 'locked' (Get-ReminderDecision -Settings $rs -Status $both -Locked $true -LastNotification $null -Now $now).Action "the screen is locked: no notification"
    Assert-Equal 'gap' (Get-ReminderDecision -Settings $rs -Status $both -Locked $false -LastNotification $now.AddHours(-1) -Now $now).Action "too soon after the last one: no notification"
    Assert-Equal 'notify' (Get-ReminderDecision -Settings $rs -Status $both -Locked $false -LastNotification $now.AddHours(-25) -Now $now).Action "the gap has passed: notify"
    $off = [pscustomobject]@{ Enabled = $false; GapHours = 24 }
    Assert-Equal 'disabled' (Get-ReminderDecision -Settings $off -Status $both -Locked $false -LastNotification $null -Now $now).Action "reminders off: no notification"
    Assert-Equal 'locked' (Get-ReminderDecision -Settings $rs -Status $both -Locked $true -LastNotification $now.AddHours(-1) -Now $now).Action "the lock is checked before the gap"

    $never = Get-ReminderStatus -Records @() -Settings $rs -Now $now
    $d = Get-ReminderDecision -Settings $rs -Status $never -Locked $false -LastNotification $null -Now $now
    Assert-Equal 'System backup: never recorded.|Mirror: never recorded.' ($d.Lines -join '|') "no records: 'never recorded', and no drive"
    $skipOnly = Get-ReminderStatus -Records @(New-Rec '2026-05-20 12:00:00' 'system' 'SYSIMG_1' 'skipped') -Settings $rs -Now $now
    Assert-Equal 'System backup: never done.' (Format-ReminderLine $skipOnly.System) "only skips: 'never done'"

    $xmlText = Get-ReminderToastXml -Title 'Backups & more' -Lines @('Mirror: <x>', 'System')
    $parsed = [xml]$xmlText
    $texts = @($parsed.toast.visual.binding.text)
    Assert-Equal 'Backups & more|Mirror: <x>|System' ($texts -join '|') "the notification's XML is well-formed and its text is escaped"

    # ------------------------------------------------------------------
    Write-Section "Reminders: skip lines"

    $skipDir = Join-Path $TestRoot 'rem_skip'
    $skipRecs = @((New-Rec '2026-06-01 12:00:00' 'system' 'SYSIMG_1' 'ok' 'LAPTOP'), (New-Rec '2026-06-01 12:00:00' 'mirror' 'BACKUP_1' 'ok' 'MY_DATA'), (New-Rec '2026-06-10 12:00:00' 'mirror' 'BACKUP_2' 'ok' 'MY_DATA'))
    $null = Add-SkipRecord -LocalDir $skipDir -Kind 'system' -Records $skipRecs -ComputerName 'THEPC' -Date $now
    $null = Add-SkipRecord -LocalDir $skipDir -Kind 'mirror' -Records $skipRecs -ComputerName 'THEPC' -Date $now
    $written = @(Read-RunRecords $skipDir)
    Assert-Equal 2 $written.Count "one line per skip"
    Assert-Equal '2026-06-15 12:00:00|system|THEPC|SYSIMG_1|skipped|not performed|not checked' (@($written[0].date, $written[0].kind, $written[0].source, $written[0].destination, $written[0].result, $written[0].verification, $written[0].health) -join '|') "a system skip: the computer and the last partition"
    Assert-Equal 'mirror|MY_DATA|BACKUP_1|skipped|not checked' (@($written[1].kind, $written[1].source, $written[1].destination, $written[1].result, $written[1].health) -join '|') "a mirror skip: the last source and the suggested drive"
    $emptyDir = Join-Path $TestRoot 'rem_skip_empty'
    $null = Add-SkipRecord -LocalDir $emptyDir -Kind 'mirror' -Records @() -ComputerName 'THEPC' -Date $now
    $written = @(Read-RunRecords $emptyDir)
    Assert-True ($written.Count -eq 1 -and $written[0].source -eq '' -and $written[0].destination -eq '') "a mirror skip with no records has no labels"
    $st = Get-ReminderStatus -Records $written -Settings $rs -Now $now
    Assert-True (-not $st.Mirror.Due -and $null -eq $st.Mirror.SuggestedDrive) "that skip postpones it and suggests no drive"

    # ------------------------------------------------------------------
    Write-Section "Reminders: the scheduled task, in memory only"

    $taskUser = "$env:USERDOMAIN\$env:USERNAME"
    $cmd = Get-ReminderCommand -ScriptPath 'C:\a b\robobak-reminders.ps1'
    Assert-True ($cmd.Execute -like '*\conhost.exe') "it starts through conhost.exe"
    Assert-True ($cmd.Argument.StartsWith('--headless ')) "with --headless"
    Assert-Contains $cmd.Argument '-File "C:\a b\robobak-reminders.ps1"' "a path with spaces is quoted"
    Assert-True (-not $cmd.Argument.EndsWith('-Check')) "the shortcut opens the window"
    Assert-True ((Get-ReminderCommand -ScriptPath 'C:\x.ps1' -Check).Argument.EndsWith(' -Check')) "the task runs -Check"

    $triggers = @(New-ReminderTriggers (Read-ReminderSettings '') $taskUser)
    Assert-Equal 3 $triggers.Count "the three triggers by default"
    Assert-Equal 'MSFT_TaskLogonTrigger|MSFT_TaskSessionStateChangeTrigger|MSFT_TaskDailyTrigger' (($triggers | ForEach-Object { $_.CimClass.CimClassName }) -join '|') "sign-in, unlock and daily"
    Assert-Equal 'PT1M|PT1M' "$($triggers[0].Delay)|$($triggers[1].Delay)" "sign-in and unlock wait a minute"
    Assert-Equal 8 ([int]$triggers[1].StateChange) "the session trigger is the unlock"
    Assert-Equal "$taskUser|$taskUser" "$($triggers[0].UserId)|$($triggers[1].UserId)" "sign-in and unlock are for this user only"
    Assert-Equal '12:00' (([datetime]$triggers[2].StartBoundary).ToString('HH:mm')) "the daily time is used"
    $some = [pscustomobject]@{ TriggerLogon = $false; TriggerUnlock = $true; TriggerDaily = $false; DailyTime = '12:00' }
    $t = @(New-ReminderTriggers $some $taskUser)
    Assert-True ($t.Count -eq 1 -and $t[0].CimClass.CimClassName -eq 'MSFT_TaskSessionStateChangeTrigger') "only the triggers switched on"
    $allOff = [pscustomobject]@{ TriggerLogon = $false; TriggerUnlock = $false; TriggerDaily = $false; DailyTime = '12:00' }
    Assert-Equal 0 @(New-ReminderTriggers $allOff $taskUser).Count "no triggers if all are off"

    $def = New-ReminderTaskDefinition -Settings (Read-ReminderSettings '') -ScriptPath 'C:\a b\robobak-reminders.ps1' -User $taskUser
    Assert-Contains $def.Action.Arguments '-Check' "the task's action runs -Check"
    Assert-Equal 'IgnoreNew' ([string]$def.Settings.MultipleInstances) "one at a time"
    Assert-True ($def.Settings.Enabled) "enabled when the reminders are on"
    Assert-Equal 'Interactive|Limited' "$($def.Principal.LogonType)|$($def.Principal.RunLevel)" "runs as the user, without admin rights"
    Assert-Equal $taskUser $def.Principal.UserId "for this user"
    $offSettings = Read-ReminderSettings ''
    $offSettings.Enabled = $false
    Assert-True (-not (New-ReminderTaskDefinition -Settings $offSettings -ScriptPath 'C:\x.ps1' -User $taskUser).Settings.Enabled) "disabled when the reminders are off"

    $denied = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception 'x'), 'HRESULT 0x80070005,Register-ScheduledTask', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    $byCategory = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception 'x'), 'y', [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
    $other = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception 'x'), 'HRESULT 0x80070002,Register-ScheduledTask', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
    Assert-True (Test-AccessDeniedError $denied) "access denied is recognized by its code"
    Assert-True (Test-AccessDeniedError $byCategory) "and by its category"
    Assert-True (-not (Test-AccessDeniedError $other)) "other errors aren't taken for it"

    $env:ROBOBAK_TEST = "local=$saveDir"
    $res = Register-ReminderTask -Settings (Read-ReminderSettings '') -ScriptPath 'C:\x.ps1'
    $threw = $false
    try { New-ReminderShortcut -ShortcutPath (Join-Path $TestRoot 'x.lnk') -ScriptPath 'C:\x.ps1' } catch { $threw = $true }
    $env:ROBOBAK_TEST = $null
    Assert-True ((-not $res.Ok) -and $res.Message -like 'TEST MODE*') "test mode never registers the task"
    Assert-True ($threw -and -not (Test-Path -LiteralPath (Join-Path $TestRoot 'x.lnk'))) "test mode never creates the shortcut"

    # ------------------------------------------------------------------
    Write-Section "End to end (j): -Check and the window"

    $RemindersScript = Join-Path $RepoRoot 'robobak-reminders.ps1'
    function Invoke-ReminderTest {
        param([string]$TestEnv, [string[]]$Arguments)
        $env:ROBOBAK_TEST = $TestEnv
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemindersScript @Arguments 2>&1
            $script:ReminderExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
            $env:ROBOBAK_TEST = $null
        }
        return (($output | ForEach-Object { "$_" }) -join "`n")
    }

    $jDir = Join-Path $TestRoot 'rem_check'
    $jEnv = "local=$jDir"
    $null = Add-RunRecord -LocalDir $jDir -Kind 'system' -Source 'PC' -Destination 'SYSIMG_1' -Result 'ok' -Verification 'not performed' -Date (Get-Date).AddDays(-20)
    $null = Add-RunRecord -LocalDir $jDir -Kind 'mirror' -Source 'DATA' -Destination 'BACKUP_1' -Result 'ok' -Verification 'passed' -Date (Get-Date).AddDays(-1)

    $out = Invoke-ReminderTest $jEnv @('-Check')
    Assert-Contains $out "TEST MODE: would notify: Backups due" "-Check says what it would notify, and shows no notification"
    Assert-Contains $out "System backup: last done 20 days ago." "with the real age"
    Assert-NotContains $out "Mirror:" "and only what's due"
    Assert-Equal 0 $script:ReminderExit "-Check exits with 0"
    Assert-True (Test-Path -LiteralPath (Join-Path $jDir 'state.json')) "the notification's time is saved"

    $out = Invoke-ReminderTest $jEnv @('-Check')
    Assert-Contains $out "RoboBak check: gap." "a second check right after: nothing, because of the gap"
    Assert-NotContains $out "would notify" "and no notification"

    Remove-Item -LiteralPath (Join-Path $jDir 'state.json') -Force
    Write-RemFile $jDir 'locked.txt' 'x'
    $out = Invoke-ReminderTest $jEnv @('-Check')
    Assert-Contains $out "RoboBak check: locked." "the lock state comes from the test folder"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $jDir 'state.json'))) "a locked screen saves no notification time"
    Remove-Item -LiteralPath (Join-Path $jDir 'locked.txt') -Force

    Save-ReminderState $jDir (Get-Date).AddHours(-25)
    $out = Invoke-ReminderTest $jEnv @('-Check')
    Assert-Contains $out "would notify" "after the gap, it notifies again"

    Remove-Item -LiteralPath (Join-Path $jDir 'state.json') -Force
    Save-ReminderSettings $jDir ([pscustomobject]@{ Enabled = $false; SystemDays = 14; MirrorDays = 14; GapHours = 24; TriggerLogon = $true; TriggerUnlock = $true; TriggerDaily = $true; DailyTime = '12:00' })
    $out = Invoke-ReminderTest $jEnv @('-Check')
    Assert-Contains $out "RoboBak check: disabled." "reminders off: nothing"
    Remove-Item -LiteralPath (Join-Path $jDir 'settings.json') -Force

    $j2Dir = Join-Path $TestRoot 'rem_check2'
    $null = Add-RunRecord -LocalDir $j2Dir -Kind 'system' -Source 'PC' -Destination 'SYSIMG_1' -Result 'ok' -Verification 'not performed' -Date (Get-Date).AddDays(-1)
    $null = Add-RunRecord -LocalDir $j2Dir -Kind 'mirror' -Source 'DATA' -Destination 'BACKUP_1' -Result 'ok' -Verification 'passed' -Date (Get-Date).AddDays(-1)
    $out = Invoke-ReminderTest "local=$j2Dir" @('-Check')
    Assert-Contains $out "RoboBak check: nothing." "nothing due: nothing"

    $out = Invoke-ReminderTest "S=$TestRoot|DATA_T" @('-Check')
    Assert-Contains $out "System backup: never recorded." "test mode without local=: no records, so everything is due"
    Assert-Contains $out "Mirror: never recorded." "and the mirror too"

    $j3Dir = Join-Path $TestRoot 'rem_window'
    $null = Add-RunRecord -LocalDir $j3Dir -Kind 'system' -Source 'PC' -Destination 'SYSIMG_1' -Result 'ok' -Verification 'not performed' -Date (Get-Date).AddDays(-20)
    $null = Add-RunRecord -LocalDir $j3Dir -Kind 'mirror' -Source 'DATA' -Destination 'BACKUP_1' -Result 'ok' -Verification 'passed' -Date (Get-Date).AddDays(-10)
    $null = Add-RunRecord -LocalDir $j3Dir -Kind 'mirror' -Source 'DATA' -Destination 'BACKUP_2' -Result 'ok' -Verification 'passed' -Date (Get-Date).AddDays(-3)
    $out = Invoke-ReminderTest "local=$j3Dir" @('-TestBuild')
    Assert-Contains $out "PANEL system: done=" "the window builds without being shown"
    Assert-True ($out -match 'PANEL system: .*\(20 days ago\).*skip=True') "a backup that's due has its Skip button enabled"
    Assert-True ($out -match 'PANEL mirror: .*drive=BACKUP_1 \| skip=False') "the mirror shows the suggested drive, and isn't due"
    Assert-Contains $out "SETTINGS: on=True system=14 mirror=14 gap=24 time=12:00" "the settings show their values"
    Assert-Contains $out "AFTER SKIP: skipped=$((Get-Date).ToString('yyyy-MM-dd'))" "Skip updates the status"
    Assert-Equal 'skipped' (Read-RunRecords $j3Dir | Select-Object -Last 1).result "Skip writes a skipped line"
    Assert-Contains $out "AFTER SAVE: Settings saved, but the task was not updated." "Save writes the settings, and test mode leaves Task Scheduler alone"
    Assert-True (Test-Path -LiteralPath (Join-Path $j3Dir 'settings.json')) "the settings file is written"
    Assert-Equal 0 $script:ReminderExit "the window's test build ends cleanly"

    $out = Invoke-ReminderTest "local=$(Join-Path $TestRoot 'rem_empty')" @('-TestBuild')
    Assert-True ($out -match 'PANEL system: done=never recorded \| skipped=never \| next=now') "with no records, the window says 'never recorded'"
    Assert-True ($out -match 'PANEL mirror: .*drive=none recorded yet') "and no suggested drive"

    # ------------------------------------------------------------------
    Write-Section "The repo's own local\ folder"

    $realAfter = if (Test-Path -LiteralPath $RealRunsCsv) { (Get-FileHash -LiteralPath $RealRunsCsv).Hash } else { 'absent' }
    Assert-Equal $RealRunsBefore $realAfter "the tests never wrote to the repo's own local\runs.csv"
}
catch {
    $script:Failed++
    Write-Host "  FAIL  unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    $env:ROBOBAK_TEST = $SavedTestEnv
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Passed: $($script:Passed)  Failed: $($script:Failed)" -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
exit 0
