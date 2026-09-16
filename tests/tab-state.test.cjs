'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  isRealTab,
  getRealTabs,
  getGroupStats,
  createDebouncedTask,
} = require('../extension/tab-state.js');

test('isRealTab accepts regular web pages and rejects browser pages', () => {
  assert.equal(isRealTab({ url: 'https://example.com' }), true);
  assert.equal(isRealTab({ url: 'chrome://settings/' }), false);
  assert.equal(isRealTab(null), true);
});

test('getRealTabs excludes browser and extension pages', () => {
  const tabs = [
    { id: 1, url: 'https://example.com/a' },
    { id: 2, url: 'chrome://settings/' },
    { id: 3, url: 'chrome-extension://abc/index.html' },
    { id: 4, url: 'about:blank' },
    { id: 5, url: 'edge://settings/' },
    { id: 6, url: 'brave://settings/' },
    { id: 7, url: 'https://example.com/b' },
  ];

  assert.deepEqual(getRealTabs(tabs).map(tab => tab.id), [1, 7]);
});

test('getGroupStats reports total, unique, and duplicate extras', () => {
  const tabs = [
    { url: 'https://example.com/a' },
    { url: 'https://example.com/a' },
    { url: 'https://example.com/b' },
  ];

  assert.deepEqual(getGroupStats(tabs), {
    tabCount: 3,
    uniqueCount: 2,
    duplicateExtras: 1,
    urlCounts: {
      'https://example.com/a': 2,
      'https://example.com/b': 1,
    },
  });
});

test('getGroupStats returns one normal row after one duplicate closes', () => {
  assert.deepEqual(getGroupStats([{ url: 'https://example.com/a' }]), {
    tabCount: 1,
    uniqueCount: 1,
    duplicateExtras: 0,
    urlCounts: { 'https://example.com/a': 1 },
  });
});

test('getGroupStats returns an empty state for no tabs', () => {
  assert.deepEqual(getGroupStats([]), {
    tabCount: 0,
    uniqueCount: 0,
    duplicateExtras: 0,
    urlCounts: {},
  });
});

test('createDebouncedTask coalesces rapid calls into one execution', async () => {
  let calls = 0;
  const task = createDebouncedTask(() => { calls += 1; }, 10);

  task();
  task();
  task();
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(calls, 1);
});

test('bindTabRefreshListeners registers created, removed, and updated events', () => {
  const registered = [];
  const event = name => ({
    addListener: callback => registered.push([name, callback]),
  });
  const tabsApi = {
    onCreated: event('created'),
    onRemoved: event('removed'),
    onUpdated: event('updated'),
  };

  const refresh = () => {};
  const { bindTabRefreshListeners } = require('../extension/tab-state.js');
  bindTabRefreshListeners(tabsApi, refresh);

  assert.deepEqual(
    registered.map(([name]) => name),
    ['created', 'removed', 'updated']
  );
  assert.ok(registered.every(([, callback]) => callback === refresh));
});
