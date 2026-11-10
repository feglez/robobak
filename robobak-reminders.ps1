# robobak-reminders.ps1 - The RoboBak window and the reminders' check.
#
#   .\robobak-reminders.ps1          opens the status and settings window
#   .\robobak-reminders.ps1 -Check   looks at what's due and may show a notification
#
# The scheduled task created by install-reminders.ps1 runs -Check. It only reads
# local\runs.csv and remembers when it last notified; it never starts a backup.

param(
    [switch]$Check,
    [switch]$TestBuild   # test mode only: builds the window without showing it
)

$LibPath = Join-Path $PSScriptRoot 'robobak-lib.ps1'
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Host "[ERROR] robobak-lib.ps1 was not found next to robobak-reminders.ps1 ($PSScriptRoot)."
    exit 1
}
. $LibPath

$TestMode = Test-RoboBakTestMode
if ($TestMode) { $null = Get-RoboBakTestMap }
$LocalDir = Get-RoboBakLocalDir $PSScriptRoot

# --- CHECK MODE ---

# Show-ReminderToast: a standard Windows notification, sent as the Start menu
# shortcut's application ID, so its sender reads "RoboBak".
function Show-ReminderToast {
    param([string]$Xml)
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
    $document = New-Object Windows.Data.Xml.Dom.XmlDocument
    $document.LoadXml($Xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $document
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:ReminderAppId).Show($toast)
}

if ($Check) {
    try {
        $settings = Read-ReminderSettings $LocalDir
        $now = Get-Date
        $status = Get-ReminderStatus -Records (Read-RunRecords $LocalDir) -Settings $settings -Now $now
        $decision = Get-ReminderDecision -Settings $settings -Status $status -Locked (Test-ReminderLocked $LocalDir) -LastNotification (Read-ReminderState $LocalDir) -Now $now
        if ($decision.Action -ne 'notify') {
            Write-Host "RoboBak check: $($decision.Action)."
            exit 0
        }
        if ($TestMode) {
            Write-Host "TEST MODE: would notify: $($decision.Title)"
            foreach ($line in $decision.Lines) { Write-Host "TEST MODE: $line" }
        } else {
            Show-ReminderToast (Get-ReminderToastXml -Title $decision.Title -Lines $decision.Lines)
        }
        Save-ReminderState $LocalDir $now
        Write-Host 'RoboBak check: notified.'
        exit 0
    } catch {
        Write-Host "RoboBak check failed: $($_.Exception.Message)"
        exit 1
    }
}

# --- THE WINDOW ---

# Must come before any window exists, or Windows stretches it on scaled displays.
Add-Type -Namespace RoboBak -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
$null = [RoboBak.Dpi]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-WindowLabel {
    param([string]$Text = '')
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $label.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 5)
    return $label
}

function New-WindowTable {
    param([int]$Columns)
    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.ColumnCount = $Columns
    $table.AutoSize = $true
    $table.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $table.Dock = [System.Windows.Forms.DockStyle]::Fill
    return $table
}

function New-WindowGroup {
    param([string]$Title, $Content)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Title
    $group.AutoSize = $true
    $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $group.Dock = [System.Windows.Forms.DockStyle]::Fill
    $group.Padding = New-Object System.Windows.Forms.Padding(8)
    $group.Controls.Add($Content)
    return $group
}

# New-StatusPanel: the status of one kind of backup, and its Skip button.
function New-StatusPanel {
    param([string]$Title, [string]$Kind)
    $table = New-WindowTable 2
    $panel = @{ Kind = $Kind; LastDone = New-WindowLabel; LastSkipped = New-WindowLabel; NextDue = New-WindowLabel; Drive = New-WindowLabel }
    $rows = @(@('Last done:', $panel.LastDone), @('Last skipped:', $panel.LastSkipped), @('Next due:', $panel.NextDue))
    if ($Kind -eq 'mirror') { $rows += , @('Suggested drive:', $panel.Drive) }
    foreach ($row in $rows) {
        $table.Controls.Add((New-WindowLabel $row[0]))
        $table.Controls.Add($row[1])
    }
    $skip = New-Object System.Windows.Forms.Button
    $skip.Text = 'Skip'
    $skip.AutoSize = $true
    $skip.Tag = $Kind
    $skip.Add_Click({ param($sender, $e) Invoke-SkipClick $sender.Tag })
    $table.Controls.Add($skip)
    $panel.Skip = $skip
    $panel.Group = New-WindowGroup $Title $table
    return $panel
}

function Format-WindowDate {
    param($Date, [string]$WhenNone)
    if ($null -eq $Date) { return $WhenNone }
    return $Date.ToString('yyyy-MM-dd')
}

# Update-StatusPanel: fills one panel. Without a record: "never recorded". With
# an interval of 0, the next one reads "off".
function Update-StatusPanel {
    param($Panel, $Item)
    $Panel.LastDone.Text = if ($null -ne $Item.LastDone) { "$(Format-WindowDate $Item.LastDone '') ($(Format-ReminderAge $Item.AgeDays))" } else { 'never recorded' }
    $Panel.LastSkipped.Text = Format-WindowDate $Item.LastSkipped 'never'
    if ($Item.Off) { $Panel.NextDue.Text = 'off' }
    elseif ($null -eq $Item.NextDue) { $Panel.NextDue.Text = 'now' }
    elseif ($Item.Due) { $Panel.NextDue.Text = "$(Format-WindowDate $Item.NextDue '') (due)" }
    else { $Panel.NextDue.Text = Format-WindowDate $Item.NextDue '' }
    if ($Item.Kind -eq 'mirror') {
        $Panel.Drive.Text = if ($Item.SuggestedDrive) { [string]$Item.SuggestedDrive } else { 'none recorded yet' }
    }
    $Panel.Skip.Enabled = [bool]$Item.Due
}

function Update-ReminderWindow {
    $script:Records = @(Read-RunRecords $LocalDir)
    $status = Get-ReminderStatus -Records $script:Records -Settings (Read-ReminderSettings $LocalDir)
    Update-StatusPanel $script:SystemPanel $status.System
    Update-StatusPanel $script:MirrorPanel $status.Mirror
}

function Show-WindowError {
    param([string]$Text)
    if ($TestBuild) { Write-Host "ERROR: $Text"; return }
    $null = [System.Windows.Forms.MessageBox]::Show($Text, 'RoboBak', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Invoke-SkipClick {
    param([string]$Kind)
    try {
        $null = Add-SkipRecord -LocalDir $LocalDir -Kind $Kind -Records $script:Records
    } catch {
        Show-WindowError "Could not record the skip: $($_.Exception.Message)"
    }
    Update-ReminderWindow
}

function Invoke-SaveClick {
    $ui = $script:SettingsUi
    $settings = [pscustomobject]@{
        Enabled = $ui.Enabled.Checked; SystemDays = [int]$ui.SystemDays.Value; MirrorDays = [int]$ui.MirrorDays.Value; GapHours = [int]$ui.GapHours.Value
        TriggerLogon = $ui.Logon.Checked; TriggerUnlock = $ui.Unlock.Checked; TriggerDaily = $ui.Daily.Checked
        DailyTime = $ui.Time.Value.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    try {
        Save-ReminderSettings $LocalDir $settings
    } catch {
        Show-WindowError "The settings were not saved: $($_.Exception.Message)"
        return
    }
    $result = Register-ReminderTask -Settings $settings -ScriptPath $PSCommandPath
    $script:SettingsUi.Result.Text = if ($result.Ok) { 'Saved.' } else { 'Settings saved, but the task was not updated.' }
    if (-not $result.Ok -and -not $TestMode) { Show-WindowError $result.Message }
    Update-ReminderWindow
}

function New-NumberBox {
    param([decimal]$Value, [decimal]$Minimum, [decimal]$Maximum)
    $box = New-Object System.Windows.Forms.NumericUpDown
    $box.Minimum = $Minimum
    $box.Maximum = $Maximum
    $box.Value = [math]::Min($Maximum, [math]::Max($Minimum, $Value))
    return $box
}

function New-CheckBox {
    param([string]$Text, [bool]$Checked)
    $box = New-Object System.Windows.Forms.CheckBox
    $box.Text = $Text
    $box.AutoSize = $true
    $box.Checked = $Checked
    return $box
}

# New-SettingsGroup: reminders on or off, the intervals, the gap and the triggers.
function New-SettingsGroup {
    param($Settings)
    $table = New-WindowTable 2
    $ui = @{
        Enabled = New-CheckBox 'Reminders on' $Settings.Enabled
        SystemDays = New-NumberBox $Settings.SystemDays 0 365
        MirrorDays = New-NumberBox $Settings.MirrorDays 0 365
        GapHours = New-NumberBox $Settings.GapHours 0 720
        Logon = New-CheckBox 'Check at sign-in' $Settings.TriggerLogon
        Unlock = New-CheckBox 'Check when the screen is unlocked' $Settings.TriggerUnlock
        Daily = New-CheckBox 'Check every day at:' $Settings.TriggerDaily
        Time = New-Object System.Windows.Forms.DateTimePicker
        Result = New-WindowLabel
    }
    $ui.Time.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
    $ui.Time.CustomFormat = 'HH:mm'
    $ui.Time.ShowUpDown = $true
    $ui.Time.Value = [datetime]::ParseExact($Settings.DailyTime, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)

    $table.Controls.Add($ui.Enabled); $table.SetColumnSpan($ui.Enabled, 2)
    foreach ($row in @(@('System backup every (days, 0 = off):', $ui.SystemDays), @('Mirror every (days, 0 = off):', $ui.MirrorDays), @('At most one notification every (hours):', $ui.GapHours))) {
        $table.Controls.Add((New-WindowLabel $row[0]))
        $table.Controls.Add($row[1])
    }
    $table.Controls.Add($ui.Logon); $table.SetColumnSpan($ui.Logon, 2)
    $table.Controls.Add($ui.Unlock); $table.SetColumnSpan($ui.Unlock, 2)
    $table.Controls.Add($ui.Daily)
    $table.Controls.Add($ui.Time)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.AutoSize = $true
    $save.Add_Click({ Invoke-SaveClick })
    $table.Controls.Add($save)
    $table.Controls.Add($ui.Result)
    $script:SettingsUi = $ui
    return (New-WindowGroup 'Settings' $table)
}

$settingsRead = Read-ReminderSettings $LocalDir
$form = New-Object System.Windows.Forms.Form
$form.Text = 'RoboBak'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoSize = $true
$form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Padding = New-Object System.Windows.Forms.Padding(8)

$script:SystemPanel = New-StatusPanel 'System backup' 'system'
$script:MirrorPanel = New-StatusPanel 'Mirror' 'mirror'
$settingsGroup = New-SettingsGroup $settingsRead

$root = New-WindowTable 1
$root.Controls.Add($script:SystemPanel.Group)
$root.Controls.Add($script:MirrorPanel.Group)
$root.Controls.Add($settingsGroup)
$form.Controls.Add($root)

Update-ReminderWindow

if ($TestBuild) {
    if (-not $TestMode) {
        Write-Host '[ERROR] -TestBuild only works in test mode.'
        $form.Dispose()
        exit 1
    }
    foreach ($panel in @($script:SystemPanel, $script:MirrorPanel)) {
        Write-Host "PANEL $($panel.Kind): done=$($panel.LastDone.Text) | skipped=$($panel.LastSkipped.Text) | next=$($panel.NextDue.Text) | drive=$($panel.Drive.Text) | skip=$($panel.Skip.Enabled)"
    }
    Write-Host "SETTINGS: on=$($script:SettingsUi.Enabled.Checked) system=$($script:SettingsUi.SystemDays.Value) mirror=$($script:SettingsUi.MirrorDays.Value) gap=$($script:SettingsUi.GapHours.Value) time=$($script:SettingsUi.Time.Value.ToString('HH:mm'))"
    Invoke-SkipClick 'mirror'
    Write-Host "AFTER SKIP: skipped=$($script:MirrorPanel.LastSkipped.Text) | skip=$($script:MirrorPanel.Skip.Enabled)"
    Invoke-SaveClick
    Write-Host "AFTER SAVE: $($script:SettingsUi.Result.Text)"
    $form.Dispose()
    exit 0
}

if ($settingsRead.Warning) { Show-WindowError $settingsRead.Warning }
[System.Windows.Forms.Application]::Run($form)
