param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$CookiePath
)
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
# Load existing process/provider helpers without constructing the GUI.
$source = Get-Content -LiteralPath (Join-Path $root 'YoutubeAudioDownloader.ps1') -Raw
Invoke-Expression $source.Substring(0, $source.IndexOf('$form = [System.Windows.Forms.Form]'))
$AppRoot=$root
function Write-Log([string]$Message) { Write-Output $Message | Out-Host }
$report = [System.Collections.Generic.List[string]]::new()
$results = @()
$stableHash = (Get-FileHash $YtDlp).Hash
$nightly = Join-Path $ToolsRoot 'yt-dlp-nightly.exe'
$reportPath = Join-Path $root ('logs\version-comparison-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$cookieCopy = Join-Path $env:TEMP ('ytdlp-version-cookie-' + [guid]::NewGuid().ToString('N') + '.txt')
$cookieBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CookiePath))
try {
    if (-not (Test-Path $nightly)) { throw 'Download official nightly to tools\yt-dlp-nightly.exe first.' }
    $provider = Ensure-PoTokenProvider
    $report.Add("URL: $Url; Client: mweb; identical cookie snapshot for each run; Deno: $Deno")
    foreach ($line in $provider.SetupLines) { $report.Add($line) }
    foreach ($build in @('stable','nightly')) {
        $exe = if ($build -eq 'stable') { $YtDlp } else { $nightly }
        [System.IO.File]::WriteAllBytes($cookieCopy, $cookieBytes)
        $version = Invoke-CapturedProcess $exe @('--version')
        $arguments = @('-v','-J','--no-playlist','--skip-download','--cookies',$cookieCopy,'--js-runtimes',"deno:$Deno",'--ffmpeg-location',$ToolsRoot,'--plugin-dirs',$provider.PluginRoot,'--extractor-args','youtube:player_client=mweb','--extractor-args',"youtubepot-bgutilhttp:base_url=$($provider.BaseUrl)",$Url)
        Write-Log "Testing $build..."
        $run = Invoke-CapturedProcess $exe $arguments
        $info=$null
        try { $info=($run.Stdout -join "`n") | ConvertFrom-Json } catch { }
        $diagnostic=[pscustomobject]@{Client='mweb';Info=$info;ExitCode=$run.ExitCode;CookiesArgumentPresent=$true;Lines=@($run.Stderr)}
        $formats=Get-PremiumClientDiffResult $diagnostic
        $row=[pscustomobject]@{
            Build=$build; Version=($version.Stdout -join ' '); ExitCode=$run.ExitCode; JsonAvailable=($null -ne $info)
            Premium=(@($run.Stderr | Where-Object {$_ -match 'Detected YouTube Premium subscription'}).Count -gt 0)
            GvsToken=(@($run.Stderr | Where-Object {$_ -match 'Retrieved a gvs PO Token for mweb client'}).Count -gt 0)
            AudioCount=$formats.AudioFormats.Count; Has141=$formats.Has141; Has774=$formats.Has774
            BestOpus=$formats.BestOpus; BestAac=$formats.BestAac
            Warnings=@($run.Stderr | Where-Object {$_ -match 'WARNING:|ERROR:'})
        }
        $results += $row
        $summary=$row | ConvertTo-Json -Depth 6
        $report.Add("===== $build ====="); $report.Add($summary)
        Write-Log $summary
        foreach ($audio in $formats.AudioFormats) { $report.Add((Format-PremiumClientDiffAudio $audio)) }
        $report.Add('BEGIN STDERR / VERBOSE (tokens and URLs redacted)')
        foreach ($line in $run.Stderr) { $report.Add((Protect-PoTokenLogLine ($line -replace 'https?://\S+', '[URL omitted]'))) }
        $report.Add('END STDERR; stdout JSON represented by format summary above (media URLs omitted).')
    }
    if ($results[0].JsonAvailable -and $results[1].JsonAvailable -and $results[0].ExitCode -eq 0 -and $results[1].ExitCode -eq 0) {
        if (($results[1].Has774 -and -not $results[0].Has774) -or ($results[1].Has141 -and -not $results[0].Has141)) {
            $conclusion='Premium format regression likely in stable. This comparison alone does not establish the cause.'
        } elseif ($results[0].Has774 -eq $results[1].Has774 -and $results[0].Has141 -eq $results[1].Has141) {
            $conclusion='No Premium high-bitrate format difference between stable and nightly for this URL.'
        } else { $conclusion='Premium format exposure differs; review the two summaries.' }
    } else { $conclusion='Comparison incomplete: at least one probe failed.' }
    $report.Add($conclusion); Write-Log $conclusion
} finally {
    $report.Add("Stable executable unchanged: $((Get-FileHash $YtDlp).Hash -eq $stableHash)")
    [System.IO.File]::WriteAllText($reportPath, ($report -join "`r`n"), [System.Text.Encoding]::UTF8)
    if (Test-Path -LiteralPath $cookieCopy) { Remove-Item -LiteralPath $cookieCopy }
    if ($Script:PoTokenProviderProcess -and -not $Script:PoTokenProviderProcess.Process.HasExited) { $Script:PoTokenProviderProcess.Process.Kill() }
    Write-Log "Report: $reportPath"
}
