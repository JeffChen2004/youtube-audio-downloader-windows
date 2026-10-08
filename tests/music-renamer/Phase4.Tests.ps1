param([switch]$Gui)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'integrations/music-renamer/MusicRenamerSettings.psm1')
Import-Module (Join-Path $repo 'integrations/music-renamer/MusicRenamerIntegration.psm1')
function Assert($Condition,$Message) {if (-not $Condition) {throw "Assertion failed: $Message"}}
function Reject([scriptblock]$Action,$Message) {$caught=$false;try {& $Action | Out-Null} catch {$caught=$true};Assert $caught $Message}
function Clone($Object) {return $Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json}
$temp=Join-Path $PSScriptRoot ('phase4-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $path=Join-Path $temp 'settings.json'
    $default=Read-MusicRenamerSettings $path
    Assert ($default.schema_version -eq 1 -and -not $default.enabled -and -not $default.warning_acknowledged) 'deterministic disabled defaults'
    Assert (-not (Test-Path $path)) 'loading defaults never writes settings'
    Assert ($null -eq (New-MusicRenamerJobSnapshot $default -RuntimeRoot (Join-Path $temp 'missing'))) 'disabled never touches runtime'
    Save-MusicRenamerSettings $default $path
    $s=Clone $default
    $s.enabled=$true; $s.warning_acknowledged=$true
    $s.extraction.artist_quoted_title=$true; $s.extraction.title_slash_artist=$true
    $s.artist_aliases=@([pscustomobject]@{source='Fixture';target='Canonical'})
    $s.title_cleanup_rules=@([pscustomobject]@{kind='remove_suffix';text=' (official)'})
    Save-MusicRenamerSettings $s $path
    $loaded=Read-MusicRenamerSettings $path
    Assert ((ConvertTo-MusicRenamerSettingsSnapshot $loaded) -eq (ConvertTo-MusicRenamerSettingsSnapshot $s)) 'roundtrip includes advanced arrays, extraction and warnings'
    $snapshot=New-MusicRenamerJobSnapshot $s
    $s.template='{title}';$s.artist_aliases[0].target='Changed'
    Assert (($snapshot | ConvertFrom-Json).artist_aliases[0].target -eq 'Canonical') 'immutable snapshot does not observe later edits'
    Assert (($snapshot | ConvertFrom-Json).template -eq $default.template) 'template snapshot stays immutable'
    $before=[System.IO.File]::ReadAllText($path)
    foreach ($kind in @('future','missing','bad_bool','template','alias','cleanup','toggle','extra')) {
        $bad=Clone $loaded
        switch ($kind) {
            future {$bad.schema_version=99}
            missing {$bad.PSObject.Properties.Remove('warning_acknowledged')}
            bad_bool {$bad.enabled='true'}
            template {$bad.template='{unknown}'}
            alias {$bad.artist_aliases=@([pscustomobject]@{source='';target='x'})}
            cleanup {$bad.title_cleanup_rules=@([pscustomobject]@{kind='invalid';text='x'})}
            toggle {$bad.extraction.title_slash_artist='true'}
            extra {$bad | Add-Member -NotePropertyName future -NotePropertyValue 1}
        }
        Reject {Save-MusicRenamerSettings $bad $path} "fail closed $kind"
        Assert ([System.IO.File]::ReadAllText($path) -eq $before) "rejected $kind leaves original bytes intact"
    }
    Reject {New-MusicRenamerJobSnapshot $loaded -RuntimeRoot (Join-Path $temp 'missing')} 'enabled missing runtime fails early'
    $stub=Join-Path $temp 'transport.py'
    $body="import sys,json`nq=json.load(sys.stdin)`nr={'protocol_version':1,'correlation_id':q['correlation_id'],'operation':'validate_config','adapter_status':'completed','valid':True,'issues':[],'error':None}`n"
    foreach ($failure in @('correlation','protocol','shape','malformed','multiple','nonzero','contradiction')) {
        $suffix=switch ($failure) {
            correlation {"r['correlation_id']='wrong'; print(json.dumps(r))"}
            protocol {"r['protocol_version']=99; print(json.dumps(r))"}
            shape {"del r['issues']; print(json.dumps(r))"}
            malformed {"print('not-json')"}
            multiple {"print(json.dumps(r)); print(json.dumps(r))"}
            nonzero {"print(json.dumps(r)); sys.exit(9)"}
            contradiction {"r['issues']=[{'code':'invalid'}]; print(json.dumps(r))"}
        }
        [System.IO.File]::WriteAllText($stub,$body+$suffix)
        Reject {Invoke-MusicRenamerConfigValidation -Snapshot $snapshot -AdapterPath $stub} "validation transport $failure fail closed"
    }
    Assert (@(Get-ChildItem $temp -Filter '*.tmp').Count -eq 0) 'atomic replacement has no orphan temps'
    $malformed=Join-Path $temp 'malformed.json'
    [System.IO.File]::WriteAllText($malformed,'{broken')
    Reject {Read-MusicRenamerSettings $malformed} 'malformed JSON no fallback'
    $old=Clone $loaded;$old.schema_version=0
    [System.IO.File]::WriteAllText($malformed,($old | ConvertTo-Json -Depth 20))
    Reject {Read-MusicRenamerSettings $malformed} 'old schema requires explicit migration'
    Assert (([System.IO.File]::ReadAllText($malformed) | ConvertFrom-Json).schema_version -eq 0) 'load does not migrate or rewrite'
    # Force replacement failure after the temp write; preserve the target and clean temp.
    $locked=[System.IO.File]::Open($path,'Open','Read','None')
    try {Reject {Save-MusicRenamerSettings $default $path} 'locked atomic write fails'} finally {$locked.Dispose()}
    Assert ([System.IO.File]::ReadAllText($path) -eq $before) 'failed atomic write preserves prior config'
    Assert (@(Get-ChildItem $temp -Filter '*.tmp').Count -eq 0) 'failed write cleans its temp'

    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'YoutubeAudioDownloader.ps1'),[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'main parser'
    foreach ($file in @('integrations/music-renamer/MusicRenamerGui.ps1','integrations/music-renamer/MusicRenamerSettings.psm1','integrations/music-renamer/MusicRenamerIntegration.psm1')) {
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$tokens,[ref]$errors) | Out-Null
        Assert ($errors.Count -eq 0) "parser $file"
    }
    foreach ($name in @('Get-DownloadRenamerSnapshot','New-DownloadStatistics','Get-DownloadJobProjection')) {
        $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression $fn.Extent.Text
    }
    $AppRoot=$repo;$EnableMusicRenamer=$false;$MusicRenamerConfigPath=''
    $Script:HeadlessMode=$true;$Script:TrackerBatchActive=$false;$Script:MusicRenamerSettingsPath=$path
    function Get-GuiMusicRenamerSettings {throw 'headless must not read GUI'}
    Assert ((Get-DownloadRenamerSnapshot $true) -eq (ConvertTo-MusicRenamerSettingsSnapshot $loaded)) 'headless reads persisted settings'
    Save-MusicRenamerSettings $default $path
    Assert ($null -eq (Get-DownloadRenamerSnapshot $true)) 'headless persisted disabled'
    $Script:MusicRenamerSettingsPath=$malformed
    Reject {Get-DownloadRenamerSnapshot $true} 'headless invalid config blocks'
    $Script:MusicRenamerSettingsPath=$path
    $Script:TrackerBatchActive=$true;$Script:TrackerRenamerSettings=$snapshot
    Assert ((Get-DownloadRenamerSnapshot $true) -eq $snapshot) 'batch retains snapshot despite config edits'
    Assert (-not ([AppDomain]::CurrentDomain.GetAssemblies().GetName().Name -contains 'System.Windows.Forms')) 'settings/headless have not loaded WinForms'
    # Real headless startup, pre-job failure and serialized envelope, without network.
    . (Join-Path $repo 'PlaylistTracker.ps1')
    $tracker=New-TrackedPlaylistConfiguration -PlaylistId 'phase4-fixture' -PlaylistUrl 'https://www.youtube.com/playlist?list=phase4-fixture' -PlaylistTitle 'Fixture' -OutputFolder $temp -Authentication ([pscustomobject]@{Mode='不使用登入'}) -QualityMode '保留來源最佳品質' -AudioFormat 'opus' -TranscodeQuality '0（最佳）'
    $trackerPath=Join-Path $temp 'tracker.json'
    Save-TrackedPlaylistConfiguration $tracker $trackerPath
    $legacy=Join-Path $temp 'legacy.json'
    $invalid=Clone $loaded;$invalid.template='{unknown}'
    [System.IO.File]::WriteAllText($legacy,(ConvertTo-MusicRenamerSettingsSnapshot $invalid))
    $resultPath=Join-Path $temp 'headless-result.json'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'YoutubeAudioDownloader.ps1') -HeadlessTrackedConfig $trackerPath -HeadlessResultPath $resultPath -EnableMusicRenamer -MusicRenamerConfigPath $legacy | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'headless pre-job invalid template exit'
    $envelope=Get-Content -Raw $resultPath | ConvertFrom-Json
    Assert (-not $envelope.winforms_loaded -and $envelope.status -eq 'failed') 'real headless failure never loads WinForms'
    Assert ($envelope.reason.Contains('unknown_placeholder') -and $envelope.rename_results.Count -eq 0 -and $envelope.new_videos_downloaded -eq 0) 'pre-job error before any per-item operation'
    Assert $envelope.rename_requested 'headless failed pre-job retains explicit request'
    foreach ($status in @('succeeded','unchanged','rejected','failed','requires_attention','unsupported','cancelled','infrastructure_failed','not_requested')) {
        $r=[pscustomobject]@{rename_status=$status;path_validity='verified';verified_final_path='C:\fixture\source.opus';recovery_status='failed_rolled_back';issue_code='fixture_issue';requires_attention=($status -eq 'requires_attention')}
        $text=Get-MusicRenamerResultText $r
        Assert ($text.Contains("[$status]")) "preserve machine status $status"
        if ($status -eq 'failed') {Assert ($text.Contains('已恢復')) 'restored detail'}
        if ($status -eq 'rejected') {Assert ($text.Contains('原始檔案')) 'rejected original path'}
        if ($status -eq 'unsupported') {Assert ($text.Contains('格式不支援')) 'unsupported is not download error'}
        $r.path_validity='unverified';$r.verified_final_path='C:\stale\never-display.opus'
        $text=Get-MusicRenamerResultText $r
        Assert ($text.Contains('最終檔案位置無法確認') -and -not $text.Contains('never-display')) "unverified $status never displays stale path"
    }
    $stats=New-DownloadStatistics;$stats.RenameEnabled=$true
    [void]$stats.Items.Add('video:one');[void]$stats.Success.Add('video:one')
    $stats.RenameResults['video:one']=[pscustomobject]@{rename_status='requires_attention';requires_attention=$true}
    $projection=Get-DownloadJobProjection $stats $false $false
    Assert ($projection.status -eq 'completed_with_rename_errors' -and $projection.download_success) 'partial not download failure'
    Assert ((Get-MusicRenamerJobText $projection).Contains('需要人工檢查')) 'attention prominent'
    $projection=Get-DownloadJobProjection $stats $true $false
    Assert ($projection.status -eq 'cancelled' -and $projection.requires_attention) 'cancellation keeps attention'
    Assert ($stats.Failed.Count -eq 0 -and $stats.Success.Count -eq 1) 'rename presentation does not mutate accounting'
    $stop=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Request-RenamerSafeStop'},$true)
    Assert ($stop.Extent.Text.Contains('正在完成安全檔案操作') -and -not $stop.Extent.Text.Contains('.Kill(')) 'safe cancellation wait UX without kill'
    if ($Gui) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $tabControl=[System.Windows.Forms.TabControl]::new()
        $Script:MusicRenamerSettingsPath=$path
        . (Join-Path $repo 'integrations/music-renamer/MusicRenamerGui.ps1')
        Assert (-not $renamerEnable.Checked -and -not $renamerWarnings.Checked) 'real GUI disabled/warnings default'
        $renamerEnable.Checked=$true;$renamerTemplate.Text='{title}'
        $guiSettings=Get-GuiMusicRenamerSettings
        $guiSnapshot=New-MusicRenamerJobSnapshot $guiSettings
        $renamerTemplate.Text='{unknown}'
        Show-MusicRenamerValidation $false
        Assert ($renamerFeedback.Text.Contains('unknown_placeholder')) 'real template feedback uses Core'
        Assert (($guiSnapshot | ConvertFrom-Json).template -eq '{title}') 'GUI edits do not affect active snapshot'
        Reject {New-MusicRenamerJobSnapshot (Get-GuiMusicRenamerSettings)} 'invalid GUI cannot start integration'
        $renamerEnable.Checked=$false
        Show-MusicRenamerValidation $true
        Assert (-not (Read-MusicRenamerSettings $path).enabled) 'explicit disable persistence'
        $tabControl.Dispose()
        $EnableMusicRenamer=$true;$MusicRenamerConfigPath=$legacy
        $tabControl=[System.Windows.Forms.TabControl]::new()
        . (Join-Path $repo 'integrations/music-renamer/MusicRenamerGui.ps1')
        Assert ($renamerEnable.Checked -and $renamerTemplate.Text -eq '{unknown}') 'CLI opt-in reflected in visible GUI controls'
        $tabControl.Dispose();$EnableMusicRenamer=$false
        # Real feedback with a relocated module and deliberately absent runtime.
        $isolated=Join-Path $temp 'isolated/integrations/music-renamer'
        New-Item -ItemType Directory -Force -Path $isolated | Out-Null
        foreach ($file in @('MusicRenamerIntegration.psm1','MusicRenamerSettings.psm1')) {
            Copy-Item -LiteralPath (Join-Path $repo "integrations/music-renamer/$file") -Destination (Join-Path $isolated $file)
        }
        Import-Module (Join-Path $isolated 'MusicRenamerSettings.psm1') -Force
        $tabControl=[System.Windows.Forms.TabControl]::new()
        . (Join-Path $repo 'integrations/music-renamer/MusicRenamerGui.ps1')
        $renamerTemplate.Text='{title}';$renamerEnable.Checked=$true
        Show-MusicRenamerValidation $false
        Assert ($renamerFeedback.Text.Contains('runtime_unavailable') -and $renamerFeedback.Text.Contains('Initialize-MusicRenamerRuntime.ps1')) 'GUI missing runtime actionable feedback'
        $tabControl.Dispose()
        Import-Module (Join-Path $repo 'integrations/music-renamer/MusicRenamerSettings.psm1') -Force
        $Script:MusicRenamerSettingsPath=$malformed
        $tabControl=[System.Windows.Forms.TabControl]::new()
        . (Join-Path $repo 'integrations/music-renamer/MusicRenamerGui.ps1')
        Assert (-not $renamerSave.Enabled -and -not $renamerEnable.Enabled) 'malformed GUI settings cannot overwrite originals'
        Reject {Get-GuiMusicRenamerSettings} 'malformed GUI does not silently apply defaults'
        $tabControl.Dispose()
    }
    Write-Output "Phase 4 settings / snapshot / presentation / headless tests PASS (GUI=$Gui)"
} finally {
    if ($temp.StartsWith((Join-Path $PSScriptRoot 'phase4-'),[System.StringComparison]::OrdinalIgnoreCase)) {Remove-Item -LiteralPath $temp -Recurse -Force}
}
