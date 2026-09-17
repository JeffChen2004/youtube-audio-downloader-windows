# YouTube Cookie Bridge prototype

這是一個獨立的 Chrome Native Messaging prototype。它不讀取 Chrome SQLite Cookies database，也不修改 `YoutubeAudioDownloader.ps1`。

## 架構

1. Task Scheduler 執行 `cookie-bridge export`，建立具有 256-bit 隨機 nonce 的短效匯出請求並刪除舊 Cookie 檔。
2. Chrome extension 透過每 30 秒一次的 alarm 連接 Native Messaging host。
3. Host 驗證固定 extension origin，再把本次 nonce 傳給 extension。
4. Extension 只讀取會套用於 `www.youtube.com`、`music.youtube.com`、`accounts.google.com` 的 Cookie。
5. Host 驗證 domain，輸出 UTF-8、CRLF 的 `data/auth/youtube.cookies.txt`。

沒有 localhost listener、外部 server、telemetry 或匿名下載 fallback。

## 建置與安裝

在 Windows PowerShell 執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\cookie-bridge\build.ps1
.\tools\cookie-bridge\dist\cookie-bridge.exe self-test
```

1. 開啟 `chrome://extensions`。
2. 開啟「開發人員模式」。
3. 選擇「載入未封裝項目」，指定 `tools\cookie-bridge\extension`。
4. 此 extension 透過 manifest public key 固定 ID 為 `fijankghajiibgecbhcplneaebaijgma`。
5. 註冊目前使用者的 Native Messaging host：

```powershell
.\tools\cookie-bridge\dist\cookie-bridge.exe install
```

`install` 只寫入 HKCU 的 Chrome Native Messaging host 登錄以及被 `.gitignore` 排除的 `data/auth` 設定。

## 匯出

Chrome 必須正在執行且 extension 已啟用：

```powershell
.\tools\cookie-bridge\dist\cookie-bridge.exe export --timeout 120
```

成功時 exit code 為 `0`，並產生：

```text
data/auth/youtube.cookies.txt
```

失敗或逾時為非零；舊 Cookie 檔會先被移除，因此不會默默沿用舊登入資料。若不想等待下一個 30 秒 alarm，可在執行 `export` 後按 extension 圖示，再按「立即檢查匯出請求」。

## yt-dlp 登入／Premium 驗證

只執行 `-J -v --skip-download` metadata probe，不下載音訊：

```powershell
.\tools\cookie-bridge\dist\cookie-bridge.exe validate `
  --url "https://www.youtube.com/watch?v=VIDEO_ID" `
  --require-premium
```

驗證器只輸出：

```text
Authentication validation successful/failed
Premium validation successful/failed
```

不會轉印 yt-dlp verbose output 或 Cookie value。

## Task Scheduler

排程動作可使用：

```text
Program: C:\Path\To\YoutubeAudioDownloader\tools\cookie-bridge\dist\cookie-bridge.exe
Arguments: export --timeout 120
Start in: C:\Path\To\YoutubeAudioDownloader
```

只有 exit code `0` 時才執行下一步：

```text
cookie-bridge.exe validate --url <probe URL> --require-premium
```

驗證成功後才執行 playlist check。Chrome 未執行、extension 未啟用、Native host 未註冊或匯出失敗時都會以非零結束，不會匿名執行 yt-dlp。

## 權限與 domain

Extension permissions：

- `cookies`：讀取限定 host permissions 的 Cookie。
- `nativeMessaging`：只傳到本機已註冊的 host。
- `alarms`：在 Chrome 執行期間輪詢 Task Scheduler 建立的匯出請求。

Host permissions 僅有：

- `https://*.youtube.com/*`
- `https://*.google.com/*`

Chrome Cookie API 要求 extension 對 Cookie 所屬 domain 具備 host permission；這兩個 wildcard 對應允許匯出的 `.youtube.com` 與 `.google.com`。Extension 仍只查詢 `www.youtube.com`、`music.youtube.com`、`accounts.google.com` 三個 URL，native host 也會再次拒絕不在明確 domain allowlist 的 Cookie。

允許的 Cookie domain：

- `.youtube.com`、`youtube.com`、`www.youtube.com`、`music.youtube.com`
- `.google.com`、`google.com`、`accounts.google.com`

沒有加入 `googleusercontent.com`、其他網站或全 profile Cookie 權限。

## 安全性

- Native host manifest 的 `allowed_origins` 是固定 extension ID，不使用 wildcard。
- 每次匯出使用一次性 256-bit nonce，過期或不相符即拒絕。
- Cookie 值只存在 Chrome → Native Messaging stdin → `youtube.cookies.txt`，不寫 console/log/result JSON。
- `data/auth` 和 Cookie 檔透過 Windows ACL 限制為目前使用者。
- `data/auth/`、編譯輸出及所有 Cookie 檔均被 Git 忽略。
- 不開 HTTP port、不 bind `0.0.0.0`、不連外上傳。
