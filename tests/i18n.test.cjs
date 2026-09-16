'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const i18n = require('../extension/i18n.js');
const proxy = require('../extension/proxy-routing.js');

test('language API is visible to the separately loaded proxy module', () => {
  assert.equal(globalThis.TabOutI18n, i18n);
});

test('language switch translates labels and counts in both directions', () => {
  i18n.setLanguage('zh');
  assert.equal(i18n.t('Open tabs'), '打开的标签页');
  assert.equal(i18n.t('Proxy routing'), '代理分流');
  assert.equal(i18n.count(2, 'tab'), '2 个标签页');
  assert.equal(i18n.count(1, 'rule'), '1 条规则');
  assert.match(proxy.statusText({ status: 'inactive', rules: [] }), /代理分流尚未启用/);
  assert.match(proxy.quickAddButton('example.com', {}), /添加代理/);
  i18n.setLanguage('en');
  assert.equal(i18n.t('Open tabs'), 'Open tabs');
  assert.equal(i18n.count(2, 'tab'), '2 tabs');
  assert.equal(i18n.count(1, 'rule'), '1 rule');
  assert.match(proxy.statusText({ status: 'inactive', rules: [] }), /not yet activated/);
});

test('language selector precedes dashboard and saved preference drives rendering', () => {
  const html = fs.readFileSync(path.join(__dirname, '../extension/index.html'), 'utf8');
  const app = fs.readFileSync(path.join(__dirname, '../extension/app.js'), 'utf8');
  assert.ok(html.indexOf('id="languageSelect"') < html.indexOf('id="openTabsSection"'));
  assert.ok(html.indexOf('src="i18n.js"') < html.indexOf('src="app.js"'));
  assert.match(app, /chrome\.storage\.local\.get\('language'\)/);
  assert.match(app, /chrome\.storage\.local\.set\(\{ language:/);
  assert.match(app, /await renderTabDerivedSections\(\);\s*showToast\(tr\('Tab closed'\)\)/);
});
