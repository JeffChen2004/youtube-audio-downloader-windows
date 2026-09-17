<#
  Persistent state helpers for tracked YouTube playlists.

  This file deliberately contains no downloader implementation.  The GUI and
  a future scheduler can share the same JSON/archive contract while the main
  script continues to own authentication and the yt-dlp pipeline.
#>

function Initialize-PlaylistTrackerStorage([string]$ApplicationRoot) {
    $Script:TrackedPlaylistsRoot = Join-Path $ApplicationRoot 'data\tracked-playlists'
    New-Item -ItemType Directory -Force -Path $Script:TrackedPlaylistsRoot | Out-Null
}

function Get-TrackedPlaylistStatePaths([string]$PlaylistId) {
    if ([string]::IsNullOrWhiteSpace($PlaylistId)) { throw '播放清單 ID 不可為空白。' }
    $safeId = [regex]::Replace($PlaylistId, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeId)) { throw '播放清單 ID 無法作為狀態檔名。' }
    return [pscustomobject]@{
        ConfigPath = Join-Path $Script:TrackedPlaylistsRoot ($safeId + '.json')
        ArchivePath = Join-Path $Script:TrackedPlaylistsRoot ($safeId + '.archive.txt')
    }
}

function Save-TrackedPlaylistConfiguration($Configuration, [string]$Path) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = Join-Path $directory (([System.IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Configuration | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporaryPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Read-TrackedPlaylistConfiguration([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到追蹤設定：$Path" }
    $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($required in @('playlist_id', 'playlist_url', 'playlist_title', 'enabled', 'output_folder', 'auth_mode', 'created_at', 'last_checked_at', 'last_success_at')) {
        if ($configuration.PSObject.Properties.Name -notcontains $required) { throw "追蹤設定缺少欄位：$required" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$configuration.playlist_id)) { throw '追蹤設定的 playlist_id 無效。' }
    return $configuration
}

function Get-TrackedPlaylistConfigurations {
    if (-not (Test-Path -LiteralPath $Script:TrackedPlaylistsRoot -PathType Container)) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Script:TrackedPlaylistsRoot -Filter '*.json' -File | Sort-Object Name)) {
        # Dotfiles and conventional temporary/backup JSON names are support
        # artifacts, not tracker configurations. Save-TrackedPlaylistConfiguration
        # also writes <name>.json.<guid>.tmp, which never matches *.json.
        if ($file.Name.StartsWith('.', [System.StringComparison]::Ordinal) -or
            $file.Name -match '(?i)\.(?:tmp|bak|backup|partial|new)\.json$') {
            continue
        }
        try {
            $items.Add([pscustomobject]@{ Path = $file.FullName; Configuration = (Read-TrackedPlaylistConfiguration $file.FullName); Error = '' })
        } catch {
            $items.Add([pscustomobject]@{ Path = $file.FullName; Configuration = $null; Error = $_.Exception.Message })
        }
    }
    return @($items)
}

function New-TrackedPlaylistConfiguration {
    param(
        [string]$PlaylistId,
        [string]$PlaylistUrl,
        [string]$PlaylistTitle,
        [string]$OutputFolder,
        $Authentication,
        [string]$QualityMode,
        [string]$AudioFormat,
        [string]$TranscodeQuality
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{
        schema_version = 1
        playlist_id = $PlaylistId
        playlist_url = $PlaylistUrl
        playlist_title = $PlaylistTitle
        enabled = $true
        output_folder = $OutputFolder
        auth_mode = [string]$Authentication.Mode
        cookie_file_path = if ($Authentication.Mode -eq 'CookieFile') { [string]$Authentication.CookiePath } else { '' }
        browser = if ($Authentication.Mode -eq 'Browser') { [string]$Authentication.Browser } else { '' }
        quality_mode = $QualityMode
        audio_format = $AudioFormat
        transcode_quality = $TranscodeQuality
        created_at = $now
        last_checked_at = $null
        last_success_at = $null
    }
}

function Update-TrackedPlaylistTimestamps([string]$ConfigPath, [bool]$Successful) {
    $configuration = Read-TrackedPlaylistConfiguration $ConfigPath
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $configuration.last_checked_at = $now
    if ($Successful) { $configuration.last_success_at = $now }
    Save-TrackedPlaylistConfiguration $configuration $ConfigPath
}
