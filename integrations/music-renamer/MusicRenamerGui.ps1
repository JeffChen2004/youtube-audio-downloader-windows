# Loaded only after the headless branch has exited. No Music Renamer GUI dependency.
$renamerTab=[System.Windows.Forms.TabPage]@{Text='Music Renamer';Padding=[System.Windows.Forms.Padding]::new(16);AutoScroll=$true}
$tabControl.TabPages.Add($renamerTab)
$renamerLayout=[System.Windows.Forms.FlowLayoutPanel]@{Dock='Fill';FlowDirection='TopDown';WrapContents=$false;AutoScroll=$true}
$renamerTab.Controls.Add($renamerLayout)
$renamerEnable=[System.Windows.Forms.CheckBox]@{Text='下載完成後使用 Music Renamer 命名';AutoSize=$true}
$renamerHelp=[System.Windows.Forms.Label]@{Text='設定只影響下一個工作／追蹤批次。支援 .opus / .m4a；其他格式安全跳過。';AutoSize=$true}
$renamerTemplateLabel=[System.Windows.Forms.Label]@{Text='Template（由 Core 驗證）';AutoSize=$true}
$renamerTemplate=[System.Windows.Forms.TextBox]@{Width=740}
$renamerQuoted=[System.Windows.Forms.CheckBox]@{Text='啟用 Artist「Title」規則';AutoSize=$true}
$renamerSlash=[System.Windows.Forms.CheckBox]@{Text='啟用 Title ⧸ Artist 規則';AutoSize=$true}
$renamerWarnings=[System.Windows.Forms.CheckBox]@{Text='允許有警告的重新命名（預設不允許；錯誤仍會阻止操作）';AutoSize=$true}
$renamerAdvanced=[System.Windows.Forms.Label]@{Text='Artist Alias / Title Cleanup 尚無 GUI 編輯器，可透過進階設定檔設定。';MaximumSize=[System.Drawing.Size]::new(750,0);AutoSize=$true}
$renamerSave=[System.Windows.Forms.Button]@{Text='驗證並儲存設定';AutoSize=$true}
$renamerValidate=[System.Windows.Forms.Button]@{Text='檢查 template／runtime';AutoSize=$true}
$renamerFeedback=[System.Windows.Forms.Label]@{Text='';MaximumSize=[System.Drawing.Size]::new(750,0);AutoSize=$true}
$renamerResultHelp=[System.Windows.Forms.Label]@{Text='Music Renamer 的每首結果與摘要會顯示在下載／追蹤紀錄中。需要人工檢查的結果會另外標示。目前不支援 Undo。';MaximumSize=[System.Drawing.Size]::new(750,0);AutoSize=$true}
$renamerLayout.Controls.AddRange(@($renamerEnable,$renamerHelp,$renamerTemplateLabel,$renamerTemplate,$renamerQuoted,$renamerSlash,$renamerWarnings,$renamerAdvanced,$renamerSave,$renamerValidate,$renamerFeedback,$renamerResultHelp))
$Script:RenamerSettingsLoadError=''
try {
    $Script:GuiRenamerSettings=Read-MusicRenamerSettings $Script:MusicRenamerSettingsPath
    if ($EnableMusicRenamer) {
        # CLI opt-in is reflected in visible controls, never hidden job state.
        $Script:GuiRenamerSettings=New-MusicRenamerDownloadSnapshot -Enabled -ConfigPath $MusicRenamerConfigPath | ConvertFrom-Json
        $Script:GuiRenamerSettings | Add-Member -NotePropertyName schema_version -NotePropertyValue 1
        $Script:GuiRenamerSettings | Add-Member -NotePropertyName enabled -NotePropertyValue $true
    }
}
catch {
    # Defaults are only a disabled display model, NOT a replacement for bad settings.
    $Script:RenamerSettingsLoadError=$_.Exception.Message
    $Script:GuiRenamerSettings=New-MusicRenamerSettings
    $renamerFeedback.Text='設定無法載入；不會部分套用／改寫。請修復 JSON 後重新啟動。'+$Script:RenamerSettingsLoadError
    $renamerFeedback.ForeColor=[System.Drawing.Color]::Firebrick
    $renamerSave.Enabled=$false
    $renamerEnable.Enabled=$false
}
$renamerEnable.Checked=$Script:GuiRenamerSettings.enabled
$renamerTemplate.Text=$Script:GuiRenamerSettings.template
$renamerQuoted.Checked=$Script:GuiRenamerSettings.extraction.artist_quoted_title
$renamerSlash.Checked=$Script:GuiRenamerSettings.extraction.title_slash_artist
$renamerWarnings.Checked=$Script:GuiRenamerSettings.warning_acknowledged

function Get-GuiMusicRenamerSettings {
    if ($Script:RenamerSettingsLoadError) { throw $Script:RenamerSettingsLoadError }
    # Deep copy: never share the advanced arrays with an active job or batch.
    $settings=$Script:GuiRenamerSettings | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $settings.enabled=[bool]$renamerEnable.Checked
    $settings.template=$renamerTemplate.Text
    $settings.extraction.artist_quoted_title=[bool]$renamerQuoted.Checked
    $settings.extraction.title_slash_artist=[bool]$renamerSlash.Checked
    $settings.warning_acknowledged=[bool]$renamerWarnings.Checked
    return $settings
}

function Show-MusicRenamerValidation([bool]$Save) {
    try {
        $settings=Get-GuiMusicRenamerSettings
        if ($Save) { Save-MusicRenamerSettings $settings $Script:MusicRenamerSettingsPath }
        else { Assert-MusicRenamerSettings $settings | Out-Null }
        $renamerFeedback.ForeColor=[System.Drawing.Color]::DarkGreen
        $renamerFeedback.Text=if ($Save -and -not $settings.enabled) {'已儲存停用設定；啟用前仍須通過完整 Core／runtime 驗證。'} else {'Core 設定／runtime 驗證通過。設定只影響下一個工作。'}
    } catch {
        $renamerFeedback.ForeColor=[System.Drawing.Color]::Firebrick
        $renamerFeedback.Text=$_.Exception.Message
    }
}
$renamerSave.Add_Click({Show-MusicRenamerValidation $true})
$renamerValidate.Add_Click({Show-MusicRenamerValidation $false})
foreach ($control in @($renamerEnable,$renamerTemplate,$renamerQuoted,$renamerSlash,$renamerWarnings)) {
    $control.Add_TextChanged({if (-not $Script:RenamerSettingsLoadError) {$renamerFeedback.Text='設定已變更；下次工作開始前會重新驗證。'}})
    if ($control -is [System.Windows.Forms.CheckBox]) {
        $control.Add_CheckedChanged({if (-not $Script:RenamerSettingsLoadError) {$renamerFeedback.Text='設定已變更；下次工作開始前會重新驗證。'}})
    }
}
