<#
  YouTube Audio Downloader (Windows)
  Downloads publicly accessible / account-authorized audio using yt-dlp and FFmpeg.
#>

param(
    [string]$HeadlessTrackedConfig = '',
    [string]$HeadlessResultPath = ''
)

$Script:HeadlessMode = -not [string]::IsNullOrWhiteSpace($HeadlessTrackedConfig)

if (-not $Script:HeadlessMode) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
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
if (-not ('YtAudioDownloader.DownloadProcessController' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace YtAudioDownloader {
    public static class DownloadProcessController {
        const uint TH32CS_SNAPPROCESS = 0x00000002;
        const uint PROCESS_TERMINATE = 0x0001;
        const uint PROCESS_SUSPEND_RESUME = 0x0800;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("ntdll.dll")]
        static extern int NtSuspendProcess(IntPtr process);
        [DllImport("ntdll.dll")]
        static extern int NtResumeProcess(IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        static List<int> Descendants(int rootPid) {
            var parents = new Dictionary<int, List<int>>();
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enumerate process tree");
            try {
                var entry = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
                if (Process32First(snapshot, ref entry)) {
                    do {
                        int parent = unchecked((int)entry.th32ParentProcessID);
                        int child = unchecked((int)entry.th32ProcessID);
                        if (!parents.ContainsKey(parent)) parents[parent] = new List<int>();
                        parents[parent].Add(child);
                        entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                    } while (Process32Next(snapshot, ref entry));
                }
            } finally { CloseHandle(snapshot); }
            var result = new List<int>();
            var queue = new Queue<int>();
            var seen = new HashSet<int>();
            queue.Enqueue(rootPid);
            seen.Add(rootPid);
            while (queue.Count > 0) {
                int parent = queue.Dequeue();
                List<int> children;
                if (!parents.TryGetValue(parent, out children)) continue;
                foreach (int child in children) {
                    if (!seen.Add(child)) continue;
                    result.Add(child);
                    queue.Enqueue(child);
                }
            }
            return result;
        }

        static bool SuspendOne(int pid) {
            IntPtr process = OpenProcess(PROCESS_SUSPEND_RESUME, false, unchecked((uint)pid));
            if (process == IntPtr.Zero) return false;
            try { return NtSuspendProcess(process) == 0; }
            finally { CloseHandle(process); }
        }

        static bool ResumeOne(int pid) {
            IntPtr process = OpenProcess(PROCESS_SUSPEND_RESUME, false, unchecked((uint)pid));
            if (process == IntPtr.Zero) return false;
            try { return NtResumeProcess(process) == 0; }
            finally { CloseHandle(process); }
        }

        public static int[] SuspendTree(int rootPid) {
            var suspended = new List<int>();
            if (!SuspendOne(rootPid))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to suspend yt-dlp");
            suspended.Add(rootPid);
            try {
                foreach (int pid in Descendants(rootPid))
                    if (SuspendOne(pid)) suspended.Add(pid);
                return suspended.ToArray();
            } catch {
                ResumeProcesses(suspended.ToArray());
                throw;
            }
        }

        public static void ResumeProcesses(int[] processIds) {
            if (processIds == null) return;
            for (int index = processIds.Length - 1; index >= 1; index--)
                ResumeOne(processIds[index]);
            if (processIds.Length > 0 && !ResumeOne(processIds[0]))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resume yt-dlp");
        }

        public static IntPtr CreateKillOnCloseJob() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create download Job Object");
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to configure download Job Object");
                return job;
            } catch {
                CloseHandle(job);
                throw;
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public static void AssignToJob(IntPtr job, IntPtr processHandle) {
            if (!AssignProcessToJobObject(job, processHandle))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to assign yt-dlp to download Job Object");
        }

        public static void TerminateJob(IntPtr job) {
            if (job == IntPtr.Zero || !TerminateJobObject(job, 1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to terminate download Job Object");
        }

        public static void TerminateJobAndTree(IntPtr job, int rootPid) {
            // Capture descendants first in case one was created in the very
            // small interval between Process.Start and assignment to the job.
            var descendants = Descendants(rootPid);
            TerminateJob(job);
            descendants.Reverse();
            foreach (int pid in descendants) {
                IntPtr process = OpenProcess(PROCESS_TERMINATE, false, unchecked((uint)pid));
                if (process == IntPtr.Zero) continue;
                try { TerminateProcess(process, 1); }
                finally { CloseHandle(process); }
            }
        }

        public static void TerminateTree(int rootPid) {
            var processes = Descendants(rootPid);
            processes.Reverse();
            processes.Add(rootPid);
            foreach (int pid in processes) {
                IntPtr process = OpenProcess(PROCESS_TERMINATE, false, unchecked((uint)pid));
                if (process == IntPtr.Zero) continue;
                try { TerminateProcess(process, 1); }
                finally { CloseHandle(process); }
            }
        }

        public static void CloseJob(IntPtr job) {
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }
}
'@
}
if (-not $Script:HeadlessMode) { [System.Windows.Forms.Application]::EnableVisualStyles() }

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
$MetadataPluginRoot = Join-Path $AppRoot 'plugins'
$SourceMetadataPlugin = Join-Path $MetadataPluginRoot 'source-metadata\yt_dlp_plugins\postprocessor\source_metadata.py'
$CookieBridgeExe = Join-Path $ToolsRoot 'cookie-bridge\dist\cookie-bridge.exe'
$CookieBridgeCookieFile = Join-Path $AppRoot 'data\auth\youtube.cookies.txt'
$CookieBridgeValidationUrl = 'https://www.youtube.com/watch?v=wWs-sl0zXqw'
$PlaylistTrackerScript = Join-Path $AppRoot 'PlaylistTracker.ps1'
if (-not (Test-Path -LiteralPath $PlaylistTrackerScript -PathType Leaf)) { throw "找不到播放清單追蹤模組：$PlaylistTrackerScript" }
. $PlaylistTrackerScript
Initialize-PlaylistTrackerStorage $AppRoot
$Script:ActiveProcess = $null
$Script:DownloadJobHandle = [IntPtr]::Zero
$Script:SuspendedDownloadPids = @()
$Script:DownloadState = 'Idle'
$Script:DownloadCancelled = $false
$Script:DownloadContext = $null
$Script:DownloadTimerBusy = $false
$Script:LastPoTokenSetupLines = @()
$Script:PoTokenProviderProcess = $null
$Script:TrackedPlaylistQueue = [System.Collections.Generic.Queue[object]]::new()
$Script:TrackerBatchActive = $false
$Script:HeadlessLastResult = $null
$Script:GuiLogChannel = 'Download'

function Invoke-UiEvents {
    if (-not $Script:HeadlessMode) { [System.Windows.Forms.Application]::DoEvents() }
}

function Write-Log([string]$Message) {
    if ($Script:HeadlessMode) {
        [Console]::Out.WriteLine("[$(Get-Date -Format 'HH:mm:ss')] $Message")
        return
    }
    $targetLog = if ($Script:GuiLogChannel -eq 'Tracker' -and $trackerLog) { $trackerLog } else { $log }
    $targetLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    $targetLog.SelectionStart = $targetLog.TextLength
    $targetLog.ScrollToCaret()
    Invoke-UiEvents
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
    while (-not $process.Process.HasExited) { Invoke-UiEvents; Start-Sleep -Milliseconds 80 }
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
                Start-Sleep -Milliseconds 250; Invoke-UiEvents
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
    if (-not (Test-Path -LiteralPath $SourceMetadataPlugin -PathType Leaf)) {
        throw "找不到來源 metadata plugin：$SourceMetadataPlugin"
    }
}

function Get-SelectedAuthenticationContext {
    $mode = switch ($authModeBox.SelectedItem.ToString()) {
        'Cookie 檔案' { 'CookieFile' }
        'Chrome Cookie Bridge' { 'CookieBridge' }
        '瀏覽器直接讀取' { 'Browser' }
        default { 'None' }
    }
    if ($mode -eq 'CookieFile') {
        $cookieFile = $cookieFileBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($cookieFile)) { throw '請先選擇 cookies.txt。' }
        if (-not (Test-Path -LiteralPath $cookieFile -PathType Leaf)) { throw "找不到 cookie 檔案：$cookieFile" }
        return [pscustomobject]@{ Mode = 'CookieFile'; CookiePath = (Resolve-Path -LiteralPath $cookieFile).Path; Browser = ''; CookieCount = 0 }
    }
    if ($mode -eq 'Browser') {
        if ($browserBox.SelectedIndex -lt 0) { throw '請選擇要直接讀取的瀏覽器。' }
        return [pscustomobject]@{ Mode = 'Browser'; CookiePath = ''; Browser = $browserBox.SelectedItem.ToString().ToLowerInvariant(); CookieCount = 0 }
    }
    if ($mode -eq 'CookieBridge') {
        return [pscustomobject]@{ Mode = 'CookieBridge'; CookiePath = $CookieBridgeCookieFile; Browser = ''; CookieCount = 0 }
    }
    return [pscustomobject]@{ Mode = 'None'; CookiePath = ''; Browser = ''; CookieCount = 0 }
}

function Get-NetscapeCookieCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#') -and ($line -split "`t").Count -ge 7) { $count++ }
    }
    return $count
}

function Invoke-CookieBridgeExport {
    # This function deliberately has no GUI dependency so a future scheduled
    # PlaylistMonitor can call the same export contract.
    # Fail closed even when the executable itself is missing: a previous
    # job's cookie file must never be mistaken for a fresh export.
    if (Test-Path -LiteralPath $CookieBridgeCookieFile) { Remove-Item -LiteralPath $CookieBridgeCookieFile -Force }
    if (-not (Test-Path -LiteralPath $CookieBridgeExe -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; CookiePath = $CookieBridgeCookieFile; CookieCount = 0; Error = "Cookie Bridge 尚未建置：$CookieBridgeExe" }
    }
    try {
        $result = Invoke-CapturedProcess $CookieBridgeExe @('export', '--timeout', '120')
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $CookieBridgeCookieFile -PathType Leaf)) {
            # The bridge already removes stale output before export.  Keep the
            # downloader fail-closed even if an unexpected bridge version does not.
            if (Test-Path -LiteralPath $CookieBridgeCookieFile) { Remove-Item -LiteralPath $CookieBridgeCookieFile -Force }
            $detail = @($result.Stderr + $result.Stdout | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            $message = if ($detail.Count) { [string]$detail[0] } else { "exit code $($result.ExitCode)" }
            return [pscustomobject]@{ Success = $false; CookiePath = $CookieBridgeCookieFile; CookieCount = 0; Error = $message }
        }
        $count = Get-NetscapeCookieCount $CookieBridgeCookieFile
        if ($count -le 0) {
            Remove-Item -LiteralPath $CookieBridgeCookieFile -Force
            return [pscustomobject]@{ Success = $false; CookiePath = $CookieBridgeCookieFile; CookieCount = 0; Error = '匯出檔沒有可用 Cookie。' }
        }
        return [pscustomobject]@{ Success = $true; CookiePath = (Resolve-Path -LiteralPath $CookieBridgeCookieFile).Path; CookieCount = $count; Error = '' }
    } catch {
        if (Test-Path -LiteralPath $CookieBridgeCookieFile) { Remove-Item -LiteralPath $CookieBridgeCookieFile -Force }
        return [pscustomobject]@{ Success = $false; CookiePath = $CookieBridgeCookieFile; CookieCount = 0; Error = $_.Exception.Message }
    }
}

function Test-CookieBridgeAuthentication([string]$Url, [bool]$RequirePremium) {
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('validate'); $arguments.Add('--url'); $arguments.Add($Url)
    $arguments.Add('--yt-dlp'); $arguments.Add($YtDlp)
    if ($RequirePremium) { $arguments.Add('--require-premium') }
    $result = Invoke-CapturedProcess $CookieBridgeExe $arguments.ToArray()
    $lines = @($result.Stdout + $result.Stderr)
    return [pscustomobject]@{
        Success = ($result.ExitCode -eq 0)
        LoginConfirmed = @($lines | Where-Object { $_ -eq 'Authentication validation successful' }).Count -gt 0
        PremiumConfirmed = @($lines | Where-Object { $_ -eq 'Premium validation successful' }).Count -gt 0
        ExitCode = $result.ExitCode
    }
}

function Get-CookieBridgeValidationUrl([string]$RequestedUrl) {
    # A pure playlist URL would make yt-dlp enumerate playlist entries during
    # auth validation.  Use the requested video when one is present; otherwise
    # use the small, already verified metadata-only probe target.
    if ($RequestedUrl -match '(?i)(youtu\.be/|[?&]v=|youtube\.com/(?:shorts|live)/)') { return $RequestedUrl }
    return $CookieBridgeValidationUrl
}

function Resolve-AuthenticationContextValue($context, [string]$ValidationUrl, [bool]$RequirePremium, [bool]$PrepareCookieBridge) {
    if ($context.Mode -ne 'CookieBridge' -or -not $PrepareCookieBridge) { return $context }

    Write-Log '[Auth] Mode: Chrome Cookie Bridge'
    Write-Log '[Auth] Requesting current Chrome cookies...'
    $export = Invoke-CookieBridgeExport
    if (-not $export.Success) {
        Write-Log '[Auth] Cookie Bridge export failed'
        Write-Log '[Auth] Download cancelled'
        throw "Cookie Bridge 匯出失敗：$($export.Error)"
    }
    Write-Log '[Auth] Cookie Bridge export successful'
    Write-Log "[Auth] Exported cookies: $($export.CookieCount)"
    try {
        $validation = Test-CookieBridgeAuthentication (Get-CookieBridgeValidationUrl $ValidationUrl) $RequirePremium
    } catch {
        Write-Log '[Auth] Authentication validation failed'
        Write-Log '[Auth] Download cancelled'
        throw
    }
    if ($validation.LoginConfirmed) { Write-Log '[Auth] YouTube login confirmed' }
    else {
        Write-Log '[Auth] YouTube login not confirmed'
        Write-Log '[Auth] Download cancelled'
        throw 'Cookie Bridge 匯出成功，但 yt-dlp 未確認 YouTube 登入。'
    }
    if ($validation.PremiumConfirmed) { Write-Log '[Auth] Premium confirmed' }
    elseif ($RequirePremium) {
        Write-Log '[Auth] Premium not confirmed'
        Write-Log '[Auth] Download cancelled'
        throw '目前的保留來源品質模式需要 Premium 驗證，但本次未能確認 Premium。'
    }
    if (-not $validation.Success) {
        Write-Log '[Auth] Authentication validation failed'
        Write-Log '[Auth] Download cancelled'
        throw "Cookie Bridge authentication validation failed (exit code $($validation.ExitCode))。"
    }
    return [pscustomobject]@{ Mode = 'CookieBridge'; CookiePath = $export.CookiePath; Browser = ''; CookieCount = $export.CookieCount }
}

function Resolve-AuthenticationContext([string]$ValidationUrl, [bool]$RequirePremium, [bool]$PrepareCookieBridge) {
    return Resolve-AuthenticationContextValue (Get-SelectedAuthenticationContext) $ValidationUrl $RequirePremium $PrepareCookieBridge
}

function Get-TrackedPlaylistAuthenticationContext($Configuration) {
    $mode = [string]$Configuration.auth_mode
    if ($mode -notin @('None', 'CookieFile', 'CookieBridge', 'Browser')) { throw "不支援的追蹤認證模式：$mode" }
    if ($mode -eq 'CookieFile') {
        $path = [string]$Configuration.cookie_file_path
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "追蹤播放清單的 Cookie 檔案不存在：$path"
        }
        return [pscustomobject]@{ Mode = $mode; CookiePath = (Resolve-Path -LiteralPath $path).Path; Browser = ''; CookieCount = 0 }
    }
    if ($mode -eq 'CookieBridge') {
        return [pscustomobject]@{ Mode = $mode; CookiePath = $CookieBridgeCookieFile; Browser = ''; CookieCount = 0 }
    }
    if ($mode -eq 'Browser') {
        $browser = [string]$Configuration.browser
        if ([string]::IsNullOrWhiteSpace($browser)) { throw '追蹤播放清單未記錄 browser。' }
        return [pscustomobject]@{ Mode = $mode; CookiePath = ''; Browser = $browser.ToLowerInvariant(); CookieCount = 0 }
    }
    return [pscustomobject]@{ Mode = 'None'; CookiePath = ''; Browser = ''; CookieCount = 0 }
}

function Add-AuthenticationArguments([System.Collections.Generic.List[string]]$ArgumentList, $Authentication) {
    if ($Authentication.Mode -in @('CookieFile', 'CookieBridge')) {
        $ArgumentList.Add('--cookies'); $ArgumentList.Add($Authentication.CookiePath)
    } elseif ($Authentication.Mode -eq 'Browser') {
        $ArgumentList.Add('--cookies-from-browser'); $ArgumentList.Add($Authentication.Browser)
    }
}

function Add-YtDlpAccessArguments([System.Collections.Generic.List[string]]$ArgumentList, $Authentication) {
    $ArgumentList.Add('--ffmpeg-location'); $ArgumentList.Add($ToolsRoot)
    $ArgumentList.Add('--js-runtimes'); $ArgumentList.Add("deno:$Deno")
    Add-AuthenticationArguments $ArgumentList $Authentication
}

function Get-ProbeCredentialContext {
    $requirePremium = $qualityModeBox.SelectedItem -eq '保留來源最佳品質'
    return Resolve-AuthenticationContext $urlBox.Text.Trim() $requirePremium $true
}

function Add-ProbeAccessArguments([System.Collections.Generic.List[string]]$ArgumentList, $Authentication, [string]$DenoPath) {
    $ArgumentList.Add('--ffmpeg-location'); $ArgumentList.Add($ToolsRoot)
    $ArgumentList.Add('--js-runtimes'); $ArgumentList.Add("deno:$DenoPath")
    Add-AuthenticationArguments $ArgumentList $Authentication
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
        Invoke-UiEvents
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
    $cacheKey = "$Url`n$($credentials.Mode)`n$($credentials.CookiePath)`n$($credentials.Browser)`n$Deno"
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

function Get-TrackedPlaylistSnapshot {
    param(
        [string]$Url,
        $Authentication,
        [string]$InitializeArchivePath = ''
    )
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('--flat-playlist')
    $arguments.Add('--skip-download')
    $arguments.Add('--dump-single-json')
    Add-YtDlpAccessArguments $arguments $Authentication

    $temporaryArchive = ''
    if (-not [string]::IsNullOrWhiteSpace($InitializeArchivePath)) {
        $archiveDirectory = Split-Path -Parent $InitializeArchivePath
        New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
        $temporaryArchive = Join-Path $archiveDirectory (([System.IO.Path]::GetFileName($InitializeArchivePath)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        # --force-write-archive asks yt-dlp itself to generate its canonical
        # extractor/id archive keys even though this is a metadata-only run.
        $arguments.Add('--force-write-archive')
        $arguments.Add('--download-archive'); $arguments.Add($temporaryArchive)
    }
    $arguments.Add($Url)

    try {
        $result = Invoke-CapturedProcess $YtDlp $arguments.ToArray()
        if ($result.ExitCode -ne 0) {
            $detail = @($result.Stderr + $result.Stdout | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            $message = if ($detail.Count) { [string]$detail[0] } else { "yt-dlp exit code $($result.ExitCode)" }
            throw "無法取得播放清單：$message"
        }
        $jsonText = ($result.Stdout -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($jsonText)) { throw 'yt-dlp 沒有回傳播放清單 JSON。' }
        $playlist = $jsonText | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$playlist.id)) { throw 'yt-dlp JSON 沒有 playlist ID。' }
        $entries = @($playlist.entries | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.id) })

        if ($temporaryArchive) {
            if (-not (Test-Path -LiteralPath $temporaryArchive -PathType Leaf)) {
                # An empty playlist legitimately produces no archive entries.
                [System.IO.File]::WriteAllText($temporaryArchive, '', [System.Text.UTF8Encoding]::new($false))
            }
            Move-Item -LiteralPath $temporaryArchive -Destination $InitializeArchivePath -Force
            $temporaryArchive = ''
        }
        return [pscustomobject]@{
            PlaylistId = [string]$playlist.id
            PlaylistTitle = if ([string]::IsNullOrWhiteSpace([string]$playlist.title)) { [string]$playlist.id } else { [string]$playlist.title }
            ItemCount = $entries.Count
            VideoIds = @($entries | ForEach-Object { [string]$_.id })
        }
    } finally {
        if ($temporaryArchive -and (Test-Path -LiteralPath $temporaryArchive)) { Remove-Item -LiteralPath $temporaryArchive -Force }
    }
}

function Show-TrackerAddModeDialog {
    $dialog = [System.Windows.Forms.Form]@{ Text='加入追蹤播放清單'; Size=[System.Drawing.Size]::new(510,230); StartPosition='CenterParent'; FormBorderStyle='FixedDialog'; MaximizeBox=$false; MinimizeBox=$false; ShowInTaskbar=$false }
    $description = [System.Windows.Forms.Label]@{ Text='選擇初始追蹤方式：'; AutoSize=$true; Location=[System.Drawing.Point]::new(20,18) }
    $fromNow = [System.Windows.Forms.RadioButton]@{ Text='從現在開始追蹤（目前項目只標記為已知，不下載）'; AutoSize=$true; Checked=$true; Location=[System.Drawing.Point]::new(24,52) }
    $backfill = [System.Windows.Forms.RadioButton]@{ Text='補齊目前播放清單（下載 archive 中尚未記錄的項目）'; AutoSize=$true; Location=[System.Drawing.Point]::new(24,86) }
    $ok = [System.Windows.Forms.Button]@{ Text='加入'; DialogResult=[System.Windows.Forms.DialogResult]::OK; Location=[System.Drawing.Point]::new(310,135); Size=[System.Drawing.Size]::new(78,30) }
    $cancel = [System.Windows.Forms.Button]@{ Text='取消'; DialogResult=[System.Windows.Forms.DialogResult]::Cancel; Location=[System.Drawing.Point]::new(397,135); Size=[System.Drawing.Size]::new(78,30) }
    $dialog.Controls.AddRange(@($description,$fromNow,$backfill,$ok,$cancel)); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $(if ($fromNow.Checked) { 'FromNow' } else { 'Backfill' })
    } finally { $dialog.Dispose() }
}

function Add-TrackedPlaylist([string]$PlaylistUrl = '') {
    if ($Script:DownloadState -ne 'Idle') {
        [System.Windows.Forms.MessageBox]::Show('請先等待目前下載工作結束。', '播放清單追蹤', 'OK', 'Information') | Out-Null
        return
    }
    $url = if ([string]::IsNullOrWhiteSpace($PlaylistUrl)) { $urlBox.Text.Trim() } else { $PlaylistUrl.Trim() }
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請先輸入 YouTube 播放清單網址。', '播放清單追蹤', 'OK', 'Warning') | Out-Null
        return
    }
    $mode = Show-TrackerAddModeDialog
    if (-not $mode) { return }
    try {
        $trackAddButton.Enabled = $false
        Ensure-Tools
        $preserveSource = $qualityModeBox.SelectedItem.ToString() -eq '保留來源最佳品質'
        $authentication = Resolve-AuthenticationContextValue (Get-SelectedAuthenticationContext) $url $preserveSource $true
        # First obtain the canonical playlist id/title.  FromNow then repeats
        # the lightweight listing with --force-write-archive so yt-dlp, not
        # this script, creates every archive entry.
        $snapshot = Get-TrackedPlaylistSnapshot $url $authentication
        $paths = Get-TrackedPlaylistStatePaths $snapshot.PlaylistId
        if ((Test-Path -LiteralPath $paths.ConfigPath) -or (Test-Path -LiteralPath $paths.ArchivePath)) {
            $choice = [System.Windows.Forms.MessageBox]::Show("播放清單 $($snapshot.PlaylistId) 已在追蹤清單中。要取代現有設定與初始狀態嗎？", '確認取代', 'YesNo', 'Warning')
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($mode -eq 'FromNow') {
            Write-Log "[Tracker] 正在初始化 archive；目前 $($snapshot.ItemCount) 個項目不會下載。"
            $initialPlaylistId = $snapshot.PlaylistId
            $snapshot = Get-TrackedPlaylistSnapshot $url $authentication $paths.ArchivePath
            if ($snapshot.PlaylistId -ne $initialPlaylistId) {
                if (Test-Path -LiteralPath $paths.ArchivePath) { Remove-Item -LiteralPath $paths.ArchivePath -Force }
                throw '初始化期間播放清單 ID 發生變化；已取消保存追蹤設定。'
            }
        } else {
            if (Test-Path -LiteralPath $paths.ArchivePath) { Remove-Item -LiteralPath $paths.ArchivePath -Force }
        }
        $destination = $folderBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($destination)) { $destination = $OutputRoot }
        $configuration = New-TrackedPlaylistConfiguration -PlaylistId $snapshot.PlaylistId -PlaylistUrl $url -PlaylistTitle $snapshot.PlaylistTitle -OutputFolder $destination -Authentication $authentication -QualityMode $qualityModeBox.SelectedItem.ToString() -AudioFormat $formatBox.SelectedItem.ToString().ToLowerInvariant() -TranscodeQuality $qualityBox.SelectedItem.ToString()
        Save-TrackedPlaylistConfiguration $configuration $paths.ConfigPath
        Write-Log "[Tracker] 已加入：$($snapshot.PlaylistTitle)"
        Write-Log "[Tracker] Playlist ID: $($snapshot.PlaylistId)"
        Write-Log "[Tracker] Archive: $($paths.ArchivePath)"
        if ($mode -eq 'FromNow') {
            Write-Log "[Tracker] 已將目前 $($snapshot.ItemCount) 個項目標記為已知；下載 0 首。"
        } else {
            Write-Log '[Tracker] 即將補齊目前播放清單。'
            Start-TrackedPlaylistBatch @($paths.ConfigPath)
        }
    } catch {
        Write-Log '[Tracker] Check failed before playlist processing'
        Write-Log "[Tracker] Reason: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '加入追蹤失敗', 'OK', 'Error') | Out-Null
    } finally {
        $trackAddButton.Enabled = $true
        if (Get-Command Refresh-TrackedPlaylistGrid -ErrorAction SilentlyContinue) { Refresh-TrackedPlaylistGrid }
    }
}

function Start-TrackedPlaylistBatch([string[]]$ConfigPaths = @()) {
    if ($Script:DownloadState -ne 'Idle') {
        [System.Windows.Forms.MessageBox]::Show('已有下載工作進行中。', '播放清單追蹤', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $ConfigPaths -or $ConfigPaths.Count -eq 0) {
        $ConfigPaths = @(Get-TrackedPlaylistConfigurations | Where-Object { $_.Configuration -and [bool]$_.Configuration.enabled } | ForEach-Object { $_.Path })
    }
    if ($ConfigPaths.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('目前沒有已啟用的追蹤播放清單。', '播放清單追蹤', 'OK', 'Information') | Out-Null
        return
    }
    $Script:TrackedPlaylistQueue.Clear()
    foreach ($path in $ConfigPaths) { $Script:TrackedPlaylistQueue.Enqueue($path) }
    $Script:TrackerBatchActive = $true
    $trackCheckButton.Enabled = $false
    Start-NextTrackedPlaylistCheck
}

function Start-NextTrackedPlaylistCheck {
    if (-not $Script:TrackerBatchActive) { return }
    if ($Script:TrackedPlaylistQueue.Count -eq 0) {
        $Script:TrackerBatchActive = $false
        $trackCheckButton.Enabled = $true
        if ($trackSelectedButton) { $trackSelectedButton.Enabled = $true }
        Write-Log '[Tracker] 所有已啟用的追蹤播放清單檢查完成。'
        if (Get-Command Refresh-TrackedPlaylistGrid -ErrorAction SilentlyContinue) { Refresh-TrackedPlaylistGrid }
        return
    }
    $path = [string]$Script:TrackedPlaylistQueue.Dequeue()
    Invoke-TrackedPlaylistCheck $path
}

function Invoke-TrackedPlaylistCheck([string]$ConfigPath) {
    try {
        $configuration = Read-TrackedPlaylistConfiguration $ConfigPath
        if (-not [bool]$configuration.enabled) {
            Write-Log "[Tracker] 已停用，跳過：$($configuration.playlist_title)"
            Start-NextTrackedPlaylistCheck
            return
        }
        $paths = Get-TrackedPlaylistStatePaths ([string]$configuration.playlist_id)
        Write-Log "[Tracker] Checking: $($configuration.playlist_title)"
        Write-Log "[Tracker] Playlist ID: $($configuration.playlist_id)"
        Write-Log "[Tracker] Auth: $($configuration.auth_mode)"
        Write-Log "[Tracker] Archive: $($paths.ArchivePath)"
        Start-Download -TrackerConfiguration $configuration -TrackerConfigPath $ConfigPath -TrackerArchivePath $paths.ArchivePath
    } catch {
        Write-Log '[Tracker] Check failed before playlist processing'
        Write-Log "[Tracker] Reason: $($_.Exception.Message)"
        try { Update-TrackedPlaylistTimestamps $ConfigPath $false } catch { Write-Log "[Tracker] 無法更新檢查時間：$($_.Exception.Message)" }
        Start-NextTrackedPlaylistCheck
    }
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
        JobFailureCategory = $null
        JobFailureReason = $null
        BrowserCookieErrorReported = $false
        AuthenticationFailureStopRequested = $false
        IsTracker = $false
        TrackerNewIds = [System.Collections.Generic.HashSet[string]]::new()
    }
}

function Test-BrowserCookieDatabaseLocked([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    return $Line -match '(?i)((?:could\s+not|failed\s+to|unable\s+to)\s+(?:copy|access|open|read)\s+(?:the\s+)?(?:google\s+)?chrome\s+cookies?\s+database|chrome[^\r\n]*cookies?\s+database[^\r\n]*(?:locked|lock|permission|access\s+denied|copy\s+failed)|(?:permission\s+denied|access\s+is\s+denied|database\s+is\s+locked)[^\r\n]*chrome[^\r\n]*cookies?)'
}

function Get-DownloadItemKey($Item) {
    if ($Item.id -and $Item.id -ne 'NA') { return "video:$($Item.id)" }
    if ($Item.playlist_index -and $Item.playlist_index -ne 'NA') { return "playlist:$($Item.playlist_index)" }
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
            if ($Statistics.IsTracker -and $item.id -and $Statistics.TrackerNewIds.Add([string]$item.id)) {
                Write-Log "[Tracker] New item detected: $($item.id)"
            }
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
    if (Test-BrowserCookieDatabaseLocked $Line) {
        $Statistics.JobFailureCategory = 'BrowserCookieDatabaseLocked'
        $Statistics.JobFailureReason = 'Chrome Cookie database 無法存取'
        if (-not $Statistics.BrowserCookieErrorReported) {
            $Statistics.BrowserCookieErrorReported = $true
            Write-Log '[Auth Error] 無法讀取 Chrome Cookie 資料庫。'
            Write-Log '[Auth Error] Chrome 可能仍在執行並鎖定 Cookies database。'
            Write-Log '[Auth Error] 請完全關閉 Chrome（包含背景 chrome.exe）後再重試。'
            Write-Log '[Auth Error] 或改用匯出的 cookies.txt。'
        }
    }
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
            if ($Statistics.IsTracker -and $item.id -and $Statistics.TrackerNewIds.Add([string]$item.id)) {
                Write-Log "[Tracker] New item detected: $($item.id)"
            }
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

function Write-DownloadSummary($Statistics, [bool]$Stopped, [bool]$ProcessFailed, [bool]$PlaylistRequested) {
    if (-not $Stopped -and $ProcessFailed -and $PlaylistRequested -and
        $Statistics.ExpectedTotal -le 0 -and $Statistics.Items.Count -eq 0) {
        Write-Log '=============================='
        Write-Log '下載工作失敗'
        Write-Log '=============================='
        if ($Statistics.JobFailureReason) { Write-Log "原因：$($Statistics.JobFailureReason)" }
        Write-Log '已成功下載：0'
        Write-Log "PO Token Retry：$($Statistics.PoTokenRetryCount)"
        Write-Log '=============================='
        return
    }
    if (-not $Stopped -and $ProcessFailed -and $Statistics.Items.Count -eq 0) {
        [void]$Statistics.Items.Add('job:1')
        [void]$Statistics.Failed.Add('job:1')
        if ($Statistics.ExpectedTotal -le 0) { $Statistics.ExpectedTotal = 1 }
    }
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
    Write-Log $(if ($Stopped) { '下載已終止' } else { '下載完成摘要' })
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

function Write-TrackedPlaylistSummary($Configuration, $Statistics, [bool]$Stopped, [bool]$ProcessFailed) {
    if ($Statistics.Items.Count -eq 0 -and $ProcessFailed) {
        Write-Log '[Tracker] Check failed before playlist processing'
        if ($Statistics.JobFailureReason) { Write-Log "[Tracker] Reason: $($Statistics.JobFailureReason)" }
        return
    }
    if (-not $Stopped -and -not $ProcessFailed -and $Statistics.Success.Count -eq 0 -and $Statistics.Failed.Count -eq 0) {
        Write-Log '[Tracker] No new videos found.'
    } else {
        Write-Log "[Tracker] New downloaded: $($Statistics.Success.Count)"
    }
    $counts = @{ '774'=0; '141'=0; '251'=0 }
    foreach ($key in $Statistics.Success) {
        if ($Statistics.SelectedByItem.ContainsKey($key)) {
            $selected = [string]$Statistics.SelectedByItem[$key]
            if ($counts.ContainsKey($selected)) { $counts[$selected]++ }
        }
    }
    Write-Log '=============================='
    Write-Log '播放清單追蹤摘要'
    Write-Log '=============================='
    Write-Log "播放清單：$($Configuration.playlist_title)"
    Write-Log "原有/已跳過：$($Statistics.Skipped.Count)"
    Write-Log "新下載：$($Statistics.Success.Count)"
    Write-Log "失敗：$($Statistics.Failed.Count)"
    Write-Log "774：$($counts['774'])"
    Write-Log "141：$($counts['141'])"
    Write-Log "251：$($counts['251'])"
    Write-Log '=============================='
}

function Close-DownloadJob {
    if ($Script:DownloadJobHandle -ne [IntPtr]::Zero) {
        [YtAudioDownloader.DownloadProcessController]::CloseJob($Script:DownloadJobHandle)
        $Script:DownloadJobHandle = [IntPtr]::Zero
    }
}

function Suspend-DownloadProcess {
    if ($Script:DownloadState -ne 'Running') { return $false }
    if (-not $Script:ActiveProcess -or $Script:ActiveProcess.HasExited) { return $false }
    try {
        $Script:SuspendedDownloadPids = @(
            [YtAudioDownloader.DownloadProcessController]::SuspendTree($Script:ActiveProcess.Id)
        )
        $Script:DownloadState = 'Paused'
        $cancelButton.Text = '已暫停'
        Write-Log '[Download] Paused by user'
        return $true
    } catch {
        $Script:SuspendedDownloadPids = @()
        $Script:DownloadState = 'Running'
        $cancelButton.Text = '停止'
        Write-Log "[Download] Failed to pause process: $($_.Exception.Message)"
        return $false
    }
}

function Resume-DownloadProcess {
    if ($Script:DownloadState -ne 'Paused') { return $false }
    try {
        if (-not $Script:ActiveProcess -or $Script:ActiveProcess.HasExited) {
            throw 'yt-dlp process 已經結束。'
        }
        [YtAudioDownloader.DownloadProcessController]::ResumeProcesses(
            [int[]]$Script:SuspendedDownloadPids
        )
        $Script:SuspendedDownloadPids = @()
        $Script:DownloadState = 'Running'
        $cancelButton.Text = '停止'
        Write-Log '[Download] Resumed by user'
        return $true
    } catch {
        Write-Log "[Download] Failed to resume process: $($_.Exception.Message)"
        return $false
    }
}

function Stop-DownloadProcessTree {
    if ($Script:DownloadState -eq 'Stopping' -or $Script:DownloadState -eq 'Idle') { return }
    if (-not $Script:ActiveProcess -or $Script:ActiveProcess.HasExited) { return }
    $previousState = $Script:DownloadState
    $Script:DownloadState = 'Stopping'
    $Script:DownloadCancelled = $true
    $cancelButton.Text = '結束中…'
    $cancelButton.Enabled = $false
    Write-Log '[Download] User requested termination'
    Write-Log '[Download] Terminating current download process...'
    $terminated = $false
    try {
        if ($Script:DownloadJobHandle -ne [IntPtr]::Zero) {
            [YtAudioDownloader.DownloadProcessController]::TerminateJobAndTree(
                $Script:DownloadJobHandle,
                $Script:ActiveProcess.Id
            )
            $terminated = $true
        } elseif ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
            [YtAudioDownloader.DownloadProcessController]::TerminateTree($Script:ActiveProcess.Id)
            $terminated = $true
        }
    } catch {
        Write-Log "[Download] Failed to terminate process tree: $($_.Exception.Message)"
        if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
            try {
                [YtAudioDownloader.DownloadProcessController]::TerminateTree($Script:ActiveProcess.Id)
                $terminated = $true
            }
            catch { Write-Log "[Download] Failed to terminate fallback process tree: $($_.Exception.Message)" }
        }
    }
    if (-not $terminated -and $Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
        $Script:DownloadCancelled = $false
        $Script:DownloadState = $previousState
        $cancelButton.Text = if ($previousState -eq 'Paused') { '已暫停' } else { '停止' }
        $cancelButton.Enabled = $true
    }
}

function Show-DownloadControlDialog {
    if ($Script:DownloadState -eq 'Running') {
        if (-not (Suspend-DownloadProcess)) { return }
    } elseif ($Script:DownloadState -ne 'Paused') {
        return
    }
    $newLine = [Environment]::NewLine
    $message = '下載已暫停。' + $newLine + $newLine + '選擇「是」繼續下載。' + $newLine + '選擇「否」結束目前下載。'
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $form,
        $message,
        '下載控制：是＝繼續，否＝結束',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](Resume-DownloadProcess)
    } else {
        Stop-DownloadProcessTree
    }
}

function Drain-DownloadProcessOutput($Context) {
    if (-not $Context -or -not $Context.LoggedProcess) { return }
    $queuedLine = $null
    while ($Context.LoggedProcess.Lines.TryDequeue([ref]$queuedLine)) {
        Write-DownloadProcessLine $queuedLine $Context.PreserveSource $Context.Statistics
    }
}

function Start-ProviderHealthPing($Context, [bool]$IsRetry) {
    try {
        $request = [System.Net.HttpWebRequest]::Create($Context.ProviderSession.BaseUrl.TrimEnd('/') + '/ping')
        $request.Method = 'GET'
        $request.Timeout = 3000
        $request.ReadWriteTimeout = 3000
        $Context.HealthRequest = $request
        $Context.HealthIsRetry = $IsRetry
        $Context.HealthStarted = Get-Date
        $Context.HealthAsync = $request.BeginGetResponse($null, $null)
    } catch {
        $Context.HealthRequest = $null
        $Context.HealthAsync = $null
        Complete-ProviderHealthPing $Context $false
    }
}

function Stop-DownloadForProviderFailure($Context, [string]$Message) {
    if ($Context.ProviderFailure) { return }
    $Context.ProviderFailure = $Message
    Write-Log "[PO Token] ERROR: $Message"
    $Script:DownloadState = 'Stopping'
    $cancelButton.Text = '結束中…'
    $cancelButton.Enabled = $false
    try {
        if ($Script:DownloadJobHandle -ne [IntPtr]::Zero) {
            [YtAudioDownloader.DownloadProcessController]::TerminateJobAndTree(
                $Script:DownloadJobHandle,
                $Script:ActiveProcess.Id
            )
        } elseif ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
            [YtAudioDownloader.DownloadProcessController]::TerminateTree($Script:ActiveProcess.Id)
        }
    } catch {
        Write-Log "[Download] Failed to terminate process tree: $($_.Exception.Message)"
    }
}

function Stop-DownloadForAuthenticationFailure($Context) {
    if ($Context.Statistics.AuthenticationFailureStopRequested) { return }
    $Context.Statistics.AuthenticationFailureStopRequested = $true
    $Script:DownloadState = 'Stopping'
    $cancelButton.Text = '結束中…'
    $cancelButton.Enabled = $false
    try {
        if ($Script:DownloadJobHandle -ne [IntPtr]::Zero) {
            [YtAudioDownloader.DownloadProcessController]::TerminateJobAndTree(
                $Script:DownloadJobHandle,
                $Script:ActiveProcess.Id
            )
        } elseif ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
            [YtAudioDownloader.DownloadProcessController]::TerminateTree($Script:ActiveProcess.Id)
        }
    } catch {
        Write-Log "[Auth Error] 無法終止失敗的 yt-dlp process：$($_.Exception.Message)"
    }
}

function Complete-ProviderHealthPing($Context, [bool]$Succeeded) {
    $wasRetry = [bool]$Context.HealthIsRetry
    $Context.HealthRequest = $null
    $Context.HealthAsync = $null
    $Context.HealthStarted = $null
    if ($Succeeded) {
        if ($wasRetry) { Write-Log '[PO Token] Retry successful' }
        $Context.HealthIsRetry = $false
        $Context.RetryAt = $null
        $Context.NextHealthCheck = (Get-Date).AddSeconds(5)
        return
    }
    if (-not $wasRetry) {
        Write-Log '[PO Token] Temporary provider error: localhost /ping failed'
        Write-Log '[PO Token] Retrying in 2 seconds...'
        $Context.Statistics.PoTokenRetryCount++
        $Context.RetryAt = (Get-Date).AddSeconds(2)
        return
    }
    Write-Log '[PO Token] Retry failed'
    Write-Log '[PO Token] Continuing according to existing error handling'
    Stop-DownloadForProviderFailure $Context 'PO Token provider 在播放清單下載期間無法通過 /ping 健康檢查；下載已停止，不會降級成 Auto client。'
}

function Update-ProviderHealth($Context) {
    if (-not $Context.PreserveSource -or $Context.ProviderFailure) { return }
    Drain-PoTokenProviderOutput
    if ($Script:PoTokenProviderProcess -and $Script:PoTokenProviderProcess.Process.HasExited) {
        Stop-DownloadForProviderFailure $Context "PO Token provider 在播放清單下載期間意外結束（exit code $($Script:PoTokenProviderProcess.Process.ExitCode)）；下載已停止，不會降級成 Auto client。"
        return
    }

    $now = Get-Date
    if ($Context.HealthAsync) {
        if (-not $Context.HealthAsync.IsCompleted -and ($now - $Context.HealthStarted).TotalSeconds -lt 4) { return }
        $succeeded = $false
        try {
            if (-not $Context.HealthAsync.IsCompleted) {
                $Context.HealthRequest.Abort()
            } else {
                $response = $Context.HealthRequest.EndGetResponse($Context.HealthAsync)
                try { $succeeded = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300 }
                finally { $response.Close() }
            }
        } catch { $succeeded = $false }
        Complete-ProviderHealthPing $Context $succeeded
        return
    }
    if ($Context.RetryAt) {
        if ($now -ge $Context.RetryAt) { Start-ProviderHealthPing $Context $true }
        return
    }
    if ($now -ge $Context.NextHealthCheck) { Start-ProviderHealthPing $Context $false }
}

function Complete-DownloadSession($Context) {
    $downloadTimer.Stop()
    Drain-DownloadProcessOutput $Context
    if ($Context.PreserveSource) { Drain-PoTokenProviderOutput }
    if ($Context.HealthRequest) {
        try { $Context.HealthRequest.Abort() } catch { }
    }
    $processFailed = (
        [bool]$Context.ProviderFailure -or
        [bool]$Context.Statistics.JobFailureCategory -or
        $Script:ActiveProcess.ExitCode -ne 0
    )
    $trackerSuccessful = $false
    try {
        if ($Context.ProviderFailure) {
            Write-Log "錯誤：$($Context.ProviderFailure)"
            if (-not $Script:HeadlessMode) {
                [System.Windows.Forms.MessageBox]::Show($Context.ProviderFailure, '下載失敗', 'OK', 'Error') | Out-Null
            }
        } elseif ($Script:DownloadCancelled) {
            Write-Log '[Download] Download terminated'
        } elseif ($Script:ActiveProcess.ExitCode -eq 0) {
            Write-Log '完成。'
        } else {
            Write-Log "下載結束，yt-dlp 結束代碼：$($Script:ActiveProcess.ExitCode)"
        }
    } finally {
        Close-DownloadJob
        if ($Context.ProviderSession) { Stop-PoTokenProvider }
        Write-DownloadSummary $Context.Statistics $Script:DownloadCancelled $processFailed $Context.PlaylistRequested
        if ($Context.TrackerConfiguration) {
            $trackerSuccessful = (-not $processFailed -and -not $Script:DownloadCancelled -and $Context.Statistics.Failed.Count -eq 0)
            Write-TrackedPlaylistSummary $Context.TrackerConfiguration $Context.Statistics $Script:DownloadCancelled $processFailed
            try { Update-TrackedPlaylistTimestamps $Context.TrackerConfigPath $trackerSuccessful }
            catch { Write-Log "[Tracker] 無法更新檢查時間：$($_.Exception.Message)" }
            if ($Script:HeadlessMode) {
                $Script:HeadlessLastResult = [pscustomobject]@{
                    success = $trackerSuccessful
                    new_videos_downloaded = $Context.Statistics.Success.Count
                    no_change = ($trackerSuccessful -and $Context.Statistics.Success.Count -eq 0)
                    failed_items = $Context.Statistics.Failed.Count
                    skipped_items = $Context.Statistics.Skipped.Count
                    reason = if ($Context.ProviderFailure) { [string]$Context.ProviderFailure } elseif ($Context.Statistics.JobFailureReason) { [string]$Context.Statistics.JobFailureReason } elseif ($processFailed) { "yt-dlp exit code $($Script:ActiveProcess.ExitCode)" } else { '' }
                }
            }
        }
        $Script:ActiveProcess = $null
        $Script:SuspendedDownloadPids = @()
        $Script:DownloadContext = $null
        $Script:DownloadState = 'Idle'
        $startButton.Enabled = $true
        $cancelButton.Enabled = $false
        $cancelButton.Text = '停止'
        if ($Context.TrackerConfiguration) {
            if ($Script:DownloadCancelled) {
                $Script:TrackedPlaylistQueue.Clear()
                $Script:TrackerBatchActive = $false
                $trackCheckButton.Enabled = $true
                Write-Log '[Tracker] 使用者已終止本次追蹤批次。'
            } else { Start-NextTrackedPlaylistCheck }
        }
    }
}

function Update-DownloadSession {
    $context = $Script:DownloadContext
    if (-not $context) { return }
    try {
        Drain-DownloadProcessOutput $context
        if ($context.Statistics.JobFailureCategory -eq 'BrowserCookieDatabaseLocked' -and
            -not $Script:ActiveProcess.HasExited) {
            Stop-DownloadForAuthenticationFailure $context
            return
        }
        if (-not $Script:ActiveProcess.HasExited) {
            $context.ExitObservedAt = $null
            Update-ProviderHealth $context
            return
        }
        # Give asynchronous stdout/stderr callbacks a short, non-blocking grace
        # period to enqueue the final lines before the summary is calculated.
        if (-not $context.ExitObservedAt) {
            $context.ExitObservedAt = Get-Date
            return
        }
        if (((Get-Date) - $context.ExitObservedAt).TotalMilliseconds -lt 300) { return }
        Complete-DownloadSession $context
    } catch {
        Write-Log "[Download] Monitor error: $($_.Exception.Message)"
        Stop-DownloadForProviderFailure $context "下載監控失敗：$($_.Exception.Message)"
    }
}

function Start-Download {
    param(
        $TrackerConfiguration = $null,
        [string]$TrackerConfigPath = '',
        [string]$TrackerArchivePath = ''
    )
    $url = if ($TrackerConfiguration) { [string]$TrackerConfiguration.playlist_url } else { $urlBox.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('請貼上影片或播放清單網址。', '缺少網址', 'OK', 'Warning') | Out-Null
        return
    }
    if ($Script:DownloadState -ne 'Idle' -or ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited)) {
        [System.Windows.Forms.MessageBox]::Show('已有下載工作進行中。', '請稍候', 'OK', 'Information') | Out-Null
        return
    }

    $providerSession = $null
    $downloadStatistics = New-DownloadStatistics
    $downloadStatistics.IsTracker = [bool]$TrackerConfiguration
    $Script:DownloadCancelled = $false
    try {
        $startButton.Enabled = $false
        $cancelButton.Enabled = $true
        Ensure-Tools

        $format = if ($TrackerConfiguration -and $TrackerConfiguration.audio_format) { [string]$TrackerConfiguration.audio_format } else { $formatBox.SelectedItem.ToString().ToLowerInvariant() }
        $qualityMode = if ($TrackerConfiguration -and $TrackerConfiguration.quality_mode) { [string]$TrackerConfiguration.quality_mode } else { $qualityModeBox.SelectedItem.ToString() }
        $preserveSource = $qualityMode -eq '保留來源最佳品質'
        $qualityLabel = if ($TrackerConfiguration -and $TrackerConfiguration.transcode_quality) { [string]$TrackerConfiguration.transcode_quality } else { $qualityBox.SelectedItem.ToString() }
        $quality = if ($qualityLabel.StartsWith('0')) { '0' } else { $qualityLabel }
        $destination = if ($TrackerConfiguration) { [string]$TrackerConfiguration.output_folder } else { $folderBox.Text.Trim() }
        if ([string]::IsNullOrWhiteSpace($destination)) { $destination = $OutputRoot }
        New-Item -ItemType Directory -Force -Path $destination | Out-Null

        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add('--newline')
        $args.Add('--no-mtime')
        $args.Add('--ignore-errors')
        $args.Add('--windows-filenames')
        # Resolve authentication exactly once per download job.  In Cookie
        # Bridge mode this performs one fresh export and validation; every
        # item in the same playlist then reuses the resulting cookie file.
        $selectedAuthentication = if ($TrackerConfiguration) { Get-TrackedPlaylistAuthenticationContext $TrackerConfiguration } else { Get-SelectedAuthenticationContext }
        $authentication = Resolve-AuthenticationContextValue $selectedAuthentication $url $preserveSource $true
        Add-YtDlpAccessArguments $args $authentication
        $selectedBrowser = if ($authentication.Mode -eq 'Browser') { $authentication.Browser } else { $null }
        if ($selectedBrowser -eq 'chrome' -and @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Log '[Auth Warning] 偵測到 Chrome 正在執行。'
            Write-Log '[Auth Warning] yt-dlp 在 Windows 上可能無法複製 Chrome Cookie database。'
            Write-Log '[Auth Warning] 如果出現 Cookie database 錯誤，請完全關閉 Chrome 後重試。'
        }
        $downloadClient = 'Auto'
        $formatSelector = 'bestaudio/best'
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
        $args.Add('--plugin-dirs'); $args.Add($MetadataPluginRoot)
        $args.Add('--embed-metadata')
        # WAV has no interoperable cover-art convention supported by yt-dlp;
        # all source-preserving outputs (.opus/.m4a) and other GUI formats do.
        if ($preserveSource -or $format -ne 'wav') {
            $args.Add('--embed-thumbnail')
            $args.Add('--convert-thumbnails'); $args.Add('jpg')
        }
        $preserveMetadataValue = if ($preserveSource) { 'true' } else { 'false' }
        $args.Add('--use-postprocessor'); $args.Add("SourceMetadataPrepare:when=video;client=$downloadClient;preserve=$preserveMetadataValue")
        $args.Add('--use-postprocessor'); $args.Add("SourceMetadata:when=after_move;client=$downloadClient;preserve=$preserveMetadataValue")
        # Count an item as successful only after metadata and cover processing
        # have completed. This remains a per-video event for playlists.
        $args.Add('--print'); $args.Add('after_video:__YAD_ITEM_SUCCESS__%(.{id,playlist_index,playlist_count,n_entries,format_id})j')
        $args.Add('--progress')
        $args.Add('-o'); $args.Add((Join-Path $destination '%(playlist_index&{} - |)s%(title)s [%(id)s].%(ext)s'))
        $playlistRequested = if ($TrackerConfiguration) { $true } else { [bool]$playlistCheck.Checked }
        if ($TrackerConfiguration) {
            if ([string]::IsNullOrWhiteSpace($TrackerArchivePath)) { throw '追蹤下載缺少 archive 路徑。' }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TrackerArchivePath) | Out-Null
            $args.Add('--download-archive'); $args.Add($TrackerArchivePath)
        }
        if ($playlistRequested) { $args.Add('--yes-playlist') } else { $args.Add('--no-playlist') }
        $args.Add($url)

        Write-Log "開始下載：格式 $format，模式 $qualityMode，輸出至 $destination"
        if ($authentication.Mode -eq 'CookieFile') {
            Write-Log '[Auth] Download mode: cookies file'
            Write-Log "[Auth] Cookie path: $($authentication.CookiePath)"
            $authSummary = 'cookies file'
        } elseif ($authentication.Mode -eq 'CookieBridge') {
            Write-Log '[Auth] Download mode: Chrome Cookie Bridge'
            $authSummary = 'cookie bridge'
        } elseif ($authentication.Mode -eq 'Browser') {
            $browserName = $authentication.Browser
            Write-Log '[Auth] Download mode: browser'
            Write-Log "[Auth] Browser: $browserName"
            $authSummary = "browser:$browserName"
        } else {
            Write-Log '[Auth] Download mode: none'
            $authSummary = 'none'
        }
        $playlistMode = if ($playlistRequested) { 'yes-playlist' } else { 'no-playlist' }
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
        try {
            $Script:DownloadJobHandle = [YtAudioDownloader.DownloadProcessController]::CreateKillOnCloseJob()
            [YtAudioDownloader.DownloadProcessController]::AssignToJob(
                $Script:DownloadJobHandle,
                $Script:ActiveProcess.Handle
            )
        } catch {
            if ($Script:DownloadJobHandle -ne [IntPtr]::Zero) { Close-DownloadJob }
            [YtAudioDownloader.DownloadProcessController]::TerminateTree($Script:ActiveProcess.Id)
            throw "無法建立下載 process Job Object：$($_.Exception.Message)"
        }
        $Script:DownloadState = 'Running'
        $Script:DownloadContext = [pscustomobject]@{
            LoggedProcess = $loggedProcess
            PreserveSource = $preserveSource
            ProviderSession = $providerSession
            Authentication = $authentication
            ProviderFailure = $null
            PlaylistRequested = $playlistRequested
            Statistics = $downloadStatistics
            TrackerConfiguration = $TrackerConfiguration
            TrackerConfigPath = $TrackerConfigPath
            TrackerArchivePath = $TrackerArchivePath
            NextHealthCheck = (Get-Date).AddSeconds(5)
            RetryAt = $null
            HealthRequest = $null
            HealthAsync = $null
            HealthIsRetry = $false
            HealthStarted = $null
            ExitObservedAt = $null
        }
        if ($Script:HeadlessMode) {
            while ($Script:DownloadState -ne 'Idle') {
                Update-DownloadSession
                Start-Sleep -Milliseconds 100
            }
        } else { $downloadTimer.Start() }
    } catch {
        Write-Log "錯誤：$($_.Exception.Message)"
        if ($TrackerConfiguration) {
            Write-Log '[Tracker] Check failed before playlist processing'
            Write-Log "[Tracker] Reason: $($_.Exception.Message)"
        } else {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '下載失敗', 'OK', 'Error') | Out-Null
        }
        Close-DownloadJob
        if ($providerSession) { Stop-PoTokenProvider }
        $Script:ActiveProcess = $null
        $Script:SuspendedDownloadPids = @()
        $Script:DownloadContext = $null
        $Script:DownloadState = 'Idle'
        $startButton.Enabled = $true
        $cancelButton.Enabled = $false
        $cancelButton.Text = '停止'
        if ($TrackerConfiguration) {
            if ($Script:HeadlessMode) {
                $Script:HeadlessLastResult = [pscustomobject]@{
                    success = $false
                    new_videos_downloaded = 0
                    no_change = $false
                    failed_items = 0
                    skipped_items = 0
                    reason = $_.Exception.Message
                }
            }
            try { Update-TrackedPlaylistTimestamps $TrackerConfigPath $false } catch { Write-Log "[Tracker] 無法更新檢查時間：$($_.Exception.Message)" }
            Start-NextTrackedPlaylistCheck
        }
    }
}

function Write-HeadlessDownloadResult([string]$Path, $Result) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporaryPath, (($Result | ConvertTo-Json -Depth 6) + "`r`n"), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

if ($Script:HeadlessMode) {
    # Minimal non-visual state objects used by the existing download pipeline.
    # No WinForms assembly, Form, timer, picker, or MessageBox is created.
    $startButton = [pscustomobject]@{ Enabled = $true }
    $cancelButton = [pscustomobject]@{ Enabled = $false; Text = '停止' }
    $trackCheckButton = [pscustomobject]@{ Enabled = $true }
    $downloadTimer = [pscustomobject]@{}
    $downloadTimer | Add-Member -MemberType ScriptMethod -Name Start -Value { }
    $downloadTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value { }

    $headlessExitCode = 1
    try {
        $resolvedConfigPath = (Resolve-Path -LiteralPath $HeadlessTrackedConfig).Path
        Invoke-TrackedPlaylistCheck $resolvedConfigPath
        if (-not $Script:HeadlessLastResult) {
            throw 'Headless tracker 沒有產生執行結果。'
        }
        $headlessExitCode = if ($Script:HeadlessLastResult.success) { 0 } else { 1 }
    } catch {
        Write-Log "[Tracker] Headless check failed: $($_.Exception.Message)"
        $Script:HeadlessLastResult = [pscustomobject]@{
            success = $false
            new_videos_downloaded = 0
            no_change = $false
            failed_items = 0
            skipped_items = 0
            reason = $_.Exception.Message
        }
        $headlessExitCode = 1
    }
    $loadedAssemblyNames = @([AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object { $_.GetName().Name })
    $resultEnvelope = [ordered]@{
        success = [bool]$Script:HeadlessLastResult.success
        new_videos_downloaded = [int]$Script:HeadlessLastResult.new_videos_downloaded
        no_change = [bool]$Script:HeadlessLastResult.no_change
        failed_items = [int]$Script:HeadlessLastResult.failed_items
        skipped_items = [int]$Script:HeadlessLastResult.skipped_items
        reason = [string]$Script:HeadlessLastResult.reason
        winforms_loaded = ($loadedAssemblyNames -contains 'System.Windows.Forms')
    }
    try { Write-HeadlessDownloadResult $HeadlessResultPath $resultEnvelope }
    catch {
        [Console]::Error.WriteLine("[Tracker] Unable to write headless result: $($_.Exception.Message)")
        $headlessExitCode = 1
    }
    exit $headlessExitCode
}

$form = [System.Windows.Forms.Form]@{ Text = 'YouTube 音訊下載器'; Size = [System.Drawing.Size]::new(980, 760); StartPosition = 'CenterScreen'; MinimumSize = [System.Drawing.Size]::new(900,680); Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 10) }
$tabControl = [System.Windows.Forms.TabControl]@{ Dock='Fill'; Padding=[System.Drawing.Point]::new(14,5) }
$downloadTab = [System.Windows.Forms.TabPage]@{ Text='下載'; Padding=[System.Windows.Forms.Padding]::new(3) }
$trackerTab = [System.Windows.Forms.TabPage]@{ Text='播放清單追蹤'; Padding=[System.Windows.Forms.Padding]::new(3) }
$tabControl.TabPages.AddRange(@($downloadTab,$trackerTab))
$form.Controls.Add($tabControl)

$panel = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(18); ColumnCount = 2; RowCount = 10 }
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 118))
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
1..8 | ForEach-Object { [void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) }
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$downloadTab.Controls.Add($panel)
$form.Add_FormClosed({
    if ($downloadTimer) { $downloadTimer.Stop() }
    if ($Script:DownloadState -in @('Running', 'Paused')) {
        Stop-DownloadProcessTree
    }
    Close-DownloadJob
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
Add-Label '登入方式' 5
$authLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$authModeBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=190 }; [void]$authModeBox.Items.AddRange(@('不使用登入','Cookie 檔案','Chrome Cookie Bridge','瀏覽器直接讀取')); $authModeBox.SelectedIndex=0
$browserBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=120 }; [void]$browserBox.Items.AddRange(@('Chrome','Edge','Firefox','Brave')); $browserBox.SelectedIndex=0
$authLine.Controls.AddRange(@($authModeBox,$browserBox)); $panel.Controls.Add($authLine,1,5)
Add-Label 'Cookies 檔案' 6
$cookieLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$cookieFileBox = [System.Windows.Forms.TextBox]@{ Width=520 }
$cookieBrowseButton = [System.Windows.Forms.Button]@{ Text='選擇…'; AutoSize=$true }
$cookieBrowseButton.Add_Click({ $d=[System.Windows.Forms.OpenFileDialog]::new(); $d.Filter='Cookie files (*.txt)|*.txt|All files (*.*)|*.*'; $d.Title='選擇 Netscape cookies.txt'; if($d.ShowDialog() -eq 'OK'){$cookieFileBox.Text=$d.FileName; $authModeBox.SelectedItem='Cookie 檔案'} })
$cookieLine.Controls.AddRange(@($cookieFileBox,$cookieBrowseButton)); $panel.Controls.Add($cookieLine,1,6)
function Update-AuthenticationControls {
    $cookieMode = $authModeBox.SelectedItem -eq 'Cookie 檔案'
    $browserMode = $authModeBox.SelectedItem -eq '瀏覽器直接讀取'
    $cookieFileBox.Enabled = $cookieMode
    $cookieBrowseButton.Enabled = $cookieMode
    $browserBox.Enabled = $browserMode
}
$urlBox.Add_TextChanged({ $Script:FormatProbeCache = $null })
$cookieFileBox.Add_TextChanged({ $Script:FormatProbeCache = $null })
$browserBox.Add_SelectedIndexChanged({ $Script:FormatProbeCache = $null })
$authModeBox.Add_SelectedIndexChanged({ $Script:FormatProbeCache = $null; Update-AuthenticationControls })
Update-AuthenticationControls
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
$buttonLine.Controls.AddRange(@($startButton,$cancelButton,$openButton,$updateButton)); $panel.Controls.Add($buttonLine,1,9)

# The tracker tab is a local-state management surface. Refreshing it reads
# tracker JSON/archive files only and never contacts YouTube.
$trackerPanel = [System.Windows.Forms.TableLayoutPanel]@{ Dock='Fill'; Padding=[System.Windows.Forms.Padding]::new(12); ColumnCount=1; RowCount=4 }
[void]$trackerPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,48))
[void]$trackerPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$trackerPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$trackerPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,52))
$trackerTab.Controls.Add($trackerPanel)

$trackerGrid = [System.Windows.Forms.DataGridView]@{ Dock='Fill'; ReadOnly=$true; AllowUserToAddRows=$false; AllowUserToDeleteRows=$false; AllowUserToResizeRows=$false; RowHeadersVisible=$false; SelectionMode='FullRowSelect'; MultiSelect=$false; AutoSizeColumnsMode='Fill'; Margin=[System.Windows.Forms.Padding]::new(3,3,3,8) }
[void]$trackerGrid.Columns.Add('Title','播放清單名稱')
[void]$trackerGrid.Columns.Add('Enabled','Enabled')
[void]$trackerGrid.Columns.Add('Auth','Auth Mode')
[void]$trackerGrid.Columns.Add('LastChecked','上次檢查時間')
[void]$trackerGrid.Columns.Add('LastSuccess','上次成功時間')
[void]$trackerGrid.Columns.Add('Output','輸出資料夾')
[void]$trackerGrid.Columns.Add('ArchiveCount','Archive 項目數')
$trackerGrid.Columns['Title'].FillWeight=125; $trackerGrid.Columns['Enabled'].FillWeight=55; $trackerGrid.Columns['Auth'].FillWeight=75
$trackerGrid.Columns['LastChecked'].FillWeight=90; $trackerGrid.Columns['LastSuccess'].FillWeight=90; $trackerGrid.Columns['Output'].FillWeight=135; $trackerGrid.Columns['ArchiveCount'].FillWeight=65
$trackerPanel.Controls.Add($trackerGrid,0,0)

$trackerButtonLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$true; Margin=[System.Windows.Forms.Padding]::new(3,0,3,8) }
$trackAddButton = [System.Windows.Forms.Button]@{ Text='加入播放清單'; AutoSize=$true }
$trackEditButton = [System.Windows.Forms.Button]@{ Text='編輯'; AutoSize=$true }
$trackToggleButton = [System.Windows.Forms.Button]@{ Text='啟用 / 停用'; AutoSize=$true }
$trackRemoveButton = [System.Windows.Forms.Button]@{ Text='移除'; AutoSize=$true }
$trackSelectedButton = [System.Windows.Forms.Button]@{ Text='檢查選取項目'; AutoSize=$true }
$trackCheckButton = [System.Windows.Forms.Button]@{ Text='立即檢查全部'; AutoSize=$true }
$trackerButtonLine.Controls.AddRange(@($trackAddButton,$trackEditButton,$trackToggleButton,$trackRemoveButton,$trackSelectedButton,$trackCheckButton))
$trackerPanel.Controls.Add($trackerButtonLine,0,1)

$automationGroup = [System.Windows.Forms.GroupBox]@{ Text='自動追蹤'; Dock='Fill'; AutoSize=$true; Padding=[System.Windows.Forms.Padding]::new(10); Margin=[System.Windows.Forms.Padding]::new(3,0,3,8) }
$automationLayout = [System.Windows.Forms.TableLayoutPanel]@{ Dock='Fill'; AutoSize=$true; ColumnCount=1; RowCount=3 }
[void]$automationLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$automationLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$automationLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$automationLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$automationStatusLabel = [System.Windows.Forms.Label]@{ Text='正在讀取排程狀態…'; AutoSize=$true; Anchor='Left'; Margin=[System.Windows.Forms.Padding]::new(3,3,3,7) }
$automationControls = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false; Margin=[System.Windows.Forms.Padding]::new(0,0,0,5) }
$intervalLabel = [System.Windows.Forms.Label]@{ Text='檢查間隔：'; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,8,3,3) }
$intervalBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=120; Margin=[System.Windows.Forms.Padding]::new(0,4,12,3) }
[void]$intervalBox.Items.AddRange(@('30 分鐘','60 分鐘','120 分鐘','180 分鐘','360 分鐘','720 分鐘','1440 分鐘'))
$intervalBox.SelectedItem='60 分鐘'
$taskApplyButton = [System.Windows.Forms.Button]@{ Text='套用排程'; AutoSize=$true }
$taskRemoveButton = [System.Windows.Forms.Button]@{ Text='停用自動追蹤'; AutoSize=$true }
$taskRunNowButton = [System.Windows.Forms.Button]@{ Text='立即執行'; AutoSize=$true }
$automationControls.Controls.AddRange(@($intervalLabel,$intervalBox,$taskApplyButton,$taskRemoveButton,$taskRunNowButton))
$automationHint = [System.Windows.Forms.Label]@{ Text="「啟用播放清單」決定 Monitor 執行時是否檢查該清單；「自動追蹤」決定 Windows 是否定時啟動 Monitor。"; AutoSize=$true; ForeColor=[System.Drawing.Color]::DimGray; Margin=[System.Windows.Forms.Padding]::new(3,0,3,3) }
$automationLayout.Controls.Add($automationStatusLabel,0,0); $automationLayout.Controls.Add($automationControls,0,1); $automationLayout.Controls.Add($automationHint,0,2)
$automationGroup.Controls.Add($automationLayout); $trackerPanel.Controls.Add($automationGroup,0,2)

$trackerLogGroup = [System.Windows.Forms.GroupBox]@{ Text='Tracker / Monitor 執行紀錄'; Dock='Fill'; Padding=[System.Windows.Forms.Padding]::new(8) }
$trackerLog = [System.Windows.Forms.TextBox]@{ Dock='Fill'; Multiline=$true; ScrollBars='Vertical'; ReadOnly=$true; BackColor=[System.Drawing.Color]::FromArgb(28,31,35); ForeColor=[System.Drawing.Color]::Gainsboro; Font=[System.Drawing.Font]::new('Consolas',9) }
$trackerLogGroup.Controls.Add($trackerLog); $trackerPanel.Controls.Add($trackerLogGroup,0,3)

function Format-TrackerDate([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '—' }
    try { return ([datetime]::Parse([string]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm')) } catch { return [string]$Value }
}

function Get-TrackerArchiveCount([string]$PlaylistId) {
    try {
        $paths = Get-TrackedPlaylistStatePaths $PlaylistId
        if (-not (Test-Path -LiteralPath $paths.ArchivePath -PathType Leaf)) { return 0 }
        return @([System.IO.File]::ReadLines($paths.ArchivePath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#') }).Count
    } catch { return '錯誤' }
}

function Refresh-TrackedPlaylistGrid {
    if (-not $trackerGrid) { return }
    $trackerGrid.Rows.Clear()
    foreach ($item in @(Get-TrackedPlaylistConfigurations)) {
        if ($item.Configuration) {
            $c = $item.Configuration
            $rowIndex = $trackerGrid.Rows.Add(
                [string]$c.playlist_title,
                $(if ([bool]$c.enabled) { '是' } else { '否' }),
                [string]$c.auth_mode,
                (Format-TrackerDate $c.last_checked_at),
                (Format-TrackerDate $c.last_success_at),
                [string]$c.output_folder,
                (Get-TrackerArchiveCount ([string]$c.playlist_id))
            )
            $trackerGrid.Rows[$rowIndex].Tag = $item.Path
        } else {
            $rowIndex = $trackerGrid.Rows.Add([System.IO.Path]::GetFileName($item.Path),'錯誤','—','—','—',$item.Error,'—')
            $trackerGrid.Rows[$rowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
}

function Get-SelectedTrackerPath {
    if ($trackerGrid.SelectedRows.Count -eq 0) { return '' }
    return [string]$trackerGrid.SelectedRows[0].Tag
}

function Show-TrackerUrlDialog {
    $dialog=[System.Windows.Forms.Form]@{Text='加入播放清單';Size=[System.Drawing.Size]::new(640,205);StartPosition='CenterParent';FormBorderStyle='FixedDialog';MaximizeBox=$false;MinimizeBox=$false;ShowInTaskbar=$false}
    $label=[System.Windows.Forms.Label]@{Text='YouTube 播放清單網址';AutoSize=$true;Location=[System.Drawing.Point]::new(18,18)}
    $box=[System.Windows.Forms.TextBox]@{Location=[System.Drawing.Point]::new(20,48);Width=585}
    $hint=[System.Windows.Forms.Label]@{Text='登入、品質與輸出設定會沿用「下載」Tab 目前的選項。';AutoSize=$true;ForeColor=[System.Drawing.Color]::DimGray;Location=[System.Drawing.Point]::new(20,82)}
    $ok=[System.Windows.Forms.Button]@{Text='下一步';DialogResult='OK';Location=[System.Drawing.Point]::new(435,118);Size=[System.Drawing.Size]::new(80,30)}
    $cancel=[System.Windows.Forms.Button]@{Text='取消';DialogResult='Cancel';Location=[System.Drawing.Point]::new(525,118);Size=[System.Drawing.Size]::new(80,30)}
    $dialog.Controls.AddRange(@($label,$box,$hint,$ok,$cancel));$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    try { if($dialog.ShowDialog($form)-ne 'OK'){return ''};return $box.Text.Trim() } finally { $dialog.Dispose() }
}

function Show-TrackerEditDialog([string]$ConfigPath) {
    $c = Read-TrackedPlaylistConfiguration $ConfigPath
    $dialog=[System.Windows.Forms.Form]@{Text='編輯追蹤播放清單';Size=[System.Drawing.Size]::new(700,490);StartPosition='CenterParent';FormBorderStyle='FixedDialog';MaximizeBox=$false;MinimizeBox=$false;ShowInTaskbar=$false}
    $layout=[System.Windows.Forms.TableLayoutPanel]@{Dock='Fill';Padding=[System.Windows.Forms.Padding]::new(16);ColumnCount=2;RowCount=9}
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute',125));[void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent',100))
    1..8|ForEach-Object{[void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))};[void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent',100))
    $labels=@('播放清單名稱','播放清單網址','輸出資料夾','Auth Mode','Cookie 檔案','Browser','品質模式','音訊格式 / 品質')
    for($i=0;$i-lt $labels.Count;$i++){ $l=[System.Windows.Forms.Label]@{Text=$labels[$i];AutoSize=$true;Anchor='Left';Margin=[System.Windows.Forms.Padding]::new(3,9,8,9)};$layout.Controls.Add($l,0,$i) }
    $title=[System.Windows.Forms.TextBox]@{Dock='Fill';Text=[string]$c.playlist_title};$layout.Controls.Add($title,1,0)
    $url=[System.Windows.Forms.TextBox]@{Dock='Fill';Text=[string]$c.playlist_url;ReadOnly=$true;BackColor=[System.Drawing.SystemColors]::Control};$layout.Controls.Add($url,1,1)
    $folderLineEdit=[System.Windows.Forms.FlowLayoutPanel]@{Dock='Fill';AutoSize=$true;WrapContents=$false};$folder=[System.Windows.Forms.TextBox]@{Width=450;Text=[string]$c.output_folder};$folderBrowse=[System.Windows.Forms.Button]@{Text='選擇…';AutoSize=$true};$folderBrowse.Add_Click({$d=[System.Windows.Forms.FolderBrowserDialog]::new();$d.SelectedPath=$folder.Text;if($d.ShowDialog() -eq 'OK'){$folder.Text=$d.SelectedPath}});$folderLineEdit.Controls.AddRange(@($folder,$folderBrowse));$layout.Controls.Add($folderLineEdit,1,2)
    $auth=[System.Windows.Forms.ComboBox]@{DropDownStyle='DropDownList';Width=180};[void]$auth.Items.AddRange(@('None','CookieFile','CookieBridge','Browser'));$auth.SelectedItem=[string]$c.auth_mode;$layout.Controls.Add($auth,1,3)
    $cookie=[System.Windows.Forms.TextBox]@{Dock='Fill';Text=[string]$c.cookie_file_path};$layout.Controls.Add($cookie,1,4)
    $browser=[System.Windows.Forms.ComboBox]@{DropDownStyle='DropDownList';Width=140};[void]$browser.Items.AddRange(@('chrome','edge','firefox','brave'));if($c.browser){$browser.SelectedItem=([string]$c.browser).ToLowerInvariant()}else{$browser.SelectedIndex=0};$layout.Controls.Add($browser,1,5)
    $mode=[System.Windows.Forms.ComboBox]@{DropDownStyle='DropDownList';Width=220};[void]$mode.Items.AddRange(@('保留來源最佳品質','重新編碼'));$mode.SelectedItem=[string]$c.quality_mode;$layout.Controls.Add($mode,1,6)
    $qualityLineEdit=[System.Windows.Forms.FlowLayoutPanel]@{Dock='Fill';AutoSize=$true;WrapContents=$false};$audio=[System.Windows.Forms.ComboBox]@{DropDownStyle='DropDownList';Width=120};[void]$audio.Items.AddRange(@('opus','mp3','m4a','flac','wav'));$audio.SelectedItem=[string]$c.audio_format;$bitrate=[System.Windows.Forms.ComboBox]@{DropDownStyle='DropDownList';Width=130};[void]$bitrate.Items.AddRange(@('0（最佳）','64K','96K','128K','160K','192K','256K','320K'));$bitrate.SelectedItem=[string]$c.transcode_quality;$qualityLineEdit.Controls.AddRange(@($audio,$bitrate));$layout.Controls.Add($qualityLineEdit,1,7)
    $buttons=[System.Windows.Forms.FlowLayoutPanel]@{Dock='Bottom';AutoSize=$true;FlowDirection='RightToLeft'};$ok=[System.Windows.Forms.Button]@{Text='儲存';DialogResult='OK';AutoSize=$true};$cancel=[System.Windows.Forms.Button]@{Text='取消';DialogResult='Cancel';AutoSize=$true};$buttons.Controls.AddRange(@($cancel,$ok));$layout.Controls.Add($buttons,1,8)
    $updateEditState={ $cookie.Enabled=$auth.SelectedItem -eq 'CookieFile';$browser.Enabled=$auth.SelectedItem -eq 'Browser';$reencode=$mode.SelectedItem -eq '重新編碼';$audio.Enabled=$reencode;$bitrate.Enabled=$reencode }
    $auth.Add_SelectedIndexChanged($updateEditState);$mode.Add_SelectedIndexChanged($updateEditState);&$updateEditState
    $dialog.Controls.Add($layout);$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    try {
        if($dialog.ShowDialog($form)-ne 'OK'){return $false}
        if([string]::IsNullOrWhiteSpace($title.Text)-or[string]::IsNullOrWhiteSpace($url.Text)-or[string]::IsNullOrWhiteSpace($folder.Text)){throw '名稱、網址與輸出資料夾不可為空白。'}
        $c.playlist_title=$title.Text.Trim();$c.playlist_url=$url.Text.Trim();$c.output_folder=$folder.Text.Trim();$c.auth_mode=[string]$auth.SelectedItem
        $c.cookie_file_path=$(if($c.auth_mode-eq'CookieFile'){$cookie.Text.Trim()}else{''});$c.browser=$(if($c.auth_mode-eq'Browser'){[string]$browser.SelectedItem}else{''})
        $c.quality_mode=[string]$mode.SelectedItem;$c.audio_format=[string]$audio.SelectedItem;$c.transcode_quality=[string]$bitrate.SelectedItem
        Save-TrackedPlaylistConfiguration $c $ConfigPath
        return $true
    } finally {$dialog.Dispose()}
}

function Get-TaskIntervalMinutes {
    try {
        $task=Get-ScheduledTask -TaskName 'YoutubeAudioDownloader_PlaylistMonitor' -ErrorAction Stop
        $value=$task.Triggers[0].Repetition.Interval
        if(-not $value){return $null}
        $span=if($value -is [timespan]){$value}else{[System.Xml.XmlConvert]::ToTimeSpan([string]$value)}
        return [int]$span.TotalMinutes
    } catch { return $null }
}

function Refresh-AutomationStatus {
    $taskScript=Join-Path $AppRoot 'PlaylistMonitorTask.ps1';$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not(Test-Path -LiteralPath $taskScript -PathType Leaf)){$automationStatusLabel.Text='Task 管理工具不存在';return}
    try {
        $result=Invoke-CapturedProcess $shell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$taskScript,'-Status')
        $values=@{};foreach($line in $result.Stdout){if($line-match '^([^:]+):\s*(.*)$'){$values[$matches[1].Trim()]=$matches[2].Trim()}}
        $installed=[string]$values['Installed'];$enabled=[string]$values['Enabled'];$interval=Get-TaskIntervalMinutes
        $autoState=if($installed-ne'Yes'){'未安裝'}elseif($enabled-eq'Yes'){'已啟用'}else{'已停用'}
        $intervalText=if($null-ne$interval){"每 $interval 分鐘"}else{'—'}
        if($null-ne$interval -and $intervalBox.Items.Contains("$interval 分鐘")){$intervalBox.SelectedItem="$interval 分鐘"}
        $lastResult=[string]$values['Last Result']
        $lastResultText=if($lastResult-eq'0'){'成功'}elseif($lastResult-in@('N/A','Never run','')){$lastResult}else{"失敗（代碼 $lastResult）"}
        $automationStatusLabel.Text="自動追蹤：$autoState`r`n檢查間隔：$intervalText`r`n上次執行：$($values['Last Run'])    上次結果：$lastResultText`r`n下次執行：$($values['Next Run'])"
    } catch {$automationStatusLabel.Text="無法讀取排程狀態：$($_.Exception.Message)"}
}

function Invoke-PlaylistMonitorTaskCommand([string]$Operation, [int]$IntervalMinutes = 0) {
    $taskScript=Join-Path $AppRoot 'PlaylistMonitorTask.ps1';$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Script:GuiLogChannel='Tracker'
    try {
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$taskScript,$Operation)
        if($Operation-eq'-Install'){
            if($IntervalMinutes-lt 30 -or $IntervalMinutes-gt 1440){throw "檢查間隔超出允許範圍：$IntervalMinutes"}
            $arguments+=@('-IntervalMinutes',[string]$IntervalMinutes)
        }
        $result=Invoke-CapturedProcess $shell $arguments
        foreach($line in $result.Stdout){Write-Log $line};foreach($line in $result.Stderr){Write-Log "[Task Error] $line"}
        if($result.ExitCode-ne 0){Write-Log "[Task] 操作失敗，exit code $($result.ExitCode)"}
    } catch {Write-Log "[Task] 操作失敗：$($_.Exception.Message)"} finally {Refresh-AutomationStatus}
}

$downloadTimer = [System.Windows.Forms.Timer]::new()
$downloadTimer.Interval = 100
$downloadTimer.Add_Tick({
    if ($Script:DownloadTimerBusy) { return }
    $Script:DownloadTimerBusy = $true
    try { Update-DownloadSession }
    finally { $Script:DownloadTimerBusy = $false }
})
$probeButton.Add_Click({ $Script:GuiLogChannel='Download'; Check-Formats })
$startButton.Add_Click({ $Script:GuiLogChannel='Download'; Start-Download })
$cancelButton.Add_Click({ Show-DownloadControlDialog })
$openButton.Add_Click({ New-Item -ItemType Directory -Force -Path $folderBox.Text | Out-Null; Start-Process explorer.exe $folderBox.Text })
$updateButton.Add_Click({ $Script:GuiLogChannel='Download'; Update-YtDlp })
$trackAddButton.Add_Click({$playlistUrl=Show-TrackerUrlDialog;if($playlistUrl){$Script:GuiLogChannel='Tracker';Add-TrackedPlaylist $playlistUrl}})
$trackEditButton.Add_Click({$path=Get-SelectedTrackerPath;if(-not $path){[System.Windows.Forms.MessageBox]::Show('請先選擇一個播放清單。','播放清單追蹤','OK','Information')|Out-Null;return};try{if(Show-TrackerEditDialog $path){$Script:GuiLogChannel='Tracker';Write-Log '[Tracker] 設定已更新。';Refresh-TrackedPlaylistGrid}}catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'編輯失敗','OK','Error')|Out-Null}})
$trackToggleButton.Add_Click({$path=Get-SelectedTrackerPath;if(-not $path){[System.Windows.Forms.MessageBox]::Show('請先選擇一個播放清單。','播放清單追蹤','OK','Information')|Out-Null;return};try{$c=Read-TrackedPlaylistConfiguration $path;$c.enabled=-not[bool]$c.enabled;Save-TrackedPlaylistConfiguration $c $path;$Script:GuiLogChannel='Tracker';Write-Log "[Tracker] $($c.playlist_title)：$(if($c.enabled){'已啟用'}else{'已停用'})";Refresh-TrackedPlaylistGrid}catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'更新失敗','OK','Error')|Out-Null}})
$trackRemoveButton.Add_Click({$path=Get-SelectedTrackerPath;if(-not $path){[System.Windows.Forms.MessageBox]::Show('請先選擇一個播放清單。','播放清單追蹤','OK','Information')|Out-Null;return};try{$c=Read-TrackedPlaylistConfiguration $path;$choice=[System.Windows.Forms.MessageBox]::Show("只移除追蹤設定「$($c.playlist_title)」嗎？`r`n已下載音訊與 archive 都會保留。",'確認移除','YesNo','Warning');if($choice-eq'Yes'){Remove-Item -LiteralPath $path -Force;$Script:GuiLogChannel='Tracker';Write-Log "[Tracker] 已移除設定：$($c.playlist_title)；archive 與音訊均保留。";Refresh-TrackedPlaylistGrid}}catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'移除失敗','OK','Error')|Out-Null}})
$trackSelectedButton.Add_Click({$path=Get-SelectedTrackerPath;if(-not $path){[System.Windows.Forms.MessageBox]::Show('請先選擇一個播放清單。','播放清單追蹤','OK','Information')|Out-Null;return};$Script:GuiLogChannel='Tracker';$trackSelectedButton.Enabled=$false;Start-TrackedPlaylistBatch @($path);if(-not $Script:TrackerBatchActive){$trackSelectedButton.Enabled=$true}})
$trackCheckButton.Add_Click({$Script:GuiLogChannel='Tracker';$trackSelectedButton.Enabled=$false;Start-TrackedPlaylistBatch;if(-not $Script:TrackerBatchActive){$trackSelectedButton.Enabled=$true}})
$taskApplyButton.Add_Click({$minutes=[int]([regex]::Match([string]$intervalBox.SelectedItem,'\d+').Value);Invoke-PlaylistMonitorTaskCommand '-Install' $minutes})
$taskRemoveButton.Add_Click({Invoke-PlaylistMonitorTaskCommand '-Remove'})
$taskRunNowButton.Add_Click({Invoke-PlaylistMonitorTaskCommand '-RunNow'})
$tabControl.Add_SelectedIndexChanged({if($tabControl.SelectedTab-eq$trackerTab){Refresh-TrackedPlaylistGrid;Refresh-AutomationStatus}})

Write-Log '就緒。保留來源最佳品質時，依序優先使用 774 → 141 → 251；只有「重新編碼」模式才會套用音訊格式與轉碼品質設定。'
Refresh-TrackedPlaylistGrid
Refresh-AutomationStatus
if ($env:YAD_TEST_NO_SHOW -ne '1') { [void]$form.ShowDialog() }
