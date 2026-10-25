'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
async function render(state) {
  const nodes = Object.fromEntries(['browserRoutingStatus', 'browserRoutingDisable', 'browserRoutingEnable', 'browserRoutingTun'].map(id => [id, {}]));
  const context = vm.createContext({ chrome: {}, document: { getElementById(id) { return nodes[id]; }, addEventListener() {} }, TabOutBrowserRouting: { async send() { return state; } } });
  vm.runInContext(fs.readFileSync(require.resolve('../extension/browser-routing-ui.js'), 'utf8'), context);
  await vm.runInContext('TabOutBrowserRoutingUI.render()', context);
  return nodes;
}
test('offline direct protection is presented as active, not as a broken whitelist', async () => {
  const nodes = await render({ enabled: true, effective: true, clashAvailable: false });
  assert.match(nodes.browserRoutingStatus.textContent, /unavailable.*all domains are DIRECT.*automatically/);
  assert.equal(nodes.browserRoutingDisable.hidden, false);
});
test('online routing explains whitelist-only proxying and direct fallback', async () => {
  const nodes = await render({ enabled: true, effective: true, clashAvailable: true });
  assert.match(nodes.browserRoutingStatus.textContent, /available.*listed.*fallback.*other domains are DIRECT/);
});
test('lost proxy ownership does not claim active routing', async () => {
  const nodes = await render({ enabled: true, effective: false, clashAvailable: true, error: 'policy' });
  assert.match(nodes.browserRoutingStatus.textContent, /not effective.*policy/);
});
