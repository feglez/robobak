# RoboBak - Usage Guide

## Overview

`robobak.ps1` is a PowerShell script that creates an exact mirror copy of one drive onto another using Robocopy. It includes multiple safety checks to prevent accidental data loss and keeps a history of all backups performed.

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later (included with Windows 10/11)
- Both source and destination drives must be connected and accessible
- `robobak.ps1` and `robobak-lib.ps1` must be in the same folder. The library holds functions shared with the tests; if it's missing, the script stops with an error before doing anything

### Execution policy

PowerShell blocks script (`.ps1`) execution by default as a security measure. If you see an error like `"cannot be loaded because running scripts is disabled on this system"`, you need to change the execution policy.

Run this **once** in a PowerShell terminal:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

What this does:
- **`RemoteSigned`** allows scripts created locally on your machine to run freely, but requires scripts downloaded from the internet to have a digital signature. This is the recommended setting for most users.
- **`-Scope CurrentUser`** applies the change only to your Windows user account, not to all users on the machine. No admin privileges are required.
- **This persists permanently** across all future PowerShell sessions. You only need to run it once, and it survives reboots. To undo it later, run `Set-ExecutionPolicy Restricted -Scope CurrentUser`.

## Setup

Before using the script, you must rename your destination (backup) drive so its volume label starts with **`BACKUP_`**. This is a safety requirement to prevent accidentally wiping the wrong drive.

**Examples of valid labels:** `BACKUP_1`, `BACKUP_OFFICE`, `BACKUP_DISK2`

### How to rename a drive

1. Open **File Explorer**
2. Right-click the drive you want to use as backup
3. Select **Properties**
4. Change the name at the top to something like `BACKUP_1`
5. Click **OK**

## Usage

```
.\robobak.ps1 [SourceLetter] [DestLetter] [flags...]
```

| Parameter | Description |
|-----------|-------------|
| `SourceLetter` | Drive letter of the disk you want to back up |
| `DestLetter` | Drive letter of the backup disk (must be labeled `BACKUP_*`) |

### Optional flags

Flags can be combined in any order after the two drive letters.

| Flag | Description |
|------|-------------|
| `--verify` | Automatically verify the backup after completion (no prompt) |
| `--no-verify` | Skip verification without asking |
| `--show-progress` | Show a progress bar during the backup (counts files processed vs total) |
| `--verbose` | Show every file operation on the terminal in real-time (adds `/TEE` to robocopy) |
| *(none)* | Clean terminal during copy; asks whether to verify afterwards |

**Note:** `--show-progress` and `--verbose` cannot be used together. The progress bar requires a clean terminal, which is incompatible with the verbose file-by-file output.

### Examples

```
.\robobak.ps1 F E
```
Backs up `F:\` to `E:\` with a clean terminal. Asks whether to verify afterwards.

```
.\robobak.ps1 F E --verify
```
Backs up `F:\` to `E:\` and automatically verifies the backup.

```
.\robobak.ps1 F E --show-progress
```
Backs up `F:\` to `E:\` showing a progress bar like `[████████░░░░░░] 48% (12,345 / 25,678 files)`.

```
.\robobak.ps1 F E --show-progress --no-verify
```
Backs up with a progress bar and skips verification.

```
.\robobak.ps1 F E --verbose --verify
```
Backs up showing every file operation on the terminal, then automatically verifies.

### Show help

```
.\robobak.ps1 /?
.\robobak.ps1 -h
```

## What the script does (step by step)

1. **Validates parameters** — checks that both drive letters are provided and that they are different
2. **Checks drive availability** — verifies both drives are physically connected
3. **Checks volume labels** — reads both drive labels (tries `Get-Volume` first, falls back to `[System.IO.DriveInfo]` for drives that don't expose their label through CIM, such as VeraCrypt-mounted volumes). If the source label is still blank, warns the user and lets them choose to continue or cancel. Then verifies the destination label starts with `BACKUP_` to prevent accidents
4. **Previews the changes (dry run)** — runs Robocopy in list-only mode (`/L`) with the same `/MIR` and the same exclusions as the real copy, to count the files it would delete and copy. Nothing is modified on either drive: the dry run's log and list are written to `%TEMP%` and only moved to the destination after you confirm (step 7), or deleted if you cancel. It runs without `/MT`, because with several threads Robocopy's lines can get mixed up, which the list can't tolerate. The counts are read **by position** from Robocopy's summary table (its labels are translated into your Windows language, but its layout isn't), and deletions are the lines tagged `EXTRA` (a Robocopy constant, never translated). Files inside a folder that will be deleted are counted and listed one by one. The dry run walks both drives, so it adds roughly the time a verification takes
5. **Asks for confirmation** — displays source and destination drives with their labels, then the dry run's counts, for example `Will delete 1.240 files (3,2 GB) and copy 37 files (412,0 MB).` Type `L` to open the list in Notepad (deletions first, then copies; the screen then asks again), `Y` to proceed, or anything else to cancel. **Above 500 files or 5 GB to delete**, the counts are shown inside a loud red warning: check the list, and if files are missing from the source by mistake, cancel and restore them first. The thresholds can be changed in `local\settings.json` (see [Settings](#settings)). If the dry run itself reported errors (Robocopy exit code 8 or more), the screen says so and the counts may be incomplete. If its summary table can't be read, the screen says the counts are unknown
6. **Checks disk space** — compares the source's used space against the destination's total size. If the source is larger, warns the user that the backup will be incomplete and lets them choose to continue or cancel. The comparison uses total size (not free space) because `/MIR` deletes extras on the destination during the copy, freeing space
7. **Prepares log folders** — ensures the source `backup_logs\` folder exists. Deletes and recreates the destination `current_backup_logs\` folder to clear any stale logs from a previous run (prevents inconsistent state if the backup fails). Then moves the dry run's list and log into it, as `dry_run_list.txt` and `dry_run_log.txt`
8. **Runs Robocopy in mirror mode** — copies all files from source to destination; files on the destination that don't exist on the source are **deleted**. By default the terminal stays clean (individual files are only logged to `robocopy_log.txt`). With `--show-progress`, files are counted first (the counting time is logged separately), then a progress bar is displayed. With `--verbose`, every file operation is printed to the terminal. A summary table and the copy duration are displayed at the end in all modes
9. **Writes a summary** — saves a `backup_summary.txt` on the destination with the status (success or failure), date, source/destination info, Robocopy exit code, the dry run's counts and duration, file count duration, copy duration, flags used, and any errors found in the log. If Robocopy reported critical errors (exit code 8+), the script stops after writing the summary and updating the timing log
10. **Updates the backup history** — maintains a `backup_history.txt` on the source drive tracking all backup disks, marking the `[NEWEST]` and `[OLDEST]` entries
11. **Optional verification** — asks if you want to verify the backup. If accepted, runs robocopy in list-only mode (`/L`) with multithreading (`/MT:16`) and retry limits (`/R:3 /W:5`) to compare source and destination without modifying anything. The `current_backup_logs` folder (destination-only, written after the copy) and `backup_logs` folder (on both source and destination — updated on the source after the copy, and its destination copy must also be excluded since `/XD` matches exact paths) are excluded from the comparison to avoid false differences. Note: `/XD` prevents excluded directories from being logged and compared at the file level, but robocopy still counts them as "EXTRA" in its stats table, which makes the exit code non-zero (2) even when the backup is a perfect match. To work around this, verification is considered successful when either the exit code is 0 or the exit code is 2 with no actual `EXTRA` lines in the log (case-sensitive — `EXTRA` is a robocopy constant, not translated). Reports whether the backup is a perfect match or if differences were found. The result and verification duration are appended to `backup_summary.txt`
12. **Updates timing log** — writes a timing entry to `backup_times.txt` on the source drive with the dry run duration, file count duration (if `--show-progress` was used), copy duration, verification duration, and flags used

## Generated files

All log files are organized into dedicated folders instead of the drive root.

### Source drive (`backup_logs\`)

| File | Description |
|------|-------------|
| `backup_history.txt` | List of all backup drives used, sorted by name, with `[NEWEST]` and `[OLDEST]` tags. Each drive label appears **only once** — if you back up to the same drive twice, its entry is updated with the latest date (not duplicated) |
| `backup_times.txt` | Rolling log of the last 10 backups with timing information (file count duration, copy duration, verification duration, flags used). The **first entry is the oldest** and the **last entry is the newest**. When the 11th backup is added, the oldest entry is removed |

### Destination drive (`current_backup_logs\`)

| File | Description |
|------|-------------|
| `robocopy_log.txt` | Full technical report from Robocopy with details of every file copied, skipped, or failed |
| `backup_summary.txt` | Backup result summary: status (success/failure), date, source, destination, Robocopy exit code, file count duration, copy duration, flags, errors, and verification result |
| `verify_log.txt` | Only created if verification is requested. Logs only the differences found between source and destination (since `/V` is not used during verification, identical files are not listed). If the backup is a perfect match, only the stats table appears |
| `dry_run_list.txt` | The list shown by `L` at the confirmation: the dry run's counts, then every file the mirror would delete (folders deleted with their contents are marked `[folder]`, and their files follow), then every file it would copy (new or changed). UTF-8, so accented names display correctly |
| `dry_run_log.txt` | Full Robocopy report of the dry run (list-only), converted to UTF-8. Robocopy writes it with `/UNILOG` so accented paths survive |

### Temporary files (`%TEMP%`)

While the confirmation screen is open, the dry run's list and log live in `%TEMP%` as `robobak_dry_run_list_<date>.txt` and `robobak_dry_run_log_<date>.txt`, so nothing is written to either drive before you confirm. They are moved to `current_backup_logs\` when the backup starts, or deleted if you cancel. If the script is closed while the confirmation screen is open, they stay in `%TEMP%` and can be deleted.

### Example `backup_history.txt`

```
# Generated by RoboBak. List of all backup drives with dates, sorted by name, tagged NEWEST/OLDEST.

BACKUP_1 | 2026-01-15 10:30:00 [OLDEST]
BACKUP_2 | 2026-02-08 14:22:45 [NEWEST]
```

Note: backing up to `BACKUP_1` again would update its date (e.g., to `2026-02-10 08:00:00`), not add a second line. `BACKUP_1` would then become `[NEWEST]` and `BACKUP_2` would become `[OLDEST]`.

### Example `backup_times.txt`

Entries are ordered chronologically — oldest first, newest last:

```
# Generated by RoboBak. Rolling log of the last 10 backups with timing information.

[2026-02-08 14:22:45] MY_DATA -> BACKUP_2 (OK)
  Dry run duration:      00:01:55
  File count duration:   00:01:30
  Copy duration:         01:23:45
  Verification duration: 00:02:10
  Flags:                 --show-progress

[2026-02-09 09:15:30] MY_DATA -> BACKUP_1 (OK)
  Dry run duration:      00:02:05
  File count duration:   not performed
  Copy duration:         01:45:12
  Verification duration: not performed
  Flags:                 (none)
```

Entries written before the dry run existed have no `Dry run duration` line. Both kinds are read and kept the same way.

### Example `backup_summary.txt`

```
# Generated by RoboBak. Summary of the backup: status, timing, errors, and verification result.

STATUS: BACKUP COMPLETED SUCCESSFULLY
Date: 2026-02-09 09:15:30
Source: F:\ (MY_DATA)
Destination: E:\ (BACKUP_1)
Robocopy exit code: 1
Dry run: would delete 12 files (48,3 MB) and copy 37 files (412,0 MB)
Dry run duration: 00:02:05
File count duration: not performed
Copy duration: 01:45:12
Flags: (none)

Verification: PASSED
Verification duration: 00:02:10
```

## Settings

Settings are optional and live in `local\settings.json`, in the folder that holds the script. The file has one section per program; RoboBak reads only its own, `robobak`:

```json
{
  "robobak": {
    "deleteWarnFiles": 500,
    "deleteWarnGB": 5
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `deleteWarnFiles` | `500` | The confirmation shows the red warning when **more** than this many files would be deleted |
| `deleteWarnGB` | `5` | The same, for size: more than this many GB (1 GB = 1024³ bytes). Decimals are allowed, e.g. `0.5` |

- **RoboBak only reads this file and never creates it.** A missing file, section or key means the default.
- **Invalid values** (negative numbers, text, broken JSON) are reported in yellow before the confirmation screen, and the defaults are used instead.
- **`local\` is ignored by Git** (`.gitignore`), so it's never committed. Beware: `git clean -x` deletes ignored files, including `local\`.

## Robocopy flags used

| Flag | Meaning |
|------|---------|
| `/MIR` | Mirror mode — makes destination an exact copy of source, deleting extra files on destination |
| `/MT:16` | Uses 16 threads for faster copying and verification. Empirically observed side effects: suppresses directory listing in the output, uses full absolute paths for files instead of relative names, and adds per-file progress percentages (suppressed by `/NP` in `--show-progress` mode). Output is also non-thread-safe — multiple threads write simultaneously, which can occasionally interleave or split lines |
| `/DCOPY:DAT` | Copies directory timestamps and attributes |
| `/R:3` | Retries failed copies up to 3 times (also used during verification to prevent hanging on locked files — robocopy's default is 1,000,000 retries) |
| `/W:5` | Waits 5 seconds between retries |
| `/V` | Verbose output — logs all files, including skipped ones. Output goes to the log file by default, or also to the terminal when `/TEE` is used |
| `/LOG+` | Appends the full output to `robocopy_log.txt` on the destination. Uses append mode (`+`) to preserve the descriptive header that the script writes to the file before launching robocopy |
| `/TEE` | Only with `--show-progress` or `--verbose`. Sends output to both the log file and the terminal (stdout) |
| `/NP` | Only with `--show-progress`. Suppresses the per-file progress percentages (0%..100%) that `/MT:16` adds to each file line (empirically confirmed). Without it, these percentages would inflate the file count used by the progress bar |
| `/XD` | Excludes **directories**: `$RECYCLE.BIN` and `System Volume Information` are excluded by name (Windows system folders that cannot be copied — these names are reserved by Windows, so name-based matching is safe). `current_backup_logs` is excluded by full path (destination-only folder with script-generated logs — full path prevents accidentally excluding user folders with the same name). The dry run uses exactly the same list as the copy, so its counts match. During verification, `backup_logs` is excluded by full path on both source and destination (updated on source after the copy; the destination copy must also be excluded since `/XD` matches exact paths — without it, the destination's `backup_logs` would appear as an extra directory) |

### Dry run flags

The dry run (step 4) uses `/MIR`, `/R:3`, `/W:5` and the same `/XD` list as the copy, plus:

| Flag | Meaning |
|------|---------|
| `/L` | List-only: reports what would be copied or deleted, without modifying anything |
| `/BYTES` | Prints sizes as plain byte counts (instead of `1.2 g`), so the summary table and the list can be read reliably |
| `/FP` | Prints the full path of each file, so the list shows where each file is |
| `/UNILOG:file` | Writes the log as Unicode (UTF-16), so accented paths survive. The log goes to `%TEMP%` until you confirm |

No `/MT`, `/V` or `/NDL`: without `/MT` each line stays whole, without `/V` unchanged files aren't listed, and the folder lines (kept by not using `/NDL`) show which folders are deleted whole.

## How file changes are detected

Robocopy decides whether to copy a file by comparing its **timestamp** and **file size** between source and destination. It does **not** compare actual file content (no checksum or hash).

This means:
- A file modified on the source with a newer timestamp is copied (most common case)
- A file with the same name but different size is copied
- A file where the content changed but the timestamp and size remained identical is **skipped** (rare, but possible)

For most backup scenarios this is reliable and fast. If you need stricter detection, you can add one of the following optional flags to the `$RoboCommon` array in the script:

| Flag | Effect |
|------|--------|
| `/FFT` | Uses a 2-second tolerance when comparing timestamps. Useful when copying between NTFS and FAT drives, where timestamp precision differs |
| `/IS` | Includes files that are considered "same" (same timestamp and size). Forces them to be copied again. Ensures every file is overwritten regardless of whether it appears unchanged |
| `/IT` | Includes files with the same name and size but different timestamps ("tweaked" files). Useful if timestamps were modified without actual content changes |

## Important warnings

- **Mirror mode deletes files.** Any file on the destination that does not exist on the source will be permanently removed. The destination becomes an exact copy of the source.
- **`current_backup_logs\` is deleted and recreated on each run.** Previous logs (including `robocopy_log.txt`, `backup_summary.txt`, and `verify_log.txt`) are permanently removed before a new backup starts. This ensures no stale logs remain if the backup fails partway through.
- **`backup_times.txt` keeps only the last 10 entries.** Older entries are automatically removed when the 11th is added.
- **`backup_history.txt` is written after Robocopy finishes**, so the destination copy will be one backup behind until the next run.
- **Do not disconnect drives during the backup.** This can cause incomplete copies or corrupted files.
- **Do not run multiple backups of the same source drive at the same time.** The script does not prevent concurrent instances. Each backup writes to a separate destination drive, so the copy itself is safe, but the source log files (`backup_history.txt` and `backup_times.txt`) could be corrupted if two instances try to update them at the same time.

## What happens if the script is cancelled mid-copy

If the script is interrupted during the Robocopy operation (e.g., pressing `Ctrl+C`, closing the terminal, or a power failure):

**Source drive: unaffected.** The script only writes to the source drive *after* the copy completes successfully (backup history in step 10, timing log in step 12). The only pre-copy write is creating the `backup_logs\` folder if it doesn't already exist, which is harmless. No source files are modified or deleted at any point. The dry run (step 4) writes nothing to either drive.

**Destination drive: left in a partially mirrored state.** Robocopy may have already copied some files, deleted some extra files, or left a file partially written. With `/MT:16`, these operations happen in parallel, so the exact state depends on when the interruption occurred. The `robocopy_log.txt` will be incomplete, and `backup_summary.txt` will not exist (it is written after the copy finishes).

**Destination logs: incomplete.** The `current_backup_logs\` folder was wiped at the start (step 7), so it only contains the dry run's files and whatever `robocopy_log.txt` was written up to the point of interruption. No `backup_summary.txt` or `verify_log.txt` will be present.

**Recovery: just run the script again.** The next run will automatically clean up:
1. Step 7 deletes and recreates `current_backup_logs\`, removing the incomplete log
2. Robocopy `/MIR` brings the destination back to an exact mirror of the source, fixing any partially copied or missing files

No manual intervention is needed. The destination will be inconsistent until the next successful backup, but the source is always safe.

## Tests

The tests are in `tests\run-tests.ps1`. They need nothing installed and never touch a real drive. Run them from PowerShell in the repo folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Each check prints `PASS` or `FAIL`, and the script ends with `Passed: N  Failed: M`. It exits with code 1 if anything failed. It works in a new folder under `%TEMP%` and deletes it at the end.

**What they cover:**
- **Parsing:** robocopy's summary table read by position, sizes, and the thresholds and `local\settings.json` handling.
- **A real list-only robocopy** on test folders with every kind of difference: a changed file, new files, deleted files, a deleted folder with a nested folder, and accented names. The counts and the list must match exactly, and both folders must be left untouched.
- **`robobak.ps1` end to end,** with the answers to its prompts piped in: cancelling leaves everything byte-identical, `L` then `Y` mirrors and keeps the dry run's files, a second run verifies, 501 deleted files trigger the red warning, and a wrong letter or label is refused before any robocopy runs.

**What they can't prove:** they use NTFS folders on the computer's own disk, not exFAT or VeraCrypt drives over USB, so the label fallback for VeraCrypt volumes, real timings and drive-specific behaviour still need a run on real drives.

### Test mode

The end-to-end tests run `robobak.ps1` in **test mode**, which is on only while the `ROBOBAK_TEST` environment variable is set. Its value maps drive letters to folders and labels, separated by `;`:

```
F=C:\Temp\rb\src|DATA;E=C:\Temp\rb\dst|BACKUP_TEST;local=C:\Temp\rb\local
```

- **`<letter>=<folder>|<label>`** is a fake drive. A letter that isn't in the map is an error, never a real drive.
- **`local=<folder>`** replaces the `local\` folder. Without it, test mode uses the default settings and never reads the real `local\`.
- **Folders can't contain spaces,** because robocopy misreads a quoted path that ends in a backslash.
- **While it's on,** the script shows a `TEST MODE` banner, and `L` prints the list's path instead of opening Notepad.

Don't set `ROBOBAK_TEST` for real backups. The test script sets it only for the copies of PowerShell it starts.

**Why not real drive letters:** `subst` drives can't have their own label, so the `BACKUP_` check can't be tested, and they change drive letters for the whole session. Virtual disks (VHDs) need administrator rights and amount to partitioning.
