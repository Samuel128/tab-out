'use strict';

(function exposeTabState(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TabOutTabState = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function createTabState() {
  // A final chip can exit for 200ms before its empty card runs a 300ms exit.
  const OPEN_TABS_REFRESH_DELAY_MS = 520;

  function isRealTab(tab) {
    const url = tab && tab.url ? tab.url : '';
    return ![
      'chrome://',
      'chrome-extension://',
      'about:',
      'edge://',
      'brave://',
    ].some(prefix => url.startsWith(prefix));
  }

  function getRealTabs(tabs) {
    return (tabs || []).filter(isRealTab);
  }

  function getGroupStats(tabs) {
    const urlCounts = {};
    for (const tab of tabs || []) {
      const url = tab.url || '';
      urlCounts[url] = (urlCounts[url] || 0) + 1;
    }

    const counts = Object.values(urlCounts);
    return {
      tabCount: (tabs || []).length,
      uniqueCount: counts.length,
      duplicateExtras: counts.reduce(
        (total, count) => total + Math.max(0, count - 1),
        0
      ),
      urlCounts,
    };
  }

  function createDebouncedTask(task, delayMs = 100) {
    let timeoutId = null;
    return function scheduleTask(...args) {
      clearTimeout(timeoutId);
      timeoutId = setTimeout(() => task(...args), delayMs);
    };
  }

  function bindTabRefreshListeners(tabsApi, refresh) {
    tabsApi.onCreated.addListener(refresh);
    tabsApi.onRemoved.addListener(refresh);
    tabsApi.onUpdated.addListener(refresh);
  }

  return {
    OPEN_TABS_REFRESH_DELAY_MS,
    isRealTab,
    getRealTabs,
    getGroupStats,
    createDebouncedTask,
    bindTabRefreshListeners,
  };
});
