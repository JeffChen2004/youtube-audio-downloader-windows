<#
  Headless entry point for tracked playlist checks.
  Intended for manual CLI use and a future Windows Task Scheduler job.
#>

[CmdletBinding()]
param(
    [switch]$CheckAll
)

$ErrorActionPreference = 'Stop'
$MonitorRoot = $PSScriptRoot
$TrackerModule = Join-Path $MonitorRoot 'PlaylistTracker.ps1'
$DownloaderScript = Join-Path $MonitorRoot 'YoutubeAudioDownloader.ps1'
$TrackedStateRoot = Join-Path $MonitorRoot 'data\tracked-playlists'
$MonitorLogRoot = Join-Path $MonitorRoot 'logs\playlist-monitor'
$MutexName = 'Global\YoutubeAudioDownloader_PlaylistMonitor'
$Script:MonitorLogPath = ''

function ConvertTo-MonitorProcessArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\*)$', '$1$1')
    return '"' + $escaped + '"'
}

function Write-MonitorLine([string]$Message, [bool]$AlreadyTimestamped = $false) {
    $line = if ($AlreadyTimestamped) { $Message } else { "[$(Get-Date -Format 'HH:mm:ss')] $Message" }
    [Console]::Out.WriteLine($line)
    if (-not [string]::IsNullOrWhiteSpace($Script:MonitorLogPath)) {
        [System.IO.File]::AppendAllText($Script:MonitorLogPath, $line + "`r`n", [System.Text.UTF8Encoding]::new($false))
    }
}

function New-MonitorLogFile {
    New-Item -ItemType Directory -Force -Path $MonitorLogRoot | Out-Null
    $baseName = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $path = Join-Path $MonitorLogRoot ($baseName + '.log')
    $suffix = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $MonitorLogRoot ("$baseName-$suffix.log")
        $suffix++
    }
    [System.IO.File]::WriteAllText($path, '', [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-HeadlessPowerShellExecutable {
    # Windows PowerShell 5.1 lazily resolves the WinForms type literals that
    # belong to the GUI-only branch of YoutubeAudioDownloader.ps1.  pwsh loads
    # that assembly while compiling the complete file even when the branch is
    # never executed.  Always using the built-in Windows worker therefore
    # guarantees the headless worker neither loads nor constructs WinForms,
    # while PlaylistMonitor.ps1 itself remains callable from powershell or pwsh.
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "找不到 headless Windows PowerShell worker：$path"
    }
    return $path
}

function Invoke-MonitorPlaylistWorker([string]$ConfigPath) {
    $resultPath = [System.IO.Path]::GetTempFileName()
    try {
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $DownloaderScript,
            '-HeadlessTrackedConfig', $ConfigPath,
            '-HeadlessResultPath', $resultPath
        )
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Get-HeadlessPowerShellExecutable
        $startInfo.WorkingDirectory = $MonitorRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-MonitorProcessArgument $_ }) -join ' ')
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw '無法啟動 headless playlist worker。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        foreach ($line in @($stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { Write-MonitorLine $line $true }
        foreach ($line in @($stderr -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { Write-MonitorLine "[Worker stderr] $line" }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            return [pscustomobject]@{ Success=$false; NewVideosDownloaded=0; NoChange=$false; Reason="worker 未產生結果（exit code $($process.ExitCode)）" }
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ([bool]$result.winforms_loaded) {
            return [pscustomobject]@{ Success=$false; NewVideosDownloaded=0; NoChange=$false; Reason='Headless worker 意外載入 WinForms。' }
        }
        $success = ($process.ExitCode -eq 0 -and [bool]$result.success)
        return [pscustomobject]@{
            Success = $success
            NewVideosDownloaded = [int]$result.new_videos_downloaded
            NoChange = ($success -and [bool]$result.no_change)
            Reason = if ($success) { '' } elseif (-not [string]::IsNullOrWhiteSpace([string]$result.reason)) { [string]$result.reason } else { "worker exit code $($process.ExitCode)" }
        }
    } catch {
        return [pscustomobject]@{ Success=$false; NewVideosDownloaded=0; NoChange=$false; Reason=$_.Exception.Message }
    } finally {
        if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
    }
}

$monitorExitCode = 2
$mutex = $null
$mutexAcquired = $false
try {
    $mutex = [System.Threading.Mutex]::new($false, $MutexName)
    try { $mutexAcquired = $mutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }

    if (-not $mutexAcquired) {
        [Console]::Out.WriteLine('[Monitor] Another instance is already running. Exiting.')
        $monitorExitCode = 0
    } else {
        if (-not $CheckAll) { throw '請指定 -CheckAll。' }
        if (-not (Test-Path -LiteralPath $TrackerModule -PathType Leaf)) { throw "找不到 tracker module：$TrackerModule" }
        if (-not (Test-Path -LiteralPath $DownloaderScript -PathType Leaf)) { throw "找不到 downloader：$DownloaderScript" }
        $Script:MonitorLogPath = New-MonitorLogFile
        Write-MonitorLine '[Monitor] Started'
        . $TrackerModule
        Initialize-PlaylistTrackerStorage $MonitorRoot
        if (-not (Test-Path -LiteralPath $TrackedStateRoot -PathType Container)) {
            throw "tracked playlist state path 不是可讀取的資料夾：$TrackedStateRoot"
        }
        # Force an enumerability/read check before a run is considered initialized.
        [void]@(Get-ChildItem -LiteralPath $TrackedStateRoot -Force -ErrorAction Stop)

        $configurationItems = @(Get-TrackedPlaylistConfigurations)
        $configurationErrors = @($configurationItems | Where-Object { -not $_.Configuration })
        if ($configurationErrors.Count -gt 0) {
            foreach ($item in $configurationErrors) {
                Write-MonitorLine "[Monitor] Invalid tracker configuration: $([System.IO.Path]::GetFileName($item.Path))"
                Write-MonitorLine "[Monitor] Reason: $($item.Error)"
            }
        }
        $enabledItems = @($configurationItems | Where-Object { [bool]$_.Configuration.enabled })
        Write-MonitorLine "[Monitor] Enabled playlists: $($enabledItems.Count)"

        $checked = 0
        $succeeded = 0
        $failed = $configurationErrors.Count
        $newVideos = 0
        $noChange = 0
        foreach ($item in $enabledItems) {
            $checked++
            $result = Invoke-MonitorPlaylistWorker $item.Path
            if ($result.Success) {
                $succeeded++
                $newVideos += $result.NewVideosDownloaded
                if ($result.NoChange) { $noChange++ }
            } else {
                $failed++
                Write-MonitorLine "[Monitor] Playlist failed: $($item.Configuration.playlist_title): $($result.Reason)"
            }
        }

        Write-MonitorLine '=============================='
        Write-MonitorLine 'Playlist Monitor Summary'
        Write-MonitorLine '=============================='
        Write-MonitorLine "Enabled playlists: $($enabledItems.Count)"
        Write-MonitorLine "Checked: $checked"
        Write-MonitorLine "Succeeded: $succeeded"
        Write-MonitorLine "Failed: $failed"
        Write-MonitorLine "New videos downloaded: $newVideos"
        Write-MonitorLine "No-change playlists: $noChange"
        Write-MonitorLine "Invalid configurations: $($configurationErrors.Count)"
        Write-MonitorLine '=============================='
        Write-MonitorLine '[Monitor] Completed'
        $monitorExitCode = if ($failed -gt 0) { 1 } else { 0 }
    }
} catch {
    $message = "[Monitor] Initialization failed: $($_.Exception.Message)"
    if ($Script:MonitorLogPath) { Write-MonitorLine $message } else { [Console]::Error.WriteLine($message) }
    $monitorExitCode = 2
} finally {
    if ($mutexAcquired -and $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($mutex) { $mutex.Dispose() }
}

exit $monitorExitCode
