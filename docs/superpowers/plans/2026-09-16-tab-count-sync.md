# Tab Count Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Tab Out domain count, duplicate badge, close-all label, and global tab total immediately reflect Chrome's real tab state after tabs are created, closed, or navigated.

**Architecture:** Extract small, pure tab-state helpers into a browser/Node-compatible module and keep Chrome's tab list as the single source of truth. Split the current all-page render into a focused open-tab render, then debounce Chrome tab events into that render so saved items and history are not unnecessarily rebuilt.

**Tech Stack:** Chrome Manifest V3 APIs, browser JavaScript, Node.js built-in `node:test`, CSS/HTML already present in Tab Out.

---

## File Structure

- Create `extension/tab-state.js`: pure real-tab filtering, group statistics, and debounce/listener helpers usable by both Chrome and Node tests.
- Create `tests/tab-state.test.cjs`: unit tests for derived counts, duplicate transitions, and listener debouncing.
- Modify `extension/index.html`: load `tab-state.js` before `app.js` while preserving the user's uncommitted history section.
- Modify `extension/app.js`: separate open-tab rendering, use real-tab totals, and subscribe to tab lifecycle events while preserving the user's uncommitted history logic.
- Modify `README.md`: document that counts update from Chrome events after the behavior is verified.

The files `extension/app.js`, `extension/index.html`, `extension/manifest.json`, and `extension/style.css` already contain user-owned uncommitted changes. Before editing, capture `git diff --` output for those paths. Do not revert those changes and do not stage an overlapping file without explicit user approval.

### Task 1: Add Pure Tab-State Tests and Helpers

**Files:**
- Create: `tests/tab-state.test.cjs`
- Create: `extension/tab-state.js`

- [ ] **Step 1: Write the failing real-tab and group-statistics tests**

Create `tests/tab-state.test.cjs` with the initial tests:

```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  getRealTabs,
  getGroupStats,
} = require('../extension/tab-state.js');

test('getRealTabs excludes browser and extension pages', () => {
  const tabs = [
    { id: 1, url: 'https://example.com/a' },
    { id: 2, url: 'chrome://settings/' },
    { id: 3, url: 'chrome-extension://abc/index.html' },
    { id: 4, url: 'about:blank' },
    { id: 5, url: 'https://example.com/b' },
  ];

  assert.deepEqual(getRealTabs(tabs).map(tab => tab.id), [1, 5]);
});

test('getGroupStats reports total and duplicate extras', () => {
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
```

- [ ] **Step 2: Run the tests and verify the module is missing**

Run:

```bash
node --test tests/tab-state.test.cjs
```

Expected: FAIL with `Cannot find module '../extension/tab-state.js'`.

- [ ] **Step 3: Implement the pure helpers as a UMD-style module**

Create `extension/tab-state.js`:

```javascript
'use strict';

(function exposeTabState(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TabOutTabState = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function createTabState() {
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
      duplicateExtras: counts.reduce((total, count) => total + Math.max(0, count - 1), 0),
      urlCounts,
    };
  }

  return { isRealTab, getRealTabs, getGroupStats };
});
```

- [ ] **Step 4: Run the tests and verify they pass**

Run:

```bash
node --test tests/tab-state.test.cjs
```

Expected: 4 tests pass, 0 fail.

- [ ] **Step 5: Commit only the new helper and test files**

```bash
git add extension/tab-state.js tests/tab-state.test.cjs
git diff --cached --check
git commit -m "test: add tab state derivation coverage"
```

Expected: the commit contains only the two new files.

### Task 2: Make Domain Card Rendering Use Shared Statistics

**Files:**
- Modify: `extension/index.html:126-132`
- Modify: `extension/app.js:722-735`
- Modify: `extension/app.js:803-891`
- Test: `tests/tab-state.test.cjs`

- [ ] **Step 1: Run the characterization tests before refactoring**

```bash
node --test tests/tab-state.test.cjs
```

Expected: 4 tests pass. These tests protect filtering and card statistics while
the renderer is changed to consume the shared module.

- [ ] **Step 2: Load the helper before the dashboard**

In `extension/index.html`, preserve the existing `config.local.js` and history
markup, then load the helper before `app.js`:

```html
<script src="config.local.js" onerror="/* no personal config, that's fine */"></script>
<script src="tab-state.js"></script>
<script src="app.js"></script>
```

- [ ] **Step 3: Replace the duplicate real-tab filter**

Replace the body of `getRealTabs()` in `extension/app.js` with:

```javascript
function getRealTabs() {
  return TabOutTabState.getRealTabs(openTabs);
}
```

- [ ] **Step 4: Use shared statistics inside `renderDomainCard`**

At the start of `renderDomainCard(group)`, replace the local count-building loop
with:

```javascript
const tabs = group.tabs || [];
const {
  tabCount,
  duplicateExtras: totalExtras,
  urlCounts,
} = TabOutTabState.getGroupStats(tabs);
const isLanding = group.domain === '__landing-pages__';
const stableId = 'domain-' + group.domain.replace(/[^a-z0-9]/g, '-');
const dupeUrls = Object.entries(urlCounts).filter(([, count]) => count > 1);
const hasDupes = totalExtras > 0;
```

Keep the existing HTML and animation behavior unchanged.

- [ ] **Step 5: Run unit and syntax checks**

Run:

```bash
node --test tests/tab-state.test.cjs
node --check extension/tab-state.js
node --check extension/app.js
```

Expected: all tests pass and both syntax checks exit 0.

- [ ] **Step 6: Preserve the user-owned dirty files**

Run:

```bash
git diff -- extension/index.html extension/app.js
git status --short
```

Expected: the previously existing history changes remain present alongside the
new script include and shared-statistics changes. Do not stage these two files
unless the user explicitly approves combining their existing work into a commit.

### Task 3: Split Full Rendering from Open-Tab Rendering

**Files:**
- Modify: `extension/app.js:1112-1276`
- Test: `tests/tab-state.test.cjs`

- [ ] **Step 1: Add a failing debounced refresh test**

Extend the import and append this test:

```javascript
const {
  getRealTabs,
  getGroupStats,
  createDebouncedTask,
} = require('../extension/tab-state.js');

test('createDebouncedTask coalesces rapid calls into one execution', async () => {
  let calls = 0;
  const task = createDebouncedTask(() => { calls += 1; }, 10);

  task();
  task();
  task();
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(calls, 1);
});
```

- [ ] **Step 2: Run the targeted test and verify failure**

Run:

```bash
node --test --test-name-pattern="coalesces rapid calls" tests/tab-state.test.cjs
```

Expected: FAIL because `createDebouncedTask` is not exported.

- [ ] **Step 3: Implement and export the debounce helper**

Add inside the `createTabState` factory in `extension/tab-state.js`:

```javascript
function createDebouncedTask(task, delayMs = 100) {
  let timeoutId = null;
  return function scheduleTask(...args) {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => task(...args), delayMs);
  };
}
```

Update the return value:

```javascript
return { isRealTab, getRealTabs, getGroupStats, createDebouncedTask };
```

- [ ] **Step 4: Extract `renderOpenTabsSection`**

In `extension/app.js`, move the existing grouping block and the domain-card,
footer-stat, and duplicate-Tab-Out rendering block into:

```javascript
async function renderOpenTabsSection({ fetchTabs = true } = {}) {
  if (fetchTabs) await fetchOpenTabs();
  const realTabs = getRealTabs();
}
```

Move, without retyping or changing behavior, the exact contiguous block currently
starting with `const LANDING_PAGE_PATTERNS = [` and ending with
`checkTabOutDupes();` into the function body immediately after `realTabs`. Change
only the existing footer assignment from `openTabs.length` to `realTabs.length`,
and add `openTabsMissionsEl.innerHTML = ''` in the empty branch. This preserves
all landing-page and `LOCAL_CUSTOM_GROUPS` behavior while giving event refreshes
a focused entry point.

- [ ] **Step 5: Reduce `renderStaticDashboard` to orchestration**

Make the full render call the focused renderer exactly once:

```javascript
async function renderStaticDashboard() {
  const greetingEl = document.getElementById('greeting');
  const dateEl = document.getElementById('dateDisplay');
  if (greetingEl) greetingEl.textContent = getGreeting();
  if (dateEl) dateEl.textContent = getDateDisplay();

  await renderOpenTabsSection();
  await renderDeferredColumn();
  await renderHistorySection();
}
```

- [ ] **Step 6: Run all tests and syntax checks**

```bash
node --test tests/tab-state.test.cjs
node --check extension/tab-state.js
node --check extension/app.js
```

Expected: 5 tests pass and syntax checks exit 0.

### Task 4: Subscribe the New-Tab Page to Chrome Tab Events

**Files:**
- Modify: `extension/tab-state.js`
- Modify: `extension/app.js:1287-1534`
- Test: `tests/tab-state.test.cjs`

- [ ] **Step 1: Add a failing listener-registration test**

Append:

```javascript
test('bindTabRefreshListeners registers created, removed, and updated events', () => {
  const registered = [];
  const event = name => ({ addListener: callback => registered.push([name, callback]) });
  const tabsApi = {
    onCreated: event('created'),
    onRemoved: event('removed'),
    onUpdated: event('updated'),
  };

  const refresh = () => {};
  const { bindTabRefreshListeners } = require('../extension/tab-state.js');
  bindTabRefreshListeners(tabsApi, refresh);

  assert.deepEqual(registered.map(([name]) => name), ['created', 'removed', 'updated']);
  assert.ok(registered.every(([, callback]) => callback === refresh));
});
```

- [ ] **Step 2: Verify the test fails**

```bash
node --test --test-name-pattern="registers created" tests/tab-state.test.cjs
```

Expected: FAIL because `bindTabRefreshListeners` is undefined.

- [ ] **Step 3: Implement the listener binder**

Add and export:

```javascript
function bindTabRefreshListeners(tabsApi, refresh) {
  tabsApi.onCreated.addListener(refresh);
  tabsApi.onRemoved.addListener(refresh);
  tabsApi.onUpdated.addListener(refresh);
}
```

The module return must now include `bindTabRefreshListeners`.

- [ ] **Step 4: Bind a debounced focused render in `app.js`**

Immediately before the final `renderDashboard();` call, add:

```javascript
const scheduleOpenTabsRefresh = TabOutTabState.createDebouncedTask(() => {
  renderOpenTabsSection().catch(error => {
    console.warn('[tab-out] Failed to refresh open tabs:', error);
  });
}, 120);

TabOutTabState.bindTabRefreshListeners(chrome.tabs, scheduleOpenTabsRefresh);
```

- [ ] **Step 5: Remove stale manual counter writes**

In the `close-single-tab`, `defer-single-tab`, `close-domain-tabs`, duplicate,
and close-all handlers:

- keep the existing Chrome removal and animation calls;
- remove writes that set `statTabs` from `openTabs.length`;
- do not manually decrement card badges or close-all labels;
- call `scheduleOpenTabsRefresh()` after the close operation as a fallback in
  addition to the Chrome event listener.

For example, the tail of `close-single-tab` becomes:

```javascript
scheduleOpenTabsRefresh();
showToast('Tab closed');
return;
```

- [ ] **Step 6: Run the test suite and syntax checks**

```bash
node --test tests/tab-state.test.cjs
node --check extension/tab-state.js
node --check extension/app.js
```

Expected: 6 tests pass, 0 fail, and syntax checks exit 0.

### Task 5: Verify Real Browser Behavior

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Reload the unpacked extension**

Open `chrome://extensions`, locate Tab Out, and click **Reload**. Open a new tab
and leave that Tab Out page visible.

- [ ] **Step 2: Verify single-tab count synchronization**

Open two distinct pages on the same domain, return to Tab Out, and close one with
its row-level close icon.

Expected within 250 ms:

- the card changes from `2 tabs open` to `1 tab open`;
- `Close all 2 tabs` changes to `Close all 1 tab`;
- the footer real-tab total decreases by one;
- the remaining row stays visible.

- [ ] **Step 3: Verify duplicate and final-tab transitions**

Open the same URL twice and close one copy.

Expected: `2x` disappears while one row remains. Close the final row.

Expected: the entire domain card disappears and domain/global totals update.

- [ ] **Step 4: Verify external tab changes**

Create, navigate, and close tabs using normal Chrome controls instead of Tab Out.

Expected: the visible Tab Out page updates without a manual reload.

- [ ] **Step 5: Verify existing features remain intact**

Expected:

- saved-for-later still saves, archives, searches, and dismisses;
- Recently visited still renders the user's existing history-domain work;
- close-domain, close-duplicates, and close-all animations still run;
- no errors appear in the extension service-worker or new-tab console.

- [ ] **Step 6: Document the behavior**

Add this README feature bullet:

```markdown
- **Live tab counts** update domain cards, duplicate indicators, and totals whenever Chrome tabs change
```

- [ ] **Step 7: Run final verification**

```bash
node --test tests/tab-state.test.cjs
node --check extension/tab-state.js
node --check extension/app.js
git diff --check
git status --short
```

Expected: tests and checks pass. User-owned changes remain present. Stage and
commit only files or hunks the user has explicitly approved for inclusion; never
commit the pre-existing dirty extension changes implicitly.
