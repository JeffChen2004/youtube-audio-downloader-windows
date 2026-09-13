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

function Test-PoTokenProviderPing([string]$BaseUrl = 'http://127.0.0.1:4416') {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($BaseUrl.TrimEnd('/') + '/ping') -TimeoutSec 3
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
    } catch { return $false }
}

function Drain-PoTokenProviderOutput {
    if (-not $Script:PoTokenProviderProcess) { return }
    $line = $null
    while ($Script:PoTokenProviderProcess.Lines.TryDequeue([ref]$line)) {
        Write-Log "[PO Token] $(Protect-PoTokenLogLine $line)"
    }
    # LoggedProcess also keeps per-stream queues. Drain these duplicates so a
    # long playlist does not retain provider output for the entire session.
    foreach ($stream in @('OutputLines', 'ErrorLines')) {
        $line = $null
        while ($Script:PoTokenProviderProcess.$stream.TryDequeue([ref]$line)) { }
    }
}

function Stop-PoTokenProvider {
    if (-not $Script:PoTokenProviderProcess) { return }
    try {
        Drain-PoTokenProviderOutput
        if (-not $Script:PoTokenProviderProcess.Process.HasExited) {
            $Script:PoTokenProviderProcess.Process.Kill()
            $Script:PoTokenProviderProcess.Process.WaitForExit()
        }
        Drain-PoTokenProviderOutput
        Write-Log '[PO Token] Provider stopped'
    } catch {
        Write-Log "[PO Token] Provider stop warning: $($_.Exception.Message)"
    } finally { $Script:PoTokenProviderProcess = $null }
}

function Ensure-PoTokenProviderRetryPatch([string]$PluginZip) {
    $runtimeRoot = Join-Path $PoTokenRoot 'plugin-runtime'
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    Expand-Archive -LiteralPath $PluginZip -DestinationPath $runtimeRoot -Force
    $sourcePath = Join-Path $runtimeRoot 'yt_dlp_plugins\extractor\getpot_bgutil_http.py'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw '解壓後找不到 bgutil HTTP provider plugin。'
    }
    $source = Get-Content -LiteralPath $sourcePath -Raw
    if (-not $source.Contains('def _request_webpage_with_retry(')) {
        $anchor = '    def is_available(self):'
        if (-not $source.Contains($anchor)) { throw 'bgutil HTTP plugin 版本無法套用有限次數 retry patch。' }
        # Both calls in this provider target its configured localhost HTTP
        # server. HTTP responses and parsing errors keep their original
        # handling; only networking TransportError receives one delayed retry.
        $source = $source.Replace('self._request_webpage(', 'self._request_webpage_with_retry(')
        $retryMethod = @'
    def _request_webpage_with_retry(self, request, **kwargs):
        for attempt in range(2):
            try:
                response = self._request_webpage(request=request, **kwargs)
                if attempt:
                    self.logger.warning('[PO Token] Retry successful')
                return response
            except HTTPError:
                raise
            except TransportError as e:
                if attempt:
                    self.logger.warning('[PO Token] Retry failed')
                    raise
                self.logger.warning(f'[PO Token] Temporary provider error: {e!r}')
                self.logger.warning('[PO Token] Retrying in 2 seconds...')
                time.sleep(2)

'@
        $source = $source.Replace($anchor, $retryMethod + $anchor)
        [System.IO.File]::WriteAllText($sourcePath, $source, [System.Text.UTF8Encoding]::new($false))
    }
    return $runtimeRoot
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
        $runtimePluginRoot = Ensure-PoTokenProviderRetryPatch $PoTokenPluginZip
        $nodeModules = Join-Path $serverRoot 'node_modules'
        if (-not (Test-Path -LiteralPath $nodeModules -PathType Container)) {
            Write-Log '[PO Token] 正在準備 bgutil Deno provider 依賴…'
            $denoInstall = Invoke-CapturedProcess $Deno @('install', '--allow-scripts=npm:canvas', '--frozen') $serverRoot
            $setupLines.Add("Deno install exit code: $($denoInstall.ExitCode)")
            foreach ($line in $denoInstall.Stdout) { $setupLines.Add("[deno stdout] $(Protect-PoTokenLogLine $line)") }
            foreach ($line in $denoInstall.Stderr) { $setupLines.Add("[deno stderr] $(Protect-PoTokenLogLine $line)") }
            if ($denoInstall.ExitCode -ne 0) { throw "bgutil Deno provider 安裝失敗（exit code $($denoInstall.ExitCode)）。" }
        }
        if ($Script:PoTokenProviderProcess -and $Script:PoTokenProviderProcess.Process.HasExited) {
            $Script:PoTokenProviderProcess = $null
        }
        $providerBaseUrl = 'http://127.0.0.1:4416'
        $serverReady = Test-PoTokenProviderPing $providerBaseUrl
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
                $serverReady = Test-PoTokenProviderPing $providerBaseUrl
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
        if (-not (Test-PoTokenProviderPing $providerBaseUrl)) {
            throw 'bgutil HTTP provider 的 /ping 健康檢查失敗。'
        }
        $setupLines.Add('bgutil HTTP provider ready at http://127.0.0.1:4416 (localhost only).')
        return [pscustomobject]@{ PluginRoot = $runtimePluginRoot; BaseUrl = $providerBaseUrl; SetupLines = @($setupLines) }
    } catch {
        $Script:LastPoTokenSetupLines = @($setupLines)
        if ($Script:PoTokenProviderProcess) { Stop-PoTokenProvider }
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

function Get-DetectedPlayerClients($Lines) {
    $clients = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -match '(?i)Downloading ([a-z0-9_]+) player API JSON') { $clients.Add($Matches[1]) }
        elseif ($line -match '(?i)Downloading web music player API JSON') { $clients.Add('web_music') }
    }
    return @($clients | Select-Object -Unique)
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

function New-DownloadStatistics {
    return [pscustomobject]@{
        ExpectedTotal = 0
        CurrentKey = $null
        Items = [System.Collections.Generic.HashSet[string]]::new()
        Success = [System.Collections.Generic.HashSet[string]]::new()
        Failed = [System.Collections.Generic.HashSet[string]]::new()
        Skipped = [System.Collections.Generic.HashSet[string]]::new()
        SelectedByItem = [System.Collections.Generic.Dictionary[string,string]]::new()
        PoTokenRetryCount = 0
    }
}

function Test-PoTokenProviderHealthWithRetry($ProviderSession, $Statistics) {
    if (Test-PoTokenProviderPing $ProviderSession.BaseUrl) { return $true }
    if ($Script:PoTokenProviderProcess -and $Script:PoTokenProviderProcess.Process.HasExited) { return $false }
    Write-Log '[PO Token] Temporary provider error: localhost /ping failed'
    Write-Log '[PO Token] Retrying in 2 seconds...'
    $Statistics.PoTokenRetryCount++
    1..20 | ForEach-Object {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    if (Test-PoTokenProviderPing $ProviderSession.BaseUrl) {
        Write-Log '[PO Token] Retry successful'
        return $true
    }
    Write-Log '[PO Token] Retry failed'
    Write-Log '[PO Token] Continuing according to existing error handling'
    return $false
}

function Get-DownloadItemKey($Item) {
    if ($Item.playlist_index -and $Item.playlist_index -ne 'NA') { return "playlist:$($Item.playlist_index)" }
    if ($Item.id -and $Item.id -ne 'NA') { return "video:$($Item.id)" }
    return 'video:1'
}

function Write-PreferredFormatSelectionLog([string]$Line, $Statistics = $null) {
    $prefix = '__YAD_PREFERRED_FORMAT__'
    if (-not $Line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        Write-Log $Line
        return
    }

    try {
        $item = $Line.Substring($prefix.Length) | ConvertFrom-Json
        $position = if ($item.playlist_index -and $item.playlist_index -ne 'NA') { [string]$item.playlist_index } else { '1' }
        $total = if ($item.playlist_count -and $item.playlist_count -ne 'NA') { [string]$item.playlist_count } elseif ($item.n_entries -and $item.n_entries -ne 'NA') { [string]$item.n_entries } else { '1' }
        $audioIds = @($item.formats | Where-Object {
            $_.vcodec -eq 'none' -and $_.acodec -and $_.acodec -ne 'none'
        } | ForEach-Object { [string]$_.format_id })
        $available = @('774', '141', '251') | Where-Object { $audioIds -contains $_ }
        $availableText = if ($available.Count) { $available -join ', ' } else { 'none' }
        Write-Log "[$position/$total] Available preferred formats: $availableText"

        $selectedId = [string]$item.format_id
        if ($Statistics) {
            $key = Get-DownloadItemKey $item
            [void]$Statistics.Items.Add($key)
            $Statistics.CurrentKey = $key
            $Statistics.SelectedByItem[$key] = $selectedId
            $reportedTotal = if ($item.playlist_count -and $item.playlist_count -ne 'NA') { [int]$item.playlist_count } elseif ($item.n_entries -and $item.n_entries -ne 'NA') { [int]$item.n_entries } else { 1 }
            if ($reportedTotal -gt $Statistics.ExpectedTotal) { $Statistics.ExpectedTotal = $reportedTotal }
        }
        if ($selectedId -in @('774', '141', '251')) {
            Write-Log "[$position/$total] Selected format: $selectedId"
            if ($selectedId -eq '141') {
                Write-Log "[$position/$total] Output: .m4a (original AAC; no audio re-encoding)"
            } else {
                Write-Log "[$position/$total] Output: .opus (original Opus; remux only, no audio re-encoding)"
            }
        } else {
            Write-Log "[$position/$total] No preferred format available; fallback selected: $selectedId"
            Write-Log "[$position/$total] Fallback keeps the original audio; no lossy re-encoding"
        }
    } catch {
        Write-Log "[Selection] 無法解析每首格式選擇紀錄：$($_.Exception.Message)"
    }
}

function Write-DownloadProcessLine([string]$Line, [bool]$PreserveSource, $Statistics) {
    if ($Line.StartsWith('__YAD_PREFERRED_FORMAT__', [System.StringComparison]::Ordinal)) {
        Write-PreferredFormatSelectionLog $Line $Statistics
        return
    }
    if ($Line.StartsWith('__YAD_ITEM_START__', [System.StringComparison]::Ordinal)) {
        try {
            $item = $Line.Substring('__YAD_ITEM_START__'.Length) | ConvertFrom-Json
            $key = Get-DownloadItemKey $item
            [void]$Statistics.Items.Add($key)
            $Statistics.CurrentKey = $key
            $Statistics.SelectedByItem[$key] = [string]$item.format_id
            $reportedTotal = if ($item.playlist_count -and $item.playlist_count -ne 'NA') { [int]$item.playlist_count } elseif ($item.n_entries -and $item.n_entries -ne 'NA') { [int]$item.n_entries } else { 1 }
            if ($reportedTotal -gt $Statistics.ExpectedTotal) { $Statistics.ExpectedTotal = $reportedTotal }
        } catch { Write-Log "[Summary] 無法解析項目開始紀錄：$($_.Exception.Message)" }
        return
    }
    if ($Line.StartsWith('__YAD_ITEM_SUCCESS__', [System.StringComparison]::Ordinal)) {
        try {
            $item = $Line.Substring('__YAD_ITEM_SUCCESS__'.Length) | ConvertFrom-Json
            $key = Get-DownloadItemKey $item
            [void]$Statistics.Items.Add($key)
            if (-not $Statistics.Skipped.Contains($key)) { [void]$Statistics.Success.Add($key) }
            [void]$Statistics.Failed.Remove($key)
        } catch { Write-Log "[Summary] 無法解析項目完成紀錄：$($_.Exception.Message)" }
        return
    }
    if ($Line -match '(?i)\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)') {
        $key = "playlist:$($Matches[1])"
        $Statistics.CurrentKey = $key
        [void]$Statistics.Items.Add($key)
        $reportedTotal = [int]$Matches[2]
        if ($reportedTotal -gt $Statistics.ExpectedTotal) { $Statistics.ExpectedTotal = $reportedTotal }
    }
    if ($Statistics.CurrentKey -and $Line -match '(?i)has already been downloaded|has already been recorded in the archive|\[download\].*skipping') {
        [void]$Statistics.Skipped.Add($Statistics.CurrentKey)
        [void]$Statistics.Success.Remove($Statistics.CurrentKey)
    }
    if ($Statistics.CurrentKey -and $Line -match '(?i)^ERROR:' -and $Line -notmatch '(?i)PO Token|bgutil|localhost|ConnectionReset|transport') {
        [void]$Statistics.Failed.Add($Statistics.CurrentKey)
    }
    if ($Line -match '\[PO Token\] Retrying in 2 seconds') { $Statistics.PoTokenRetryCount++ }
    Write-Log $Line
}

function Write-DownloadSummary($Statistics, [bool]$Stopped) {
    $total = if ($Statistics.ExpectedTotal -gt 0) { $Statistics.ExpectedTotal } elseif ($Statistics.Items.Count -gt 0) { $Statistics.Items.Count } else { 1 }
    if (-not $Stopped) {
        foreach ($key in $Statistics.Items) {
            if (-not $Statistics.Success.Contains($key) -and -not $Statistics.Skipped.Contains($key)) { [void]$Statistics.Failed.Add($key) }
        }
    }
    $counts = @{ '774' = 0; '141' = 0; '251' = 0; 'fallback' = 0 }
    foreach ($key in $Statistics.Success) {
        $selected = if ($Statistics.SelectedByItem.ContainsKey($key)) { $Statistics.SelectedByItem[$key] } else { '' }
        if ($selected -in @('774', '141', '251')) { $counts[$selected]++ } else { $counts['fallback']++ }
    }
    $processed = $Statistics.Items.Count
    $unprocessed = [Math]::Max(0, $total - $processed)
    Write-Log '=============================='
    Write-Log $(if ($Stopped) { '下載已停止' } else { '下載完成摘要' })
    Write-Log '=============================='
    Write-Log "總項目：$total"
    if ($Stopped) { Write-Log "已處理：$processed / $total" }
    Write-Log "成功：$($Statistics.Success.Count)"
    Write-Log "774：$($counts['774'])"
    Write-Log "141：$($counts['141'])"
    Write-Log "251：$($counts['251'])"
    Write-Log "其他來源音訊：$($counts['fallback'])"
    Write-Log "失敗：$($Statistics.Failed.Count)"
    Write-Log "跳過：$($Statistics.Skipped.Count)"
    if ($Stopped) { Write-Log "未處理：$unprocessed" }
    Write-Log "PO Token Retry：$($Statistics.PoTokenRetryCount)"
    Write-Log '=============================='
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

    $providerSession = $null
    $providerFailure = $null
    $downloadStatistics = New-DownloadStatistics
    $downloadProcessStarted = $false
    $summaryWritten = $false
    $Script:DownloadCancelled = $false
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
        $preserveSource = $qualityMode -eq '保留來源最佳品質'
        if ($preserveSource) {
            $providerSession = Ensure-PoTokenProvider
            if (-not (Test-PoTokenProviderPing $providerSession.BaseUrl)) {
                throw 'PO Token provider 未通過 /ping 健康檢查；不會以 Auto client 繼續。'
            }
            Drain-PoTokenProviderOutput
            $downloadClient = 'web_music'
            $args.Add('--plugin-dirs'); $args.Add($providerSession.PluginRoot)
            $args.Add('--extractor-args'); $args.Add('youtube:player_client=web_music')
            $args.Add('--extractor-args'); $args.Add("youtubepot-bgutilhttp:base_url=$($providerSession.BaseUrl)")
            Write-Log '[Client] web_music'
            Write-Log '[PO Token] Provider ready'
            # yt-dlp evaluates slash-separated alternatives again for every
            # playlist item, so no format selected for one item is reused by
            # the next item. The final alternatives retain the existing
            # best-original-audio fallback without lossy conversion.
            $formatSelector = '774/141/251/bestaudio/best'
            $args.Add('-f'); $args.Add($formatSelector)
            # Remux only WebM sources (774/251) to an Opus container. Format
            # 141 is already AAC/m4a and is intentionally left unchanged.
            $args.Add('--remux-video'); $args.Add('webm>opus')
            $args.Add('--print'); $args.Add('before_dl:__YAD_PREFERRED_FORMAT__%(.{id,playlist_index,playlist_count,n_entries,format_id,ext,acodec,formats})j')
            Write-Log '[Download] Per-item source priority: 774 > 141 > 251 > original-audio fallback'
            Write-Log '[Remux] WebM Opus becomes .opus; format 141 remains original AAC in .m4a; no audio re-encoding'
        } else {
            $args.Add('-f'); $args.Add('bestaudio/best')
            $args.Add('-x')
            $args.Add('--audio-format'); $args.Add($format)
            if ($format -notin @('flac', 'wav')) {
                $args.Add('--audio-quality'); $args.Add($quality)
            }
            $args.Add('--print'); $args.Add('before_dl:__YAD_ITEM_START__%(.{id,playlist_index,playlist_count,n_entries,format_id})j')
            Write-Log "[Download] Re-encoding or codec conversion to $format ($qualityLabel)"
        }
        $args.Add('--print'); $args.Add('after_move:__YAD_ITEM_SUCCESS__%(.{id,playlist_index,playlist_count,n_entries,format_id})j')
        $args.Add('--progress')
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
        $downloadProcessStarted = $true
        $nextProviderHealthCheck = (Get-Date).AddSeconds(5)
        while (-not $Script:ActiveProcess.HasExited) {
            $queuedLine = $null
            while ($loggedProcess.Lines.TryDequeue([ref]$queuedLine)) {
                Write-DownloadProcessLine $queuedLine $preserveSource $downloadStatistics
            }
            if ($preserveSource) {
                Drain-PoTokenProviderOutput
                if ($Script:PoTokenProviderProcess -and $Script:PoTokenProviderProcess.Process.HasExited) {
                    $providerFailure = "PO Token provider 在播放清單下載期間意外結束（exit code $($Script:PoTokenProviderProcess.Process.ExitCode)）；下載已停止，不會降級成 Auto client。"
                } elseif ((Get-Date) -ge $nextProviderHealthCheck) {
                    if (-not (Test-PoTokenProviderHealthWithRetry $providerSession $downloadStatistics)) {
                        $providerFailure = 'PO Token provider 在播放清單下載期間無法通過 /ping 健康檢查；下載已停止，不會降級成 Auto client。'
                    }
                    $nextProviderHealthCheck = (Get-Date).AddSeconds(5)
                }
                if ($providerFailure) {
                    Write-Log "[PO Token] ERROR: $providerFailure"
                    if (-not $Script:ActiveProcess.HasExited) { $Script:ActiveProcess.Kill() }
                    break
                }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $Script:ActiveProcess.WaitForExit()
        $queuedLine = $null
        while ($loggedProcess.Lines.TryDequeue([ref]$queuedLine)) {
            Write-DownloadProcessLine $queuedLine $preserveSource $downloadStatistics
        }
        if ($preserveSource) {
            Drain-PoTokenProviderOutput
            if (-not $providerFailure -and $Script:PoTokenProviderProcess -and $Script:PoTokenProviderProcess.Process.HasExited) {
                $providerFailure = "PO Token provider 在 yt-dlp process 結束前後意外終止（exit code $($Script:PoTokenProviderProcess.Process.ExitCode)）；未使用 Auto client fallback。"
                Write-Log "[PO Token] ERROR: $providerFailure"
            } elseif (-not $providerFailure -and -not (Test-PoTokenProviderPing $providerSession.BaseUrl)) {
                $providerFailure = 'PO Token provider 在 yt-dlp process 結束時無法通過 /ping 健康檢查；未使用 Auto client fallback。'
                Write-Log "[PO Token] ERROR: $providerFailure"
            }
        }
        if ($providerFailure) { throw $providerFailure }
        if ($Script:ActiveProcess.ExitCode -eq 0) { Write-Log '完成。' } else { Write-Log "下載結束，yt-dlp 結束代碼：$($Script:ActiveProcess.ExitCode)" }
    } catch {
        Write-Log "錯誤：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '下載失敗', 'OK', 'Error') | Out-Null
    } finally {
        if ($providerSession) { Stop-PoTokenProvider }
        if ($downloadProcessStarted -and -not $summaryWritten) {
            Write-DownloadSummary $downloadStatistics $Script:DownloadCancelled
            $summaryWritten = $true
        }
        $Script:ActiveProcess = $null
        $startButton.Enabled = $true
        $cancelButton.Enabled = $false
    }
}

$form = [System.Windows.Forms.Form]@{ Text = 'YouTube 音訊下載器'; Size = [System.Drawing.Size]::new(820, 680); StartPosition = 'CenterScreen'; MinimumSize = [System.Drawing.Size]::new(820,620); Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 10) }
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
$urlLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$urlBox = [System.Windows.Forms.TextBox]@{ Width=500; Margin=[System.Windows.Forms.Padding]::new(0,3,5,3) }
$probeButton = [System.Windows.Forms.Button]@{ Text='檢查可用品質'; AutoSize=$true }
$urlLine.Controls.AddRange(@($urlBox,$probeButton)); $panel.Controls.Add($urlLine,1,0)
Add-Label '下載範圍' 1
$playlistCheck = [System.Windows.Forms.CheckBox]@{ Text='下載整個播放清單（取消勾選即只下載此影片）'; Checked=$true; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,7,3,7) }; $panel.Controls.Add($playlistCheck,1,1)
Add-Label '品質模式' 2
$qualityModeLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$qualityModeBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=220 }; [void]$qualityModeBox.Items.AddRange(@('保留來源最佳品質','重新編碼')); $qualityModeBox.SelectedIndex=0
$sourcePriorityLabel = [System.Windows.Forms.Label]@{ Text='優先：774 → 141 → 251'; AutoSize=$true; ForeColor=[System.Drawing.Color]::DimGray; Font=[System.Drawing.Font]::new('Microsoft JhengHei UI',9); Margin=[System.Windows.Forms.Padding]::new(10,6,3,3) }
$qualityModeLine.Controls.AddRange(@($qualityModeBox,$sourcePriorityLabel)); $panel.Controls.Add($qualityModeLine,1,2)
Add-Label '音訊格式' 3
$formatBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$formatBox.Items.AddRange(@('opus','mp3','m4a','flac','wav')); $formatBox.SelectedItem='opus'; $panel.Controls.Add($formatBox,1,3)
Add-Label '轉碼品質' 4
$qualityBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$qualityBox.Items.AddRange(@('0（最佳）','64K','96K','128K','160K','192K','256K','320K')); $qualityBox.SelectedItem='0（最佳）'; $panel.Controls.Add($qualityBox,1,4)
function Update-QualityControls {
    $reencode = $qualityModeBox.SelectedItem -eq '重新編碼'
    $formatBox.Enabled = $reencode
    $qualityBox.Enabled = $reencode
}
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
$startButton = [System.Windows.Forms.Button]@{ Text='開始下載'; AutoSize=$true; Padding=[System.Windows.Forms.Padding]::new(12,4,12,4); BackColor=[System.Drawing.Color]::FromArgb(0,120,215); ForeColor=[System.Drawing.Color]::White; FlatStyle='Flat'; UseVisualStyleBackColor=$false }
$cancelButton = [System.Windows.Forms.Button]@{ Text='停止'; AutoSize=$true; Enabled=$false }
$openButton = [System.Windows.Forms.Button]@{ Text='開啟下載資料夾'; AutoSize=$true }
$updateButton = [System.Windows.Forms.Button]@{ Text='更新 yt-dlp'; AutoSize=$true }
$probeButton.Add_Click({ Check-Formats })
$startButton.Add_Click({ Start-Download })
$cancelButton.Add_Click({ if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) { $Script:DownloadCancelled = $true; $Script:ActiveProcess.Kill(); Write-Log '已要求停止下載。' } })
$openButton.Add_Click({ New-Item -ItemType Directory -Force -Path $folderBox.Text | Out-Null; Start-Process explorer.exe $folderBox.Text })
$updateButton.Add_Click({ Update-YtDlp })
$buttonLine.Controls.AddRange(@($startButton,$cancelButton,$openButton,$updateButton)); $panel.Controls.Add($buttonLine,1,9)

Write-Log '就緒。保留來源最佳品質時，依序優先使用 774 → 141 → 251；只有「重新編碼」模式才會套用音訊格式與轉碼品質設定。'
[void]$form.ShowDialog()
