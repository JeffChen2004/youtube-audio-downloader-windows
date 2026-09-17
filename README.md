# YouTube 音訊下載器

Windows 圖形介面工具，支援影片或播放清單、音訊格式與品質選擇。

## 使用方式

1. 直接雙擊 `啟動下載器.cmd`（或對 `YoutubeAudioDownloader.ps1` 按右鍵，選 **使用 PowerShell 執行**）。
2. 貼上 YouTube 影片或播放清單網址。
3. 選擇格式與品質模式。對 Opus 選「保留來源最佳品質」時，工具會檢查並直接下載最高位元率的原始 Opus；選「重新編碼」或輸出其他格式時，才會套用「轉碼品質」。
4. 在「登入方式」選擇不使用登入、Cookie 檔案、Chrome Cookie Bridge，或瀏覽器直接讀取。Chrome Cookie Bridge 會在每個新下載工作開始前要求 Chrome 匯出一份新 Cookie，並在整份播放清單中共用。

首次執行會在 `tools` 資料夾下載官方的 `yt-dlp.exe`、FFmpeg 與 Deno。Deno 用於處理 YouTube 目前要求的 JavaScript challenge；音訊預設儲存在 `downloads`。

下載 Opus 時，紀錄中可能先出現 `.webm`：這是 YouTube 提供的原始音訊容器，完成後會由 FFmpeg 轉封裝為 `.opus`。不需手動處理暫存檔。

## 播放清單追蹤

主畫面底部提供「加入追蹤播放清單」、「檢查追蹤播放清單」與「查看追蹤清單」。加入時可選擇：

- **從現在開始追蹤**：以 yt-dlp 原生 `--force-write-archive` 初始化目前項目，不下載既有內容。
- **補齊目前播放清單**：建立空白追蹤狀態後，立即透過既有下載流程補齊尚未成功下載的項目。

每個播放清單的設定與 archive 分別儲存在 `data/tracked-playlists/<playlist_id>.json` 和 `<playlist_id>.archive.txt`。檢查時使用設定內保存的認證模式與輸出資料夾，並以 `--download-archive` 判斷新增項目；檔名、播放清單順序與本機音訊是否仍存在都不作為已下載判斷依據。這個資料夾屬於本機狀態，已排除於 Git。

「檢查格式」會以 `yt-dlp -J` 依序探測 `Auto`、`web_music`、`web`、`mweb` 四種 YouTube player client，並從每個 client 的 audio-only 格式選出實際 abr 最高的 Opus。若 Auto 已達 250 kbps 以上會提前停止，以減少請求。工具快取探測結果；只有網址、cookies.txt 路徑或登入瀏覽器改變時才會失效。若找不到原始 Opus，工具會先詢問你是否下載其他最高品質的原始音訊，不會自動重新編碼。

「詳細診斷」只測 `Auto` 與 `web_music`，並將 yt-dlp 的完整 verbose 輸出寫入 `logs\probe-debug-YYYYMMDD-HHMMSS.txt`。GUI 只顯示版本、cookies、登入／Premium 訊號、PO Token、SABR、格式與 JS/EJS 警告的摘要；未出現的訊號會標為 `Unknown` 或 `None reported`，不會推測原因。可用「更新 yt-dlp」按鈕從官方 release 手動取得最新版。


## 說明與限制

- 勾選「下載整個播放清單」可批次下載；取消勾選就只抓該網址的單支影片。
- Chrome Cookie Bridge 模式使用專案內的 Native Messaging extension，將目前的 YouTube/Google Cookie 匯出到 `data/auth/youtube.cookies.txt`。匯出或 Premium 驗證失敗時會取消下載，不會改用匿名、瀏覽器直接讀取或舊 Cookie。
- Cookie 檔案模式只會使用 GUI 指定的 Netscape `cookies.txt`；不會執行 Cookie Bridge。檔案具有登入權限，請妥善保管、不要分享。
- 瀏覽器直接讀取模式維持 yt-dlp 的 `--cookies-from-browser` 行為。Chrome 開啟時可能無法複製 Cookie database；程式只會提示關閉 Chrome，不會自動終止瀏覽器或 fallback。
- YouTube Premium 的「離線下載」檔受 DRM 保護，無法透過此工具匯出或轉檔。本工具不會繞過 DRM；登入僅用於下載你的帳號正常有權存取、且以非 DRM 方式提供的串流。
- 請確認下載與使用方式符合 YouTube 條款、著作權法及內容權利人的授權。
