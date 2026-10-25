'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const Routing = require('../extension/browser-routing.js');
const snapshot = { rules: [{ type: 'suffix', value: 'proxy.example' }, { type: 'keyword', value: 'cloud' }, { type: 'exact', value: 'exact.example' }], protectedSuffixes: ['internal.example'], proxyPort: 7897, clashAvailable: true };
function route(host, data = snapshot) { const context = vm.createContext({}); vm.runInContext(Routing.buildPac(data), context); return context.FindProxyForURL(`https://${host}/`, host); }
test('non-whitelisted hosts connect directly even if the proxy is not running', () => {
  assert.equal(route('normal.example'), 'DIRECT');
  assert.equal(route('app.internal.example'), 'DIRECT');
  assert.equal(route('app.cloud.internal.example'), 'DIRECT');
  assert.equal(route('notproxy.example'), 'DIRECT');
});
test('whitelist matching is host-only and suffixes respect domain boundaries', () => {
  assert.equal(route('proxy.example'), 'PROXY 127.0.0.1:7897; DIRECT');
  assert.equal(route('APP.PROXY.EXAMPLE.'), 'PROXY 127.0.0.1:7897; DIRECT');
  assert.equal(route('exact.example'), 'PROXY 127.0.0.1:7897; DIRECT');
  assert.equal(route('sub.exact.example'), 'DIRECT');
  const c = vm.createContext({}); vm.runInContext(Routing.buildPac(snapshot), c);
  assert.equal(c.FindProxyForURL('https://normal.example/cloud/proxy.example', 'normal.example'), 'DIRECT');
});
test('private IPv4, IPv6, localhost and simple hostnames always bypass broad keywords', () => {
  const data = { ...snapshot, rules: [{ type: 'keyword', value: '172' }, { type: 'keyword', value: 'localhost' }, { type: 'keyword', value: 'fd0' }] };
  for (const host of ['172.16.2.3', '127.0.0.1', '[::1]', '[fd00::1]', '[fe80::1]', 'localhost', 'a.localhost', 'printer', 'host.local']) assert.equal(route(host, data), 'DIRECT', host);
});
test('generated PAC uses no DNS and falls back to DIRECT if Clash closes between checks', () => {
  assert.doesNotMatch(Routing.buildPac(snapshot), /dnsResolve|isResolvable|eval\(/);
  assert.equal(route('proxy.example').includes('; DIRECT'), true);
  assert.throws(() => Routing.buildPac({ ...snapshot, proxyPort: 0 }));
  assert.throws(() => Routing.buildPac({ ...snapshot, rules: [{ type: 'suffix', value: 'x";alert(1)' }] }));
  assert.throws(() => Routing.buildPac({ ...snapshot, clashAvailable: 'true' }));
});
test('offline or old helper snapshots never route any hostname to Clash', () => {
  for (const availability of [false, undefined]) {
    const data = { ...snapshot, clashAvailable: availability };
    for (const host of ['normal.example', 'proxy.example', 'app.cloud.example']) assert.equal(route(host, data), 'DIRECT');
  }
});
function chromeMock(level = 'controllable_by_this_extension') {
  const calls = [], storage = { browserRoutingEnabled: false };
  let current = { mode: 'system' }, data = snapshot;
  return { calls, storage, get current() { return current; }, set data(value) { data = value; }, api: {
    runtime: { sendNativeMessage(_host, request, callback) { calls.push(request.command); callback({ ok: true, protocolVersion: 1, data }); } },
    storage: { local: { async get() { return structuredClone(storage); }, async set(value) { Object.assign(storage, structuredClone(value)); } } },
    permissions: { async contains() { return true; } },
    proxy: { settings: { async get() { return { levelOfControl: ['pac_script', 'direct'].includes(current.mode) ? 'controlled_by_this_extension' : level, value: structuredClone(current) }; }, async set({ value }) { calls.push('set'); current = structuredClone(value); }, async clear() { calls.push('clear'); current = { mode: 'system' }; } } },
  } };
}
test('enabling verifies ownership, writes an inline PAC and remembers explicit opt-in', async () => {
  const mock = chromeMock();
  const manager = Routing.createManager(mock.api);
  await manager.enable();
  assert.deepEqual(mock.calls, ['routing_snapshot', 'set']);
  assert.equal(mock.storage.browserRoutingEnabled, true);
  assert.equal((await manager.status()).effective, true);
  await manager.disable();
  assert.equal(mock.storage.browserRoutingEnabled, false);
  assert.ok(mock.calls.includes('clear'));
});
test('does not change browser settings until enabled, and refuses another extension or policy', async () => {
  const mock = chromeMock(); await Routing.createManager(mock.api).refresh();
  assert.deepEqual(mock.calls, []);
  const locked = chromeMock('controlled_by_other_extensions');
  await assert.rejects(Routing.createManager(locked.api).enable(), /control/i);
  assert.equal(locked.storage.browserRoutingEnabled, false);
  assert.equal(locked.calls.includes('set'), false);
});
test('failed refresh uses extension-owned DIRECT, never the dead system proxy', async () => {
  const mock = chromeMock(), manager = Routing.createManager(mock.api); await manager.enable();
  mock.api.runtime.sendNativeMessage = (_host, _request, callback) => callback({ ok: false, protocolVersion: 1, error: { message: 'Snapshot unavailable' } });
  const result = await manager.refresh();
  assert.match(result.error, /Snapshot unavailable/);
  assert.equal(mock.current.mode, 'direct');
  assert.equal(result.clashAvailable, false);
  assert.equal(mock.storage.browserRoutingEnabled, true);
  assert.equal(mock.calls.filter(c => c === 'set').length, 2);
  assert.equal((await manager.status()).effective, true);
  mock.api.runtime.sendNativeMessage = (_host, _request, callback) => callback({ ok: true, protocolVersion: 1, data: snapshot });
  const restored = await manager.refresh();
  assert.equal(restored.clashAvailable, true);
  assert.equal(restored.error, null);
  assert.equal(mock.current.mode, 'pac_script');
});
test('online/offline transitions recover automatically and unchanged checks do not reset PAC', async () => {
  const mock = chromeMock(), manager = Routing.createManager(mock.api);
  await manager.enable();
  await manager.refresh();
  assert.equal(mock.calls.filter(c => c === 'set').length, 1);
  mock.data = { ...snapshot, clashAvailable: false };
  const offline = await manager.refresh();
  assert.equal(offline.effective, true);
  assert.equal(offline.clashAvailable, false);
  assert.equal(mock.current.mode, 'direct');
  mock.data = snapshot;
  assert.equal((await manager.refresh()).clashAvailable, true);
  assert.equal(mock.current.mode, 'pac_script');
});
test('initial helper failure still shields normal sites after explicit opt-in', async () => {
  const mock = chromeMock();
  mock.api.runtime.sendNativeMessage = (_host, _request, callback) => callback({ ok: false, error: { message: 'Offline helper' } });
  const result = await Routing.createManager(mock.api).enable();
  assert.equal(result.effective, true);
  assert.match(result.error, /Offline helper/);
  assert.equal(mock.current.mode, 'direct');
});
test('status verifies the actual installed PAC, not just the proxy setting mode', async () => {
  const mock = chromeMock(), manager = Routing.createManager(mock.api);
  await manager.enable();
  mock.current.pacScript.data = 'function FindProxyForURL() { return "PROXY 127.0.0.1:9"; }';
  assert.equal((await manager.status()).effective, false);
  assert.equal((await manager.refresh()).effective, true);
});
test('fatal PAC errors recover to direct without releasing to the system proxy', async () => {
  const mock = chromeMock(), manager = Routing.createManager(mock.api);
  await manager.enable();
  assert.equal((await manager.recover()).effective, true);
  assert.equal(mock.current.mode, 'direct');
  assert.equal(mock.calls.includes('clear'), false);
  await manager.disable();
  const count = mock.calls.length;
  await manager.recover();
  assert.equal(mock.calls.length, count);
});
test('browser proxy permission is optional and the dashboard loads its controls before app code', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../extension/manifest.json'), 'utf8'));
  assert.equal(manifest.permissions.includes('proxy'), false);
  assert.ok(manifest.optional_permissions.includes('proxy'));
  const html = fs.readFileSync(path.join(__dirname, '../extension/index.html'), 'utf8');
  assert.ok(html.indexOf('src="browser-routing.js"') < html.indexOf('src="browser-routing-ui.js"'));
  assert.ok(html.indexOf('src="browser-routing-ui.js"') < html.indexOf('src="app.js"'));
  assert.match(html, /id="browserRoutingEnable"/);
  assert.match(html, /id="browserRoutingDisable"[^>]*hidden/);
});

test('missing worker explains extension reload without silently changing browser settings', async () => {
  const api = { runtime: { async sendMessage() { throw new Error('Could not establish connection. Receiving end does not exist.'); } } };
  await assert.rejects(Routing.send(api, 'browser-routing-status'), /Reload Tab Out/);
});
