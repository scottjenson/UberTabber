// Reports raw tab/window focus events to the UberTabber app over a local
// WebSocket, and performs "activate tab" commands sent back by the app.
// No history logic lives here; the app owns that.

const PORT = 47821;
let ws = null;

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  ws.onopen = sendSnapshot;
  ws.onmessage = (e) => handleCommand(JSON.parse(e.data));
  ws.onclose = () => { ws = null; };
}

function send(msg) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  } else {
    connect();
  }
}

function tabInfo(tab) {
  return {
    id: tab.id,
    windowId: tab.windowId,
    index: tab.index,
    title: tab.title,
    url: tab.url,
    favIconUrl: tab.favIconUrl,
    active: tab.active,
  };
}

// Full state on every (re)connect, so the app never depends on events missed
// while it wasn't running.
async function sendSnapshot() {
  const tabs = await chrome.tabs.query({});
  const win = await chrome.windows.getLastFocused().catch(() => null);
  send({
    type: "snapshot",
    tabs: tabs.map(tabInfo),
    focusedWindowId: win && win.focused ? win.id : null,
    lastFocusedWindowId: win ? win.id : null,
  });
  // The app may have restarted, so report icons again.
  iconOrigins.clear();
  tabs.forEach(findIcon);
}

// --- Large site icons ---
// Chrome's favicon is usually 16-32px. Look for the bigger icons sites publish
// for phones (apple-touch-icon, web app manifest) and report the largest.

const iconOrigins = new Set();  // origins already reported since the worker started

function collectIconLinks() {  // runs inside the page
  const links = [...document.querySelectorAll(
    'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')];
  return {
    icons: links.map((l) => ({
      href: l.href,
      size: parseInt(l.sizes?.value) || (l.rel.includes("apple-touch-icon") ? 180 : 0),
      type: l.type,
    })),
    manifest: document.querySelector('link[rel="manifest"]')?.href,
  };
}

const isRaster = (icon) => !/svg/.test(icon.type || "") && !/\.svg(\?|$)/.test(icon.href);

async function findIcon(tab) {
  if (!/^https?:/.test(tab.url || "")) return;
  const origin = new URL(tab.url).origin;
  if (iconOrigins.has(origin)) return;
  iconOrigins.add(origin);

  let candidates = [];
  try {
    const [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: collectIconLinks });
    candidates = result.icons;
    if (result.manifest) {
      const manifest = await (await fetch(result.manifest)).json();
      for (const icon of manifest.icons || []) {
        candidates.push({
          href: new URL(icon.src, result.manifest).href,
          size: parseInt(icon.sizes) || 0,
          type: icon.type,
        });
      }
    }
  } catch {
    // Discarded tabs, Chrome Web Store pages, bad manifests: fall through.
  }

  let best = candidates.filter(isRaster).sort((a, b) => b.size - a.size)[0];
  if (!best || best.size < 64) {
    const guess = `${origin}/apple-touch-icon.png`;
    const res = await fetch(guess, { method: "HEAD" }).catch(() => null);
    if (res && res.ok && (res.headers.get("content-type") || "").startsWith("image/")) {
      best = { href: guess, size: 180 };
    }
  }
  if (best && best.size >= 64) send({ type: "siteIcon", origin, iconUrl: best.href, size: best.size });
}

async function handleCommand(cmd) {
  if (cmd.cmd === "activate") activate(cmd);
}

// Switch to a tab. Tabs left alone for a while can be unloaded by Chrome and
// come back with a new ID, so if the ID is gone, look for the same page by URL
// and tell the app the new ID. If it's really gone, say so and resync.
async function activate({ tabId, url }) {
  let tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab && url) {
    tab = (await chrome.tabs.query({})).find((t) => t.url === url) || null;
    if (tab) send({ type: "tabReplaced", oldTabId: tabId, tab: tabInfo(tab) });
  }
  if (!tab) {
    send({ type: "activateFailed", tabId, url });
    sendSnapshot();
    return;
  }
  await chrome.tabs.update(tab.id, { active: true }).catch(() => {});
  await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
}

// Chrome swaps in a new tab ID when it unloads or reloads a tab in the background.
chrome.tabs.onReplaced.addListener(async (addedTabId, removedTabId) => {
  const tab = await chrome.tabs.get(addedTabId).catch(() => null);
  if (tab) send({ type: "tabReplaced", oldTabId: removedTabId, tab: tabInfo(tab) });
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  const tab = await chrome.tabs.get(tabId);
  send({ type: "tabActivated", tab: tabInfo(tab) });
  findIcon(tab);
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    send({ type: "chromeBlurred" });
    return;
  }
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  if (tab) send({ type: "windowFocused", windowId, tab: tabInfo(tab) });
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.title || change.url || change.favIconUrl) {
    send({ type: "tabUpdated", tab: tabInfo(tab) });
  }
  if (change.status === "complete") findIcon(tab);
});

chrome.tabs.onRemoved.addListener((tabId, { windowId }) => {
  send({ type: "tabRemoved", tabId, windowId });
});

// The alarm wakes the service worker to retry when the app wasn't running.
// The ping keeps an open socket (and so the worker) alive.
chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connect);
setInterval(() => send({ type: "ping" }), 20000);

connect();
