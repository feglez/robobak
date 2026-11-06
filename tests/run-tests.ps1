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
