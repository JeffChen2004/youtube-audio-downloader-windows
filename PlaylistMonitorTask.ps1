<#
  Installs and manages the current-user Windows Task Scheduler entry for
  PlaylistMonitor.ps1.  This script never runs the monitor directly.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Remove,
    [switch]$Status,
    [switch]$RunNow,
    [ValidateSet('Interval', 'Daily', 'Weekly')]
    [string]$Mode = 'Interval',
    [ValidateRange(30, 1440)]
    [int]$IntervalMinutes = 60,
    [string]$Time = '',
    [string[]]$Days = @()
)

$ErrorActionPreference = 'Stop'
$TaskName = 'YoutubeAudioDownloader_PlaylistMonitor'
$TaskDescription = 'Automatically checks tracked YouTube playlists and downloads newly added items.'
$MonitorScript = Join-Path $PSScriptRoot 'PlaylistMonitor.ps1'
$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-TaskLine([string]$Message) {
    [Console]::Out.WriteLine($Message)
}

function Get-PlaylistMonitorTask {
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Format-TaskDate($Value) {
    if ($null -eq $Value -or $Value -eq [datetime]::MinValue) { return 'Never' }
    return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss')
}

function ConvertTo-ScheduleTime([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw '-Time 必須使用有效的 24 小時 HH:mm 格式，例如 08:30 或 20:00。'
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "無效的執行時間：$Value"
    }
    return (Get-Date).Date.Add($parsed.TimeOfDay)
}

function ConvertTo-ScheduleDays([string[]]$Values) {
    $allowed = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    $result = [System.Collections.Generic.List[System.DayOfWeek]]::new()
    foreach ($value in @($Values)) {
        foreach ($part in @([string]$value -split ',')) {
            $name = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $canonical = @($allowed | Where-Object { $_ -ieq $name } | Select-Object -First 1)
            if ($canonical.Count -eq 0) {
                throw "無效的星期：$name。允許 Monday 至 Sunday。"
            }
            $day = [System.Enum]::Parse([System.DayOfWeek], [string]$canonical[0], $true)
            if (-not $result.Contains($day)) { $result.Add($day) }
        }
    }
    if ($result.Count -eq 0) { throw 'Weekly mode 至少必須透過 -Days 指定一天。' }
    return $result.ToArray()
}

function Get-TriggerStartTime($Trigger) {
    try { return ([datetime]::Parse([string]$Trigger.StartBoundary)).ToString('HH:mm') }
    catch { return '' }
}

function Get-WeeklyTriggerDays($Trigger) {
    $mask = [int]$Trigger.DaysOfWeek
    $mapping = [ordered]@{
        Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8
        Thursday = 16; Friday = 32; Saturday = 64
    }
    return @($mapping.Keys | Where-Object { ($mask -band $mapping[$_]) -ne 0 })
}

function Get-TaskScheduleInfo($Task) {
    $trigger = $Task.Triggers | Select-Object -First 1
    if (-not $trigger) {
        return [pscustomobject]@{ Mode='Unknown'; Description='Unknown'; IntervalMinutes=''; Time=''; Days=@() }
    }
    $className = [string]$trigger.CimClass.CimClassName
    if ($className -match 'WeeklyTrigger') {
        $time = Get-TriggerStartTime $trigger
        $days = @(Get-WeeklyTriggerDays $trigger)
        return [pscustomobject]@{
            Mode='Weekly'; Description="$(($days -join ', ')) at $time"; IntervalMinutes=''; Time=$time; Days=$days
        }
    }
    if ($className -match 'DailyTrigger') {
        $time = Get-TriggerStartTime $trigger
        return [pscustomobject]@{
            Mode='Daily'; Description="Every day at $time"; IntervalMinutes=''; Time=$time; Days=@()
        }
    }
    $intervalValue = $trigger.Repetition.Interval
    if ($intervalValue) {
        try {
            $span = if ($intervalValue -is [timespan]) { $intervalValue } else { [System.Xml.XmlConvert]::ToTimeSpan([string]$intervalValue) }
            $minutes = [int]$span.TotalMinutes
            return [pscustomobject]@{
                Mode='Interval'; Description="Every $minutes minutes"; IntervalMinutes=$minutes; Time=''; Days=@()
            }
        } catch { }
    }
    return [pscustomobject]@{ Mode='Unknown'; Description='Unknown'; IntervalMinutes=''; Time=''; Days=@() }
}

function Show-PlaylistMonitorTaskStatus {
    $task = Get-PlaylistMonitorTask
    Write-TaskLine "Task: $TaskName"
    if (-not $task) {
        Write-TaskLine 'Installed: No'
        Write-TaskLine 'Enabled: No'
        Write-TaskLine 'Schedule Mode: N/A'
        Write-TaskLine 'Schedule: N/A'
        Write-TaskLine 'Schedule Interval Minutes: N/A'
        Write-TaskLine 'Schedule Time: N/A'
        Write-TaskLine 'Schedule Days: N/A'
        Write-TaskLine 'Last Run: Never'
        Write-TaskLine 'Last Result: N/A'
        Write-TaskLine 'Next Run: Never'
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $schedule = Get-TaskScheduleInfo $task
    $neverRun = ($info.LastTaskResult -eq 267011 -or $info.LastRunTime.Year -lt 2000)
    Write-TaskLine 'Installed: Yes'
    Write-TaskLine ("Enabled: " + $(if ($task.State -eq 'Disabled') { 'No' } else { 'Yes' }))
    Write-TaskLine "Schedule Mode: $($schedule.Mode)"
    Write-TaskLine "Schedule: $($schedule.Description)"
    Write-TaskLine "Schedule Interval Minutes: $(if ($schedule.IntervalMinutes) { $schedule.IntervalMinutes } else { 'N/A' })"
    Write-TaskLine "Schedule Time: $(if ($schedule.Time) { $schedule.Time } else { 'N/A' })"
    Write-TaskLine "Schedule Days: $(if ($schedule.Days.Count) { $schedule.Days -join ',' } else { 'N/A' })"
    Write-TaskLine ("Last Run: " + $(if ($neverRun) { 'Never' } else { Format-TaskDate $info.LastRunTime }))
    Write-TaskLine ("Last Result: " + $(if ($neverRun) { 'Never run' } else { [string]$info.LastTaskResult }))
    Write-TaskLine "Next Run: $(Format-TaskDate $info.NextRunTime)"
}

function Install-PlaylistMonitorTask {
    if (-not (Test-Path -LiteralPath $MonitorScript -PathType Leaf)) { throw "找不到 PlaylistMonitor.ps1：$MonitorScript" }
    if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) { throw "找不到 Windows PowerShell 5.1：$WindowsPowerShell" }
    $absoluteMonitorPath = (Resolve-Path -LiteralPath $MonitorScript).Path
    $currentAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($currentAccount)) { throw '無法判斷目前 Windows 使用者帳號。' }

    $existing = Get-PlaylistMonitorTask
    if ($existing) {
        Write-TaskLine '[Task] Existing task found'
        Write-TaskLine '[Task] Updating configuration'
    } else {
        Write-TaskLine '[Task] Creating task'
    }

    $actionArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -CheckAll' -f $absoluteMonitorPath.Replace('"', '\"')
    $action = New-ScheduledTaskAction -Execute $WindowsPowerShell -Argument $actionArguments
    $scheduleDescription = ''
    switch ($Mode) {
        'Interval' {
            $firstRun = (Get-Date).AddMinutes($IntervalMinutes)
            $trigger = New-ScheduledTaskTrigger -Once -At $firstRun -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
            $scheduleDescription = "Every $IntervalMinutes minutes"
        }
        'Daily' {
            $at = ConvertTo-ScheduleTime $Time
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
            $scheduleDescription = "Every day at $($at.ToString('HH:mm'))"
        }
        'Weekly' {
            $at = ConvertTo-ScheduleTime $Time
            $validatedDays = @(ConvertTo-ScheduleDays $Days)
            $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $validatedDays -At $at
            $scheduleDescription = "$($validatedDays -join ', ') at $($at.ToString('HH:mm'))"
        }
    }
    $principal = New-ScheduledTaskPrincipal -UserId $currentAccount -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 10) `
        -WakeToRun:$false
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $TaskDescription
    Register-ScheduledTask -TaskName $TaskName -InputObject $definition -Force | Out-Null
    Write-TaskLine '[Task] Installed successfully'
    Write-TaskLine "[Task] Account: $currentAccount"
    Write-TaskLine '[Task] Logon mode: Interactive (only while the user is logged on)'
    Write-TaskLine "[Task] Schedule mode: $Mode"
    Write-TaskLine "[Task] Schedule: $scheduleDescription"
    Write-TaskLine "[Task] Action: $WindowsPowerShell $actionArguments"
}

function Remove-PlaylistMonitorTask {
    $task = Get-PlaylistMonitorTask
    if (-not $task) {
        Write-TaskLine '[Task] Task is not installed'
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-TaskLine "[Task] Removed: $TaskName"
    Write-TaskLine '[Task] Tracker JSON, archives, logs, cookies, extension, and Native Messaging host were not changed.'
}

function Start-PlaylistMonitorTask {
    if (-not (Get-PlaylistMonitorTask)) { throw "Task 尚未安裝：$TaskName" }
    Start-ScheduledTask -TaskName $TaskName
    Write-TaskLine "[Task] RunNow requested through Task Scheduler: $TaskName"
}

$operationCount = @(@($Install, $Remove, $Status, $RunNow) | Where-Object { [bool]$_ }).Count
if ($operationCount -ne 1) {
    [Console]::Error.WriteLine('請指定且只指定一個操作：-Install、-Remove、-Status 或 -RunNow。')
    exit 2
}

try {
    if ($Install) { Install-PlaylistMonitorTask }
    elseif ($Remove) { Remove-PlaylistMonitorTask }
    elseif ($Status) { Show-PlaylistMonitorTaskStatus }
    elseif ($RunNow) { Start-PlaylistMonitorTask }
    exit 0
} catch {
    [Console]::Error.WriteLine("[Task] Error: $($_.Exception.Message)")
    exit 1
}
