'use strict';
const TabOutBrowserRouting = (() => {
  const HOST = 'com.samuel.tabout.proxy';
  const messages = new Set(['browser-routing-status', 'browser-routing-enable', 'browser-routing-disable', 'browser-routing-refresh']);
  function validateSnapshot(data) {
    if (!data || !Number.isInteger(data.proxyPort) || data.proxyPort < 1 || data.proxyPort > 65535 || !Array.isArray(data.rules) || data.rules.length > 2000 || !Array.isArray(data.protectedSuffixes)) throw new Error('Invalid browser routing snapshot');
    if (data.clashAvailable !== undefined && typeof data.clashAvailable !== 'boolean') throw new Error('Invalid Clash availability');
    const valid = text => typeof text === 'string' && text.length > 0 && text.length <= 253 && /^[a-z0-9.:-]+$/.test(text);
    if (!data.rules.every(rule => ['suffix', 'exact', 'keyword'].includes(rule.type) && valid(rule.value)) || !data.protectedSuffixes.every(valid)) throw new Error('Invalid browser routing rule');
    return data;
  }
  function buildPac(snapshot) {
    const data = validateSnapshot(snapshot);
    if (data.clashAvailable !== true) return 'function FindProxyForURL(url, host) { return "DIRECT"; }';
    // Only hostnames are matched. Avoid DNS inside PAC, particularly a stopped local DNS proxy.
    return `function FindProxyForURL(url, host) {
  host = String(host).toLowerCase().replace(/\\.+$/, "").replace(/^\\[|\\]$/g, "");
  var rules = ${JSON.stringify(data.rules.map(({ type, value }) => ({ type, value })))};
  var protectedSuffixes = ${JSON.stringify(data.protectedSuffixes)};
  function suffix(value) { return host === value || host.slice(-(value.length + 1)) === "." + value; }
  function privateIPv4(value) {
    var p = value.split(".");
    if (p.length !== 4 || !p.every(function(n) { return /^\\d{1,3}$/.test(n) && Number(n) <= 255; })) return false;
    var a = Number(p[0]), b = Number(p[1]);
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  }
  if (host.indexOf(".") === -1 && host.indexOf(":") === -1) return "DIRECT";
  if (suffix("localhost") || suffix("local") || privateIPv4(host) || /^(?:fc|fd|fe[89ab])[0-9a-f]*:/.test(host) || host === "::1" || host === "0:0:0:0:0:0:0:1" || (/^::ffff:/.test(host) && privateIPv4(host.slice(7)))) return "DIRECT";
  for (var i = 0; i < protectedSuffixes.length; i++) if (suffix(protectedSuffixes[i])) return "DIRECT";
  for (var j = 0; j < rules.length; j++) {
    var rule = rules[j];
    if ((rule.type === "suffix" && suffix(rule.value)) || (rule.type === "exact" && host === rule.value) || (rule.type === "keyword" && host.indexOf(rule.value) !== -1)) return "PROXY 127.0.0.1:${data.proxyPort}; DIRECT";
  }
  return "DIRECT";
}`;
  }
  function readSnapshot(api) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Routing helper timed out.')), 5000);
      try { api.runtime.sendNativeMessage(HOST, { protocolVersion: 1, command: 'routing_snapshot', payload: {} }, response => {
        clearTimeout(timer);
        if (api.runtime.lastError) { reject(new Error(api.runtime.lastError.message)); return; }
        if (!response?.ok || response.protocolVersion !== 1) { reject(new Error(response?.error?.message || 'Update the native routing helper.')); return; }
        try { resolve(validateSnapshot(response.data)); } catch (error) { reject(error); }
      }); } catch (error) { clearTimeout(timer); reject(error); }
    });
  }
  function createManager(api) {
    let queue = Promise.resolve();
    const serialize = work => { const result = queue.catch(() => {}).then(work); queue = result; return result; };
    async function permitted() { return api.permissions?.contains({ permissions: ['proxy'] }) ?? false; }
    async function status() {
      const saved = await api.storage.local.get(['browserRoutingEnabled', 'browserRoutingError', 'browserRoutingTun', 'browserRoutingClash', 'browserRoutingValue']);
      if (!await permitted()) return { enabled: Boolean(saved.browserRoutingEnabled), effective: false, permission: false, error: saved.browserRoutingError };
      const current = await api.proxy.settings.get({ incognito: false });
      return { enabled: Boolean(saved.browserRoutingEnabled), effective: Boolean(saved.browserRoutingEnabled) && current.levelOfControl === 'controlled_by_this_extension' && sameValue(current.value, saved.browserRoutingValue), permission: true, error: saved.browserRoutingError, clashAvailable: saved.browserRoutingClash === true, tunConfigured: saved.browserRoutingTun, levelOfControl: current.levelOfControl };
    }
    function sameValue(a, b) {
      return a && b && a.mode === b.mode && (a.mode === 'direct' || (a.mode === 'pac_script' && a.pacScript?.data === b.pacScript?.data && a.pacScript?.mandatory === b.pacScript?.mandatory));
    }
    async function controllable() {
      if (!await permitted() || !api.proxy) throw new Error('Browser proxy permission has not been granted.');
      const current = await api.proxy.settings.get({ incognito: false });
      if (!['controlled_by_this_extension', 'controllable_by_this_extension'].includes(current.levelOfControl)) throw new Error('Browser proxy settings are controlled by another extension or policy.');
      return current;
    }
    async function writeValue(value, state) {
      const current = await controllable();
      if (current.levelOfControl !== 'controlled_by_this_extension' || !sameValue(current.value, value)) await api.proxy.settings.set({ scope: 'regular', value });
      const verified = await api.proxy.settings.get({ incognito: false });
      if (verified.levelOfControl !== 'controlled_by_this_extension' || !sameValue(verified.value, value)) throw new Error('Browser routing could not be verified.');
      await api.storage.local.set({ browserRoutingEnabled: true, browserRoutingValue: value, ...state });
      return status();
    }
    async function apply() {
      await controllable();
      let snapshot;
      try { snapshot = await readSnapshot(api); }
      catch (error) {
        // Do not clear: that would resurrect a stopped system HTTP proxy.
        return writeValue({ mode: 'direct' }, { browserRoutingClash: false, browserRoutingError: error.message });
      }
      const online = snapshot.clashAvailable === true;
      const value = online ? { mode: 'pac_script', pacScript: { data: buildPac(snapshot), mandatory: true } } : { mode: 'direct' };
      return writeValue(value, { browserRoutingClash: online, browserRoutingError: snapshot.clashAvailable === undefined ? 'Update the native routing helper; using DIRECT until health can be checked.' : null, browserRoutingTun: Boolean(snapshot.tunConfigured) });
    }
    async function handleFailure(work) {
      try { return await work(); }
      catch (error) { await api.storage.local.set({ browserRoutingError: error.message }); throw error; }
    }
    return {
      status,
      enable() { return serialize(() => handleFailure(apply)); },
      refresh() { return serialize(async () => { const saved = await api.storage.local.get('browserRoutingEnabled'); return saved.browserRoutingEnabled ? handleFailure(apply) : status(); }); },
      recover() { return serialize(async () => {
        const saved = await api.storage.local.get('browserRoutingEnabled');
        return saved.browserRoutingEnabled ? handleFailure(() => writeValue({ mode: 'direct' }, { browserRoutingClash: false, browserRoutingError: 'Browser proxy error; using DIRECT until the next health check.' })) : status();
      }); },
      disable() { return serialize(async () => {
        if (await permitted()) {
          const current = await api.proxy.settings.get({ incognito: false });
          if (current.levelOfControl === 'controlled_by_this_extension') await api.proxy.settings.clear({ scope: 'regular' });
        }
        await api.storage.local.set({ browserRoutingEnabled: false, browserRoutingError: null });
        return status();
      }); },
    };
  }
  async function send(api, type) {
    let response;
    try { response = await api.runtime.sendMessage({ type }); }
    catch (error) {
      if (/Receiving end does not exist|Extension context invalidated/i.test(error.message || '')) {
        const message = 'Reload Tab Out in Chrome extensions, then refresh this page. The browser routing worker is unavailable.';
        throw new Error(globalThis.TabOutI18n?.t(message) || message);
      }
      throw error;
    }
    if (!response?.ok) throw new Error(response?.error || 'Browser routing worker unavailable.');
    return response.data;
  }
  return { buildPac, validateSnapshot, createManager, messages, send };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = TabOutBrowserRouting;
