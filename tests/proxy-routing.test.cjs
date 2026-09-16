'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ProxyRouting = require('../extension/proxy-routing.js');

test('native adapter sends only versioned allowlisted commands to fixed host', async () => {
  const calls = [];
  const chromeApi = {
    runtime: {
      lastError: null,
      sendNativeMessage(host, message, callback) {
        calls.push({ host, message });
        callback({ ok: true, protocolVersion: 1, data: { status: 'active', rules: [], syncedAt: null } });
      },
    },
  };
  const data = await ProxyRouting.sendRequest(chromeApi, 'add', { type: 'suffix', value: 'example.com', path: '/tmp/forbidden' });
  assert.equal(data.status, 'active');
  assert.deepEqual(calls, [{
    host: 'com.samuel.tabout.proxy',
    message: { protocolVersion: 1, command: 'add', payload: { type: 'suffix', value: 'example.com' } },
  }]);
  await assert.rejects(ProxyRouting.sendRequest(chromeApi, 'writeFile', { path: '/tmp/x' }), /Unsupported command/);
  assert.equal(calls.length, 1);
});

test('native adapter reports missing helper instead of pretending success', async () => {
  const runtime = {
    sendNativeMessage(_host, _message, callback) {
      runtime.lastError = { message: 'Specified native messaging host not found.' };
      callback(undefined);
      runtime.lastError = null;
    },
  };
  await assert.rejects(
    ProxyRouting.sendRequest({ runtime }, 'status'),
    error => error.code === 'helper_unavailable' && /install/i.test(error.message)
  );
});

test('native adapter reports protocol mismatch and helper errors', async () => {
  const makeApi = response => ({ runtime: { sendNativeMessage(_host, _request, callback) { callback(response); } } });
  await assert.rejects(ProxyRouting.sendRequest(makeApi({ ok: true, protocolVersion: 2, data: {} }), 'list'),
    error => error.code === 'protocol_mismatch');
  await assert.rejects(ProxyRouting.sendRequest(makeApi({ ok: false, protocolVersion: 1, error: { code: 'unsupported_profile', message: 'No PROXY group' } }), 'status'),
    error => error.code === 'unsupported_profile' && /PROXY/.test(error.message));
  await assert.rejects(ProxyRouting.sendRequest(makeApi(undefined), 'status'),
    error => error.code === 'invalid_response');
});

test('quick add accepts only public HTTP(S) hostnames', () => {
  assert.equal(ProxyRouting.quickAddHost('https://Docs.Example.com/path'), 'docs.example.com');
  assert.equal(ProxyRouting.quickAddHost('http://localhost:3000'), null);
  assert.equal(ProxyRouting.quickAddHost('https://app.internal.example/a'), null);
  assert.equal(ProxyRouting.quickAddHost('https://api.corp.example'), null);
  assert.equal(ProxyRouting.quickAddHost('http://192.168.1.2'), null);
  assert.equal(ProxyRouting.quickAddHost('http://10.1.2.3'), null);
  assert.equal(ProxyRouting.quickAddHost('http://172.31.8.1'), null);
  assert.equal(ProxyRouting.quickAddHost('file:///tmp/a'), null);
  assert.equal(ProxyRouting.quickAddHost('chrome://newtab'), null);
  assert.equal(ProxyRouting.quickAddHost('https://example.com.evil.net'), 'example.com.evil.net');
  assert.equal(ProxyRouting.quickAddHost('https://example.test'), null);
});

test('suffix coverage includes parent domain and subdomains but not lookalikes', () => {
  const rules = [
    { id: 'a', type: 'suffix', value: 'example.com' },
    { id: 'b', type: 'keyword', value: 'google' },
  ];
  assert.equal(ProxyRouting.isSuffixCovered('example.com', rules), true);
  assert.equal(ProxyRouting.isSuffixCovered('docs.example.com', rules), true);
  assert.equal(ProxyRouting.isSuffixCovered('notexample.com', rules), false);
  assert.equal(ProxyRouting.isSuffixCovered('google.com', rules), false);
});

test('rule preview and rendering escape untrusted helper values', () => {
  assert.equal(ProxyRouting.rulePreview('keyword', '  gooGle  '), 'DOMAIN-KEYWORD,google');
  assert.equal(ProxyRouting.rulePreview('exact', 'https://api.example.com/a'), 'DOMAIN,api.example.com');
  const html = ProxyRouting.renderRuleRows([{ id: 'x" onclick="evil()', type: 'suffix', value: '<img src=x>' }]);
  assert.doesNotMatch(html, /<img src=x>/);
  assert.doesNotMatch(html, /onclick="evil/);
  assert.match(html, /DOMAIN-SUFFIX/);
});

test('rule rows distinguish applied, pending, and unverified states', () => {
  const rules = [{ id: 'abc', type: 'suffix', value: 'example.com' }];
  assert.match(ProxyRouting.renderRuleRows(rules, 'active'), /Applied/);
  assert.match(ProxyRouting.renderRuleRows(rules, 'pending'), /Waiting for Clash/);
  assert.match(ProxyRouting.renderRuleRows(rules, 'error'), /Unverified/);
});

test('status presentation distinguishes active, pending, stored, and unavailable', () => {
  assert.match(ProxyRouting.statusText({ status: 'active', rules: [], syncedAt: '2026-09-16T00:00:00Z' }), /connected/i);
  assert.match(ProxyRouting.statusText({ status: 'pending', rules: [] }), /waiting/i);
  assert.match(ProxyRouting.statusText({ status: 'stored', rules: [] }), /stored/i);
  assert.match(ProxyRouting.statusText(null, { code: 'helper_unavailable' }), /install/i);
  assert.match(ProxyRouting.statusText(null, { code: 'proxy_group_missing', message: 'No PROXY group' }), /Unsupported Clash profile/);
});

test('controller loads authoritative rules and does not fake successful add', async () => {
  const calls = [];
  const controller = ProxyRouting.createController(async (command, payload) => {
    calls.push([command, payload]);
    if (command === 'status') return { status: 'active', rules: [], syncedAt: '2026-09-16T00:00:00Z' };
    throw Object.assign(new Error('Helper not available'), { code: 'helper_unavailable' });
  });
  await controller.load();
  assert.equal(controller.state().data.status, 'active');
  await assert.rejects(controller.add('suffix', 'example.com'), /Helper not available/);
  assert.deepEqual(controller.state().data.rules, []);
  assert.equal(controller.state().error.code, 'helper_unavailable');
  assert.deepEqual(calls.map(([command]) => command), ['status', 'add']);
});

test('controller removes a rule and offers five seconds to undo', async () => {
  const rule = { id: 'abc', type: 'keyword', value: 'google' };
  const calls = [];
  const timers = new Map();
  let nextTimer = 1;
  let rules = [rule];
  const controller = ProxyRouting.createController(async (command, payload) => {
    calls.push([command, payload]);
    if (command === 'remove') rules = [];
    if (command === 'add') rules = [rule];
    return { status: 'active', rules, syncedAt: '2026-09-16T00:00:00Z' };
  }, {
    setTimeout(callback, ms) { assert.equal(ms, 5000); const id = nextTimer++; timers.set(id, callback); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  await controller.load();
  await controller.remove('abc');
  assert.equal(controller.state().data.rules.length, 0);
  assert.equal(controller.state().undo.value, 'google');
  await controller.undo();
  assert.equal(controller.state().data.rules.length, 1);
  assert.equal(controller.state().undo, null);
  assert.equal(timers.size, 0);
  assert.deepEqual(calls.map(([command]) => command), ['status', 'remove', 'add']);
});

test('controller keeps failed removal in the displayed list without offering undo', async () => {
  const rule = { id: 'abc', type: 'suffix', value: 'example.com' };
  let callback;
  const controller = ProxyRouting.createController(async command => {
    if (command === 'remove') throw new Error('Could not apply');
    return { status: 'pending', rules: [rule], syncedAt: null };
  }, { setTimeout(fn) { callback = fn; return 1; }, clearTimeout() {} });
  await controller.load();
  await assert.rejects(controller.remove('abc'), /Could not apply/);
  assert.equal(controller.state().data.rules.length, 1);
  assert.equal(controller.state().undo, null);
  assert.equal(callback, undefined);
});

test('proxy routing controls are placed between history and footer and loaded before app', () => {
  const html = fs.readFileSync(path.join(__dirname, '../extension/index.html'), 'utf8');
  const history = html.indexOf('id="historySection"');
  const proxy = html.indexOf('id="proxyRoutingSection"');
  const footer = html.indexOf('<footer>');
  assert.ok(history >= 0 && history < proxy && proxy < footer);
  for (const id of ['proxyStatus', 'proxyRuleCount', 'proxyLastSync', 'proxyMatchType', 'proxyValue', 'proxyAdd', 'proxyRuleList', 'proxyRulePreview', 'proxyKeywordWarning', 'proxyUndo']) {
    assert.match(html, new RegExp(`id="${id}"`));
  }
  assert.ok(html.indexOf('src="proxy-routing.js"') < html.indexOf('src="app.js"'));
});

test('manifest adds only nativeMessaging without removing old permissions', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../extension/manifest.json'), 'utf8'));
  for (const permission of ['tabs', 'activeTab', 'storage', 'history', 'nativeMessaging']) {
    assert.ok(manifest.permissions.includes(permission), permission);
  }
});

test('quick-add markup is absent for synthetic or company hosts and marks covered suffixes', () => {
  assert.equal(ProxyRouting.quickAddButton('__landing-pages__', []), '');
  assert.equal(ProxyRouting.quickAddButton('app.internal.example', []), '');
  assert.equal(ProxyRouting.quickAddButton('localhost', []), '');
  const add = ProxyRouting.quickAddButton('docs.example.com', []);
  assert.match(add, /data-action="proxy-quick-add"/);
  assert.match(add, /data-proxy-domain="docs.example.com"/);
  assert.match(add, /Add proxy/);
  const covered = ProxyRouting.quickAddButton('docs.example.com', [{ type: 'suffix', value: 'example.com' }]);
  assert.match(covered, /Proxy added/);
  assert.match(covered, /disabled/);
});
