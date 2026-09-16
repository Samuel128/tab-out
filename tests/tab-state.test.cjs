'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  isRealTab,
  getRealTabs,
  getGroupStats,
  createDebouncedTask,
  OPEN_TABS_REFRESH_DELAY_MS,
} = require('../extension/tab-state.js');

test('isRealTab accepts regular web pages and rejects browser pages', () => {
  assert.equal(isRealTab({ url: 'https://example.com' }), true);
  assert.equal(isRealTab({ url: 'file:///tmp/example.html' }), true);
  assert.equal(isRealTab({ url: 'chrome://settings/' }), false);
  assert.equal(isRealTab(null), false);
  assert.equal(isRealTab({}), false);
  assert.equal(isRealTab({ url: '' }), false);
  assert.equal(isRealTab({ url: 'not a renderable URL' }), false);
  assert.equal(isRealTab({ url: 'data:text/plain,hello' }), false);
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
    { id: 8 },
    { id: 9, url: '' },
    { id: 10, url: 'not a renderable URL' },
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

test('live refresh waits for sequential chip and card exit animations', () => {
  const longestExitSequenceMs = 200 + 300;

  assert.ok(OPEN_TABS_REFRESH_DELAY_MS > longestExitSequenceMs);
  assert.ok(OPEN_TABS_REFRESH_DELAY_MS <= 600);
});

test('bindTabRefreshListeners always refreshes created and removed tabs', () => {
  const registered = [];
  const event = name => ({
    addListener: callback => registered.push([name, callback]),
  });
  const tabsApi = {
    onCreated: event('created'),
    onRemoved: event('removed'),
    onUpdated: event('updated'),
  };

  let refreshes = 0;
  const refresh = () => { refreshes += 1; };
  const { bindTabRefreshListeners } = require('../extension/tab-state.js');
  bindTabRefreshListeners(tabsApi, refresh);

  assert.deepEqual(
    registered.map(([name]) => name),
    ['created', 'removed', 'updated']
  );

  registered.find(([name]) => name === 'created')[1]({ id: 1 });
  registered.find(([name]) => name === 'removed')[1](1, {});

  assert.equal(refreshes, 2);
});

test('bindTabRefreshListeners ignores non-URL tab updates', () => {
  const registered = {};
  const event = name => ({
    addListener: callback => { registered[name] = callback; },
  });
  const tabsApi = {
    onCreated: event('created'),
    onRemoved: event('removed'),
    onUpdated: event('updated'),
  };

  let refreshes = 0;
  const { bindTabRefreshListeners } = require('../extension/tab-state.js');
  bindTabRefreshListeners(tabsApi, () => { refreshes += 1; });

  registered.updated(1, { status: 'loading' }, {});
  registered.updated(1, { title: 'Updated title' }, {});
  assert.equal(refreshes, 0);

  registered.updated(1, { url: 'https://example.com/new' }, {});
  assert.equal(refreshes, 1);
});
