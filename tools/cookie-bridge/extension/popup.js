const button = document.getElementById("export");
const status = document.getElementById("status");

button.addEventListener("click", async () => {
  button.disabled = true;
  status.textContent = "正在連線本機 bridge…";
  try {
    const result = await chrome.runtime.sendMessage({ type: "export-now" });
    status.textContent = result?.status || "已完成檢查";
  } catch (_) {
    status.textContent = "Native Messaging bridge 無法使用";
  } finally {
    button.disabled = false;
  }
});
