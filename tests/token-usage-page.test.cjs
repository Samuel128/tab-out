'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const page = require('../extension/usage.js');
const extensionFile = name => fs.readFileSync(path.join(__dirname, '..', 'extension', name), 'utf8');

test('dashboard links to a separate bundled token usage page', () => {
  assert.match(extensionFile('index.html'), /href="usage\.html"/);
  assert.match(extensionFile('usage.html'), /src="usage\.js"/);
  assert.match(extensionFile('usage.html'), /id="refreshUsage"/);
  assert.match(extensionFile('usage.html'), /id="languageSelect"/);
  for (const id of ['historyFilter', 'historyStart', 'historyEnd', 'historyPageSize', 'historyPrev', 'historyNext']) {
    assert.match(extensionFile('usage.html'), new RegExp(`id="${id}"`));
  }
});

test('page footer explains the separately installed collector and Markdown cache', () => {
  const html = extensionFile('usage.html');
  const translations = extensionFile('i18n.js');
  assert.match(html, /id="usageHowItWorks"/);
  assert.match(html, /Install TokenCollector separately/);
  assert.match(html, /Show cache, then refresh in background/);
  assert.match(html, /--query-local \+ --query-wide/);
  assert.match(html, /token-usage-history\.md/);
  assert.match(html, /Show saved history when the query is unavailable/);
  assert.match(translations, /单独安装 TokenCollector/);
});

test('usage request sends only the fixed read-only native command', async () => {
  const calls = [];
  const chromeApi = { runtime: { lastError: null, sendNativeMessage(host, message, done) {
    calls.push({ host, message });
    done({ ok: true, protocolVersion: 1, data: { status: 'fresh', days: [] } });
  } } };
  const data = await page.requestUsage(chromeApi);
  assert.equal(data.status, 'fresh');
  assert.deepEqual(calls, [{
    host: 'com.samuel.tabout.proxy',
    message: { protocolVersion: 1, command: 'token_usage', payload: {} },
  }]);
});

test('cached usage request is separate from the slow background refresh', async () => {
  const calls = [];
  const chromeApi = { runtime: { lastError: null, sendNativeMessage(host, message, done) {
    calls.push({ host, message });
    done({ ok: true, protocolVersion: 1, data: { status: 'cached', days: [] } });
  } } };

  const data = await page.requestCachedUsage(chromeApi);

  assert.equal(data.status, 'cached');
  assert.deepEqual(calls[0].message, {
    protocolVersion: 1, command: 'token_usage_cached', payload: {},
  });
});

test('date range request sends bounded dates through a separate read-only command', async () => {
  const calls = [];
  const chromeApi = { runtime: { lastError: null, sendNativeMessage(host, message, done) {
    calls.push({ host, message });
    done({ ok: true, protocolVersion: 1, data: { status: 'fresh', days: [] } });
  } } };
  await page.requestRange(chromeApi, '2026-09-01', '2026-09-10');
  assert.deepEqual(calls[0].message, {
    protocolVersion: 1, command: 'token_usage_range',
    payload: { startDate: '2026-09-01', endDate: '2026-09-10' },
  });
  assert.throws(() => page.validateRange('2026-09-10', '2026-09-01', '2026-09-16'));
  assert.throws(() => page.validateRange('2026-09-17', '2026-09-17', '2026-09-16'));
});

test('daily history filters by date and paginates without changing summary totals', () => {
  const days = Array.from({ length: 23 }, (_, index) => ({ date: `2026-09-${String(23 - index).padStart(2, '0')}`, totalTokens: index + 1 }));
  const first = page.paginateHistory(days, { startDate: '2026-09-05', endDate: '2026-09-20', page: 1, pageSize: 10 });
  const second = page.paginateHistory(days, { startDate: '2026-09-05', endDate: '2026-09-20', page: 2, pageSize: 10 });
  assert.equal(first.total, 16);
  assert.equal(first.rows.length, 10);
  assert.equal(first.rows[0].date, '2026-09-20');
  assert.equal(second.rows.length, 6);
  assert.equal(second.rows.at(-1).date, '2026-09-05');
  assert.equal(page.paginateHistory(days, { page: 5, pageSize: 10 }).page, 3);
  assert.equal(days.length, 23);
});

test('view model totals do not double-count cached input', () => {
  const model = page.prepareUsage({
    status: 'fresh', throughDate: '2026-09-16', updatedAt: '2026-09-17T02:00:00Z', person: 'Sample User',
    days: [
      { date: '2026-09-16', inputTokens: 80, cachedInputTokens: 30, outputTokens: 20, totalTokens: 100, sessionCount: 1, turns: 2 },
      { date: '2026-09-10', inputTokens: 40, cachedInputTokens: 10, outputTokens: 10, totalTokens: 50, sessionCount: 1, turns: 1 },
      { date: '2026-08-01', inputTokens: 20, cachedInputTokens: 0, outputTokens: 5, totalTokens: 25, sessionCount: 1, turns: 1 },
    ],
  });
  assert.equal(model.last7.totalTokens, 150);
  assert.equal(model.last7.cachedInputTokens, 40);
  assert.equal(model.lifetime.totalTokens, 175);
  assert.equal(model.days.length, 3);
});

test('view model distinguishes missing dates from recorded zero usage', () => {
  const model = page.prepareUsage({
    status: 'fresh', throughDate: '2026-09-22', updatedAt: '2026-09-23T03:00:00Z', person: 'Sample User',
    days: [
      { date: '2026-09-22', inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, totalTokens: 0, sessionCount: 0, turns: 2 },
      { date: '2026-09-18', inputTokens: 80, cachedInputTokens: 30, outputTokens: 20, totalTokens: 100, sessionCount: 1, turns: 2 },
    ],
  });
  assert.deepEqual(model.last7Coverage, { recorded: 2, total: 7 });
  assert.deepEqual(model.last30Coverage, { recorded: 2, total: 30 });
  assert.deepEqual(model.chartDays.find(day => day.date === '2026-09-22'), { date: '2026-09-22', totalTokens: 0, source: 'server', coverageStatus: 'complete', hasData: true });
  assert.deepEqual(model.chartDays.find(day => day.date === '2026-09-21'), { date: '2026-09-21', totalTokens: null, source: null, coverageStatus: null, hasData: false });
});

test('view model exposes local backfill without treating it as server-confirmed data', () => {
  const model = page.prepareUsage({
    status: 'local', throughDate: '2026-09-22', updatedAt: '2026-09-23T03:00:00Z', person: 'Sample User',
    days: [
      { date: '2026-09-22', inputTokens: 80, cachedInputTokens: 30, outputTokens: 20, totalTokens: 100, sessionCount: 1, turns: 2, source: 'local', coverageStatus: 'complete' },
      { date: '2026-09-21', inputTokens: 40, cachedInputTokens: 10, outputTokens: 10, totalTokens: 50, sessionCount: 1, turns: 1, source: 'combined', coverageStatus: 'partial' },
    ],
  });

  assert.equal(model.status, 'local');
  assert.equal(model.localBackfillDays, 2);
  assert.equal(model.partialDays, 1);
  assert.equal(model.chartDays.find(day => day.date === '2026-09-22').source, 'local');
});

test('view model rejects malformed or unsafe native values', () => {
  assert.throws(() => page.prepareUsage({ status: 'fresh', days: [{ date: 'bad', totalTokens: 5 }] }));
  assert.throws(() => page.prepareUsage({ status: 'fresh', days: [{ date: '2026-09-16', totalTokens: -1 }] }));
  assert.throws(() => page.prepareUsage({ status: 'fresh', days: [{ date: '2026-09-16', inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, totalTokens: 2, sessionCount: 1, turns: 1, source: 'unsafe' }] }));
});
