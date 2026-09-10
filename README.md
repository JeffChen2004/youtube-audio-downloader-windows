# YouTube 音訊下載器

Windows 圖形介面工具，支援影片或播放清單、音訊格式與品質選擇。

## 使用方式

1. 直接雙擊 `啟動下載器.cmd`（或對 `YoutubeAudioDownloader.ps1` 按右鍵，選 **使用 PowerShell 執行**）。
2. 貼上 YouTube 影片或播放清單網址。
3. 選擇格式（含 `opus`）與品質；`0（最佳）` 會以來源可用的最佳音訊下載／轉換。
4. 若內容需要登入才可存取，可在「登入瀏覽器」選擇已登入 YouTube 的瀏覽器。若出現 DPAPI 錯誤，請改用下方的 `cookies.txt` 檔案。

首次執行會在 `tools` 資料夾下載官方的 `yt-dlp.exe`、FFmpeg 與 Deno。Deno 用於處理 YouTube 目前要求的 JavaScript challenge；音訊預設儲存在 `downloads`。

下載 Opus 時，紀錄中可能先出現 `.webm`：這是 YouTube 提供的原始音訊容器，完成後會由 FFmpeg 轉封裝為 `.opus`。不需手動處理暫存檔。


## 說明與限制

- 勾選「下載整個播放清單」可批次下載；取消勾選就只抓該網址的單支影片。
- 選擇瀏覽器時，工具會讓 yt-dlp 從該瀏覽器讀取當次登入 cookie；不會另外複製或保存 cookie。請先完全關閉該瀏覽器，若遇到 cookie 資料庫被鎖定的錯誤。
- Chromium 有時會以 Windows 的 App-Bound Encryption 保護 cookie，這會使直接讀取瀏覽器失敗。此時請以可信任的瀏覽器擴充功能匯出 **僅 `youtube.com`** 的 Netscape/Mozilla 格式 `cookies.txt`，再在「Cookies 檔案」選取它。檔案具有登入權限，請妥善保管、不要分享，完成後可刪除。指定檔案會優先於「登入瀏覽器」。
- YouTube Premium 的「離線下載」檔受 DRM 保護，無法透過此工具匯出或轉檔。本工具不會繞過 DRM；登入僅用於下載你的帳號正常有權存取、且以非 DRM 方式提供的串流。
- 請確認下載與使用方式符合 YouTube 條款、著作權法及內容權利人的授權。
