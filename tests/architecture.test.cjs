'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const i18n = require('../extension/i18n.js');

const extensionFile = name => fs.readFileSync(path.join(__dirname, '../extension', name), 'utf8');

test('proxy routing opens a bundled architecture page', () => {
  const dashboard = extensionFile('index.html');
  const page = extensionFile('architecture.html');

  assert.match(dashboard, /href="architecture\.html"[^>]*target="_blank"/);
  assert.match(page, /src="i18n\.js"/);
  assert.match(page, /src="architecture\.js"/);
  assert.match(page, /RULE-SET,need-proxy,PROXY/);
  assert.match(page, /MATCH,DIRECT/);
  assert.match(page, /internal\.com/);
  assert.match(page, /tab-out-need-proxy\.yaml/);
  assert.match(page, /state\.json/);
  assert.match(page, /DOMAIN-SUFFIX,chatgpt\.com/);
  assert.match(page, /rule-providers/);
  assert.match(page, /chrome\.runtime\.sendNativeMessage/);
});

test('architecture page follows the stored dashboard language', () => {
  const script = extensionFile('architecture.js');
  assert.match(script, /chrome\.storage\.local\.get\('language'\)/);
  assert.match(script, /chrome\.storage\.local\.set\(\{ language:/);
  i18n.setLanguage('zh');
  assert.notEqual(i18n.t('Routing architecture'), 'Routing architecture');
  i18n.setLanguage('en');
});
