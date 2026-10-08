# Downloader-owned settings and presentation; no WinForms or naming semantics.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'MusicRenamerIntegration.psm1')

function New-MusicRenamerSettings {
    return [pscustomobject][ordered]@{
        schema_version=1; enabled=$false; template='{artist} - {title} [{youtube_id}]'
        warning_acknowledged=$false; artist_aliases=@(); title_cleanup_rules=@()
        extraction=[pscustomobject]@{artist_quoted_title=$false; title_slash_artist=$false}
    }
}

function ConvertTo-MusicRenamerSettingsSnapshot($Settings) {
    $fields=@('schema_version','enabled','template','warning_acknowledged','artist_aliases','title_cleanup_rules','extraction')
    if ($null -eq $Settings -or @(Compare-Object ($fields | Sort-Object) (@($Settings.PSObject.Properties.Name) | Sort-Object)).Count) {
        throw 'Music Renamer settings must contain exactly the schema v1 fields; no partial settings are applied.'
    }
    if (($Settings.schema_version -isnot [int] -and $Settings.schema_version -isnot [long]) -or
        $Settings.schema_version -ne 1 -or $Settings.enabled -isnot [bool]) {
        throw 'Unsupported Music Renamer settings schema or invalid enabled value; explicit migration is required.'
    }
    $config=[pscustomobject][ordered]@{}
    foreach ($field in @('template','warning_acknowledged','artist_aliases','title_cleanup_rules','extraction')) {
        $config | Add-Member -NotePropertyName $field -NotePropertyValue $Settings.$field
    }
    return ConvertTo-MusicRenamerConfigSnapshot $config
}

function Read-MusicRenamerSettings([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return New-MusicRenamerSettings }
    $settings=[System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    ConvertTo-MusicRenamerSettingsSnapshot $settings | Out-Null
    return $settings
}

function Assert-MusicRenamerSettings {
    param($Settings,[string]$RuntimeRoot=(Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\music-renamer-runtime'))
    $snapshot=ConvertTo-MusicRenamerSettingsSnapshot $Settings
    $health=Invoke-MusicRenamerAdapterHealth -RuntimeRoot $RuntimeRoot
    if ($health.adapter_status -ne 'healthy') {
        throw "Music Renamer runtime 未就緒 ($($health.error.code))。請執行 Initialize-MusicRenamerRuntime.ps1；不會自動停用後繼續下載。"
    }
    $validation=Invoke-MusicRenamerConfigValidation -Snapshot $snapshot -RuntimeRoot $RuntimeRoot
    if (-not $validation.valid) {
        # Show codes, not arbitrary user-supplied titles/config contents.
        throw ('Music Renamer 設定無效：' + (($validation.issues | ForEach-Object { $_.code }) -join ', '))
    }
    return $snapshot
}

function New-MusicRenamerJobSnapshot {
    param($Settings,[string]$RuntimeRoot=(Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\music-renamer-runtime'))
    ConvertTo-MusicRenamerSettingsSnapshot $Settings | Out-Null
    if (-not $Settings.enabled) { return $null }
    return Assert-MusicRenamerSettings -Settings $Settings -RuntimeRoot $RuntimeRoot
}

function Save-MusicRenamerSettings {
    param($Settings,[string]$Path,[string]$RuntimeRoot=(Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\music-renamer-runtime'))
    ConvertTo-MusicRenamerSettingsSnapshot $Settings | Out-Null
    # Disabled configuration may be saved without installing the optional runtime.
    # It must still pass full Core validation before it can ever be enabled.
    if ($Settings.enabled) { Assert-MusicRenamerSettings -Settings $Settings -RuntimeRoot $RuntimeRoot | Out-Null }
    $directory=Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temp=Join-Path $directory ([System.IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [System.IO.File]::WriteAllText($temp, (($Settings | ConvertTo-Json -Depth 20)+"`r`n"), [System.Text.UTF8Encoding]::new($false))
        # Same-directory temp + atomic replacement; keep the old file on failure.
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($temp,[System.IO.Path]::GetFullPath($Path),[System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($temp,[System.IO.Path]::GetFullPath($Path)) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-MusicRenamerResultText($Result) {
    $label=switch ($Result.rename_status) {
        'not_requested' {'未套用 Music Renamer：未啟用'}
        'unsupported' {'未套用 Music Renamer：格式不支援'}
        'succeeded' {'Music Renamer：已重新命名'}
        'unchanged' {'Music Renamer：名稱未變更'}
        'rejected' {'Music Renamer：拒絕命名（未變更檔案）'}
        'failed' {if ($Result.recovery_status -eq 'failed_rolled_back') {'Music Renamer：命名失敗，已恢復'} else {'Music Renamer：命名失敗；請檢查 recovery 狀態'}}
        'requires_attention' {'【需要人工檢查】Music Renamer 恢復不完整或最終位置無法確認'}
        'infrastructure_failed' {'【需要人工檢查】Music Renamer 基礎設施失敗'}
        'cancelled' {'Music Renamer：操作前已取消'}
        default {'【需要人工檢查】未知 Music Renamer 結果'}
    }
    $path=if ($Result.path_validity -eq 'verified' -and $Result.verified_final_path) {
        if ($Result.rename_status -eq 'rejected') { '原始檔案（已確認）：'+[string]$Result.verified_final_path }
        else { '已確認檔案：'+[string]$Result.verified_final_path }
    } else {'最終檔案位置無法確認'}
    $issue=if ($Result.issue_code) {"；issue=$($Result.issue_code)"} else {''}
    return "$label [$($Result.rename_status)]$issue；$path"
}

function Get-MusicRenamerJobText($Projection) {
    $label=switch ($Projection.status) {
        'completed' {'工作完成'}
        'completed_with_rename_errors' {'下載完成，但 Music Renamer 有待處理結果（不是下載失敗）'}
        'failed' {'工作失敗：請檢查下載或 integration 基礎設施錯誤'}
        'cancelled' {'工作已取消'}
    }
    if ($Projection.requires_attention) { $label += '；【需要人工檢查】請勿假定檔案已恢復或位置可用' }
    return $label
}

Export-ModuleMember -Function @('New-MusicRenamerSettings','ConvertTo-MusicRenamerSettingsSnapshot','Read-MusicRenamerSettings',
    'Assert-MusicRenamerSettings','New-MusicRenamerJobSnapshot','Save-MusicRenamerSettings','Get-MusicRenamerResultText','Get-MusicRenamerJobText')
