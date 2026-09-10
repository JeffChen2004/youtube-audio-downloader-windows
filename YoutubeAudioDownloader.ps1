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
        public Process Process { get; private set; }

        public LoggedProcess() {
            Lines = new ConcurrentQueue<string>();
        }

        public void Start(ProcessStartInfo startInfo) {
            Process = new Process();
            Process.StartInfo = startInfo;
            Process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) Lines.Enqueue(e.Data);
            };
            Process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) Lines.Enqueue(e.Data);
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
$Script:ActiveProcess = $null

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
        $args.Add('--ffmpeg-location'); $args.Add($ToolsRoot)
        $args.Add('--js-runtimes'); $args.Add("deno:$Deno")
        $args.Add('-f'); $args.Add('bestaudio/best')
        $args.Add('-x')
        $args.Add('--audio-format'); $args.Add($format)
        if ($format -notin @('flac', 'wav')) {
            $args.Add('--audio-quality'); $args.Add($quality)
        }
        $args.Add('-o'); $args.Add((Join-Path $destination '%(playlist_index&{} - |)s%(title)s [%(id)s].%(ext)s'))
        if ($playlistCheck.Checked) { $args.Add('--yes-playlist') } else { $args.Add('--no-playlist') }
        $cookieFile = $cookieFileBox.Text.Trim()
        if ($cookieFile) {
            if (-not (Test-Path -LiteralPath $cookieFile -PathType Leaf)) { throw "找不到 cookie 檔案：$cookieFile" }
            $args.Add('--cookies'); $args.Add($cookieFile)
        } elseif ($browserBox.SelectedIndex -gt 0) {
            $args.Add('--cookies-from-browser'); $args.Add($browserBox.SelectedItem.ToString().ToLowerInvariant())
        }
        $args.Add($url)

        Write-Log "開始下載：格式 $format，品質 $qualityLabel，輸出至 $destination"
        if ($cookieFile) { Write-Log '將使用指定的 cookies.txt 檔案。' }
        elseif ($browserBox.SelectedIndex -gt 0) { Write-Log "將使用 $($browserBox.SelectedItem) 的登入 cookie（不會複製或儲存 cookie）。" }

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

$form = [System.Windows.Forms.Form]@{ Text = 'YouTube 音訊下載器'; Size = [System.Drawing.Size]::new(820, 650); StartPosition = 'CenterScreen'; MinimumSize = [System.Drawing.Size]::new(820,650); Font = [System.Drawing.Font]::new('Microsoft JhengHei UI', 10) }
$panel = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(18); ColumnCount = 2; RowCount = 9 }
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 118))
[void]$panel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
1..7 | ForEach-Object { [void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) }
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
[void]$panel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
$form.Controls.Add($panel)

function Add-Label([string]$text, [int]$row) { $c=[System.Windows.Forms.Label]@{Text=$text; Anchor='Left'; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,9,8,9)}; $panel.Controls.Add($c,0,$row) }
Add-Label 'YouTube 網址' 0
$urlBox = [System.Windows.Forms.TextBox]@{ Dock='Fill'; Margin=[System.Windows.Forms.Padding]::new(3,5,3,5) }; $panel.Controls.Add($urlBox,1,0)
Add-Label '下載範圍' 1
$playlistCheck = [System.Windows.Forms.CheckBox]@{ Text='下載整個播放清單（取消勾選即只下載此影片）'; Checked=$true; AutoSize=$true; Margin=[System.Windows.Forms.Padding]::new(3,7,3,7) }; $panel.Controls.Add($playlistCheck,1,1)
Add-Label '音訊格式' 2
$formatBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$formatBox.Items.AddRange(@('opus','mp3','m4a','flac','wav')); $formatBox.SelectedItem='opus'; $panel.Controls.Add($formatBox,1,2)
Add-Label '音訊品質' 3
$qualityBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$qualityBox.Items.AddRange(@('0（最佳）','64K','96K','128K','160K','192K','256K','320K')); $qualityBox.SelectedItem='0（最佳）'; $panel.Controls.Add($qualityBox,1,3)
Add-Label '登入瀏覽器' 4
$browserBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle='DropDownList'; Width=170 }; [void]$browserBox.Items.AddRange(@('不使用登入','Chrome','Edge','Firefox','Brave')); $browserBox.SelectedIndex=0; $panel.Controls.Add($browserBox,1,4)
Add-Label 'Cookies 檔案' 5
$cookieLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$cookieFileBox = [System.Windows.Forms.TextBox]@{ Width=520 }
$cookieBrowseButton = [System.Windows.Forms.Button]@{ Text='選擇…'; AutoSize=$true }
$cookieBrowseButton.Add_Click({ $d=[System.Windows.Forms.OpenFileDialog]::new(); $d.Filter='Cookie files (*.txt)|*.txt|All files (*.*)|*.*'; $d.Title='選擇 Netscape cookies.txt'; if($d.ShowDialog() -eq 'OK'){$cookieFileBox.Text=$d.FileName} })
$cookieLine.Controls.AddRange(@($cookieFileBox,$cookieBrowseButton)); $panel.Controls.Add($cookieLine,1,5)
Add-Label '輸出資料夾' 6
$folderLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; WrapContents=$false }
$folderBox = [System.Windows.Forms.TextBox]@{ Width=520; Text=$OutputRoot }; $browseButton = [System.Windows.Forms.Button]@{ Text='選擇…'; AutoSize=$true }
$browseButton.Add_Click({ $d=[System.Windows.Forms.FolderBrowserDialog]::new(); $d.SelectedPath=$folderBox.Text; if($d.ShowDialog() -eq 'OK'){$folderBox.Text=$d.SelectedPath} }); $folderLine.Controls.AddRange(@($folderBox,$browseButton)); $panel.Controls.Add($folderLine,1,6)
Add-Label '執行紀錄' 7
$log = [System.Windows.Forms.TextBox]@{ Dock='Fill'; Multiline=$true; ScrollBars='Vertical'; ReadOnly=$true; BackColor=[System.Drawing.Color]::FromArgb(28,31,35); ForeColor=[System.Drawing.Color]::Gainsboro; Font=[System.Drawing.Font]::new('Consolas',9); Margin=[System.Windows.Forms.Padding]::new(3,5,3,8) }; $panel.Controls.Add($log,1,7)
$buttonLine = [System.Windows.Forms.FlowLayoutPanel]@{ Dock='Fill'; AutoSize=$true; FlowDirection='RightToLeft' }
$startButton = [System.Windows.Forms.Button]@{ Text='開始下載'; AutoSize=$true; Padding=[System.Windows.Forms.Padding]::new(12,4,12,4) }
$cancelButton = [System.Windows.Forms.Button]@{ Text='停止'; AutoSize=$true; Enabled=$false }
$openButton = [System.Windows.Forms.Button]@{ Text='開啟下載資料夾'; AutoSize=$true }
$startButton.Add_Click({ Start-Download })
$cancelButton.Add_Click({ if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) { $Script:ActiveProcess.Kill(); Write-Log '已要求停止下載。' } })
$openButton.Add_Click({ New-Item -ItemType Directory -Force -Path $folderBox.Text | Out-Null; Start-Process explorer.exe $folderBox.Text })
$buttonLine.Controls.AddRange(@($startButton,$cancelButton,$openButton)); $panel.Controls.Add($buttonLine,1,8)

Write-Log '就緒。選擇 Opus + 0（最佳）可保留最高可用音訊品質。'
[void]$form.ShowDialog()
