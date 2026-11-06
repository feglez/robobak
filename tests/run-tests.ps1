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
    # unchanged, run directly on a twin fixture to get the reference logs.
    function Invoke-OriginalCommands {
        param($Fx, [string[]]$ModeFlags, [switch]$Verify)
        $Source = $Fx.Src + '\'
        $Dest = $Fx.Dst + '\'
        $DestLogsDir = Join-Path $Dest 'current_backup_logs'
        $SourceLogsDir = Join-Path $Source 'backup_logs'
        $DestBackupLogsDir = Join-Path $Dest 'backup_logs'
        New-Item -ItemType Directory -Path $DestLogsDir, $SourceLogsDir -Force | Out-Null
        $LogRobo = Join-Path $DestLogsDir 'robocopy_log.txt'
        $LogVerify = Join-Path $DestLogsDir 'verify_log.txt'
        $RoboCommon = @(
            "/MIR", "/MT:16", "/DCOPY:DAT", "/R:3", "/W:5", "/V",
            "/LOG+:$LogRobo",
            "/XD", '$RECYCLE.BIN', "System Volume Information", $DestLogsDir
        )
        & robocopy $Source $Dest @RoboCommon @ModeFlags > $null
        if ($Verify) {
            & robocopy $Source $Dest /MIR /L /MT:16 /R:3 /W:5 /LOG+:$LogVerify /XD '$RECYCLE.BIN' "System Volume Information" $DestLogsDir $SourceLogsDir $DestBackupLogsDir > $null
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
        Assert-Contains $out "1 Extra dir is expected" "$($m.Name): the expected-extra-dir note is still shown"
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
