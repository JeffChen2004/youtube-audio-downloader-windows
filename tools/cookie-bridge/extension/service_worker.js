const HOST_NAME = "com.youtube_audio_downloader.cookie_bridge";
const POLL_ALARM = "cookie-bridge-poll";
const COOKIE_URLS = [
  "https://www.youtube.com/",
  "https://music.youtube.com/",
  "https://accounts.google.com/"
];

let activeExport = null;

function allowedCookieDomain(domain) {
  const normalized = String(domain || "").toLowerCase();
  return normalized === ".youtube.com" ||
    normalized === "youtube.com" ||
    normalized === "www.youtube.com" ||
    normalized === "music.youtube.com" ||
    normalized === ".google.com" ||
    normalized === "google.com" ||
    normalized === "accounts.google.com";
}

async function collectAllowedCookies() {
  const cookieGroups = await Promise.all(
    COOKIE_URLS.map((url) => chrome.cookies.getAll({ url }))
  );
  const unique = new Map();
  for (const cookie of cookieGroups.flat()) {
    if (!allowedCookieDomain(cookie.domain)) continue;
    if (cookie.partitionKey) continue;
    const key = [cookie.storeId, cookie.domain, cookie.path, cookie.name].join("\n");
    unique.set(key, {
      domain: cookie.domain,
      path: cookie.path,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      expirationDate: cookie.expirationDate,
      name: cookie.name,
      value: cookie.value
    });
  }
  return [...unique.values()];
}

async function pollNativeHost() {
  if (activeExport) return activeExport;
  activeExport = new Promise((resolve) => {
    let finished = false;
    let port;
    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      try { port?.disconnect(); } catch (_) { }
      resolve(result);
    };
    const timeout = setTimeout(() => finish({ ok: false, status: "native host timeout" }), 20000);

    try {
      port = chrome.runtime.connectNative(HOST_NAME);
      port.onMessage.addListener(async (message) => {
        if (message?.type === "no_request") {
          finish({ ok: true, status: "no export requested" });
          return;
        }
        if (message?.type === "export_request") {
          try {
            const cookies = await collectAllowedCookies();
            port.postMessage({
              type: "cookie_export",
              requestId: message.requestId,
              cookies
            });
          } catch (_) {
            finish({ ok: false, status: "cookie collection failed" });
          }
          return;
        }
        if (message?.type === "result") {
          finish({ ok: Boolean(message.success), status: message.success ? "export complete" : "native host rejected export" });
        }
      });
      port.onDisconnect.addListener(() => {
        if (!finished) finish({ ok: false, status: "native host disconnected" });
      });
      port.postMessage({ type: "hello", version: 1 });
    } catch (_) {
      finish({ ok: false, status: "native host unavailable" });
    }
  }).finally(() => { activeExport = null; });
  return activeExport;
}

function ensurePollingAlarm() {
  chrome.alarms.create(POLL_ALARM, {
    delayInMinutes: 0.5,
    periodInMinutes: 0.5
  });
}

chrome.runtime.onInstalled.addListener(() => {
  ensurePollingAlarm();
  void pollNativeHost();
});

chrome.runtime.onStartup.addListener(() => {
  ensurePollingAlarm();
  void pollNativeHost();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === POLL_ALARM) void pollNativeHost();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "export-now") return false;
  pollNativeHost().then(sendResponse);
  return true;
});

ensurePollingAlarm();
