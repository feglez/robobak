# RoboBak - Usage Guide

## Overview

`robobak.ps1` is a PowerShell script that creates an exact mirror copy of one drive onto another using Robocopy. It includes multiple safety checks to prevent accidental data loss and keeps a history of all backups performed.

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later (included with Windows 10/11)
- Both source and destination drives must be connected and accessible
- `robobak.ps1`, `robobak-lib.ps1` and `robobak-health.ps1` must be in the same folder. The library holds functions shared with the tests; if it's missing, the script stops with an error before doing anything
- Optional, for [disk health](#disk-health): smartmontools or CrystalDiskInfo, and administrator rights when the run ends
- Optional, for the [reminders](#reminders): `robobak-reminders.ps1` and `install-reminders.ps1`, in the same folder

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
| `--health` | Log [disk health](#disk-health) at the end without asking |
| `--no-health` | Don't log disk health, and don't ask |
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

## Recording a system backup (`--system-done`)

If you also make system backups (full images of the computer's disk) with another program, RoboBak can record them next to the mirror runs, so `local\runs.csv` shows when each kind of backup was last made:

```
.\robobak.ps1 --system-done S
```

Run it right after the system backup program has finished, where `S` is the partition that holds the system images. It:

1. **Checks the letter** — the drive must be connected. A partition labeled `BACKUP_*` is **refused**: that label marks a mirror drive, and the system image partition never has one, so it most likely means the wrong letter was typed. The partition needs no particular label
2. **Asks for confirmation** — shows the letter and label, and requires you to type `Y`
3. **Logs the partition's disk health** — optional, see [Disk health](#disk-health). `--health` or `--no-health` after the letter answer the question in advance
4. **Records it** — appends one `system` line to `local\runs.csv` (see [Script folder](#script-folder-local)), with the computer's name as the source and the partition's label as the destination

It **never copies or deletes anything**, runs no Robocopy, and doesn't check the backup itself: checking it is the backup program's job.

## What the script does (step by step)

1. **Validates parameters** — checks that both drive letters are provided and that they are different
2. **Checks drive availability** — verifies both drives are physically connected
3. **Checks volume labels** — reads both drive labels (tries `Get-Volume` first, falls back to `[System.IO.DriveInfo]` for drives that don't expose their label through CIM, such as VeraCrypt-mounted volumes). If the source label is still blank, warns the user and lets them choose to continue or cancel. Then verifies the destination label starts with `BACKUP_` to prevent accidents
4. **Previews the changes (dry run)** — runs Robocopy in list-only mode (`/L`) with the same `/MIR` and the same exclusions as the real copy, to count the files it would delete and copy. Nothing is modified on either drive: the dry run's log and list are written to `%TEMP%` and only moved to the destination after you confirm (step 7), or deleted if you cancel. It runs without `/MT`, because with several threads Robocopy's lines can get mixed up, which the list can't tolerate. The counts are read **by position** from Robocopy's summary table (its labels are translated into your Windows language, but its layout isn't), and deletions are the lines tagged `EXTRA` (a Robocopy constant, never translated). Files inside a folder that will be deleted are counted and listed one by one. The dry run walks both drives like the verification does, but with a single thread, so it may take longer than a verification. Its duration is shown on screen and saved in `backup_summary.txt` and `backup_times.txt`. Before it starts, the screen shows how long the last dry run to the same drive took (see [Time estimates](#time-estimates))
5. **Asks for confirmation** — displays source and destination drives with their labels, then the dry run's counts, for example `Will delete 1.240 files (3,2 GB) and copy 37 files (412,0 MB).` Type `L` to open the list in Notepad (deletions first, then copies; the screen then asks again), `Y` to proceed, or anything else to cancel. **Above 500 files or 5 GB to delete**, the counts are shown inside a loud red warning: check the list, and if files are missing from the source by mistake, cancel and restore them first. The thresholds can be changed in `local\settings.json` (see [Settings](#settings)). If the dry run itself reported errors (Robocopy exit code 8 or more), the screen says so and the counts may be incomplete. If its summary table can't be read, the screen says the counts are unknown. Under the counts, the screen estimates how long the copy will take, for example `Estimated copy time: less than a minute (412,0 MB at 52,7 MB/s, measured on the last large copy to BACKUP_1)` (see [Time estimates](#time-estimates))
6. **Checks disk space** — compares the source's used space against the destination's total size. If the source is larger, warns the user that the backup will be incomplete and lets them choose to continue or cancel. The comparison uses total size (not free space) because `/MIR` deletes extras on the destination during the copy, freeing space
7. **Prepares log folders** — ensures the source `backup_logs\` folder exists. Deletes and recreates the destination `current_backup_logs\` folder to clear any stale logs from a previous run (prevents inconsistent state if the backup fails). Then moves the dry run's list and log into it, as `dry_run_list.txt` and `dry_run_log.txt`
8. **Runs Robocopy in mirror mode** — copies all files from source to destination; files on the destination that don't exist on the source are **deleted**. By default the terminal stays clean (individual files are only logged to `robocopy_log.txt`). With `--show-progress`, files are counted first (the counting time is logged separately), then a progress bar is displayed. With `--verbose`, every file operation is printed to the terminal. A summary table and the copy duration are displayed at the end in all modes
9. **Writes a summary** — saves a `backup_summary.txt` on the destination with the status (success or failure), date, source/destination info, Robocopy exit code, the dry run's counts and duration, file count duration, copy duration, flags used, and any errors found in the log. If Robocopy reported critical errors (exit code 8+), the script stops after writing the summary, updating the timing log and recording the run (step 14)
10. **Updates the backup history** — maintains a `backup_history.txt` on the source drive tracking all backup disks, marking the `[NEWEST]` and `[OLDEST]` entries
11. **Optional verification** — asks if you want to verify the backup. If accepted, runs robocopy in list-only mode (`/L`) with multithreading (`/MT:16`) and retry limits (`/R:3 /W:5`) to compare source and destination without modifying anything. The `current_backup_logs` and `robobak_health` folders (destination-only) and the `backup_logs` folder (on both source and destination — updated on the source after the copy, and its destination copy must also be excluded since `/XD` matches exact paths) are excluded from the comparison to avoid false differences. Note: `/XD` prevents excluded directories from being logged and compared at the file level, but robocopy still counts them as "EXTRA" in its stats table, which makes the exit code non-zero (2) even when the backup is a perfect match. To work around this, verification is considered successful when either the exit code is 0 or the exit code is 2 with no actual `EXTRA` lines in the log (case-sensitive — `EXTRA` is a robocopy constant, not translated). Reports whether the backup is a perfect match or if differences were found. The result and verification duration are appended to `backup_summary.txt`. How long the last verification to the same drive took is shown just before the question, or under "Verifying backup integrity..." with `--verify`
12. **Updates timing log** — writes a timing entry to `backup_times.txt` on the source drive with the dry run duration, file count duration (if `--show-progress` was used), copy duration, the size the dry run said would be copied, verification duration, and flags used. The next runs read these to estimate their times
13. **Logs disk health** — optional: asks, then reads the disks used through an administrator prompt, writes a line on each drive, and shows any warning. Done after verification, so the line knows the run's result. See [Disk health](#disk-health)
14. **Records the run** — appends one line to `local\runs.csv`, next to the script, with the date, both labels, the result (`ok` or `failed`), the verification result and the disk health result. This happens once at the end of **every run that ran the copy**: a failed copy, a run without verification, a verified run, and a run whose verification found differences. A run cancelled at a prompt, or refused before the copy, writes nothing. If the line can't be written (for example, the file is open in Excel), a yellow warning says so and the run still ends normally. See [Script folder](#script-folder-local)

## Generated files

All log files are organized into dedicated folders instead of the drive root.

### Source drive (`backup_logs\`)

| File | Description |
|------|-------------|
| `backup_history.txt` | List of all backup drives used, sorted by name, with `[NEWEST]` and `[OLDEST]` tags. Each drive label appears **only once** — if you back up to the same drive twice, its entry is updated with the latest date (not duplicated) |
| `backup_times.txt` | Rolling log of the last 10 backups with timing information (dry run duration, file count duration, copy duration, copied size, verification duration, flags used), which the [time estimates](#time-estimates) read. The **first entry is the oldest** and the **last entry is the newest**. When the 11th backup is added, the oldest entry is removed |
| `disk_health.txt`, `disk_link.json` | This drive's [disk health](#disk-health) history, and which disk holds it. Being in `backup_logs\`, they also reach the backup drives with the mirror |

### Destination drive (`current_backup_logs\`)

| File | Description |
|------|-------------|
| `robocopy_log.txt` | Full technical report from Robocopy with details of every file copied, skipped, or failed |
| `backup_summary.txt` | Backup result summary: status (success/failure), date, source, destination, Robocopy exit code, file count duration, copy duration, flags, errors, and verification result |
| `verify_log.txt` | Only created if verification is requested. Logs only the differences found between source and destination (since `/V` is not used during verification, identical files are not listed). If the backup is a perfect match, only the stats table appears |
| `dry_run_list.txt` | The list shown by `L` at the confirmation: the dry run's counts, then every file the mirror would delete (folders deleted with their contents are marked `[folder]`, and their files follow), then every file it would copy (new or changed). UTF-8, so accented names display correctly |
| `dry_run_log.txt` | Full Robocopy report of the dry run (list-only), converted to UTF-8. Robocopy writes it with `/UNILOG` so accented paths survive |

### Destination drive and system image partition (`robobak_health\`)

| File | Description |
|------|-------------|
| `disk_health.txt` | One line per [disk health](#disk-health) check of this drive. Never wiped: the folder is excluded from the mirror and from the verification |
| `disk_link.json` | Which disk holds this drive (its serial) and the year you got it. Only on volumes Windows can't match to a disk by itself, such as VeraCrypt volumes |

### Script folder (`local\`)

| File | Description |
|------|-------------|
| `runs.csv` | One line per backup: every mirror run that ran the copy (step 14), every system backup recorded with `--system-done`, and every Skip in the [reminders window](#reminders). Lines are only ever appended, never rewritten. Created, with its header, the first time a line is written |
| `settings.json` | Optional: the warnings' thresholds, written by you, and the reminder settings, written by the window (see [Settings](#settings)). `robobak.ps1` never creates it |
| `state.json` | When the last [reminder](#reminders) notification was shown. Written by the check |

`runs.csv` columns:

| Column | Values |
|--------|--------|
| `date` | Local time, `yyyy-MM-dd HH:mm:ss` |
| `kind` | `mirror` or `system` |
| `source` | The source drive's label. For a system backup, the computer's name |
| `destination` | The destination drive's label, or the system image partition's label |
| `result` | `ok`, `failed` (Robocopy exit code 8 or more) or `skipped` (the Skip button in the reminders window; the verification is `not performed` and the health `not checked`) |
| `verification` | `passed`, `differences` or `not performed`. Always `not performed` for a system backup |
| `health` | `ok`, `yellow`, `red`, `not approved`, or `not checked` (no tool installed, or no disk could be read). With two disks, the worst of those that were read. See [Disk health](#disk-health) |

The file is UTF-8 (with a byte order mark, so Excel and PowerShell read accents correctly). The header is plain, and every value is quoted, so labels with commas or quotes are kept intact. To read it in PowerShell: `Import-Csv .\local\runs.csv -Encoding UTF8`.

### Example `runs.csv`

```
date,kind,source,destination,result,verification,health
"2026-02-08 14:22:45","mirror","MY_DATA","BACKUP_2","ok","passed","ok"
"2026-02-09 09:15:30","mirror","MY_DATA","BACKUP_1","ok","not performed","not approved"
"2026-02-09 10:02:11","system","LAPTOP","SYSIMG_1","ok","not performed","yellow"
"2026-02-23 18:40:03","mirror","MY_DATA","BACKUP_2","failed","not performed","red"
```

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
  Copied (dry run):      250.37 GB
  Verification duration: 00:02:10
  Flags:                 --show-progress

[2026-02-09 09:15:30] MY_DATA -> BACKUP_1 (OK)
  Dry run duration:      00:02:05
  File count duration:   not performed
  Copy duration:         01:45:12
  Copied (dry run):      312.80 GB
  Verification duration: not performed
  Flags:                 (none)
```

`Copied (dry run)` is the size the dry run said would be copied, always written with a point so it reads back on any system, or `unknown` if the dry run's counts couldn't be read. Entries written by older versions have no `Copied (dry run)` line, and the oldest ones no `Dry run duration` line either. All kinds are read and kept the same way.

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

## The local folder

`local\` sits in the folder that holds the script and keeps what only this computer knows: the backup records (`runs.csv`), the settings (`settings.json`, if there are any) and when the last reminder was shown (`state.json`). RoboBak creates the folder the first time it records a run.

- **Ignored by Git** (`.gitignore`), so it's never committed or published. Beware: `git clean -x` deletes ignored files, including `local\`.
- **Back it up before reinstalling Windows or moving to another computer:** copy the whole `local\` folder somewhere safe (an external drive, for example). After installing RoboBak again, put it back next to `robobak.ps1`. Without it, everything still works, but the records start from zero.
- **A copy is enough:** the files are plain text. If you use the [reminders](#reminders), run `install-reminders.ps1` again afterwards, because the shortcut and the scheduled task aren't in this folder.

## Settings

Settings are optional and live in `local\settings.json`, in the folder that holds the script. The file has one section per program. `robobak.ps1` reads only its own, `robobak`:

```json
{
  "robobak": {
    "deleteWarnFiles": 500,
    "deleteWarnGB": 5,
    "healthWarnHours": 20000,
    "healthWarnYears": 5,
    "healthWarnTempC": 50
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `deleteWarnFiles` | `500` | The confirmation shows the red warning when **more** than this many files would be deleted |
| `deleteWarnGB` | `5` | The same, for size: more than this many GB (1 GB = 1024³ bytes). Decimals are allowed, e.g. `0.5` |
| `healthWarnHours` | `20000` | [Disk health](#disk-health): yellow warning above this many power-on hours |
| `healthWarnYears` | `5` | Disk health: yellow warning for a disk older than this many years. Only for disks whose year you gave |
| `healthWarnTempC` | `50` | Disk health: yellow warning above this temperature at the end of the run, in °C |

The [reminders window](#reminders) keeps its own section, `reminders`, and rewrites only that one when you press Save:

```json
{
  "reminders": {
    "enabled": true,
    "systemDays": 14,
    "mirrorDays": 14,
    "gapHours": 24,
    "triggerLogon": true,
    "triggerUnlock": true,
    "triggerDaily": true,
    "dailyTime": "12:00"
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Reminders on or off. Off also disables the scheduled task |
| `systemDays` | `14` | Days between system backups before one is due |
| `mirrorDays` | `14` | Days between mirrors before one is due |
| `gapHours` | `24` | At most one notification every this many hours. `0` means no limit |
| `triggerLogon`, `triggerUnlock`, `triggerDaily` | `true` | When the check runs: at sign-in, when the screen is unlocked, and every day |
| `dailyTime` | `12:00` | The time of the daily check, as `HH:mm` |

- **`robobak.ps1` only reads this file and never creates it.** A missing file, section or key means the default.
- **Invalid values** (negative numbers, text, broken JSON) are reported in yellow before the confirmation screen, or by the window, and the defaults are used instead. The window won't save over a file with broken JSON.
- **`local\` is ignored by Git** (`.gitignore`), so it's never committed. Beware: `git clean -x` deletes ignored files, including `local\` (see [The local folder](#the-local-folder)).

## Disk health

At the end of a mirror run, and of `--system-done`, RoboBak can log the health of the disks it used. It's optional. Without smartmontools or CrystalDiskInfo, RoboBak says so in one line, asks nothing and writes nothing on the drives.

### What happens

1. **It asks** `Log disk health? This needs admin rights.` `--health` and `--no-health` answer in advance.
2. **If you accept,** Windows shows its admin prompt, because reading SMART data needs it. A helper, `robobak-health.ps1`, runs with those rights, reads every connected disk once, and hands the result back through a temporary file in `%TEMP%`, which is then deleted. It only reads.
3. **For each drive in the run** (the source and the destination, or the partition given to `--system-done`), RoboBak finds its disk, compares it with the previous line of that drive's history, writes a new line, and shows the result and any warning.

**If you answer no or cancel the admin prompt,** each drive's history gets a `not approved` line and `runs.csv` says `not approved`. This step never affects the backup: anything unexpected is a yellow warning, and the run ends normally.

### Which disk is which

- **A plain partition** is matched through Windows (drive letter, then disk number).
- **A VeraCrypt volume** can't be, so the first time RoboBak lists the disks as the tool reports them (model, serial, size) and asks which one holds it, and the year you got it (optional). It saves that in `disk_link.json` on the drive, so it travels with the drive. Later runs match the disk by its serial.
- **If you move a volume to another disk,** delete its `disk_link.json` and RoboBak will ask again.
- **Two volumes on one disk** have two histories, one on each volume, and each line is compared with the previous line in the same file.

### Tools

RoboBak uses smartmontools, and CrystalDiskInfo for any disk smartmontools can't read. It calls them by their default paths, so install them in their default folders.

**smartmontools:**
1. Download `smartmontools-<version>.win32-setup.exe` from the [releases page](https://github.com/smartmontools/smartmontools/releases). It installs the 64-bit program on 64-bit Windows.
2. Run it with the default options. RoboBak expects `C:\Program Files\smartmontools\bin\smartctl.exe`.
3. To check it, run this in PowerShell as administrator; your disks should be listed:
   ```powershell
   & "C:\Program Files\smartmontools\bin\smartctl.exe" --scan-open
   ```

To uninstall it: **Settings > Apps > Installed apps > smartmontools > Uninstall**.

**CrystalDiskInfo:**
1. Install it with its standard installer. RoboBak expects `C:\Program Files\CrystalDiskInfo\DiskInfo64.exe`.
2. To check it, open it and see that your disks are listed.

To uninstall it: **Settings > Apps > Installed apps > CrystalDiskInfo > Uninstall**. Each time RoboBak uses it, it writes `DiskInfo.txt` next to its executable.

### What it creates

| Where | What | Removing it |
|-------|------|-------------|
| Source drive, `backup_logs\` | `disk_health.txt`, `disk_link.json` | Loses that drive's history; RoboBak starts a new one |
| Destination drive or system image partition, `robobak_health\` | `disk_health.txt`, `disk_link.json` | The same |
| `%TEMP%` | `robobak_health_<id>.json`, the helper's result | Deleted at once by RoboBak |
| `local\runs.csv` | The `health` column | Part of the run's record |

### A line of the history

```
2026-02-08 14:22:45 | mirror | level=ok | smart=passed | 05=0 | C5=0 | C6=0 | C7=0 | hours=12034 | tempC=34 | serial=ABC123 | model=DISK MODEL | tool=smartctl | copyErrors=0 | verification=passed
```

`level` is `ok`, `yellow`, `red`, `not approved` or `not checked`. A value the tool doesn't give is `unknown`. Lines with no reading (`not approved`, `not checked`) only keep the date, the run and why.

### The warnings

Each reading is compared with the previous reading of the same disk in that drive's history.

| Level | Sign |
|-------|------|
| Red | SMART status not OK |
| Red | 05 (reallocated sectors), C5 (pending sectors) or C6 (uncorrectable sectors) rising, or above zero for the first time. On a drive's first reading, any value above zero counts as the first time |
| Red | Copy errors (any `ERROR` line in `robocopy_log.txt`, even for a file that succeeded on a retry) or a failed copy, or a verification that found differences, in this run |
| Yellow | 05, C5 or C6 above zero but not rising |
| Yellow | C7 (CRC errors, usually the enclosure or the cable) rising |
| Yellow | Power-on hours above `healthWarnHours` (20,000) |
| Yellow | Older than `healthWarnYears` (5 years), when you gave the year |
| Yellow | Temperature at the end above `healthWarnTempC` (50 °C) |

The thresholds are in [Settings](#settings).

**Limits:**
- **NVMe disks** have no 05, C5, C6 or C7, so those rules don't apply to them.
- **Through CrystalDiskInfo,** the SMART status is `unknown` unless its report says `Good` or `Bad`, because the word is translated into CrystalDiskInfo's language. The attribute rules still apply.

## Reminders

Optional. A small window shows when each backup was last done and what's due, and a scheduled task shows a Windows notification when one is due. **Nothing here ever runs a backup.** The reminders only read `local\runs.csv`, so a backup that wasn't recorded counts as not done: run `robobak.ps1` for mirrors, and `--system-done` after each system backup.

### Install

In PowerShell, in the script's folder:

```powershell
.\install-reminders.ps1
```

If Windows refuses to create the scheduled task (access denied), the script says so: open PowerShell as administrator, go to the same folder and run it again. The window's Save button rewrites the task too, and shows the same message if it's refused.

It creates:

| Where | What | Removing it |
|-------|------|-------------|
| Start menu | A `RoboBak` shortcut (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\RoboBak.lnk`). It opens the window, and carries the application ID that makes notifications show "RoboBak" as their sender | `-Uninstall` |
| Task Scheduler | A task named `RoboBak reminders`, which runs the check as your user, without administrator rights, one at a time, through `conhost.exe --headless` so that no window appears | `-Uninstall` |

Using them adds to `local\`:

| File | What | Removing it |
|------|------|-------------|
| `runs.csv` | A `skipped` line for each Skip | Part of the records |
| `settings.json` | The `reminders` section, when you press Save | The defaults come back |
| `state.json` | When the last notification was shown | The next one can come at once |

The shortcut and the task hold the script's full path, so **if you move or rename the folder, run `install-reminders.ps1` again**.

### Uninstall

```powershell
.\install-reminders.ps1 -Uninstall
```

It removes the shortcut and the scheduled task, then asks before deleting `local\`, which holds your records: type `Y` to delete it, anything else to keep it.

### The window

Open **RoboBak** from the Start menu, or run `.\robobak-reminders.ps1`.

- **For the system backup and the mirror:** when it was last done, when it was last skipped, and when the next one is due. Before any record exists, it says `never recorded`, and the backup counts as due.
- **Suggested drive:** the backup drive whose last successful copy is oldest. It only knows drives that have a successful mirror in `runs.csv`; failed and skipped lines don't count.
- **Skip:** enabled only for a backup that's due. It writes a `skipped` line, and the next reminder comes one interval later. The age shown in notifications remains that of the last backup actually done.
- **Settings:** reminders on or off, the two intervals, the gap between notifications, and when the check runs. **Save** writes the `reminders` section of `local\settings.json` and rewrites the scheduled task.

### The check

The scheduled task runs `robobak-reminders.ps1 -Check` at sign-in, when the screen is unlocked (each a minute later, so the lock screen has closed) and every day at the time you set. Each time it goes through these steps, in order, and stops at the first that applies:

1. **Reminders off:** nothing.
2. **Screen locked** (Windows' lock screen process, `LogonUI.exe`, is running): nothing.
3. **A notification less than the gap ago** (24 hours by default): nothing.
4. **Nothing due:** nothing.
5. **Otherwise,** one notification listing what's due, and it saves the time in `local\state.json`:

```
Backups due
System backup: last done 20 days ago.
Mirror: last done 20 days ago. Next drive: BACKUP_2.
```

A backup is due from the start of its next due date, which is the date of its last done-or-skipped record plus the interval. A failed mirror doesn't count as done.

To run the check by hand and see what it decides, run `.\robobak-reminders.ps1 -Check` in PowerShell: it prints the reason, or `notified`.

## Time estimates

RoboBak reads how long past runs took from `backup_times.txt` on the source drive (and, to tell whether a drive is new, `backup_history.txt`), and shows:

| When | Example | How it's worked out |
|------|---------|---------------------|
| Before the dry run | `Last time to BACKUP_1 it took 00:01:55.` | The last dry run from this source to the same drive. If there's none, the last one to another drive (`No previous dry run to BACKUP_2; to BACKUP_1 it took 00:01:55.`), or `First dry run from this drive: no previous time to compare.` |
| On the confirmation screen | `Estimated copy time: about 2 h 30 min (462,8 GB at 52,7 MB/s, measured on the last large copy to BACKUP_1)` | The size to copy (from the dry run) divided by a speed. The speed comes from the most recent successful copy of 10 GB or more to the same drive: the size it copied divided by its copy time. If there's none, from such a copy to another drive (`measured on a copy to BACKUP_2`), and otherwise a default of 50 MB/s (`a default: no large copy measured yet`). If the destination isn't in `backup_history.txt`, the line starts with `First backup to BACKUP_1.` |
| At the verification | `Last time to BACKUP_1 it took 00:02:10.` | The last verification to the same drive, or `First verification to BACKUP_1: no previous time.` Shown just before the verify question, or under "Verifying backup integrity..." with `--verify` |

**Limits:**
- **They're estimates.** The time to go through the folders isn't counted, because the copy starts right after the dry run has read them, so it takes seconds. The speed changes with file sizes: many small files copy more slowly than a few large ones.
- **Copies under 10 GB don't measure the speed,** because they're too short to give a reliable one.
- **`backup_times.txt` keeps only the last 10 runs,** so after many small runs the last large copy drops out, and the estimate falls back to another drive's speed or to the default.
- **Runs made by older versions** have no `Copied (dry run)` line, so they don't measure a speed either.
- **On screen, numbers follow your Windows language settings** (the examples are from a Spanish system).

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
| `/XD` | Excludes **directories**: `$RECYCLE.BIN` and `System Volume Information` are excluded by name (Windows system folders that cannot be copied — these names are reserved by Windows, so name-based matching is safe). `current_backup_logs` and `robobak_health` are excluded by full path (destination-only folders: script-generated logs and the drive's [disk health](#disk-health) history, which `/MIR` would otherwise delete — full path prevents accidentally excluding user folders with the same name). The dry run uses exactly the same list as the copy, so its counts match. During verification, `backup_logs` is excluded by full path on both source and destination (updated on source after the copy; the destination copy must also be excluded since `/XD` matches exact paths — without it, the destination's `backup_logs` would appear as an extra directory) |

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
- **`backup_times.txt` keeps only the last 10 entries.** Older entries are automatically removed when the 11th is added, which also limits the [time estimates](#time-estimates).
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
- **Behaviour kept from before the dry run existed:** for the default mode, `--show-progress` and `--verbose`, and for the verification, robocopy's echo of its own options (source, destination, excluded folders and flags) must match exactly what the original commands produce on an identical pair of folders. They also cover the verify question when no flag is given, the refusals (`--show-progress` with `--verbose`, the same letter twice), the help, the warning for a source without a label, and a failed copy (a locked file): `BACKUP FAILED`, the error in the summary, the failed entry in `backup_times.txt`, and no history update.
- **Disk health:** smartctl's and CrystalDiskInfo's output parsed from recorded examples, the history file, every red and yellow rule, the first reading, a saved disk that isn't connected, cancelling the admin prompt, `--health` and `--no-health`, no tool installed, and a mirror keeping the history.
- **Reminders:** every rule for what's due, the suggested drive, skip lines, the notification gap and text, the settings saved without touching the other sections, the task's triggers built in memory, `-Check` end to end, and the window built without being shown. `install-reminders.ps1` is only parsed: running it would create a real shortcut and task.
- **Backup records:** one `runs.csv` line per run that ran the copy (verified, not verified, verify question answered N, failed), none for cancelled or refused runs, the header written once, the byte order mark, and labels with quotes, commas and accents surviving `Import-Csv`. `--system-done`: `Y` records one `system` line, `N` records nothing, an unmapped letter, a missing letter and a `BACKUP_` label are refused, and nothing is copied or changed on any folder. The tests check at the end that the repo's own `local\runs.csv` was never touched.

**What they can't prove:** they use NTFS folders on the computer's own disk, not exFAT or VeraCrypt drives over USB, so the label fallback for VeraCrypt volumes, real timings and drive-specific behaviour still need a run on real drives. Disk health uses recorded data instead of the tools and runs the helper without administrator rights, so the real admin prompt and the real tools' output also need a run on real drives. For the reminders, the shortcut, the scheduled task, the notification and how the window looks can only be checked on the computer.

### Test mode

The end-to-end tests run `robobak.ps1` in **test mode**, which is on only while the `ROBOBAK_TEST` environment variable is set. Its value maps drive letters to folders and labels, separated by `;`:

```
F=C:\Temp\rb\src|DATA;E=C:\Temp\rb\dst|BACKUP_TEST;local=C:\Temp\rb\local
```

- **`<letter>=<folder>|<label>`** is a fake drive. A letter that isn't in the map is an error, never a real drive.
- **`local=<folder>`** replaces the `local\` folder, for both the settings and `runs.csv`. Without it, test mode uses the default settings, records nothing (it says so on screen), and never touches the real `local\`.
- **`health=<folder>`** holds recorded disk health data instead of the tools and Windows: `pd<N>.json` and `pd<N>.sat.json` (what `smartctl -a -j` prints for disk N, without and with `-d sat`), `DiskInfo.txt` (CrystalDiskInfo's report), `disk_of_<LETTER>.txt` (the disk number of a plain partition) and `cancel_elevation.txt` (simulates cancelling the admin prompt). The helper is started the same way, without elevation. Without this entry, test mode skips disk health.
- **Folders can't contain spaces,** because robocopy misreads a quoted path that ends in a backslash.
- **While it's on,** the script shows a `TEST MODE` banner, and `L` prints the list's path instead of opening Notepad.
- **For the reminders,** `-Check` prints what it would notify instead of showing a notification, a file named `locked.txt` in the `local=` folder stands for a locked screen, `robobak-reminders.ps1 -TestBuild` builds the window without showing it, nothing is registered with Task Scheduler, and `install-reminders.ps1` refuses to run.

Don't set `ROBOBAK_TEST` for real backups. The test script sets it only for the copies of PowerShell it starts.

**Why not real drive letters:** `subst` drives can't have their own label, so the `BACKUP_` check can't be tested, and they change drive letters for the whole session. Virtual disks (VHDs) need administrator rights and amount to partitioning.
