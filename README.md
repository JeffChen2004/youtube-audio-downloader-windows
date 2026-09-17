# YouTube 音訊下載器

Windows PowerShell WinForms 工具，可下載單支 YouTube 影片或播放清單的音訊、追蹤播放清單新增項目，並透過 Windows Task Scheduler 定期執行無介面 Monitor。

請只下載你有權存取及保存的內容，並遵守 YouTube 服務條款、著作權法與內容授權。本工具不會繞過 DRM。

## 系統需求

- Windows 10/11
- Windows PowerShell 5.1（GUI、Monitor 與 Task Scheduler 預設使用）
- 網路連線
- Chrome（只有 Chrome Cookie Bridge 模式需要）
- Git（首次安裝 bgutil PO Token provider 時需要）
- .NET Framework 4.x 的 64-bit C# compiler（建置 Cookie Bridge 時需要）

程式會在需要時下載官方 `yt-dlp.exe`、FFmpeg、Deno 及 bgutil provider/plugin 到 `tools/`。這些 runtime dependency 與編譯輸出不納入 source repository。

## 啟動

雙擊：

```text
啟動下載器.cmd
```

或在專案目錄執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\YoutubeAudioDownloader.ps1
```

下載結果預設位於 `downloads/`。

## 下載與品質

GUI 的「下載」Tab 支援：

- 單支影片或整個播放清單
- 保留來源最佳品質或重新編碼
- Opus、MP3、M4A、FLAC、WAV
- Cookie 檔案、Chrome Cookie Bridge、瀏覽器直接讀取或不登入

「保留來源最佳品質」會對每支影片獨立使用以下優先順序：

```text
774 > 141 > 251 > 其他原始音訊 fallback
```

- 774／251：保留原始 Opus，必要時只從 WebM remux 成 `.opus`。
- 141：保留原始 AAC／M4A。
- 只有「重新編碼」模式才依 GUI 指定格式與 bitrate 轉碼。

來源允許時，輸出會嵌入標題、演出者／頻道、專輯、YouTube ID、來源 URL、實際 format ID／codec／ABR／client、播放清單資訊及縮圖。Metadata 與封面處理不會重新編碼保留模式的音訊串流。

## Chrome Cookie Bridge

Cookie Bridge 讓 Chrome 自己透過 Native Messaging 匯出限定 YouTube／Google domain 的登入 Cookie，不直接讀取可能被 Chrome 鎖定的 SQLite database。

### 建置

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\cookie-bridge\build.ps1
.\tools\cookie-bridge\dist\cookie-bridge.exe self-test
```

### 載入 extension

1. 開啟 `chrome://extensions`。
2. 開啟「開發人員模式」。
3. 選擇「載入未封裝項目」。
4. 選擇本專案的 `tools\cookie-bridge\extension`。

Extension ID 由 manifest public key 固定；該 ID 不是登入憑證。

### 註冊 Native Messaging host

```powershell
.\tools\cookie-bridge\dist\cookie-bridge.exe install
```

Installer 會依 executable 與專案實際位置動態產生 Native Messaging manifest，並只在目前使用者的 HKCU 登錄。沒有需要提交的固定本機絕對路徑。

更完整的架構、權限與驗證說明見 [`tools/cookie-bridge/README.md`](tools/cookie-bridge/README.md)。

## Cookie 與 Credential 安全

`data/auth/youtube.cookies.txt` 等 Cookie 檔具有帳號登入權限，等同敏感憑證：

- 不要分享、貼到 issue、上傳雲端或提交 Git。
- 不要將 verbose auth log 公開。
- 懷疑外洩時，請從 Google 帳號安全設定撤銷相關 session。
- Cookie Bridge 匯出或驗證失敗時，下載器會停止，不會匿名 fallback 或沿用舊 Cookie。

Repository 的 `.gitignore` 排除 `data/auth/`、常見 Cookie filename、logs、downloads、tracker runtime state 與第三方 binary。公開前仍應使用 `git status` 及 secret scan 再確認一次。

## 播放清單追蹤

GUI 的「播放清單追蹤」Tab 可：

- 加入、編輯、啟用／停用或移除 tracker 設定
- 查看上次檢查／成功時間、Auth Mode、輸出資料夾及 archive 項目數
- 立即檢查全部或選定的 tracker
- 管理 Windows 自動追蹤排程

「啟用播放清單」只決定 Monitor 執行時是否檢查該清單；「自動追蹤」則決定 Windows 是否定期啟動 Monitor，兩者是不同設定。

Runtime 設定與 yt-dlp download archive 位於：

```text
data/tracked-playlists/<playlist_id>.json
data/tracked-playlists/<playlist_id>.archive.txt
```

這些檔案可能包含私人播放清單、輸出路徑與觀看／下載狀態，因此不納入 Git。公開格式範例見 [`examples/tracked-playlist.example.json`](examples/tracked-playlist.example.json)。

## Headless Monitor

不開啟 GUI 檢查所有 `enabled=true` tracker：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitor.ps1 -CheckAll
```

也可使用 PowerShell 7 啟動入口；實際 downloader worker 仍使用 Windows PowerShell 5.1：

```powershell
pwsh.exe -NoProfile -File .\PlaylistMonitor.ps1 -CheckAll
```

Monitor 使用 `$PSScriptRoot` 定位專案，不依賴目前工作目錄。每次執行的 log 位於 `logs/playlist-monitor/`，named mutex 會阻止重疊執行。

## Windows Task Scheduler

Task 名稱固定為 `YoutubeAudioDownloader_PlaylistMonitor`，使用目前登入使用者、Interactive logon、Limited run level，且不要求系統管理員權限。

### 固定間隔

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 `
  -Install -Mode Interval -IntervalMinutes 60
```

### 每日固定時間

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 `
  -Install -Mode Daily -Time "20:00"
```

### 每週指定時間

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 `
  -Install -Mode Weekly -Days Monday,Wednesday,Friday -Time "20:00"
```

### 查詢、立即執行與移除

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 -Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 -RunNow
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PlaylistMonitorTask.ps1 -Remove
```

重複 `-Install` 會更新同一個 Task。`-Remove` 只移除 Windows Task，不刪除 tracker JSON、archive、音訊、logs、Cookie Bridge 或 extension。

## 開發診斷工具

[`tools/diagnostics/Compare-YtDlpVersions.ps1`](tools/diagnostics/Compare-YtDlpVersions.ps1) 用於比較 yt-dlp stable 與 nightly 在相同 URL、Cookie 與 mweb 條件下可見的音訊格式。這是開發診斷工具，不是一般下載流程所需；`-Url` 與 `-CookiePath` 都必須由使用者明確提供，不會預設讀取 `data/auth/` 的真實 Cookie。

## 本機資料目錄

下列內容不應提交：

- `data/auth/`：Cookie、Native Messaging manifest、nonce／result 等認證狀態
- `data/tracked-playlists/`：tracker JSON 與 download archive
- `downloads/`：下載的音訊
- `logs/`：診斷與 Monitor logs
- `tools/*.exe`、provider runtime、plugin ZIP：下載或建置產物

## 第三方元件

本專案會使用 yt-dlp、FFmpeg、Deno 與 bgutil-ytdlp-pot-provider。它們是獨立的第三方專案，各自由其上游授權條款規範；本 repository 不提交其下載 binary。請查看各上游專案的 license 與發行資訊。

## License

本專案原始碼採用 [MIT License](LICENSE)。第三方元件仍依其各自的授權條款提供。
