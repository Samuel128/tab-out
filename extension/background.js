/**
 * background.js — Badge updates and optional browser whitelist routing
 *
 * Chrome's "always-on" background script for Tab Out.
 * Keeps the toolbar badge current and checks local proxy health when opted in.
 *
 * Since we no longer have a server, we query chrome.tabs directly.
 * The badge counts real web tabs (skipping chrome:// and extension pages).
 *
 * Color coding gives a quick at-a-glance health signal:
 *   Green  (#3d7a4a) → 1–10 tabs  (focused, manageable)
 *   Amber  (#b8892e) → 11–20 tabs (getting busy)
 *   Red    (#b35a5a) → 21+ tabs   (time to cull!)
 */

importScripts('browser-routing.js');
const browserRouting = TabOutBrowserRouting.createManager(chrome);
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !TabOutBrowserRouting.messages.has(message?.type)) return false;
  const action = { 'browser-routing-status': 'status', 'browser-routing-enable': 'enable', 'browser-routing-disable': 'disable', 'browser-routing-refresh': 'refresh' }[message.type];
  browserRouting[action]().then(data => reply({ ok: true, data }), error => reply({ ok: false, error: error.message }));
  return true;
});
const ROUTING_ALARM = 'tab-out-routing-health';
let routingRefresh;
function refreshBrowserRouting() {
  if (!routingRefresh) routingRefresh = browserRouting.refresh().catch(() => {}).finally(() => { routingRefresh = null; });
  return routingRefresh;
}
async function syncRoutingAlarm() {
  if (!chrome.alarms?.get || !chrome.alarms?.create || !chrome.alarms?.clear) return;
  const saved = await chrome.storage.local.get('browserRoutingEnabled');
  const allowed = await chrome.permissions.contains({ permissions: ['proxy'] });
  if (saved.browserRoutingEnabled && allowed) {
    const alarm = await chrome.alarms.get(ROUTING_ALARM);
    if (!alarm || alarm.periodInMinutes !== 0.5) await chrome.alarms.create(ROUTING_ALARM, { periodInMinutes: 0.5 });
  } else await chrome.alarms.clear(ROUTING_ALARM);
}
function startBrowserRouting() { void syncRoutingAlarm().catch(() => {}); void refreshBrowserRouting(); }
chrome.runtime.onStartup.addListener(refreshBrowserRouting);
chrome.runtime.onInstalled.addListener(startBrowserRouting);
chrome.alarms?.onAlarm?.addListener(alarm => { if (alarm.name === ROUTING_ALARM) void refreshBrowserRouting(); });
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.browserRoutingEnabled) void syncRoutingAlarm().catch(() => {});
});
chrome.permissions.onAdded.addListener(startBrowserRouting);
chrome.permissions.onRemoved.addListener(() => { void syncRoutingAlarm().catch(() => {}); });
chrome.proxy?.onProxyError?.addListener(error => {
  if (error.fatal) void browserRouting.recover().catch(() => {});
  else void refreshBrowserRouting();
});
startBrowserRouting();

// ─── Badge updater ────────────────────────────────────────────────────────────

/**
 * updateBadge()
 *
 * Counts open real-web tabs and updates the extension's toolbar badge.
 * "Real" tabs = not chrome://, not extension pages, not about:blank.
 */
async function updateBadge() {
  try {
    const tabs = await chrome.tabs.query({});

    // Only count actual web pages — skip browser internals and extension pages
    const count = tabs.filter(t => {
      const url = t.url || '';
      return (
        !url.startsWith('chrome://') &&
        !url.startsWith('chrome-extension://') &&
        !url.startsWith('about:') &&
        !url.startsWith('edge://') &&
        !url.startsWith('brave://')
      );
    }).length;

    // Don't show "0" — an empty badge is cleaner
    await chrome.action.setBadgeText({ text: count > 0 ? String(count) : '' });

    if (count === 0) return;

    // Pick badge color based on workload level
    let color;
    if (count <= 10) {
      color = '#3d7a4a'; // Green — you're in control
    } else if (count <= 20) {
      color = '#b8892e'; // Amber — things are piling up
    } else {
      color = '#b35a5a'; // Red — time to focus and close some tabs
    }

    await chrome.action.setBadgeBackgroundColor({ color });

  } catch {
    // If something goes wrong, clear the badge rather than show stale data
    chrome.action.setBadgeText({ text: '' });
  }
}

// ─── Event listeners ──────────────────────────────────────────────────────────

// Update badge when the extension is first installed
chrome.runtime.onInstalled.addListener(() => {
  updateBadge();
});

// Update badge when Chrome starts up
chrome.runtime.onStartup.addListener(() => {
  updateBadge();
});

// Update badge whenever a tab is opened
chrome.tabs.onCreated.addListener(() => {
  updateBadge();
  void refreshBrowserRouting();
});

// Update badge whenever a tab is closed
chrome.tabs.onRemoved.addListener(() => {
  updateBadge();
});

// Update badge when a tab's URL changes (e.g. navigating to/from chrome://)
chrome.tabs.onUpdated.addListener(() => {
  updateBadge();
});

// ─── Initial run ─────────────────────────────────────────────────────────────

// Run once immediately when the service worker first loads
updateBadge();
