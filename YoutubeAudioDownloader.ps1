<#
  YouTube Audio Downloader (Windows)
  Downloads publicly accessible / account-authorized audio using yt-dlp and FFmpeg.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('YtAudioDownloader.LoggedProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace YtAudioDownloader {
    public sealed class LoggedProcess {
        public ConcurrentQueue<string> Lines { get; private set; }
        public ConcurrentQueue<string> OutputLines { get; private set; }
        public ConcurrentQueue<string> ErrorLines { get; private set; }
        public Process Process { get; private set; }

        public LoggedProcess() {
            Lines = new ConcurrentQueue<string>();
            OutputLines = new ConcurrentQueue<string>();
            ErrorLines = new ConcurrentQueue<string>();
        }

        public void Start(ProcessStartInfo startInfo) {
            Process = new Process();
            Process.StartInfo = startInfo;
            Process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) { Lines.Enqueue(e.Data); OutputLines.Enqueue(e.Data); }
            };
            Process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) { Lines.Enqueue(e.Data); ErrorLines.Enqueue(e.Data); }
            };
            Process.Start();
            Process.BeginOutputReadLine();
            Process.BeginErrorReadLine();
        }
    }
}
'@
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsRoot = Join-Path $AppRoot 'tools'
$OutputRoot = Join-Path $AppRoot 'downloads'
$YtDlp = Join-Path $ToolsRoot 'yt-dlp.exe'
$Ffmpeg = Join-Path $ToolsRoot 'ffmpeg.exe'
$Deno = Join-Path $ToolsRoot 'deno.exe'
$PoTokenRoot = Join-Path $ToolsRoot 'po-token-provider'
$PoTokenProviderRoot = Join-Path $PoTokenRoot 'bgutil-ytdlp-pot-provider'
$PoTokenPluginRoot = Join-Path $ToolsRoot 'yt-dlp-plugins'
$PoTokenPluginZip = Join-Path $PoTokenPluginRoot 'bgutil-ytdlp-pot-provider.zip'
$Script:ActiveProcess = $null
$Script:LastPoTokenSetupLines = @()
$Script:PoTokenProviderProcess = $null

function Write-Log([string]$Message) {
    $log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ProcessStartInfo.ArgumentList only exists in PowerShell 7/.NET Core.  This
# quotes an argument according to the Windows command-line parsing rules so the
# tool also runs on the Windows-built-in PowerShell 5.1.
function ConvertTo-ProcessArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\*)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-CapturedProcess([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory = $AppRoot) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName; $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $process = [YtAudioDownloader.LoggedProcess]::new(); $process.Start($psi)
    while (-not $process.Process.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
    $process.Process.WaitForExit()
    $stdout = [System.Collections.Generic.List[string]]::new(); $stderr = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($process.OutputLines.TryDequeue([ref]$line)) { $stdout.Add($line) }
    $line = $null; while ($process.ErrorLines.TryDequeue([ref]$line)) { $stderr.Add($line) }
    return [pscustomobject]@{ ExitCode = $process.Process.ExitCode; CommandLine = $psi.Arguments; Stdout = @($stdout); Stderr = @($stderr) }
}

function Protect-PoTokenLogLine([string]$Line) {
    if ($null -eq $Line) { return '' }
    # Provider output must be useful for diagnostics without persisting a PO token.
    return [regex]::Replace($Line, '(?i)((?:po[_ -]?token|pot|token)\s*(?:=|:|is)\s*)[^\s,;\]\}]+', '$1[REDACTED]')
}

function Ensure-PoTokenProvider {
    $setupLines = [System.Collections.Generic.List[string]]::new()
    $Script:LastPoTokenSetupLines = @()
    try {
        New-Item -ItemType Directory -Force -Path $PoTokenRoot, $PoTokenPluginRoot | Out-Null
        $serverRoot = Join-Path $PoTokenProviderRoot 'server'
        if (-not (Test-Path -LiteralPath (Join-Path $serverRoot 'src\main.ts') -PathType Leaf)) {
            $git = Get-Command git -ErrorAction SilentlyContinue
            if (-not $git) { throw '找不到 Git，無法安裝 bgutil-ytdlp-pot-provider。' }
            Write-Log '[PO Token] 正在取得官方 featured bgutil provider…'
            $clone = Invoke-CapturedProcess $git.Source @('clone', '--depth', '1', 'https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git', $PoTokenProviderRoot) $PoTokenRoot
            $setupLines.Add("Provider clone exit code: $($clone.ExitCode)")
            foreach ($line in $clone.Stdout) { $setupLines.Add("[clone stdout] $(Protect-PoTokenLogLine $line)") }
            foreach ($line in $clone.Stderr) { $setupLines.Add("[clone stderr] $(Protect-PoTokenLogLine $line)") }
            if ($clone.ExitCode -ne 0) { throw "bgutil provider clone 失敗（exit code $($clone.ExitCode)）。" }
        }
        if (-not (Test-Path -LiteralPath $PoTokenPluginZip -PathType Leaf)) {
            Write-Log '[PO Token] 正在下載 bgutil yt-dlp plugin…'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/latest/download/bgutil-ytdlp-pot-provider.zip' -OutFile $PoTokenPluginZip
            $setupLines.Add('Plugin ZIP downloaded from the provider latest release.')
        }
        $nodeModules = Join-Path $serverRoot 'node_modules'
        if (-not (Test-Path -LiteralPath $nodeModules -PathType Container)) {
            Write-Log '[PO Token] 正在準備 bgutil Deno provider 依賴…'
            $denoInstall = Invoke-CapturedProcess $Deno @('install', '--allow-scripts=npm:canvas', '--frozen') $serverRoot
            $setupLines.Add("Deno install exit code: $($denoInstall.ExitCode)")
            foreach ($line in $denoInstall.Stdout) { $setupLines.Add("[deno stdout] $(Protect-PoTokenLogLine $line)") }
            foreach ($line in $denoInstall.Stderr) { $setupLines.Add("[deno stderr] $(Protect-PoTokenLogLine $line)") }
            if ($denoInstall.ExitCode -ne 0) { throw "bgutil Deno provider 安裝失敗（exit code $($denoInstall.ExitCode)）。" }
        }
        $serverReady = $false
        try { $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', 4416); $client.Dispose(); $serverReady = $true } catch { }
        if (-not $serverReady) {
            Write-Log '[PO Token] 正在啟動 localhost bgutil HTTP provider…'
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $Deno; $psi.WorkingDirectory = $nodeModules; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $providerArgs = @('run', '--no-prompt', '--allow-env', '--allow-net', '--allow-ffi=.', '--allow-read=.', '../src/main.ts')
            $psi.Arguments = (($providerArgs | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
            $setupLines.Add("Provider executable: $Deno")
            $setupLines.Add("Provider working directory: $nodeModules")
            $setupLines.Add("Provider arguments: $($psi.Arguments)")
            $providerProcess = [YtAudioDownloader.LoggedProcess]::new(); $providerProcess.Start($psi); $Script:PoTokenProviderProcess = $providerProcess
            $startupWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $nextUpdate = 10
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline -and -not $serverReady -and -not $providerProcess.Process.HasExited) {
                Start-Sleep -Milliseconds 250; [System.Windows.Forms.Application]::DoEvents()
                $client = [System.Net.Sockets.TcpClient]::new()
                try {
                    $connect = $client.ConnectAsync('127.0.0.1', 4416)
                    if ($connect.Wait(100)) { $serverReady = $client.Connected }
                } catch { } finally { $client.Dispose() }
                $line = $null
                while ($providerProcess.Lines.TryDequeue([ref]$line)) { $setupLines.Add("[provider] $(Protect-PoTokenLogLine $line)") }
                if ($startupWatch.Elapsed.TotalSeconds -ge $nextUpdate -and -not $serverReady) {
                    Write-Log "[PO Token] Provider 啟動中，已等待 $([int]$startupWatch.Elapsed.TotalSeconds) 秒（上限 120 秒）…"
                    $nextUpdate += 10
                }
            }
            $line = $null
            while ($providerProcess.Lines.TryDequeue([ref]$line)) { $setupLines.Add("[provider] $(Protect-PoTokenLogLine $line)") }
            if (-not $serverReady) {
                $exitDetail = if ($providerProcess.Process.HasExited) { "exit code $($providerProcess.Process.ExitCode)" } else { 'startup timed out' }
                if (-not $providerProcess.Process.HasExited) { $providerProcess.Process.Kill() }
                $providerProcess.Process.WaitForExit()
                $setupLines.Add("Provider status: $exitDetail; ProcessExitCode: $($providerProcess.Process.ExitCode); elapsed: $([int]$startupWatch.Elapsed.TotalSeconds)s")
                foreach ($stream in @('OutputLines', 'ErrorLines')) {
                    $line = $null
                    while ($providerProcess.$stream.TryDequeue([ref]$line)) { $setupLines.Add("[provider $stream] $(Protect-PoTokenLogLine $line)") }
                }
                $Script:PoTokenProviderProcess = $null
                throw "bgutil HTTP provider 未能在 localhost:4416 啟動（$exitDetail）。"
            }
        }
        $setupLines.Add('bgutil HTTP provider ready at http://127.0.0.1:4416 (localhost only).')
        return [pscustomobject]@{ PluginRoot = $PoTokenPluginRoot; BaseUrl = 'http://127.0.0.1:4416'; SetupLines = @($setupLines) }
    } catch {
        $Script:LastPoTokenSetupLines = @($setupLines)
        throw
    }
}

function Ensure-Tools {
    New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

    if (-not (Test-Path $YtDlp)) {
        Write-Log '正在下載 yt-dlp…'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $YtDlp
    }
    if (-not (Test-Path $Ffmpeg)) {
        Write-Log '正在下載 FFmpeg…'
        $zip = Join-Path $env:TEMP 'ffmpeg-release-essentials.zip'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip
            $extract = Join-Path $env:TEMP ('ffmpeg-' + [guid]::NewGuid())
            Expand-Archive -Path $zip -DestinationPath $extract -Force
            $ffmpegSource = Get-ChildItem -Path $extract -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
            if (-not $ffmpegSource) { throw '下載的 FFmpeg 壓縮檔中找不到 ffmpeg.exe。' }
            Copy-Item -LiteralPath $ffmpegSource.FullName -Destination $Ffmpeg -Force
        } finally {
            if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
            if ($extract -and (Test-Path $extract)) { Remove-Item -LiteralPath $extract -Recurse -Force }
        }
    }
    if (-not (Test-Path $Deno)) {
        Write-Log '正在下載 Deno（YouTube JavaScript challenge 支援）…'
        $zip = Join-Path $env:TEMP 'deno-x86_64-pc-windows-msvc.zip'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' -OutFile $zip
            $extract = Join-Path $env:TEMP ('deno-' + [guid]::NewGuid())
            Expand-Archive -Path $zip -DestinationPath $extract -Force
            $denoSource = Get-ChildItem -Path $extract -Filter 'deno.exe' -Recurse | Select-Object -First 1
            if (-not $denoSource) { throw '下載的 Deno 壓縮檔中找不到 deno.exe。' }
            Copy-Item -LiteralPath $denoSource.FullName -Destination $Deno -Force
        } finally {
            if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
            if ($extract -and (Test-Path $extract)) { Remove-Item -LiteralPath $extract -Recurse -Force }
        }
    }
}

function Add-YtDlpAccessArguments([System.Collections.Generic.List[string]]$ArgumentList) {
    $ArgumentList.Add('--ffmpeg-location'); $ArgumentList.Add($ToolsRoot)
    $ArgumentList.Add('--js-runtimes'); $ArgumentList.Add("deno:$Deno")
    $cookieFile = $cookieFileBox.Text.Trim()
    if ($cookieFile) {
        if (-not (Test-Path -LiteralPath $cookieFile -PathType Leaf)) { throw "找不到 cookie 檔案：$cookieFile" }
        $ArgumentList.Add('--cookies'); $ArgumentList.Add($cookieFile)
    } elseif ($browserBox.SelectedIndex -gt 0) {
        $ArgumentList.Add('--cookies-from-browser'); $ArgumentList.Add($browserBox.SelectedItem.ToString().ToLowerInvariant())
    }
}

function Get-ProbeCredentialContext {
    $cookieFile = $cookieFileBox.Text.Trim()
    if ($cookieFile) {
        if (-not (Test-Path -LiteralPath $cookieFile -PathType Leaf)) { throw "找不到 cookie 檔案：$cookieFile" }
        return [pscustomobject]@{ Kind = 'file'; Value = (Resolve-Path -LiteralPath $cookieFile).Path }
    }
    if ($browserBox.SelectedIndex -gt 0) {
        return [pscustomobject]@{ Kind = 'browser'; Value = $browserBox.SelectedItem.ToString().ToLowerInvariant() }
    }
    return [pscustomobject]@{ Kind = 'none'; Value = '' }
}

function Add-ProbeAccessArguments([System.Collections.Generic.List[string]]$ArgumentList, $Cookies, [string]$DenoPath) {
    $ArgumentList.Add('--ffmpeg-location'); $ArgumentList.Add($ToolsRoot)
    $ArgumentList.Add('--js-runtimes'); $ArgumentList.Add("deno:$DenoPath")
    if ($Cookies.Kind -eq 'file') { $ArgumentList.Add('--cookies'); $ArgumentList.Add($Cookies.Value) }
    elseif ($Cookies.Kind -eq 'browser') { $ArgumentList.Add('--cookies-from-browser'); $ArgumentList.Add($Cookies.Value) }
}

function Probe-AudioFormats([string]$Url, [string]$Client, $Cookies, [string]$DenoPath) {
    Ensure-Tools
    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('--no-warnings')
    $args.Add('--no-playlist')
    $args.Add('--skip-download')
    $args.Add('-J')
    Add-ProbeAccessArguments $args $Cookies $DenoPath
    if ($Client -ne 'Auto') {
        $args.Add('--extractor-args'); $args.Add("youtube:player_client=$Client")
    }
    $args.Add($Url)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $YtDlp
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($args | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $loggedProcess = [YtAudioDownloader.LoggedProcess]::new()
    $loggedProcess.Start($psi)
    while (-not $loggedProcess.Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 80
    }
    $loggedProcess.Process.WaitForExit()

    $outputLines = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($loggedProcess.OutputLines.TryDequeue([ref]$line)) { $outputLines.Add($line) }
    $errorLines = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($loggedProcess.ErrorLines.TryDequeue([ref]$line)) { $errorLines.Add($line) }
    if ($loggedProcess.Process.ExitCode -ne 0) {
        $detail = if ($errorLines.Count) { $errorLines -join ' ' } else { 'yt-dlp 未回傳可用格式資訊。' }
        throw $detail
    }
    try { $info = (($outputLines -join "`n") | ConvertFrom-Json) }
    catch { throw "無法解析 yt-dlp JSON。$($_.Exception.Message)" }
    $audioFormats = @($info.formats | Where-Object {
        $_.vcodec -eq 'none' -and $_.acodec -and $_.acodec -ne 'none'
    } | ForEach-Object {
        [pscustomobject]@{
            format_id = [string]$_.format_id
            abr = if ($null -eq $_.abr) { 0 } else { [double]$_.abr }
            ext = [string]$_.ext
            acodec = [string]$_.acodec
            protocol = [string]$_.protocol
        }
    })
    return [pscustomobject]@{ Client = $Client; Title = [string]$info.title; AudioFormats = $audioFormats; BestOpus = Get-BestOpusFormat $info.formats }
}

function Get-BestOpusFormat($Formats) {
    $opusFormats = @($Formats | Where-Object {
        $_.vcodec -eq 'none' -and $_.acodec -and $_.acodec -ne 'none' -and $_.acodec -match '(?i)opus'
    } | Sort-Object @{ Expression = { if ($null -eq $_.abr) { 0 } else { [double]$_.abr } }; Descending = $true })
    if (-not $opusFormats.Count) { return $null }
    $best = $opusFormats[0]
    return [pscustomobject]@{
        format_id = [string]$best.format_id
        abr = if ($null -eq $best.abr) { 0 } else { [double]$best.abr }
        ext = [string]$best.ext
        acodec = [string]$best.acodec
        protocol = [string]$best.protocol
    }
}

function Compare-ClientAudioFormats([string]$Url, $Cookies, [string]$DenoPath) {
    $clients = @('Auto', 'web_music', 'web', 'mweb')
    $results = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $position = 0
    foreach ($client in $clients) {
        Write-Log "[Probe] Testing $client..."
        try {
            $result = Probe-AudioFormats $Url $client $Cookies $DenoPath
            $result | Add-Member -NotePropertyName Position -NotePropertyValue $position
            $results.Add($result)
            Write-Log "[Probe] ${client}: Found $($result.AudioFormats.Count) audio-only formats"
            foreach ($audio in ($result.AudioFormats | Sort-Object @{ Expression = 'abr'; Descending = $true })) {
                $mark = if ($result.BestOpus -and $audio.format_id -eq $result.BestOpus.format_id) { '  <-- Best Opus' } else { '' }
                Write-Log ("[Probe] {0}: {1} / {2} / {3:N1} kbps / {4} / {5}{6}" -f $client, $audio.format_id, $audio.acodec, $audio.abr, $audio.ext, $audio.protocol, $mark)
            }
            if ($result.BestOpus) {
                Write-Log ("[Probe] {0}: Best Opus {1:N0} kbps (format {2})" -f $client, $result.BestOpus.abr, $result.BestOpus.format_id)
                if ($client -eq 'Auto' -and $result.BestOpus.abr -ge 250) {
                    Write-Log ("[Probe] Auto already provides {0:N0} kbps Opus. Skipping alternate clients." -f $result.BestOpus.abr)
                    break
                }
            } else { Write-Log "[Probe] ${client}: No original Opus format found." }
        } catch {
            $message = $_.Exception.Message
            $failures.Add("${client}: $message")
            Write-Log "[Probe] $client failed: $message"
        }
        $position++
    }
    if (-not $results.Count) { throw "所有 client probe 都失敗：$($failures -join ' | ')" }
    $candidates = @($results | Where-Object { $_.BestOpus } | Sort-Object @{ Expression = { $_.BestOpus.abr }; Descending = $true }, Position)
    $selected = if ($candidates.Count) { $candidates[0] } else { $null }
    if ($selected) {
        Write-Log ("[Probe] Selected: {0} / format {1} / Opus {2:N0} kbps" -f $selected.Client, $selected.BestOpus.format_id, $selected.BestOpus.abr)
    } else { Write-Log '[Probe] 沒有任何 client 回傳原始 Opus 格式。' }
    return [pscustomobject]@{ Url = $Url; Results = @($results); Selected = $selected; Failures = @($failures) }
}

function Get-AudioFormatProbe([string]$Url) {
    $credentials = Get-ProbeCredentialContext
    $cacheKey = "$Url`n$($credentials.Kind)`n$($credentials.Value)`n$Deno"
    if ($Script:FormatProbeCache -and $Script:FormatProbeCache.CacheKey -eq $cacheKey) { return $Script:FormatProbeCache }
    $probe = Compare-ClientAudioFormats $Url $credentials $Deno
    $probe | Add-Member -NotePropertyName CacheKey -NotePropertyValue $cacheKey
    $Script:FormatProbeCache = $probe
    return $probe
}

function Get-YtDlpVersion {
    Ensure-Tools
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $YtDlp
    $psi.Arguments = '--version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [YtAudioDownloader.LoggedProcess]::new()
    $process.Start($psi)
    $process.Process.WaitForExit()
    $line = $null; $versionLines = [System.Collections.Generic.List[string]]::new()
    while ($process.OutputLines.TryDequeue([ref]$line)) { $versionLines.Add($line) }
    if ($process.Process.ExitCode -ne 0 -or -not $versionLines.Count) { return 'Unknown' }
    return ($versionLines -join ' ').Trim()
}

function Get-DiagnosticJsonFields($Value, [string]$Path = 'root', [int]$Depth = 0) {
    if ($Depth -gt 6 -or $null -eq $Value) { return }
    if ($Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
        $index = 0
        foreach ($item in $Value) {
            if ($index -ge 10) { break }
            Get-DiagnosticJsonFields $item "${Path}[$index]" ($Depth + 1)
            $index++
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.MemberType -notin @('NoteProperty', 'Property')) { continue }
        $propertyPath = "$Path.$($property.Name)"
        $propertyValue = $property.Value
        if ($property.Name -match '(?i)(premium|member|paid|login|account|cookie|client|availability|format|po.?token|sabr|skip|missing)') {
            if ($propertyValue -is [string] -or $propertyValue -is [ValueType] -or $null -eq $propertyValue) {
                "${propertyPath} = $propertyValue"
            } else { "${propertyPath} = [present]" }
        }
        Get-DiagnosticJsonFields $propertyValue $propertyPath ($Depth + 1)
    }
}

function Get-DiagnosticLineSummary($Lines, [string]$Pattern, [string]$Unknown = 'Unknown') {
    $matches = @($Lines | Where-Object { $_ -match $Pattern } | Select-Object -First 4)
    if ($matches.Count) { return ($matches -join ' | ') }
    return $Unknown
}

function Invoke-VerboseDiagnosticProbe([string]$Url, [string]$Client, $Cookies, [string]$DenoPath, [string[]]$ExtraArguments = @()) {
    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-v')
    $args.Add('--no-playlist')
    $args.Add('--skip-download')
    $args.Add('-J')
    Add-ProbeAccessArguments $args $Cookies $DenoPath
    if ($Client -ne 'Auto') {
        $args.Add('--extractor-args'); $args.Add("youtube:player_client=$Client")
    }
    foreach ($argument in $ExtraArguments) { $args.Add($argument) }
    $args.Add($Url)
    $hasCookiesArgument = $args.Contains('--cookies')
    $hasBrowserArgument = $args.Contains('--cookies-from-browser')
    if ($Cookies.Kind -eq 'file' -and -not $hasCookiesArgument) {
        throw 'Probe authentication bug: GUI 選取了 cookies.txt，但實際 yt-dlp 參數未包含 --cookies。已停止匿名 probe。'
    }
    if ($Cookies.Kind -eq 'browser' -and -not $hasBrowserArgument) {
        throw 'Probe authentication bug: GUI 選取了瀏覽器登入，但實際 yt-dlp 參數未包含 --cookies-from-browser。已停止匿名 probe。'
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $YtDlp
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($args | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $process = [YtAudioDownloader.LoggedProcess]::new()
    $process.Start($psi)
    while (-not $process.Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 80
    }
    $process.Process.WaitForExit()
    $allLines = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($process.Lines.TryDequeue([ref]$line)) { $allLines.Add($line) }
    $outputLines = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($process.OutputLines.TryDequeue([ref]$line)) { $outputLines.Add($line) }
    $errorLines = [System.Collections.Generic.List[string]]::new(); $line = $null
    while ($process.ErrorLines.TryDequeue([ref]$line)) { $errorLines.Add($line) }
    $info = $null
    try { $info = (($outputLines -join "`n") | ConvertFrom-Json) } catch { }
    return [pscustomobject]@{
        Client = $Client; ExitCode = $process.Process.ExitCode; Lines = @($allLines); Info = $info
        OutputLines = @($outputLines); ErrorLines = @($errorLines)
        CommandLine = $psi.Arguments
        CookiesArgumentPresent = $hasCookiesArgument; BrowserArgumentPresent = $hasBrowserArgument
    }
}

function Get-DetectedPlayerClients($Lines) {
    $clients = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -match '(?i)Downloading ([a-z0-9_]+) player API JSON') { $clients.Add($Matches[1]) }
        elseif ($line -match '(?i)Downloading web music player API JSON') { $clients.Add('web_music') }
    }
    return @($clients | Select-Object -Unique)
}

function Write-DiagnosticFormatSummary($Diagnostic) {
    if (-not $Diagnostic.Info) {
        Write-Log "[Diagnostic] $($Diagnostic.Client) formats: Unknown (JSON unavailable)"
        return
    }
    $audioFormats = @($Diagnostic.Info.formats | Where-Object {
        $_.vcodec -eq 'none' -and $_.acodec -and $_.acodec -ne 'none'
    } | ForEach-Object {
        [pscustomobject]@{ format_id = [string]$_.format_id; acodec = [string]$_.acodec; abr = if ($null -eq $_.abr) { 0 } else { [double]$_.abr }; ext = [string]$_.ext }
    } | Sort-Object abr -Descending)
    $formatSummary = if ($audioFormats.Count) { @($audioFormats | ForEach-Object { "{0}/{1}/{2:N1} kbps/{3}" -f $_.format_id, $_.acodec, $_.abr, $_.ext }) -join '; ' } else { 'none' }
    Write-Log "[Diagnostic] $($Diagnostic.Client) audio-only formats: $formatSummary"
    $bestOpus = Get-BestOpusFormat $Diagnostic.Info.formats
    if ($bestOpus) { Write-Log ("[Diagnostic] {0} best Opus: {1} / {2:N1} kbps" -f $Diagnostic.Client, $bestOpus.format_id, $bestOpus.abr) }
    else { Write-Log "[Diagnostic] $($Diagnostic.Client) best Opus: none" }
    $formatIds = @($Diagnostic.Info.formats | ForEach-Object { [string]$_.format_id })
    if ($formatIds -contains '141') { Write-Log "[Premium Probe] $($Diagnostic.Client): Format 141 exposed" } else { Write-Log "[Premium Probe] $($Diagnostic.Client): Format 141 not exposed" }
    if ($formatIds -contains '774') { Write-Log "[Premium Probe] $($Diagnostic.Client): Format 774 exposed" } else { Write-Log "[Premium Probe] $($Diagnostic.Client): Format 774 not exposed" }
}

function Get-DiagnosticCookieVerdict($Diagnostic, $Cookies) {
    if ($Cookies.Kind -eq 'none') { return 'B. No cookie selected; login not confirmed' }
    if ($Cookies.Kind -eq 'file' -and -not $Diagnostic.CookiesArgumentPresent) { return 'A. Cookie 未成功傳入' }
    if ($Cookies.Kind -eq 'browser' -and -not $Diagnostic.BrowserArgumentPresent) { return 'A. Cookie 未成功傳入' }
    $hasPremiumFormat = $false
    if ($Diagnostic.Info) {
        $ids = @($Diagnostic.Info.formats | ForEach-Object { [string]$_.format_id })
        $hasPremiumFormat = $ids -contains '141' -or $ids -contains '774'
    }
    if ($hasPremiumFormat) { return 'D. Cookie 已傳入，並出現 format 141 或 774' }
    $loggedIn = @($Diagnostic.Lines | Where-Object { -not $_.StartsWith('{') -and $_ -match '(?i)logged[ -]?in|authenticated|account' }).Count -gt 0
    if ($loggedIn) { return 'C. Cookie 已傳入且確認登入，但沒有 Premium formats' }
    return 'B. Cookie 已傳入，但未確認登入'
}

function Get-CookieFileDiagnostics([string]$CookiePath) {
    $expectedNames = @('SID', 'HSID', 'SSID', 'APISID', 'SAPISID', '__Secure-1PSID', '__Secure-3PSID')
    $presentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $domains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $youtubeGoogleCount = 0
    foreach ($line in (Get-Content -LiteralPath $CookiePath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $isHttpOnly = $line.StartsWith('#HttpOnly_', [System.StringComparison]::OrdinalIgnoreCase)
        if ($line.StartsWith('#') -and -not $isHttpOnly) { continue }
        $columns = $line -split "`t"
        if ($columns.Count -lt 7) { continue }
        $domain = $columns[0] -replace '^#HttpOnly_', ''
        $name = $columns[5]
        if ([string]::IsNullOrWhiteSpace($domain) -or [string]::IsNullOrWhiteSpace($name)) { continue }
        [void]$domains.Add($domain.TrimStart('.'))
        if ($domain -match '(?i)(^|\.)youtube\.com$|(^|\.)google\.com$') { $youtubeGoogleCount++ }
        if ($expectedNames -contains $name) { [void]$presentNames.Add($name) }
    }
    $presence = [ordered]@{}
    foreach ($name in $expectedNames) { $presence[$name] = $presentNames.Contains($name) }
    $file = Get-Item -LiteralPath $CookiePath
    return [pscustomobject]@{
        Path = $CookiePath
        LastWriteTime = $file.LastWriteTime
        DomainCount = $domains.Count
        YouTubeGoogleCookieCount = $youtubeGoogleCount
        SessionCookiePresence = $presence
        HasCompleteCommonSessionSet = @($presence.Values | Where-Object { -not $_ }).Count -eq 0
    }
}

function Write-CookieFileDiagnostics($CookieDiagnostics) {
    Write-Log "[Auth Validation] Cookie file modified: $($CookieDiagnostics.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "[Auth Validation] Domains: $($CookieDiagnostics.DomainCount); youtube.com/google.com cookies: $($CookieDiagnostics.YouTubeGoogleCookieCount)"
    foreach ($name in $CookieDiagnostics.SessionCookiePresence.Keys) {
        $state = if ($CookieDiagnostics.SessionCookiePresence[$name]) { 'present' } else { 'missing' }
        Write-Log "[Auth Validation] ${name}: $state"
    }
    Write-Log '[Auth Validation] Cookie-name presence is a completeness signal only; it does not prove that the session is valid.'
}

function Get-AuthenticationValidationSignals($Diagnostic) {
    # Lines is the merged stdout + stderr queue from LoggedProcess.  Do not
    # limit this check to the JSON emitted on stdout.
    $diagnosticLines = @($Diagnostic.Lines | Where-Object { -not $_.StartsWith('{') })
    return [pscustomobject]@{
        LoginConfirmed = @($diagnosticLines | Where-Object {
            $_ -match '(?i)Found YouTube account cookies|logged[ -]?in|authenticated as|account.*logged'
        }).Count -gt 0
        PremiumConfirmed = @($diagnosticLines | Where-Object {
            $_ -match '(?i)Detected YouTube Premium subscription|premium.*(account|logged|member)|account.*premium'
        }).Count -gt 0
    }
}

function Get-AuthenticationValidationVerdict($CookieDiagnostics, $Diagnostic) {
    $signals = Get-AuthenticationValidationSignals $Diagnostic
    if ($signals.LoginConfirmed -and $signals.PremiumConfirmed) { return 'D. yt-dlp 明確確認已登入 YouTube Premium' }
    if ($signals.LoginConfirmed) { return 'C. yt-dlp 明確確認已登入' }
    if ($signals.PremiumConfirmed) { return 'Premium 已由 yt-dlp 確認；未找到獨立的登入確認訊息' }
    if (-not $Diagnostic.CookiesArgumentPresent) { return 'A. Cookie 檔只是有傳入，但內容看起來不完整' }
    if (-not $CookieDiagnostics.HasCompleteCommonSessionSet) { return 'A. Cookie 檔只是有傳入，但內容看起來不完整' }
    return 'B. Cookie 檔內容包含完整的登入型 session cookies，但登入仍無法由 yt-dlp 確認'
}

function Run-AuthenticationValidation {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片網址後再驗證登入。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $authValidationButton.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -ne 'file') {
            throw 'Authentication Validation 需要在 GUI 中選取 cookies.txt；不會改用匿名或瀏覽器 probe。'
        }
        Write-Log '[Auth] Validation mode: cookies file'
        Write-Log "[Auth] Cookie path: $($credentials.Value)"
        $cookieDiagnostics = Get-CookieFileDiagnostics $credentials.Value
        Write-CookieFileDiagnostics $cookieDiagnostics
        Write-Log '[Auth Validation] Testing Auto client only...'
        $diagnostic = Invoke-VerboseDiagnosticProbe $url 'Auto' $credentials $Deno
        if (-not $diagnostic.CookiesArgumentPresent) {
            throw 'Authentication validation bug: --cookies 未加入實際 yt-dlp command。已停止。'
        }
        Write-Log "[Auth] Auto command auth: --cookies `"$($credentials.Value)`""
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $logPath = Join-Path $logsRoot "auth-validation-$timestamp.txt"
        [System.IO.File]::WriteAllText($logPath, ($diagnostic.Lines -join "`r`n"), [System.Text.Encoding]::UTF8)
        $relevantLines = @($diagnostic.Lines | Where-Object {
            -not $_.StartsWith('{') -and $_ -match '(?i)logged[ -]?in|account|authenticat|cookies?|session|premium|visitor.?data|data.?sync.?id|account.required|consent|age|sign.?in'
        } | Select-Object -First 20)
        if ($relevantLines.Count) {
            foreach ($line in $relevantLines) { Write-Log "[Auth Validation] $line" }
        } else { Write-Log '[Auth Validation] No explicit login/account/session messages reported by yt-dlp.' }
        $signals = Get-AuthenticationValidationSignals $diagnostic
        $loginStatus = if ($signals.LoginConfirmed) { 'Confirmed' } else { 'Unknown' }
        $premiumStatus = if ($signals.PremiumConfirmed) { 'Confirmed' } else { 'Unknown' }
        Write-Log "[Auth Validation] Login status: $loginStatus"
        Write-Log "[Auth Validation] Premium status: $premiumStatus"
        Write-Log "[Auth Validation] Verdict: $(Get-AuthenticationValidationVerdict $cookieDiagnostics $diagnostic)"
        Write-Log "[Auth Validation] Full verbose log: $logPath"
    } catch {
        Write-Log "[Auth Validation] 錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Authentication Validation 失敗', 'OK', 'Error') | Out-Null
    } finally { $authValidationButton.Enabled = $true }
}

function Get-PremiumClientDiffWarning($Lines, [string]$Pattern) {
    $matches = @($Lines | Where-Object { -not $_.StartsWith('{') -and $_ -match $Pattern } | Select-Object -First 3)
    return [pscustomobject]@{ Present = ($matches.Count -gt 0); Detail = if ($matches.Count) { $matches -join ' | ' } else { 'none' } }
}

function Format-PremiumClientDiffAudio($Audio) {
    $mark = [System.Collections.Generic.List[string]]::new()
    if ($Audio.format_id -eq '251') { $mark.Add('format 251') }
    if ($Audio.format_id -eq '141') { $mark.Add('format 141') }
    if ($Audio.format_id -eq '774') { $mark.Add('format 774') }
    if ($Audio.IsBestOpus) { $mark.Add('Best Opus') }
    if ($Audio.IsBestAac) { $mark.Add('Best AAC') }
    $suffix = if ($mark.Count) { '  <-- ' + ($mark -join ', ') } else { '' }
    return ('[Diff] {0}: id={1}; ext={2}; codec={3}; abr={4:N1} kbps; tbr={5:N1} kbps; asr={6}; protocol={7}; note={8}{9}' -f `
        $Audio.Client, $Audio.format_id, $Audio.ext, $Audio.acodec, $Audio.abr, $Audio.tbr, $Audio.asr, $Audio.protocol, $Audio.format_note, $suffix)
}

function Get-PremiumClientDiffResult($Diagnostic) {
    $signals = Get-AuthenticationValidationSignals $Diagnostic
    $allFormats = if ($Diagnostic.Info) { @($Diagnostic.Info.formats) } else { @() }
    # yt-dlp represents storyboards as vcodec/acodec "none".  Exclude those
    # non-audio resources while retaining every actual audio-only stream.
    $audioFormats = @($allFormats | Where-Object { $_.vcodec -eq 'none' -and $_.acodec -and $_.acodec -ne 'none' } | ForEach-Object {
        [pscustomobject]@{
            Client = $Diagnostic.Client
            format_id = [string]$_.format_id
            ext = [string]$_.ext
            acodec = [string]$_.acodec
            abr = if ($null -eq $_.abr) { 0 } else { [double]$_.abr }
            tbr = if ($null -eq $_.tbr) { 0 } else { [double]$_.tbr }
            asr = if ($null -eq $_.asr) { 'Unknown' } else { [string]$_.asr }
            protocol = [string]$_.protocol
            format_note = [string]$_.format_note
        }
    } | Sort-Object abr -Descending)
    $bestOpus = @($audioFormats | Where-Object { $_.acodec -match '(?i)opus' } | Sort-Object abr -Descending | Select-Object -First 1)
    $bestAac = @($audioFormats | Where-Object { $_.acodec -match '(?i)aac|mp4a' } | Sort-Object abr -Descending | Select-Object -First 1)
    foreach ($audio in $audioFormats) {
        $audio | Add-Member -NotePropertyName IsBestOpus -NotePropertyValue ($bestOpus.Count -gt 0 -and $audio.format_id -eq $bestOpus[0].format_id)
        $audio | Add-Member -NotePropertyName IsBestAac -NotePropertyValue ($bestAac.Count -gt 0 -and $audio.format_id -eq $bestAac[0].format_id)
    }
    $ids = @($allFormats | ForEach-Object { [string]$_.format_id })
    $gvs = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)(warning:.*gvs po.?token|gvs po.?token.*(require|skip|unavailable|missing))'
    $sabr = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)sabr'
    $skippedHttps = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)skip.*https.*format|https.*format.*skip'
    $skippedFormats = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)skip(ped|ping).*format|format.*skip'
    $jsEjs = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)(js challenge|ejs|signature solving|javascript.*warning)'
    $requestedUnavailable = Get-PremiumClientDiffWarning $Diagnostic.Lines '(?i)Requested format is not available'
    return [pscustomobject]@{
        Client = $Diagnostic.Client
        Success = ($Diagnostic.ExitCode -eq 0 -and $null -ne $Diagnostic.Info)
        ExitCode = $Diagnostic.ExitCode
        CookiesArgumentPresent = $Diagnostic.CookiesArgumentPresent
        LoginConfirmed = $signals.LoginConfirmed
        PremiumConfirmed = $signals.PremiumConfirmed
        PlayerClients = @(Get-DetectedPlayerClients $Diagnostic.Lines)
        FormatCount = $allFormats.Count
        AudioFormats = $audioFormats
        BestOpus = if ($bestOpus.Count) { $bestOpus[0] } else { $null }
        BestAac = if ($bestAac.Count) { $bestAac[0] } else { $null }
        Has141 = ($ids -contains '141')
        Has774 = ($ids -contains '774')
        GvsWarning = $gvs
        SabrWarning = $sabr
        SkippedHttps = $skippedHttps
        SkippedFormats = $skippedFormats
        JsEjsWarning = $jsEjs
        RequestedFormatUnavailable = $requestedUnavailable
        Lines = $Diagnostic.Lines
    }
}

function Write-PremiumClientDiffSummary($Result) {
    $premium = if ($Result.PremiumConfirmed) { 'confirmed' } else { 'Unknown' }
    $players = if ($Result.PlayerClients.Count) { $Result.PlayerClients -join ', ' } else { 'Unknown' }
    $opus = if ($Result.BestOpus) { '{0} / {1:N1} kbps' -f $Result.BestOpus.format_id, $Result.BestOpus.abr } else { 'none' }
    $aac = if ($Result.BestAac) { '{0} / {1:N1} kbps' -f $Result.BestAac.format_id, $Result.BestAac.abr } else { 'none' }
    Write-Log "[Diff] $($Result.Client)"
    Write-Log "[Diff] Premium: $premium; player client: $players; Formats: $($Result.FormatCount); Audio-only: $($Result.AudioFormats.Count)"
    Write-Log "[Diff] Best Opus: $opus; Best AAC: $aac; 141: $(if ($Result.Has141) { 'exposed' } else { 'missing' }); 774: $(if ($Result.Has774) { 'exposed' } else { 'missing' })"
    Write-Log "[Diff] GVS PO Token warning: $(if ($Result.GvsWarning.Present) { 'yes' } else { 'no' }); SABR warning: $(if ($Result.SabrWarning.Present) { 'yes' } else { 'no' }); skipped HTTPS formats: $(if ($Result.SkippedHttps.Present) { 'yes' } else { 'no' })"
    Write-Log "[Diff] skipped formats: $(if ($Result.SkippedFormats.Present) { 'yes' } else { 'no' }); JS/EJS warnings: $(if ($Result.JsEjsWarning.Present) { 'yes' } else { 'no' }); requested format unavailable: $(if ($Result.RequestedFormatUnavailable.Present) { 'yes' } else { 'no' })"
    foreach ($audio in $Result.AudioFormats) { Write-Log (Format-PremiumClientDiffAudio $audio) }
}

function Run-PremiumClientFormatDiff {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片網址後再執行 Premium Client Format Diff。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $premiumDiffButton.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -ne 'file') {
            throw 'Premium Client Format Diff 需要在 GUI 中選取同一份 cookies.txt；不會改用匿名或瀏覽器登入。'
        }
        Write-Log '[Auth] Premium Client Format Diff: cookies file'
        Write-Log "[Auth] Cookie path: $($credentials.Value)"
        $version = Get-YtDlpVersion
        Write-Log "[Diff] yt-dlp version: $version; Deno: $Deno"
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $logPath = Join-Path $logsRoot "premium-client-diff-$timestamp.txt"
        $fileLines = [System.Collections.Generic.List[string]]::new()
        $fileLines.Add("Premium Client Format Diff | yt-dlp $version | Deno $Deno | URL $url")
        $fileLines.Add('Authentication: cookies file (path intentionally omitted from file summary)')
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($client in @('Auto', 'web_creator', 'web_music', 'mweb')) {
            Write-Log "[Diff] Testing $client..."
            try {
                $diagnostic = Invoke-VerboseDiagnosticProbe $url $client $credentials $Deno
                if (-not $diagnostic.CookiesArgumentPresent) {
                    throw "authentication argument missing: --cookies was not included for $client; anonymous test was not run"
                }
                Write-Log "[Auth] ${client}: cookies file"
                $result = Get-PremiumClientDiffResult $diagnostic
                $results.Add($result)
                if ($result.Success) { Write-PremiumClientDiffSummary $result }
                else { Write-Log "[Diff] $client failed: ProcessExitCode=$($diagnostic.ExitCode); JsonAvailable=$(if ($diagnostic.Info) { 'Yes' } else { 'No' }); VerboseSaved=Yes" }
                $fileLines.Add("`r`n===== $client diagnostic =====")
                $fileLines.Add("Client: $client")
                $fileLines.Add("Exit code: $($diagnostic.ExitCode)")
                $fileLines.Add('Authentication: cookies file')
                $fileLines.Add("Command-line arguments: $($diagnostic.CommandLine)")
                $fileLines.Add("ProcessExitCode: $($diagnostic.ExitCode)")
                $fileLines.Add("JsonAvailable: $(if ($diagnostic.Info) { 'Yes' } else { 'No' })")
                $fileLines.Add('VerboseSaved: Yes')
                $fileLines.Add("stdout lines: $($diagnostic.OutputLines.Count); stderr lines: $($diagnostic.ErrorLines.Count)")
                $fileLines.Add("`r`n----- BEGIN SUMMARY -----")
                $fileLines.Add("Premium: $(if ($result.PremiumConfirmed) { 'confirmed' } else { 'Unknown' })")
                $fileLines.Add("Player client: $(if ($result.PlayerClients.Count) { $result.PlayerClients -join ', ' } else { 'Unknown' })")
                foreach ($audio in $result.AudioFormats) { $fileLines.Add((Format-PremiumClientDiffAudio $audio)) }
                $fileLines.Add("GVS PO Token: $($result.GvsWarning.Detail)")
                $fileLines.Add("SABR: $($result.SabrWarning.Detail)")
                $fileLines.Add("Skipped HTTPS formats: $($result.SkippedHttps.Detail)")
                $fileLines.Add("Skipped formats: $($result.SkippedFormats.Detail)")
                $fileLines.Add("JS/EJS: $($result.JsEjsWarning.Detail)")
                $fileLines.Add("Requested format unavailable: $($result.RequestedFormatUnavailable.Detail)")
                $failureKeywords = @($diagnostic.Lines | Where-Object {
                    -not $_.StartsWith('{') -and $_ -match '(?i)po.?token|gvs|sabr|requested format is not available|sign.?in|account|premium|cookies?|page needs to be reloaded|challenge|skip|formats?|http error|\b403\b|player response'
                } | Select-Object -First 40)
                $fileLines.Add('Failure keyword matches:')
                if ($failureKeywords.Count) { foreach ($line in $failureKeywords) { $fileLines.Add($line) } } else { $fileLines.Add('Unknown / no matching diagnostic line') }
                $fileLines.Add('----- END SUMMARY -----')
                $fileLines.Add("`r`n----- BEGIN STDOUT -----")
                foreach ($line in $diagnostic.OutputLines) { $fileLines.Add($line) }
                $fileLines.Add('----- END STDOUT -----')
                $fileLines.Add("`r`n----- BEGIN STDERR -----")
                foreach ($line in $diagnostic.ErrorLines) { $fileLines.Add($line) }
                $fileLines.Add('----- END STDERR -----')
                $fileLines.Add("`r`n----- BEGIN VERBOSE (merged stdout/stderr) -----")
                foreach ($line in $diagnostic.Lines) { $fileLines.Add($line) }
                $fileLines.Add('----- END VERBOSE -----')
            } catch {
                Write-Log "[Diff] $client failed: $($_.Exception.Message)"
                $fileLines.Add("`r`n===== $client failed =====")
                $fileLines.Add($_.Exception.Message)
            }
        }
        Write-Log '[Diff] Client | Premium | Audio-only | Best Opus | 141 | 774 | GVS Warning'
        foreach ($result in $results) {
            $opus = if ($result.BestOpus) { '{0} / {1:N1}' -f $result.BestOpus.format_id, $result.BestOpus.abr } else { 'none' }
            Write-Log ('[Diff] {0} | {1} | {2} | {3} | {4} | {5} | {6}' -f $result.Client, $(if ($result.PremiumConfirmed) { 'Yes' } else { 'No/Unknown' }), $result.AudioFormats.Count, $opus, $(if ($result.Has141) { 'Yes' } else { 'No' }), $(if ($result.Has774) { 'Yes' } else { 'No' }), $(if ($result.GvsWarning.Present) { 'Yes' } else { 'No' }))
        }
        [System.IO.File]::WriteAllText($logPath, ($fileLines -join "`r`n"), [System.Text.Encoding]::UTF8)
        Write-Log "[Diff] Full verbose + JSON log: $logPath"
        if (-not $results.Count) { throw '所有 Premium Client Format Diff 測試皆失敗。' }
        if (@($results | Where-Object Has774).Count) { Write-Log '[Diff] Verdict: A. 至少一個 client 暴露 format 774' }
        elseif (@($results | Where-Object Has141).Count) { Write-Log '[Diff] Verdict: B. 至少一個 client 暴露 format 141，但沒有 774' }
        else {
            $allPremium = @($results | Where-Object { -not $_.PremiumConfirmed }).Count -eq 0
            if ($allPremium) { Write-Log '[Diff] Verdict: C. 所有 client 都確認 Premium，但都沒有 141/774' }
            else { Write-Log '[Diff] Verdict: E. 某些 client 沒有正確使用或確認 Premium session' }
        }
        if (@($results | Where-Object { $_.GvsWarning.Present }).Count) {
            Write-Log '[Diff] Verdict: D. 某些 client 因 GVS PO Token 被跳過'
        }
    } catch {
        Write-Log "[Diff] 錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Premium Client Format Diff 失敗', 'OK', 'Error') | Out-Null
    } finally { $premiumDiffButton.Enabled = $true }
}

function Run-PoTokenTest {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片網址後再執行 PO Token Test。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    $logPath = $null; $fileLines = [System.Collections.Generic.List[string]]::new()
    try {
        $poTokenTestButton.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -ne 'file') { throw 'PO Token Test 需要在 GUI 中選取 cookies.txt；不會改用匿名或瀏覽器登入。' }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $logPath = Join-Path $logsRoot "po-token-test-$timestamp.txt"
        $fileLines.Add("PO Token Test | client=mweb | URL=$url")
        $fileLines.Add('Authentication: cookies file (cookie path and values omitted)')
        Write-Log '[Auth] PO Token Test: cookies file'
        Write-Log '[PO Token] Installing/checking official bgutil provider plugin…'
        $provider = Ensure-PoTokenProvider
        foreach ($line in $provider.SetupLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }
        Write-Log '[PO Token] Provider: ready (bgutil localhost HTTP provider)'
        Write-Log '[PO Token] GVS token context: mweb.gvs (token value is never logged)'
        $extraArguments = @('--plugin-dirs', $provider.PluginRoot, '--extractor-args', "youtubepot-bgutilhttp:base_url=$($provider.BaseUrl)")
        $diagnostic = Invoke-VerboseDiagnosticProbe $url 'mweb' $credentials $Deno $extraArguments
        if (-not $diagnostic.CookiesArgumentPresent) { throw 'PO Token Test bug: --cookies 未加入 mweb command；已停止匿名 probe。' }
        $result = Get-PremiumClientDiffResult $diagnostic
        $providerDetected = @($diagnostic.Lines | Where-Object { -not $_.StartsWith('{') -and $_ -match '(?i)PO Token Providers:.*bgutil|bgutil.*provider' }).Count -gt 0
        $tokenRetrieved = @($diagnostic.Lines | Where-Object { -not $_.StartsWith('{') -and $_ -match '(?i)bgutil.*(fetch|generat|provid|obtain).*token|po token.*(fetch|generat|provid|obtain)' }).Count -gt 0
        Write-Log "[PO Token] Provider detected by yt-dlp: $(if ($providerDetected) { 'yes' } else { 'Unknown' })"
        Write-Log "[PO Token] GVS token: $(if ($tokenRetrieved) { 'available' } else { 'Unknown (provider did not expose retrieval status)' })"
        Write-Log "[PO Token] mweb GVS warning: $(if ($result.GvsWarning.Present) { 'still present' } else { 'not reported' })"
        if (-not $result.Success) { Write-Log "[PO Token] mweb process failed: exit code $($diagnostic.ExitCode); JSON unavailable=$(if ($diagnostic.Info) { 'No' } else { 'Yes' })" }
        else {
            Write-Log "[Probe] mweb formats: $($result.FormatCount); audio-only formats: $($result.AudioFormats.Count)"
            Write-Log "[Probe] 141: $(if ($result.Has141) { 'present' } else { 'missing' }); 774: $(if ($result.Has774) { 'present' } else { 'missing' })"
            if ($result.BestOpus) { Write-Log ('[Probe] Best Opus: {0} / ~{1:N0} kbps' -f $result.BestOpus.format_id, $result.BestOpus.abr) } else { Write-Log '[Probe] Best Opus: none' }
            if ($result.BestAac) { Write-Log ('[Probe] Best AAC: {0} / ~{1:N0} kbps' -f $result.BestAac.format_id, $result.BestAac.abr) } else { Write-Log '[Probe] Best AAC: none' }
        }
        $fileLines.Add("Provider ready: $(if ($providerDetected) { 'Yes' } else { 'Unknown' })")
        $fileLines.Add("GVS token available: $(if ($tokenRetrieved) { 'Yes' } else { 'Unknown' })")
        $fileLines.Add("ProcessExitCode: $($diagnostic.ExitCode)")
        $fileLines.Add("JsonAvailable: $(if ($diagnostic.Info) { 'Yes' } else { 'No' })")
        $fileLines.Add("GVS warning: $($result.GvsWarning.Detail)")
        $fileLines.Add("Formats: $($result.FormatCount); Audio-only: $($result.AudioFormats.Count); 141: $($result.Has141); 774: $($result.Has774)")
        $fileLines.Add('----- BEGIN STDOUT (redacted) -----'); foreach ($line in $diagnostic.OutputLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }; $fileLines.Add('----- END STDOUT -----')
        $fileLines.Add('----- BEGIN STDERR (redacted) -----'); foreach ($line in $diagnostic.ErrorLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }; $fileLines.Add('----- END STDERR -----')
        $fileLines.Add('----- BEGIN VERBOSE (redacted) -----'); foreach ($line in $diagnostic.Lines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }; $fileLines.Add('----- END VERBOSE -----')
        if ($result.Has774) { Write-Log '[PO Token] Result: format 774 exposed. Diagnostic complete; download selector unchanged.' }
        elseif ($result.Has141) { Write-Log '[PO Token] Result: format 141 exposed; format 774 still missing.' }
        else { Write-Log '[PO Token] Result: mweb still has no 141/774.' }
    } catch {
        Write-Log "[PO Token] 錯誤：$($_.Exception.Message)"
        $fileLines.Add("Provider/process error: $($_.Exception.Message)")
        foreach ($line in $Script:LastPoTokenSetupLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PO Token Test 失敗', 'OK', 'Error') | Out-Null
    } finally {
        if ($logPath) {
            [System.IO.File]::WriteAllText($logPath, ($fileLines -join "`r`n"), [System.Text.Encoding]::UTF8)
            Write-Log "[PO Token] Full diagnostic log: $logPath"
        }
        $poTokenTestButton.Enabled = $true
    }
}

function Run-PremiumExposureVerification {
    $url = $urlBox.Text.Trim()
    $reportPath = $null
    $report = [System.Collections.Generic.List[string]]::new()
    $autoPremium = $false; $mwebResult = $null; $gvsConfirmed = $false
    $previousEnabled = $panel.Enabled
    try {
        if (-not $url) { throw '請先輸入要驗證的影片 URL。' }
        $panel.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -ne 'file') { throw 'Premium Exposure Verification 需要 GUI 選取的 cookies.txt。' }
        $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $reportPath = Join-Path $logsRoot ("premium-exposure-verification-{0}-{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,8))
        $report.Add("Premium Exposure Verification | URL: $url | yt-dlp: $(Get-YtDlpVersion) | Deno: $Deno")
        $report.Add("Both stages use cookies file: $($credentials.Value)")
        foreach ($clientName in @('Auto', 'mweb')) {
            $report.Add("===== $clientName =====")
            Write-Log "[Exposure] Testing $clientName..."
            try {
                $extra = @()
                if ($clientName -eq 'mweb') {
                    $provider = Ensure-PoTokenProvider
                    foreach ($line in $provider.SetupLines) { $report.Add((Protect-PoTokenLogLine $line)) }
                    $extra = @('--plugin-dirs', $provider.PluginRoot, '--extractor-args', "youtubepot-bgutilhttp:base_url=$($provider.BaseUrl)")
                }
                $diagnostic = Invoke-VerboseDiagnosticProbe $url $clientName $credentials $Deno $extra
                # Preserve failed probes before processing formats.
                $report.Add("ProcessExitCode: $($diagnostic.ExitCode); JsonAvailable: $($null -ne $diagnostic.Info)")
                $report.Add('BEGIN VERBOSE (token values redacted)')
                foreach ($line in $diagnostic.Lines) { $report.Add((Protect-PoTokenLogLine $line)) }
                $report.Add('END VERBOSE')
                if (-not $diagnostic.CookiesArgumentPresent) { throw 'Missing --cookies; authentication verification failed.' }
                $lines = @($diagnostic.Lines | Where-Object { -not $_.TrimStart().StartsWith('{') })
                $result = Get-PremiumClientDiffResult $diagnostic
                $summary = [System.Collections.Generic.List[string]]::new()
                $summary.Add("[Auth] ${clientName}: cookies file")
                if ($clientName -eq 'Auto') {
                    $accountFound = @($lines | Where-Object { $_ -match 'Found YouTube account cookies' }).Count -gt 0
                    $autoPremium = @($lines | Where-Object { $_ -match 'Detected YouTube Premium subscription' }).Count -gt 0
                    $players = @($lines | ForEach-Object {
                        if ($_ -match 'Downloading (.+?) player API JSON') { $Matches[1].Replace(' ', '_') }
                    } | Select-Object -Unique)
                    $summary.Add("[Exposure] Auto account cookies found: $accountFound; Premium confirmed: $autoPremium")
                    $summary.Add("[Exposure] Auto actual player clients: $(if ($players.Count) { $players -join ', ' } else { 'Unknown' })")
                } else {
                    $gvsConfirmed = @($lines | Where-Object { $_ -match 'Retrieved a gvs PO Token for mweb client' }).Count -gt 0
                    $mwebResult = $result
                    $summary.Add("[Exposure] mweb GVS token confirmed: $gvsConfirmed; GVS warning: $($result.GvsWarning.Present)")
                    foreach ($audio in $result.AudioFormats) { $summary.Add((Format-PremiumClientDiffAudio $audio)) }
                }
                if ($diagnostic.Info) {
                    $opus = if ($result.BestOpus) { "$($result.BestOpus.format_id) / $($result.BestOpus.abr) kbps" } else { 'none' }
                    $aac = if ($result.BestAac) { "$($result.BestAac.format_id) / $($result.BestAac.abr) kbps" } else { 'none' }
                    $summary.Add("[Exposure] ${clientName}: Audio-only=$($result.AudioFormats.Count); Best Opus=$opus; Best AAC=$aac; 141=$($result.Has141); 774=$($result.Has774)")
                } else { $summary.Add("[Exposure] ${clientName}: format availability Unknown (JSON unavailable)") }
                foreach ($line in $summary) { Write-Log $line; $report.Add($line) }
            } catch {
                $failure = Protect-PoTokenLogLine "[Exposure] $clientName failed: $($_.Exception.Message)"
                Write-Log $failure; $report.Add($failure)
                if ($clientName -eq 'mweb') { foreach ($line in $Script:LastPoTokenSetupLines) { $report.Add((Protect-PoTokenLogLine $line)) } }
            }
            [System.IO.File]::WriteAllText($reportPath, ($report -join "`r`n"), [System.Text.Encoding]::UTF8)
        }
        $conclusion = [System.Collections.Generic.List[string]]::new()
        if (-not $autoPremium) { $conclusion.Add('Premium confirmation unavailable in this run') }
        else { $conclusion.Add('Premium confirmed by Auto using the same cookies file in this report.') }
        $conclusion.Add("mweb GVS token: $(if ($gvsConfirmed) { 'confirmed' } else { 'Unknown / not confirmed' })")
        if ($mwebResult -and $mwebResult.Success) {
            if ($mwebResult.Has774 -or $mwebResult.Has141) {
                $conclusion.Add("mweb exposes format 141: $($mwebResult.Has141); format 774: $($mwebResult.Has774).")
            } else {
                $conclusion.Add('mweb: 141/774 missing from returned formats.')
                if ($autoPremium -and $gvsConfirmed -and -not $mwebResult.GvsWarning.Present) {
                    $conclusion.Add('Premium identity is confirmed, but mweb does not expose the high-bitrate formats for this URL.')
                }
            }
        } else { $conclusion.Add('mweb format exposure: Unknown (probe failed or JSON unavailable).') }
        foreach ($line in $conclusion) { Write-Log "[Exposure] $line"; $report.Add($line) }
    } catch {
        $message = Protect-PoTokenLogLine "[Exposure] Error: $($_.Exception.Message)"
        Write-Log $message; $report.Add($message)
    } finally {
        $panel.Enabled = $previousEnabled
        if ($reportPath) {
            [System.IO.File]::WriteAllText($reportPath, ($report -join "`r`n"), [System.Text.Encoding]::UTF8)
            Write-Log "[Exposure] Report: $reportPath"
        }
    }
}

function Run-BatchPremiumFormatTest {
    $urls = @($batchUrlBox.Lines | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if (-not $urls.Count) {
        [System.Windows.Forms.MessageBox]::Show('請在「批次網址」欄位每行輸入一個 YouTube / YouTube Music URL。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    $logPath = $null; $fileLines = [System.Collections.Generic.List[string]]::new(); $results = [System.Collections.Generic.List[object]]::new()
    try {
        $batchPremiumTestButton.Enabled = $false
        $panel.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -ne 'file') { throw 'Batch Premium Format Test 需要在 GUI 中選取 cookies.txt；不會改用匿名或瀏覽器登入。' }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $logPath = Join-Path $logsRoot "batch-premium-formats-$timestamp.txt"
        $fileLines.Add("Batch Premium Format Test | client=mweb | URL count=$($urls.Count)")
        $fileLines.Add("yt-dlp: $YtDlp | version: $(Get-YtDlpVersion) | Deno: $Deno")
        $fileLines.Add('Authentication: cookies file (cookie path and values omitted)')
        Write-Log "[Batch] Testing $($urls.Count) URL(s) with mweb + bgutil PO Token provider."
        $provider = Ensure-PoTokenProvider
        foreach ($line in $provider.SetupLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }
        Write-Log '[PO Token] Provider: ready (bgutil localhost HTTP provider)'
        $extraArguments = @('--plugin-dirs', $provider.PluginRoot, '--extractor-args', "youtubepot-bgutilhttp:base_url=$($provider.BaseUrl)")
        $position = 0
        foreach ($url in $urls) {
            $position++
            Write-Log "[Batch] Testing $position/$($urls.Count): $url"
            try {
                $diagnostic = Invoke-VerboseDiagnosticProbe $url 'mweb' $credentials $Deno $extraArguments
                if (-not $diagnostic.CookiesArgumentPresent) { throw 'authentication argument missing: --cookies was not included; anonymous probe was not run' }
                $result = Get-PremiumClientDiffResult $diagnostic
                $info = $diagnostic.Info
                $videoId = if ($info) { [string]$info.id } else { 'Unknown' }
                $title = if ($info) { [string]$info.title } else { 'Unknown' }
                $channel = if ($info) { [string]$(if ($info.channel) { $info.channel } else { $info.uploader }) } else { 'Unknown' }
                $musicSource = 'Unknown'
                if ($info -and ($info.artist -or @($info.artists | Where-Object { $_ }).Count -gt 0 -or $info.album -or $info.track)) { $musicSource = 'Music metadata present; artist/topic channel status: Unknown' }
                elseif ($info -and @($info.categories) -contains 'Music') { $musicSource = 'JSON category: Music; artist/topic channel status: Unknown' }
                $gvsToken = @($diagnostic.Lines | Where-Object { -not $_.StartsWith('{') -and $_ -match '(?i)Retrieved a gvs PO Token.*mweb' }).Count -gt 0
                $record = [pscustomobject]@{
                    Url=$url; VideoId=$videoId; Title=$title; Channel=$channel; MusicSource=$musicSource
                    PremiumConfirmed=(Get-AuthenticationValidationSignals $diagnostic).PremiumConfirmed
                    Success=$result.Success; ExitCode=$diagnostic.ExitCode; FormatCount=$result.FormatCount; AudioCount=$result.AudioFormats.Count
                    Has141=$result.Has141; Has774=$result.Has774; BestOpus=$result.BestOpus; BestAac=$result.BestAac
                    GvsToken=$gvsToken; GvsWarning=$result.GvsWarning.Present
                }
                $results.Add($record)
                $opusText = if ($record.BestOpus) { '{0} / {1:N1} kbps' -f $record.BestOpus.format_id, $record.BestOpus.abr } else { 'none' }
                $aacText = if ($record.BestAac) { '{0} / {1:N1} kbps' -f $record.BestAac.format_id, $record.BestAac.abr } else { 'none' }
                Write-Log "[Batch] $title | Opus: $opusText | 774: $(if ($record.Has774) { 'Yes' } else { 'No' }) | AAC: $aacText | 141: $(if ($record.Has141) { 'Yes' } else { 'No' })"
                if ($record.Has774) {
                    $format774 = @($info.formats | Where-Object { $_.format_id -eq '774' })[0]
                    Write-Log '[Premium Format Found]'
                    Write-Log "[Premium Format Found] Video: $title [$videoId]"
                    $foundLine = "[Premium Format Found] Format: 774; Codec: $($format774.acodec); ABR: $($format774.abr) kbps; Client: mweb; GVS PO Token: $(if ($record.GvsToken) { 'available' } else { 'Unknown' })"
                    Write-Log $foundLine
                    $fileLines.Add("[Premium Format Found] Video: $title [$videoId]"); $fileLines.Add($foundLine)
                }
                $fileLines.Add("`r`n===== Video $position/$($urls.Count) =====")
                $fileLines.Add("URL: $url"); $fileLines.Add("Video ID: $videoId"); $fileLines.Add("Title: $title"); $fileLines.Add("Channel/uploader: $channel")
                $fileLines.Add("Music/artist/topic source: $musicSource"); $fileLines.Add("Premium: $(if ($record.PremiumConfirmed) { 'Confirmed' } else { 'Unknown' })")
                $fileLines.Add("ProcessExitCode: $($record.ExitCode); JsonAvailable: $(if ($info) { 'Yes' } else { 'No' }); GVS token: $($record.GvsToken); GVS warning: $($record.GvsWarning)")
                $fileLines.Add("Formats: $($record.FormatCount); Audio-only: $($record.AudioCount); 141: $($record.Has141); 774: $($record.Has774); Best Opus: $opusText; Best AAC: $aacText")
                foreach ($audio in $result.AudioFormats) { $fileLines.Add((Format-PremiumClientDiffAudio $audio)) }
                $fileLines.Add('----- BEGIN VERBOSE (redacted) -----'); foreach ($line in $diagnostic.Lines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }; $fileLines.Add('----- END VERBOSE -----')
            } catch {
                Write-Log "[Batch] Failed: $url | $($_.Exception.Message)"
                $results.Add([pscustomobject]@{ Url=$url; VideoId='Unknown'; Title='Unknown'; Channel='Unknown'; MusicSource='Unknown'; PremiumConfirmed=$false; Success=$false; ExitCode='Unknown'; FormatCount=0; AudioCount=0; Has141=$false; Has774=$false; BestOpus=$null; BestAac=$null; GvsToken=$false; GvsWarning=$false })
                $fileLines.Add("`r`n===== Failed URL $position/$($urls.Count) ====="); $fileLines.Add("URL: $url"); $fileLines.Add("Error: $($_.Exception.Message)")
            }
        }
        $successful = @($results | Where-Object Success)
        $count774 = @($successful | Where-Object Has774).Count; $count141 = @($successful | Where-Object Has141).Count
        $only251 = @($successful | Where-Object { $_.BestOpus -and $_.BestOpus.format_id -eq '251' }).Count
        $denominator = $successful.Count
        $ratio774 = if ($denominator) { 100 * $count774 / $denominator } else { 0 }; $ratio141 = if ($denominator) { 100 * $count141 / $denominator } else { 0 }
        Write-Log '[Batch] Ratios use successful JSON results as denominator; failed probes are excluded.'
        $fileLines.Add('Ratios use successful JSON results as denominator; failed probes are excluded.')
        Write-Log '[Batch] Title | Best Opus | 774 | Best AAC | 141'
        foreach ($record in $results) {
            $opusText = if ($record.BestOpus) { '{0} / {1:N1}' -f $record.BestOpus.format_id, $record.BestOpus.abr } else { 'none' }
            $aacText = if ($record.BestAac) { '{0} / {1:N1}' -f $record.BestAac.format_id, $record.BestAac.abr } else { 'none' }
            Write-Log ('[Batch] {0} | {1} | {2} | {3} | {4}' -f $record.Title, $opusText, $(if ($record.Has774) { 'Yes' } else { 'No' }), $aacText, $(if ($record.Has141) { 'Yes' } else { 'No' }))
        }
        Write-Log ('[Batch] Statistics: tested={0}; successful JSON={1}; 774={2}; 141={3}; only-251-best-Opus={4}; 774 ratio={5:N1}%; 141 ratio={6:N1}%' -f $urls.Count, $denominator, $count774, $count141, $only251, $ratio774, $ratio141)
        $fileLines.Add("`r`n===== Total table ====="); $fileLines.Add('Title | Best Opus | 774 | Best AAC | 141')
        foreach ($record in $results) {
            $opusText = if ($record.BestOpus) { '{0} / {1:N1}' -f $record.BestOpus.format_id, $record.BestOpus.abr } else { 'none' }; $aacText = if ($record.BestAac) { '{0} / {1:N1}' -f $record.BestAac.format_id, $record.BestAac.abr } else { 'none' }
            $fileLines.Add(('{0} | {1} | {2} | {3} | {4}' -f $record.Title, $opusText, $record.Has774, $aacText, $record.Has141))
        }
        $fileLines.Add(('Statistics: tested={0}; successful JSON={1}; 774={2}; 141={3}; only-251-best-Opus={4}; 774 ratio={5:N1}%; 141 ratio={6:N1}%' -f $urls.Count, $denominator, $count774, $count141, $only251, $ratio774, $ratio141))
        if ($successful.Count -eq $urls.Count -and $successful.Count -gt 0 -and @($successful | Where-Object { -not ($_.BestOpus -and $_.BestOpus.format_id -eq '251' -and $_.BestAac -and $_.BestAac.format_id -eq '140') }).Count -eq 0) {
            Write-Log 'No Premium high-bitrate format was exposed for any tested URL.'
            $fileLines.Add('No Premium high-bitrate format was exposed for any tested URL.')
        }
    } catch {
        Write-Log "[Batch] 錯誤：$($_.Exception.Message)"; $fileLines.Add("Batch setup error: $($_.Exception.Message)")
        foreach ($line in $Script:LastPoTokenSetupLines) { $fileLines.Add((Protect-PoTokenLogLine $line)) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Batch Premium Format Test 失敗', 'OK', 'Error') | Out-Null
    } finally {
        if ($logPath) { [System.IO.File]::WriteAllText($logPath, ($fileLines -join "`r`n"), [System.Text.Encoding]::UTF8); Write-Log "[Batch] Full result log: $logPath" }
        $batchPremiumTestButton.Enabled = $true
        $panel.Enabled = $true
    }
}

function Write-DiagnosticSummary($Diagnostic, [string]$Version, $Cookies) {
    $lines = @($Diagnostic.Lines | Where-Object { -not $_.StartsWith('{') })
    $versionLine = Get-DiagnosticLineSummary $lines '(?i)yt-dlp version|\[debug\].*version' $Version
    Write-Log "[Diagnostic] yt-dlp version: $versionLine"
    $cookieStatus = if ($Cookies.Kind -eq 'none') { 'not requested' } else { Get-DiagnosticLineSummary $lines '(?i)(extracting|loading|loaded|found).*cookies|cookies.*(extracting|loading|loaded|found)' 'Unknown' }
    Write-Log "[Diagnostic] Cookies: $cookieStatus"
    Write-Log "[Diagnostic] Login status: $(Get-DiagnosticLineSummary $lines '(?i)logged[ -]?in|login|authenticated|account' 'Unknown')"
    Write-Log "[Diagnostic] Premium status: $(Get-DiagnosticLineSummary $lines '(?i)premium' 'Unknown')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) PO Token: $(Get-DiagnosticLineSummary $lines '(?i)po[ -_]?token' 'None reported')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) SABR: $(Get-DiagnosticLineSummary $lines '(?i)sabr' 'None reported')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) skipped formats: $(Get-DiagnosticLineSummary $lines '(?i)skip(ped|ping).*format|format.*skip' 'None reported')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) missing formats: $(Get-DiagnosticLineSummary $lines '(?i)missing.*format|format.*(not available|unavailable)' 'None reported')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) JS/EJS: $(Get-DiagnosticLineSummary $lines '(?i)(javascript|js challenge|ejs|signature solving)' 'None reported')"
    Write-Log "[Diagnostic] $($Diagnostic.Client) client availability: $(Get-DiagnosticLineSummary $lines '(?i)(player.?client|client).*(not available|unavailable|skip|format)' 'None reported')"
    if ($Diagnostic.Info) {
        $jsonFields = @(Get-DiagnosticJsonFields $Diagnostic.Info | Select-Object -First 20)
        if ($jsonFields.Count) { Write-Log "[Diagnostic] $($Diagnostic.Client) JSON signals: $($jsonFields -join ' | ')" }
        else { Write-Log "[Diagnostic] $($Diagnostic.Client) JSON signals: Unknown" }
    } else { Write-Log "[Diagnostic] $($Diagnostic.Client) JSON signals: Unknown" }
}

function Run-DetailedDiagnostics {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片網址後再執行詳細診斷。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $diagnosticButton.Enabled = $false
        Ensure-Tools
        $credentials = Get-ProbeCredentialContext
        if ($credentials.Kind -eq 'file') {
            Write-Log '[Auth] Probe mode: cookies file'
            Write-Log "[Auth] Cookie path: $($credentials.Value)"
        } elseif ($credentials.Kind -eq 'browser') {
            Write-Log '[Auth] Probe mode: browser'
            Write-Log "[Auth] Browser: $($credentials.Value)"
        } else { Write-Log '[Auth] Probe mode: none' }
        $version = Get-YtDlpVersion
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logsRoot = Join-Path $AppRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
        $logPath = Join-Path $logsRoot "probe-debug-$timestamp.txt"
        $fileLines = [System.Collections.Generic.List[string]]::new()
        $successes = 0
        foreach ($client in @('Auto', 'web_music')) {
            Write-Log "[Diagnostic] Testing $client..."
            try {
                $diagnostic = Invoke-VerboseDiagnosticProbe $url $client $credentials $Deno
                $fileLines.Add("===== $client (exit code $($diagnostic.ExitCode)) =====")
                foreach ($line in $diagnostic.Lines) { $fileLines.Add($line) }
                $fileLines.Add('')
                if ($diagnostic.ExitCode -eq 0) { $successes++ }
                else { Write-Log "[Diagnostic] $client failed with exit code $($diagnostic.ExitCode)." }
                if ($credentials.Kind -eq 'file') {
                    Write-Log "[Auth] ${client}: verified --cookies argument"
                    Write-Log "[Auth] $client command auth: --cookies `"$($credentials.Value)`""
                }
                elseif ($credentials.Kind -eq 'browser') { Write-Log "[Auth] ${client}: verified --cookies-from-browser argument" }
                else { Write-Log "[Auth] ${client}: no authentication argument requested" }
                $detectedClients = Get-DetectedPlayerClients $diagnostic.Lines
                if ($detectedClients.Count) { Write-Log "[Diagnostic] $client player client(s): $($detectedClients -join ', ')" }
                else { Write-Log "[Diagnostic] $client player client(s): Unknown" }
                Write-DiagnosticSummary $diagnostic $version $credentials
                Write-DiagnosticFormatSummary $diagnostic
                Write-Log "[Diagnostic] $client verdict: $(Get-DiagnosticCookieVerdict $diagnostic $credentials)"
            } catch {
                $message = $_.Exception.Message
                $fileLines.Add("===== $client failed before verbose output =====")
                $fileLines.Add($message)
                $fileLines.Add('')
                Write-Log "[Diagnostic] $client failed: $message"
            }
        }
        [System.IO.File]::WriteAllText($logPath, ($fileLines -join "`r`n"), [System.Text.Encoding]::UTF8)
        Write-Log "[Diagnostic] Full verbose log: $logPath"
        if (-not $successes) { throw 'Auto 與 web_music 詳細診斷皆失敗；請查看完整 verbose log。' }
    } catch {
        Write-Log "[Diagnostic] 錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '詳細診斷失敗', 'OK', 'Error') | Out-Null
    } finally { $diagnosticButton.Enabled = $true }
}

function Update-YtDlp {
    if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('下載進行中，無法更新 yt-dlp。', '請稍候', 'OK', 'Information') | Out-Null
        return
    }
    $updateButton.Enabled = $false
    try {
        New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
        $tempFile = Join-Path $env:TEMP ('yt-dlp-' + [guid]::NewGuid() + '.exe')
        try {
            Write-Log '[Update] 正在從官方 release 下載最新版 yt-dlp…'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $tempFile
            Copy-Item -LiteralPath $tempFile -Destination $YtDlp -Force
        } finally { if (Test-Path $tempFile) { Remove-Item -LiteralPath $tempFile -Force } }
        Write-Log "[Update] yt-dlp updated: $(Get-YtDlpVersion)"
    } catch {
        Write-Log "[Update] 錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'yt-dlp 更新失敗', 'OK', 'Error') | Out-Null
    } finally { $updateButton.Enabled = $true }
}

function Check-Formats {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片網址後再檢查格式。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $probeButton.Enabled = $false
        $Script:FormatProbeCache = $null
        [void](Get-AudioFormatProbe $url)
    } catch {
        Write-Log "[Probe] 錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '格式檢查失敗', 'OK', 'Error') | Out-Null
    } finally { $probeButton.Enabled = $true }
}

function Start-Download {
    $url = $urlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片或播放清單網址。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('已有下載工作進行中。', '請稍候', 'OK', 'Information') | Out-Null
        return
    }

    try {
        $startButton.Enabled = $false
        $cancelButton.Enabled = $true
        Ensure-Tools

        $format = $formatBox.SelectedItem.ToString().ToLowerInvariant()
        $qualityMode = $qualityModeBox.SelectedItem.ToString()
        $qualityLabel = $qualityBox.SelectedItem.ToString()
        $quality = if ($qualityLabel.StartsWith('0')) { '0' } else { $qualityLabel }
        $destination = $folderBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($destination)) { $destination = $OutputRoot }
        New-Item -ItemType Directory -Force -Path $destination | Out-Null

        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add('--newline')
        $args.Add('--no-mtime')
        $args.Add('--ignore-errors')
        $args.Add('--windows-filenames')
        Add-YtDlpAccessArguments $args
        $downloadClient = 'Auto'
        $formatSelector = 'bestaudio/best'
        $useOriginalOpus = $format -eq 'opus' -and $qualityMode -eq '保留來源最佳品質'
        if ($useOriginalOpus) {
            $probe = Get-AudioFormatProbe $url
            if ($probe.Selected) {
                $selected = $probe.Selected
                $downloadClient = $selected.Client
                $formatSelector = $selected.BestOpus.format_id
                if ($selected.Client -ne 'Auto') {
                    $args.Add('--extractor-args'); $args.Add("youtube:player_client=$($selected.Client)")
                }
                $args.Add('-f'); $args.Add($selected.BestOpus.format_id)
                $args.Add('--remux-video'); $args.Add('opus')
                Write-Log "[Download] Using $($selected.Client) original Opus format $($selected.BestOpus.format_id)"
                Write-Log '[Remux] No audio re-encoding'
            } else {
                Write-Log '[Download] 沒有找到原始 Opus 格式；不會默默重新編碼。'
                $fallback = [System.Windows.Forms.MessageBox]::Show(
                    '此影片沒有原始 Opus 音訊。要改下載最佳可用原始音訊（不轉碼，副檔名可能不是 .opus）嗎？',
                    '找不到原始 Opus', 'YesNo', 'Warning')
                if ($fallback -ne 'Yes') { Write-Log '[Download] 使用者取消 fallback。'; return }
                $args.Add('-f'); $args.Add('bestaudio/best')
                Write-Log '[Download] Fallback to best available original audio; no audio re-encoding.'
            }
        } else {
            $args.Add('-f'); $args.Add('bestaudio/best')
            $args.Add('-x')
            $args.Add('--audio-format'); $args.Add($format)
            if ($format -notin @('flac', 'wav')) {
                $args.Add('--audio-quality'); $args.Add($quality)
            }
            Write-Log "[Download] Re-encoding or codec conversion to $format ($qualityLabel)"
        }
        $args.Add('-o'); $args.Add((Join-Path $destination '%(playlist_index&{} - |)s%(title)s [%(id)s].%(ext)s'))
        if ($playlistCheck.Checked) { $args.Add('--yes-playlist') } else { $args.Add('--no-playlist') }
        $args.Add($url)

        Write-Log "開始下載：格式 $format，模式 $qualityMode，輸出至 $destination"
        $cookieFile = $cookieFileBox.Text.Trim()
        if ($cookieFile) {
            Write-Log '[Auth] Download mode: cookies file'
            Write-Log "[Auth] Cookie path: $cookieFile"
            $authSummary = 'cookies file'
        } elseif ($browserBox.SelectedIndex -gt 0) {
            $browserName = $browserBox.SelectedItem.ToString().ToLowerInvariant()
            Write-Log '[Auth] Download mode: browser'
            Write-Log "[Auth] Browser: $browserName"
            $authSummary = "browser:$browserName"
        } else {
            Write-Log '[Auth] Download mode: none'
            $authSummary = 'none'
        }
        $playlistMode = if ($playlistCheck.Checked) { 'yes-playlist' } else { 'no-playlist' }
        Write-Log "[Command] format=$formatSelector; client=$downloadClient; auth=$authSummary; deno=$Deno; playlist=$playlistMode"

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $YtDlp
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = (($args | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
        # The CLR helper owns the async stream callbacks.  PowerShell itself
        # only reads the queue on the UI thread, avoiding deadlocks and event
        # callback failures in Windows PowerShell 5.1.
        $loggedProcess = [YtAudioDownloader.LoggedProcess]::new()
        $loggedProcess.Start($psi)
        $Script:ActiveProcess = $loggedProcess.Process
        while (-not $Script:ActiveProcess.HasExited) {
            $queuedLine = $null
            while ($loggedProcess.Lines.TryDequeue([ref]$queuedLine)) { Write-Log $queuedLine }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $Script:ActiveProcess.WaitForExit()
        $queuedLine = $null
        while ($loggedProcess.Lines.TryDequeue([ref]$queuedLine)) { Write-Log $queuedLine }
        if ($Script:ActiveProcess.ExitCode -eq 0) { Write-Log '完成。' } else { Write-Log "下載結束，yt-dlp 結束代碼：$($Script:ActiveProcess.ExitCode)" }
    } catch {
        Write-Log "錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '下載失敗', 'OK', 'Error') | Out-Null
    } finally {
        $Script:ActiveProcess = $null
        $startButton.Enabled = $true
        $cancelButton.Enabled = $false
    }
}

$form = [System.Windows.Forms.Form]@{ Text = 'YouTube 音訊下載器'; Size = [System.Drawing.Size]::new(820, 740); StartPosition = 'CenterScreen'; MinimumSize = [System.Drawing.Size]::new(820,740); Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 10) }
$panel = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(18); ColumnCount = 2; RowCount = 10 }
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 118))
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
1..8 | ForEach-Object { [void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) }
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$form.Controls.Add($panel)
$form.Add_FormClosed({
    if ($Script:PoTokenProviderProcess -and -not $Script:PoTokenProviderProcess.Process.HasExited) {
        $Script:PoTokenProviderProcess.Process.Kill()
    }
})

function Add-Label([string]$text, [int]$row) { $c=[System.Windows.Forms.Label]@{Text=$text; Anchor='Left'; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,9,8,9)}; $panel.Controls.Add($c,0,$row) }
Add-Label 'YouTube 網址' 0
$urlLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$true }
$urlBox = [System.Windows.Forms.TextBox]@{ Width=390; Margin=[System.Windows.Forms.Padding]::new(0,3,5,3) }
$probeButton = [System.Windows.Forms.Button]@{ Text='檢查格式'; AutoSize=$true }
$diagnosticButton = [System.Windows.Forms.Button]@{ Text='詳細診斷'; AutoSize=$true }
$batchUrlLabel = [System.Windows.Forms.Label]@{ Text='批次網址（每行一個）'; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(0,8,8,3) }
$batchUrlBox = [System.Windows.Forms.TextBox]@{ Width=540; Height=58; Multiline=$true; ScrollBars='Vertical'; Margin=[System.Windows.Forms.Padding]::new(0,3,5,3) }
$batchPremiumTestButton = [System.Windows.Forms.Button]@{ Text='Batch Premium Format Test'; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(0,12,3,3) }
$urlLine.Controls.AddRange(@($urlBox,$probeButton,$diagnosticButton,$batchUrlLabel,$batchUrlBox,$batchPremiumTestButton)); $panel.Controls.Add($urlLine,1,0)
Add-Label '下載範圍' 1
$playlistCheck = [System.Windows.Forms.CheckBox]@{ Text='下載整個播放清單（取消勾選即只下載此影片）'; Checked=$true; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,7,3,7) }; $panel.Controls.Add($playlistCheck,1,1)
Add-Label '音訊格式' 2
$formatBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$formatBox.Items.AddRange(@('opus','mp3','m4a','flac','wav')); $formatBox.SelectedItem='opus'; $panel.Controls.Add($formatBox,1,2)
Add-Label '品質模式' 3
$qualityModeBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=220 }; [void]$qualityModeBox.Items.AddRange(@('保留來源最佳品質','重新編碼')); $qualityModeBox.SelectedIndex=0; $panel.Controls.Add($qualityModeBox,1,3)
Add-Label '轉碼品質' 4
$qualityBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$qualityBox.Items.AddRange(@('0（最佳）','64K','96K','128K','160K','192K','256K','320K')); $qualityBox.SelectedItem='0（最佳）'; $panel.Controls.Add($qualityBox,1,4)
function Update-QualityControls {
    $preserveOriginalOpus = $formatBox.SelectedItem -eq 'opus' -and $qualityModeBox.SelectedItem -eq '保留來源最佳品質'
    $qualityBox.Enabled = -not $preserveOriginalOpus
}
$formatBox.Add_SelectedIndexChanged({ Update-QualityControls })
$qualityModeBox.Add_SelectedIndexChanged({ Update-QualityControls })
Update-QualityControls
Add-Label '登入瀏覽器' 5
$browserBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$browserBox.Items.AddRange(@('不使用登入','Chrome','Edge','Firefox','Brave')); $browserBox.SelectedIndex=0; $panel.Controls.Add($browserBox,1,5)
Add-Label 'Cookies 檔案' 6
$cookieLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$cookieFileBox = [System.Windows.Forms.TextBox]@{ Width=520 }
$cookieBrowseButton = [System.Windows.Forms.Button]@{ Text='選擇…'; AutoSize=$true }
$cookieBrowseButton.Add_Click({ $d=[System.Windows.Forms.OpenFileDialog]::new(); $d.Filter='Cookie files (*.txt)|*.txt|All files (*.*)|*.*'; $d.Title='選擇 Netscape cookies.txt'; if($d.ShowDialog() -eq 'OK'){$cookieFileBox.Text=$d.FileName} })
$cookieLine.Controls.AddRange(@($cookieFileBox,$cookieBrowseButton)); $panel.Controls.Add($cookieLine,1,6)
$urlBox.Add_TextChanged({ $Script:FormatProbeCache = $null })
$cookieFileBox.Add_TextChanged({ $Script:FormatProbeCache = $null })
$browserBox.Add_SelectedIndexChanged({ $Script:FormatProbeCache = $null })
Add-Label '輸出資料夾' 7
$folderLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$folderBox = [System.Windows.Forms.TextBox]@{ Width=520; Text=$OutputRoot }; $browseButton = [System.Windows.Forms.Button]@{ Text='選擇…'; AutoSize=$true }
$browseButton.Add_Click({ $d=[System.Windows.Forms.FolderBrowserDialog]::new(); $d.SelectedPath=$folderBox.Text; if($d.ShowDialog() -eq 'OK'){$folderBox.Text=$d.SelectedPath} }); $folderLine.Controls.AddRange(@($folderBox,$browseButton)); $panel.Controls.Add($folderLine,1,7)
Add-Label '執行紀錄' 8
$log = [System.Windows.Forms.TextBox]@{ Dock='Fill'; Multiline=$true; ScrollBars='Vertical'; ReadOnly=$true; BackColor=[System.Drawing.Color]::FromArgb(28,31,35); ForeColor=[System.Drawing.Color]::Gainsboro; Font=[System.Drawing.Font]::new('Consolas',9); Margin=[System.Windows.Forms.Padding]::new(3,5,3,8) }; $panel.Controls.Add($log,1,8)
$buttonLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; FlowDirection='RightToLeft' }
$startButton = [System.Windows.Forms.Button]@{ Text='開始下載'; AutoSize=$true; Padding=[System.Windows.Forms.Padding]::new(12,4,12,4) }
$cancelButton = [System.Windows.Forms.Button]@{ Text='停止'; AutoSize=$true; Enabled=$false }
$openButton = [System.Windows.Forms.Button]@{ Text='開啟下載資料夾'; AutoSize=$true }
$updateButton = [System.Windows.Forms.Button]@{ Text='更新 yt-dlp'; AutoSize=$true }
$authValidationButton = [System.Windows.Forms.Button]@{ Text='驗證登入'; AutoSize=$true }
$premiumDiffButton = [System.Windows.Forms.Button]@{ Text='Premium Client Format Diff'; AutoSize=$true }
$poTokenTestButton = [System.Windows.Forms.Button]@{ Text='PO Token Test'; AutoSize=$true }
$exposureButton = [System.Windows.Forms.Button]@{ Text='Premium Exposure Verification'; AutoSize=$true }
$exposureButton.Add_Click({ Run-PremiumExposureVerification })
$buttonLine.Controls.Add($exposureButton)
$probeButton.Add_Click({ Check-Formats })
$diagnosticButton.Add_Click({ Run-DetailedDiagnostics })
$authValidationButton.Add_Click({ Run-AuthenticationValidation })
$premiumDiffButton.Add_Click({ Run-PremiumClientFormatDiff })
$poTokenTestButton.Add_Click({ Run-PoTokenTest })
$batchPremiumTestButton.Add_Click({ Run-BatchPremiumFormatTest })
$startButton.Add_Click({ Start-Download })
$cancelButton.Add_Click({ if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) { $Script:ActiveProcess.Kill(); Write-Log '已要求停止下載。' } })
$openButton.Add_Click({ New-Item -ItemType Directory -Force -Path $folderBox.Text | Out-Null; Start-Process explorer.exe $folderBox.Text })
$updateButton.Add_Click({ Update-YtDlp })
$buttonLine.Controls.AddRange(@($startButton,$cancelButton,$openButton,$updateButton,$authValidationButton,$premiumDiffButton,$poTokenTestButton)); $panel.Controls.Add($buttonLine,1,9)

Write-Log '就緒。選擇 Opus + 0（最佳）可保留最高可用音訊品質。'
[void]$form.ShowDialog()
