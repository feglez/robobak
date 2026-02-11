# RoboBak

A PowerShell script that creates exact mirror backups of one drive onto another using Robocopy. Includes safety checks to prevent accidental data loss, progress tracking, verification, and backup history management.

## Features

- **Mirror backup** — destination becomes an exact copy of the source (extra files on destination are deleted)
- **Safety checks** — destination drive must be labeled `BACKUP_*` to prevent wiping the wrong drive; warns if the destination is too small
- **Optional verification** — compares source and destination after the backup to confirm integrity
- **Progress bar** — optional real-time progress indicator during the copy
- **Backup history** — tracks all backup drives on the source, marking the newest and oldest
- **Timing log** — rolling log of the last 10 backups with durations
- **Detailed logging** — full Robocopy report, summary with errors, and verification report on the destination

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (included with Windows 10/11)

## Quick start

1. Rename your backup drive so its label starts with `BACKUP_` (e.g. `BACKUP_1`)
2. Run:

```powershell
.\robobak.ps1 F E
```

Where `F` is the source drive and `E` is the destination.

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

## Generated files

| Location | File | Description |
|----------|------|-------------|
| Source `backup_logs\` | `backup_history.txt` | List of all backup drives with `[NEWEST]`/`[OLDEST]` tags |
| Source `backup_logs\` | `backup_times.txt` | Rolling log of the last 10 backups with timing info |
| Dest `current_backup_logs\` | `robocopy_log.txt` | Full Robocopy technical report |
| Dest `current_backup_logs\` | `backup_summary.txt` | Status, date, errors, timing, and verification result |
| Dest `current_backup_logs\` | `verify_log.txt` | Verification comparison report (only if requested) |

## Documentation

See [usage_guide.md](usage_guide.md) for the full documentation, including step-by-step details, Robocopy flags used, how file changes are detected, and what happens if the script is interrupted mid-copy.
