'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function fixture(enabled = true, missing = []) {
  const events = {}, calls = [], storage = { browserRoutingEnabled: enabled };
  const event = name => ({ addListener(fn) { (events[name] ??= []).push(fn); } });
  let alarm;
  const chrome = {
    runtime: { id: 'fixture', onMessage: event('message'), onStartup: event('startup'), onInstalled: event('installed') },
    storage: { local: { async get() { return storage; } }, onChanged: event('storage') },
    permissions: { async contains() { return true; }, onAdded: event('permissionAdded'), onRemoved: event('permissionRemoved') },
    alarms: { onAlarm: event('alarm'), async get() { return alarm; }, async create(name, info) { alarm = { name, ...info }; calls.push(['alarm', alarm]); }, async clear() { alarm = undefined; calls.push(['clearAlarm']); } },
    proxy: { onProxyError: event('proxyError') },
    tabs: { async query() { return []; }, onCreated: event('tabCreated'), onRemoved: event('tabRemoved'), onUpdated: event('tabUpdated') },
    action: { async setBadgeText() {}, async setBadgeBackgroundColor() {} },
  };
  const manager = { async refresh() { calls.push(['refresh']); }, async recover() { calls.push(['recover']); } };
  for (const key of missing) delete chrome[key];
  const context = vm.createContext({ chrome, importScripts() {}, TabOutBrowserRouting: { createManager() { return manager; }, messages: new Set() } });
  vm.runInContext(fs.readFileSync(require.resolve('../extension/background.js'), 'utf8'), context);
  return { events, calls, storage, get alarm() { return alarm; }, async fire(name, ...args) { for (const fn of events[name] ?? []) fn(...args); await new Promise(resolve => setImmediate(resolve)); } };
}
test('missing alarm or optional proxy API does not kill the message receiver', async () => {
  const f = fixture(false, ['alarms', 'proxy']);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.events.message.length, 1);
  assert.ok(f.events.tabCreated.length);
});
test('enabled routing recreates a periodic health alarm on worker startup and refreshes on alarm', async () => {
  const f = fixture();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.alarm?.periodInMinutes, 0.5);
  assert.ok(f.calls.some(([type]) => type === 'refresh'));
  const count = f.calls.length;
  await f.fire('alarm', { name: f.alarm.name });
  assert.ok(f.calls.slice(count).some(([type]) => type === 'refresh'));
});
test('no background routing poll without explicit opt-in; enable/disable updates the alarm', async () => {
  const f = fixture(false);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.alarm, undefined);
  f.storage.browserRoutingEnabled = true;
  await f.fire('storage', { browserRoutingEnabled: { newValue: true } }, 'local');
  assert.equal(f.alarm?.periodInMinutes, 0.5);
  f.storage.browserRoutingEnabled = false;
  await f.fire('storage', { browserRoutingEnabled: { newValue: false } }, 'local');
  assert.equal(f.alarm, undefined);
});
test('fatal proxy errors use direct recovery; unrelated alarms do not refresh routing', async () => {
  const f = fixture();
  await new Promise(resolve => setImmediate(resolve));
  await f.fire('proxyError', { fatal: true });
  assert.ok(f.calls.some(([type]) => type === 'recover'));
  const count = f.calls.length;
  await f.fire('alarm', { name: 'unrelated' });
  assert.equal(f.calls.length, count);
});
test('manifest includes alarms permission for suspended service workers', () => {
  const manifest = require('../extension/manifest.json');
  assert.ok(manifest.permissions.includes('alarms'));
});
