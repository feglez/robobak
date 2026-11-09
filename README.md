# RoboBak

A PowerShell script that creates exact mirror backups of one drive onto another using Robocopy. Includes safety checks to prevent accidental data loss, progress tracking, verification, and backup history management.

## Features

- **Mirror backup** — destination becomes an exact copy of the source (extra files on destination are deleted)
- **Safety checks** — destination drive must be labeled `BACKUP_*` to prevent wiping the wrong drive; warns if the destination is too small
- **Deletion warning** — before every run, a list-only dry run counts the files that will be deleted and copied. Type `L` at the confirmation to see the list. Above 500 files or 5 GB to delete, the confirmation becomes a loud red warning
- **Optional verification** — compares source and destination after the backup to confirm integrity
- **Progress bar** — optional real-time progress indicator during the copy
- **Backup history** — tracks all backup drives on the source, marking the newest and oldest
- **Timing log** — rolling log of the last 10 backups with durations
- **Time estimates** — before the dry run and the verification, shows how long they took last time; the confirmation estimates the copy time from the amount to copy and the speed of past copies
- **Backup records** — one line per mirror run in `local\runs.csv`, next to the script, with its result and verification
- **System backup records** — `--system-done` records a system backup made with another program, so the records cover both kinds of backup
- **Disk health** — optional, at the end of a run: reads the SMART data of the disks used (with smartmontools or CrystalDiskInfo), keeps a history on each drive and shows red or yellow warnings
- **Reminders** — optional: a small window shows when each backup was last done and what's due, and a scheduled task shows a Windows notification when one is due. Nothing runs a backup automatically
- **System backups guide** — a procedure for imaging the computer with Hasleo Backup Suite Free, alongside the mirrors
- **Detailed logging** — full Robocopy report, summary with errors, and verification report on the destination

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (included with Windows 10/11)
- `robobak.ps1`, `robobak-lib.ps1` and `robobak-health.ps1` in the same folder
- Optional, for disk health: [smartmontools](https://github.com/smartmontools/smartmontools/releases) or CrystalDiskInfo, and administrator rights when the run ends
- Optional, for the reminders: `robobak-reminders.ps1` and `install-reminders.ps1`, in the same folder

## Quick start

1. Rename your backup drive so its label starts with `BACKUP_` (e.g. `BACKUP_1`)
2. Run:

```powershell
.\robobak.ps1 F E
```

Where `F` is the source drive and `E` is the destination.

3. Read the confirmation screen. It says how many files the mirror will delete and copy, and estimates how long the copy will take:

```
Will delete 1.240 files (3,2 GB) and copy 37 files (412,0 MB).
Estimated copy time: less than a minute (412,0 MB at 52,7 MB/s, measured on the last large copy to BACKUP_1)
Type L to see the list, Y to continue, anything else to cancel:
```

Numbers follow your Windows language settings (the example is from a Spanish system).

## Usage

```
.\robobak.ps1 [SourceLetter] [DestLetter] [flags...]
```

| Flag | Description |
|------|-------------|
| `--verify` | Automatically verify the backup after completion |
| `--no-verify` | Skip verification without asking |
| `--show-progress` | Show a progress bar during the backup |
| `--verbose` | Show every file operation on the terminal |
| `--health` | Log disk health at the end without asking |
| `--no-health` | Don't log disk health, and don't ask |

### Examples

```powershell
.\robobak.ps1 F E --verify                    # Backup and verify
.\robobak.ps1 F E --show-progress              # Backup with progress bar
.\robobak.ps1 F E --show-progress --no-verify  # Progress bar, skip verification
.\robobak.ps1 F E --verbose --verify           # Show all file operations, then verify
.\robobak.ps1 /?                               # Show help
```

`--show-progress` and `--verbose` cannot be used together.

### Recording a system backup

```powershell
.\robobak.ps1 --system-done S
```

Records in `local\runs.csv` that a system backup (made with another program, such as a disk imaging tool) was just written to the partition at `S:`. It asks for confirmation, never copies or deletes anything, and refuses a partition labeled `BACKUP_*`, because that's a mirror drive. It can log that partition's disk health too (`--health` or `--no-health` answer in advance). See [Recording a system backup](usage_guide.md#recording-a-system-backup---system-done) in the usage guide.

## Generated files

| Location | File | Description |
|----------|------|-------------|
| Source `backup_logs\` | `backup_history.txt` | List of all backup drives with `[NEWEST]`/`[OLDEST]` tags |
| Source `backup_logs\` | `backup_times.txt` | Rolling log of the last 10 backups with timing info, also used for the time estimates |
| Source `backup_logs\` | `disk_health.txt`, `disk_link.json` | This drive's disk health history, and which disk holds it |
| Dest `current_backup_logs\` | `robocopy_log.txt` | Full Robocopy technical report |
| Dest `current_backup_logs\` | `backup_summary.txt` | Status, date, errors, timing, and verification result |
| Dest `current_backup_logs\` | `verify_log.txt` | Verification comparison report (only if requested) |
| Dest `current_backup_logs\` | `dry_run_list.txt` | What the dry run listed: files to delete, then files to copy |
| Dest `current_backup_logs\` | `dry_run_log.txt` | Full Robocopy report of the dry run |
| Dest or image partition `robobak_health\` | `disk_health.txt`, `disk_link.json` | That drive's disk health history, and which disk holds it. Kept between runs |
| Script folder `local\` | `runs.csv` | One line per mirror run, recorded system backup and skipped backup |
| Script folder `local\` | `settings.json` | Optional: warning thresholds, and the window's reminder settings |
| Script folder `local\` | `state.json` | When the last reminder notification was shown |

## Reminders

Optional. Install them from PowerShell, in the script's folder:

```powershell
.\install-reminders.ps1
```

This creates a **Start menu shortcut** called `RoboBak`, which opens the status and settings window, and a **scheduled task** called `RoboBak reminders`, which shows a Windows notification when a backup is due. To remove both (it asks before deleting `local\`):

```powershell
.\install-reminders.ps1 -Uninstall
```

See [Reminders](usage_guide.md#reminders) in the usage guide.

## Disk health

At the end of a run, RoboBak asks `Log disk health? This needs admin rights.` If you accept, it reads the disks used through Windows' admin prompt, compares them with each drive's history, and shows any warning. Without smartmontools or CrystalDiskInfo it says so in one line, asks nothing and writes nothing on the drives. See [Disk health](usage_guide.md#disk-health) in the usage guide, including how to install and uninstall both tools.

## System backups

RoboBak doesn't make images of the computer's own disk. The usage guide has a procedure for doing that with Hasleo Backup Suite Free and recording each backup with `--system-done`: the two-week session, the rescue stick, restoring, copying files out, restoring WSL from an image, and how Secure Boot and BitLocker affect them. An actual restore hasn't been tried. See [System backups with Hasleo](usage_guide.md#system-backups-with-hasleo).

## The `local\` folder

`local\` sits next to the script and holds what only this computer knows: `runs.csv` (the backup records), optionally `settings.json` (the warnings' thresholds, which `robobak.ps1` only reads, and the reminder settings, which the window writes) and `state.json` (when the last reminder was shown). It's ignored by Git, so it's never committed, but `git clean -x` would delete it. To keep the records when you reinstall Windows or move to another computer, copy the whole folder and put it back next to the script. See [The local folder](usage_guide.md#the-local-folder) in the usage guide.

## Tests

The tests run RoboBak against temporary folders, never real drives:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

See [Tests](usage_guide.md#tests) in the usage guide.

## Documentation

See [usage_guide.md](usage_guide.md) for the full documentation, including step-by-step details, Robocopy flags used, how file changes are detected, and what happens if the script is interrupted mid-copy.
