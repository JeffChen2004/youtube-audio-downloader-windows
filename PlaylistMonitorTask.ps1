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
    [ValidateRange(30, 1440)]
    [int]$IntervalMinutes = 60
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

function Show-PlaylistMonitorTaskStatus {
    $task = Get-PlaylistMonitorTask
    Write-TaskLine "Task: $TaskName"
    if (-not $task) {
        Write-TaskLine 'Installed: No'
        Write-TaskLine 'Enabled: No'
        Write-TaskLine 'Last Run: Never'
        Write-TaskLine 'Last Result: N/A'
        Write-TaskLine 'Next Run: Never'
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $neverRun = ($info.LastTaskResult -eq 267011 -or $info.LastRunTime.Year -lt 2000)
    Write-TaskLine 'Installed: Yes'
    Write-TaskLine ("Enabled: " + $(if ($task.State -eq 'Disabled') { 'No' } else { 'Yes' }))
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
    $firstRun = (Get-Date).AddMinutes($IntervalMinutes)
    $trigger = New-ScheduledTaskTrigger -Once -At $firstRun -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
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
    Write-TaskLine "[Task] Interval: $IntervalMinutes minute(s)"
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
