// Disposable Chromium profile only. Never edits or grants permissions in the user's Chrome profile.
import assert from 'node:assert/strict';
import { mkdtemp, copyFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
assert(process.env.PLAYWRIGHT_MODULE && process.env.BROWSER_EXECUTABLE && process.env.TEST_DIRECT_URL, 'Set installed Playwright, full Chromium executable and a direct test URL');
const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE).href);
const root = await mkdtemp(path.join(tmpdir(), 'tab-out-routing-smoke-'));
const extension = path.join(root, 'extension'); await mkdir(extension);
await copyFile(new URL('../extension/browser-routing.js', import.meta.url), path.join(extension, 'browser-routing.js'));
await writeFile(path.join(extension, 'manifest.json'), JSON.stringify({ manifest_version: 3, name: 'Tab Out routing test fixture', version: '1.0.0', permissions: ['proxy', 'storage'], background: { service_worker: 'worker.js' } }));
await writeFile(path.join(extension, 'worker.js'), "importScripts('browser-routing.js');");
await writeFile(path.join(extension, 'probe.html'), '<!doctype html><title>Routing fixture</title><script src="browser-routing.js"></script>');
const context = await chromium.launchPersistentContext(path.join(root, 'profile'), { headless: true, executablePath: process.env.BROWSER_EXECUTABLE, args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`] });
try {
  const worker = context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker');
  const id = new URL(worker.url()).host;
  const probe = await context.newPage(); await probe.goto(`chrome-extension://${id}/probe.html`);
  const state = await probe.evaluate(async () => {
    globalThis.routingSnapshot = { rules: [{ type: 'suffix', value: 'proxied.example' }], protectedSuffixes: ['internal.example'], proxyPort: 9, clashAvailable: true };
    const api = { proxy: chrome.proxy, permissions: chrome.permissions, storage: chrome.storage, runtime: { sendNativeMessage(_host, _request, callback) { callback({ ok: true, protocolVersion: 1, data: globalThis.routingSnapshot }); } } };
    globalThis.manager = TabOutBrowserRouting.createManager(api);
    return manager.enable();
  });
  assert.equal(state.effective, true);
  const direct = await context.newPage();
  const response = await direct.goto(process.env.TEST_DIRECT_URL, { waitUntil: 'domcontentloaded', timeout: 25000 });
  assert(response && response.status() >= 200 && response.status() < 400, 'Non-listed host must load while the test proxy is offline');
  const matched = await context.newPage();
  await probe.evaluate(async host => {
    routingSnapshot.rules = [{ type: 'exact', value: host }];
    await manager.refresh();
  }, new URL(process.env.TEST_DIRECT_URL).hostname);
  const fallbackResponse = await matched.goto(process.env.TEST_DIRECT_URL, { waitUntil: 'domcontentloaded', timeout: 25000 });
  assert(fallbackResponse && fallbackResponse.status() >= 200 && fallbackResponse.status() < 400, 'Matched host may fall back to DIRECT when proxy port is unavailable');
  const offline = await probe.evaluate(async () => { routingSnapshot.clashAvailable = false; return manager.refresh(); });
  assert.equal(offline.effective, true);
  assert.equal(offline.clashAvailable, false);
  assert.equal((await probe.evaluate(() => chrome.proxy.settings.get({ incognito: false }))).value.mode, 'direct');
  const disabled = await probe.evaluate(() => manager.disable()); assert.equal(disabled.enabled, false);
  console.log(JSON.stringify({ effective: state.effective, nonListedStatus: response.status(), matchedFallbackStatus: fallbackResponse.status(), offlineDirectMode: true, restoredFixtureSettings: true, userProfileModified: false }, null, 2));
} finally { await context.close(); }
