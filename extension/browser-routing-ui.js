'use strict';
const TabOutBrowserRoutingUI = (() => {
  const tr = text => globalThis.TabOutI18n?.t(text) || text;
  let busy = false;
  async function render() {
    const status = document.getElementById('browserRoutingStatus');
    if (!status) return;
    try {
      const data = await TabOutBrowserRouting.send(chrome, 'browser-routing-status');
      const message = data.enabled && data.effective ? (data.clashAvailable ? 'Clash available: listed domains use proxy with DIRECT fallback; all other domains are DIRECT.' : 'Clash unavailable: all domains are DIRECT. Whitelist proxying resumes automatically when available.') : data.enabled ? 'Browser whitelist is not effective. Check permission, other extensions or policy.' : 'Not enabled: Chrome still follows its existing proxy settings.';
      status.textContent = tr(message) + (data.error ? ` ${data.error}` : '');
      document.getElementById('browserRoutingDisable').hidden = !data.enabled;
      document.getElementById('browserRoutingEnable').textContent = tr(data.enabled ? 'Retry browser whitelist' : 'Enable browser whitelist');
      document.getElementById('browserRoutingTun').hidden = !data.tunConfigured;
    } catch (error) { status.textContent = error.message; }
  }
  async function refresh() {
    try { await TabOutBrowserRouting.send(chrome, 'browser-routing-refresh'); }
    catch (error) { console.warn('[tab-out] Browser whitelist:', error.message); }
    await render();
  }
  function start() {
    const enable = document.getElementById('browserRoutingEnable'), disable = document.getElementById('browserRoutingDisable');
    if (!enable || !disable) return;
    enable.addEventListener('click', async () => {
      if (busy) return;
      busy = true; enable.disabled = true;
      try {
        // Permission must be requested immediately from this deliberate user gesture.
        const granted = await chrome.permissions.request({ permissions: ['proxy'] });
        if (!granted) throw new Error(tr('Browser proxy permission was not granted. No settings changed.'));
        await TabOutBrowserRouting.send(chrome, 'browser-routing-enable');
      } catch (error) { document.getElementById('browserRoutingStatus').textContent = error.message; return; }
      finally { busy = false; enable.disabled = false; }
      await render();
    });
    disable.addEventListener('click', async () => {
      if (busy || !confirm(tr('Return Chrome to its previous system proxy? A stopped system proxy can prevent normal sites from opening.'))) return;
      busy = true; disable.disabled = true;
      try { await TabOutBrowserRouting.send(chrome, 'browser-routing-disable'); }
      catch (error) { document.getElementById('browserRoutingStatus').textContent = error.message; }
      finally { busy = false; disable.disabled = false; }
      await render();
    });
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && ['browserRoutingEnabled', 'browserRoutingError', 'browserRoutingTun', 'browserRoutingClash', 'browserRoutingValue'].some(key => changes[key])) void render();
    });
    void refresh();
  }
  if (typeof document !== 'undefined') document.addEventListener('DOMContentLoaded', start);
  return { refresh, render };
})();
