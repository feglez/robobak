# RoboBak - Usage Guide

## Overview

`robobak.ps1` is a PowerShell script that creates an exact mirror copy of one drive onto another using Robocopy. It includes multiple safety checks to prevent accidental data loss and keeps a history of all backups performed.

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later (included with Windows 10/11)
- Both source and destination drives must be connected and accessible

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
4. **Asks for confirmation** — displays source and destination drives with their labels and requires you to type `Y` to proceed
5. **Checks disk space** — compares the source's used space against the destination's total size. If the source is larger, warns the user that the backup will be incomplete and lets them choose to continue or cancel. The comparison uses total size (not free space) because `/MIR` deletes extras on the destination during the copy, freeing space
6. **Prepares log folders** — ensures the source `backup_logs\` folder exists. Deletes and recreates the destination `current_backup_logs\` folder to clear any stale logs from a previous run (prevents inconsistent state if the backup fails)
7. **Runs Robocopy in mirror mode** — copies all files from source to destination; files on the destination that don't exist on the source are **deleted**. By default the terminal stays clean (individual files are only logged to `robocopy_log.txt`). With `--show-progress`, files are counted first (the counting time is logged separately), then a progress bar is displayed. With `--verbose`, every file operation is printed to the terminal. A summary table and the copy duration are displayed at the end in all modes
8. **Writes a summary** — saves a `backup_summary.txt` on the destination with the status (success or failure), date, source/destination info, Robocopy exit code, file count duration, copy duration, flags used, and any errors found in the log. If Robocopy reported critical errors (exit code 8+), the script stops after writing the summary and updating the timing log
9. **Updates the backup history** — maintains a `backup_history.txt` on the source drive tracking all backup disks, marking the `[NEWEST]` and `[OLDEST]` entries
10. **Optional verification** — asks if you want to verify the backup. If accepted, runs robocopy in list-only mode (`/L`) with multithreading (`/MT:16`) and retry limits (`/R:3 /W:5`) to compare source and destination without modifying anything. The `current_backup_logs` folder (destination-only, written after the copy) and `backup_logs` folder (on both source and destination — updated on the source after the copy, and its destination copy must also be excluded since `/XD` matches exact paths) are excluded from the comparison to avoid false differences. Note: `/XD` prevents excluded directories from being logged and compared at the file level, but robocopy still counts them as "EXTRA" in its stats table, which makes the exit code non-zero (2) even when the backup is a perfect match. To work around this, verification is considered successful when either the exit code is 0 or the exit code is 2 with no actual `EXTRA` lines in the log (case-sensitive — `EXTRA` is a robocopy constant, not translated). Reports whether the backup is a perfect match or if differences were found. The result and verification duration are appended to `backup_summary.txt`
11. **Updates timing log** — writes a timing entry to `backup_times.txt` on the source drive with the file count duration (if `--show-progress` was used), copy duration, verification duration, and flags used

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

### Example `backup_history.txt`

```
BACKUP_1 | 2026-01-15 10:30:00 [OLDEST]
BACKUP_2 | 2026-02-08 14:22:45 [NEWEST]
```

Note: backing up to `BACKUP_1` again would update its date (e.g., to `2026-02-10 08:00:00`), not add a second line. `BACKUP_1` would then become `[NEWEST]` and `BACKUP_2` would become `[OLDEST]`.

### Example `backup_times.txt`

Entries are ordered chronologically — oldest first, newest last:

```
[2026-02-08 14:22:45] MY_DATA -> BACKUP_2 (OK)
  File count duration:   00:01:30
  Copy duration:         01:23:45
  Verification duration: 00:02:10
  Flags:                 --show-progress

[2026-02-09 09:15:30] MY_DATA -> BACKUP_1 (OK)
  File count duration:   not performed
  Copy duration:         01:45:12
  Verification duration: not performed
  Flags:                 (none)
```

### Example `backup_summary.txt`

```
STATUS: BACKUP COMPLETED SUCCESSFULLY
Date: 2026-02-09 09:15:30
Source: F:\ (MY_DATA)
Destination: E:\ (BACKUP_1)
Robocopy exit code: 1
File count duration: not performed
Copy duration: 01:45:12
Flags: (none)

Verification: PASSED
Verification duration: 00:02:10
```

## Robocopy flags used

| Flag | Meaning |
|------|---------|
| `/MIR` | Mirror mode — makes destination an exact copy of source, deleting extra files on destination |
| `/MT:16` | Uses 16 threads for faster copying and verification. Empirically observed side effects: suppresses directory listing in the output, uses full absolute paths for files instead of relative names, and adds per-file progress percentages (suppressed by `/NP` in `--show-progress` mode). Output is also non-thread-safe — multiple threads write simultaneously, which can occasionally interleave or split lines |
| `/DCOPY:DAT` | Copies directory timestamps and attributes |
| `/R:3` | Retries failed copies up to 3 times (also used during verification to prevent hanging on locked files — robocopy's default is 1,000,000 retries) |
| `/W:5` | Waits 5 seconds between retries |
| `/V` | Verbose output — logs all files, including skipped ones. Output goes to the log file by default, or also to the terminal when `/TEE` is used |
| `/LOG` | Writes the full output to `robocopy_log.txt` on the destination |
| `/TEE` | Only with `--show-progress` or `--verbose`. Sends output to both the log file and the terminal (stdout) |
| `/NP` | Only with `--show-progress`. Suppresses the per-file progress percentages (0%..100%) that `/MT:16` adds to each file line (empirically confirmed). Without it, these percentages would inflate the file count used by the progress bar |
| `/XD` | Excludes **directories**: `$RECYCLE.BIN` and `System Volume Information` are excluded by name (Windows system folders that cannot be copied — these names are reserved by Windows, so name-based matching is safe). `current_backup_logs` is excluded by full path (destination-only folder with script-generated logs — full path prevents accidentally excluding user folders with the same name). During verification, `backup_logs` is excluded by full path on both source and destination (updated on source after the copy; the destination copy must also be excluded since `/XD` matches exact paths — without it, the destination's `backup_logs` would appear as an extra directory) |

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

**Source drive: unaffected.** The script only writes to the source drive *after* the copy completes successfully (backup history in step 9, timing log in step 11). The only pre-copy write is creating the `backup_logs\` folder if it doesn't already exist, which is harmless. No source files are modified or deleted at any point.

**Destination drive: left in a partially mirrored state.** Robocopy may have already copied some files, deleted some extra files, or left a file partially written. With `/MT:16`, these operations happen in parallel, so the exact state depends on when the interruption occurred. The `robocopy_log.txt` will be incomplete, and `backup_summary.txt` will not exist (it is written after the copy finishes).

**Destination logs: incomplete.** The `current_backup_logs\` folder was wiped at the start (step 6), so it only contains whatever `robocopy_log.txt` was written up to the point of interruption. No `backup_summary.txt` or `verify_log.txt` will be present.

**Recovery: just run the script again.** The next run will automatically clean up:
1. Step 6 deletes and recreates `current_backup_logs\`, removing the incomplete log
2. Robocopy `/MIR` brings the destination back to an exact mirror of the source, fixing any partially copied or missing files

No manual intervention is needed. The destination will be inconsistent until the next successful backup, but the source is always safe.
