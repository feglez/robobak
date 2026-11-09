# install-reminders.ps1 - Installs or removes RoboBak's reminders.
#
#   .\install-reminders.ps1              creates the Start menu shortcut and the scheduled task
#   .\install-reminders.ps1 -Uninstall   removes both, and asks before deleting local\
#
# It creates only these two things. It never runs a backup.

param([switch]$Uninstall)

$LibPath = Join-Path $PSScriptRoot 'robobak-lib.ps1'
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Host "[ERROR] robobak-lib.ps1 was not found next to install-reminders.ps1 ($PSScriptRoot)." -ForegroundColor Red
    exit 1
}
. $LibPath

if (Test-RoboBakTestMode) {
    Write-Host '[ERROR] ROBOBAK_TEST is set: nothing is installed or removed in test mode.' -ForegroundColor Red
    exit 1
}

$RemindersScript = Join-Path $PSScriptRoot 'robobak-reminders.ps1'
$ShortcutPath    = Join-Path ([Environment]::GetFolderPath('Programs')) $script:ReminderShortcutName
$LocalFolder     = Join-Path $PSScriptRoot 'local'

if ($Uninstall) {
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        Write-Host "Removed the Start menu shortcut: $ShortcutPath" -ForegroundColor Green
    } else {
        Write-Host 'The Start menu shortcut was not there.' -ForegroundColor DarkGray
    }

    $task = Get-ScheduledTask -TaskName $script:ReminderTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        try {
            Unregister-ScheduledTask -TaskName $script:ReminderTaskName -Confirm:$false -ErrorAction Stop
            Write-Host "Removed the scheduled task: $($script:ReminderTaskName)" -ForegroundColor Green
        } catch {
            if (Test-AccessDeniedError $_) {
                Write-Host 'Windows refused to remove the scheduled task (access denied). Open PowerShell as administrator and run .\install-reminders.ps1 -Uninstall again.' -ForegroundColor Red
            } else {
                Write-Host "Could not remove the scheduled task: $($_.Exception.Message)" -ForegroundColor Red
            }
            exit 1
        }
    } else {
        Write-Host 'The scheduled task was not there.' -ForegroundColor DarkGray
    }

    if (Test-Path -LiteralPath $LocalFolder) {
        Write-Host ''
        Write-Host "The folder `"$LocalFolder`" holds your backup records (runs.csv), settings and reminder state." -ForegroundColor Yellow
        Write-Host 'Deleting it loses those records for good.' -ForegroundColor Yellow
        $answer = Read-Host 'Type Y to delete it, anything else to keep it'
        if ($answer -eq 'Y') {
            Remove-Item -LiteralPath $LocalFolder -Recurse -Force
            Write-Host 'Deleted local\.' -ForegroundColor Green
        } else {
            Write-Host 'Kept local\.' -ForegroundColor Green
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $RemindersScript)) {
    Write-Host "[ERROR] robobak-reminders.ps1 was not found next to install-reminders.ps1 ($PSScriptRoot)." -ForegroundColor Red
    exit 1
}

try {
    New-ReminderShortcut -ShortcutPath $ShortcutPath -ScriptPath $RemindersScript
    Write-Host "Created the Start menu shortcut: $ShortcutPath" -ForegroundColor Green
} catch {
    Write-Host "Could not create the Start menu shortcut: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$settings = Read-ReminderSettings $LocalFolder
if ($settings.Warning) { Write-Host "WARNING: $($settings.Warning)" -ForegroundColor Yellow }
$result = Register-ReminderTask -Settings $settings -ScriptPath $RemindersScript
if (-not $result.Ok) {
    Write-Host $result.Message -ForegroundColor Red
    exit 1
}
Write-Host "Created the scheduled task: $($script:ReminderTaskName)" -ForegroundColor Green
Write-Host ''
Write-Host 'Open "RoboBak" from the Start menu to see the status and change the settings.'
