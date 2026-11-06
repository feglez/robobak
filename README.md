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
- **Backup records** — one line per mirror run in `local\runs.csv`, next to the script, with its result and verification
- **System backup records** — `--system-done` records a system backup made with another program, so the records cover both kinds of backup
- **Detailed logging** — full Robocopy report, summary with errors, and verification report on the destination

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (included with Windows 10/11)
- `robobak.ps1` and `robobak-lib.ps1` in the same folder

## Quick start

1. Rename your backup drive so its label starts with `BACKUP_` (e.g. `BACKUP_1`)
2. Run:

```powershell
.\robobak.ps1 F E
```

Where `F` is the source drive and `E` is the destination.

3. Read the confirmation screen. It says how many files the mirror will delete and copy:

```
Will delete 1.240 files (3,2 GB) and copy 37 files (412,0 MB).
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

Records in `local\runs.csv` that a system backup (made with another program, such as a disk imaging tool) was just written to the partition at `S:`. It asks for confirmation, never copies or deletes anything, and refuses a partition labeled `BACKUP_*`, because that's a mirror drive. See [Recording a system backup](usage_guide.md#recording-a-system-backup---system-done) in the usage guide.

## Generated files

| Location | File | Description |
|----------|------|-------------|
| Source `backup_logs\` | `backup_history.txt` | List of all backup drives with `[NEWEST]`/`[OLDEST]` tags |
| Source `backup_logs\` | `backup_times.txt` | Rolling log of the last 10 backups with timing info |
| Dest `current_backup_logs\` | `robocopy_log.txt` | Full Robocopy technical report |
| Dest `current_backup_logs\` | `backup_summary.txt` | Status, date, errors, timing, and verification result |
| Dest `current_backup_logs\` | `verify_log.txt` | Verification comparison report (only if requested) |
| Dest `current_backup_logs\` | `dry_run_list.txt` | What the dry run listed: files to delete, then files to copy |
| Dest `current_backup_logs\` | `dry_run_log.txt` | Full Robocopy report of the dry run |
| Script folder `local\` | `runs.csv` | One line per mirror run and per recorded system backup |

## The `local\` folder

`local\` sits next to the script and holds what only this computer knows: `runs.csv` (the backup records) and, optionally, `settings.json` (the red warning's thresholds, which RoboBak only reads and never creates). It's ignored by Git, so it's never committed, but `git clean -x` would delete it. To keep the records when you reinstall Windows or move to another computer, copy the whole folder and put it back next to the script. See [The local folder](usage_guide.md#the-local-folder) in the usage guide.

## Tests

The tests run RoboBak against temporary folders, never real drives:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

See [Tests](usage_guide.md#tests) in the usage guide.

## Documentation

See [usage_guide.md](usage_guide.md) for the full documentation, including step-by-step details, Robocopy flags used, how file changes are detected, and what happens if the script is interrupted mid-copy.
