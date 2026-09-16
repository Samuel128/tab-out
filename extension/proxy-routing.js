'use strict';

const TabOutProxyRouting = (() => {
  const tr = value => globalThis.TabOutI18n?.t(value) || value;
  const HOST = 'com.samuel.tabout.proxy';
  const VERSION = 1;
  const TYPES = { suffix: 'DOMAIN-SUFFIX', keyword: 'DOMAIN-KEYWORD', exact: 'DOMAIN' };
  const LABELS = { suffix: 'Suffix', keyword: 'Contains', exact: 'Exact' };
  const COMMANDS = new Set(['status', 'list', 'add', 'remove']);

  function proxyError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function requestPayload(command, payload) {
    if (!COMMANDS.has(command)) throw proxyError('unsupported_command', 'Unsupported command');
    if (command === 'add') {
      if (!payload || !Object.hasOwn(TYPES, payload.type) || typeof payload.value !== 'string') {
        throw proxyError('invalid_request', 'Choose a match type and enter a domain or keyword.');
      }
      return { type: payload.type, value: payload.value };
    }
    if (command === 'remove') {
      if (!payload || typeof payload.id !== 'string' || !payload.id) {
        throw proxyError('invalid_request', 'Rule ID is missing.');
      }
      return { id: payload.id };
    }
    return {};
  }

  function sendRequest(chromeApi, command, payload = {}) {
    let safePayload;
    try { safePayload = requestPayload(command, payload); }
    catch (error) { return Promise.reject(error); }
    if (!chromeApi?.runtime?.sendNativeMessage) {
      return Promise.reject(proxyError('helper_unavailable', 'Install the Tab Out native helper to manage Clash rules.'));
    }
    return new Promise((resolve, reject) => {
      try {
        chromeApi.runtime.sendNativeMessage(
          HOST,
          { protocolVersion: VERSION, command, payload: safePayload },
          response => {
            const nativeError = chromeApi.runtime.lastError;
            if (nativeError) {
              reject(proxyError('helper_unavailable', `Install or reconnect the Tab Out native helper. ${nativeError.message || ''}`.trim()));
              return;
            }
            if (!response || typeof response !== 'object') {
              reject(proxyError('invalid_response', 'The native helper returned no valid response.'));
              return;
            }
            if (response.protocolVersion !== VERSION) {
              reject(proxyError('protocol_mismatch', 'Tab Out and its native helper use different protocol versions. Please update both.'));
              return;
            }
            if (response.ok === false) {
              reject(proxyError(response.error?.code || 'helper_error', response.error?.message || 'The native helper could not apply this rule.'));
              return;
            }
            const data = response.data;
            if (response.ok !== true || !data || !Array.isArray(data.rules) || !['active', 'pending', 'stored', 'inactive'].includes(data.status)) {
              reject(proxyError('invalid_response', 'The native helper returned an unexpected response.'));
              return;
            }
            resolve(data);
          }
        );
      } catch (error) {
        reject(proxyError('helper_unavailable', `Install or reconnect the Tab Out native helper. ${error.message || ''}`.trim()));
      }
    });
  }

  function quickAddHost(url) {
    let parsed;
    try { parsed = new URL(url); } catch { return null; }
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) return null;
    const host = parsed.hostname.toLowerCase().replace(/\.$/, '');
    if (!host.includes('.') || host.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(host)) return null;
    if (!host.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) return null;
    if (['localhost', 'local', 'internal', 'invalid', 'test'].some(suffix => host === suffix || host.endsWith(`.${suffix}`))) return null;
    if (['internal.example', 'corp.example', 'business.example'].some(suffix => host === suffix || host.endsWith(`.${suffix}`))) return null;
    return host;
  }

  async function confirmedQuickAdd(host, confirm, add) {
    const eligible = quickAddHost(`https://${host}`);
    if (!eligible) return null;
    const approved = await confirm(eligible, tr('This is not a company/internal domain'));
    if (approved !== true) return null;
    return add(eligible);
  }

  function createQuickAddDialog({ dialog, domain, check, cancel, submit }) {
    check.addEventListener('change', () => { submit.disabled = !check.checked; });
    cancel.addEventListener('click', () => { if (dialog.open) dialog.close('cancel'); });
    submit.addEventListener('click', () => {
      if (dialog.open && check.checked && !submit.disabled) dialog.close('confirm');
    });

    return host => {
      if (dialog.open) return Promise.resolve(false);
      domain.textContent = host;
      check.checked = false;
      submit.disabled = true;
      dialog.returnValue = 'cancel';
      return new Promise((resolve, reject) => {
        const onClose = () => {
          dialog.removeEventListener('close', onClose);
          resolve(dialog.returnValue === 'confirm' && check.checked);
        };
        dialog.addEventListener('close', onClose);
        try { dialog.showModal(); }
        catch (error) {
          dialog.removeEventListener('close', onClose);
          reject(error);
        }
      });
    };
  }

  function isSuffixCovered(host, rules) {
    const name = String(host || '').toLowerCase();
    return Array.isArray(rules) && rules.some(rule => rule.type === 'suffix' &&
      (name === rule.value || name.endsWith(`.${rule.value}`)));
  }

  function quickAddPresentation(host, state) {
    const covered = isSuffixCovered(host, state?.data?.rules);
    if (!covered && state?.error && state?.failedAddHost === host) {
      return { label: 'Sync failed', modifier: 'is-failed', disabled: false, title: 'Proxy rule could not be synchronized; click to retry' };
    }
    if (!covered) return { label: '+ Add proxy', modifier: '', disabled: false, title: 'Add domain suffix to proxy routing' };
    if (state?.error) return { label: 'Unverified', modifier: 'is-unverified', disabled: true, title: 'Rule exists, but its Clash status could not be verified' };
    if (state?.data?.status === 'active') return { label: 'Proxy added', modifier: 'is-active', disabled: true, title: 'Rule verified active in Clash' };
    if (state?.data?.status === 'pending') return { label: 'Waiting for Clash', modifier: 'is-pending', disabled: true, title: 'Rule saved; waiting for Clash to start' };
    return { label: 'Sync not checked', modifier: 'is-unverified', disabled: true, title: 'Rule stored locally; Clash sync not checked' };
  }

  function applyQuickAddButtonState(button, state) {
    const presentation = quickAddPresentation(button.dataset.proxyDomain, state);
    for (const modifier of ['is-active', 'is-pending', 'is-unverified', 'is-failed']) {
      button.classList.toggle(modifier, presentation.modifier === modifier);
    }
    button.disabled = presentation.disabled;
    button.textContent = tr(presentation.label);
    button.title = tr(presentation.title);
    button.setAttribute('aria-label', `${tr(presentation.label)} ${button.dataset.proxyDomain}`);
  }

  function quickAddButton(host, state) {
    const eligible = quickAddHost(`https://${host}`);
    if (!eligible) return '';
    const presentation = quickAddPresentation(eligible, state);
    return `<button type="button" class="proxy-quick-add${presentation.modifier ? ` ${presentation.modifier}` : ''}" data-action="proxy-quick-add" data-proxy-domain="${escapeHtml(eligible)}" ${presentation.disabled ? 'disabled' : ''} title="${escapeHtml(tr(presentation.title))}" aria-label="${escapeHtml(tr(presentation.label))} ${escapeHtml(eligible)}">${escapeHtml(tr(presentation.label))}</button>`;
  }

  function normalizedInput(type, value) {
    const raw = String(value || '').trim().toLowerCase();
    if (type === 'keyword') {
      if (['/', ':', '?', '#', '\\'].some(character => raw.includes(character))) {
        throw proxyError('invalid_keyword_input', 'Contains accepts a keyword, not a URL or path. Remove the scheme, path, port, query, or fragment.');
      }
      return raw.replace(/\.+$/, '');
    }
    try {
      return new URL(raw.includes('://') ? raw : `https://${raw}`).hostname.toLowerCase().replace(/\.$/, '');
    } catch { return raw; }
  }

  async function submitManualRule(type, raw, add) {
    const value = normalizedInput(type, raw);
    if (!value) return null;
    return add(type, value);
  }

  function rulePreview(type, value) {
    if (!TYPES[type] || !String(value || '').trim()) return tr('Choose a match and enter a value');
    try { return `${TYPES[type]},${normalizedInput(type, value)}`; }
    catch (error) { return tr(error.message); }
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, char => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[char]);
  }

  function renderRuleRows(rules, status = 'error') {
    if (!Array.isArray(rules) || rules.length === 0) return `<p class="proxy-empty">${tr('No proxy rules yet. Other sites stay direct.')}</p>`;
    const stateLabel = status === 'active' ? 'Applied' : status === 'pending' ? 'Waiting for Clash' : 'Unverified';
    const stateClass = status === 'active' ? 'is-active' : status === 'pending' ? 'is-pending' : 'is-error';
    return rules.map(rule => `<div class="proxy-rule">
      <span class="proxy-rule-badge">${escapeHtml(tr(LABELS[rule.type] || rule.type))}</span>
      <span class="proxy-rule-value" title="${escapeHtml(rule.value)}">${escapeHtml(rule.value)}</span>
      <code class="proxy-rule-code">${escapeHtml(TYPES[rule.type] || 'RULE')}</code>
      <span class="proxy-rule-state ${stateClass}">${tr(stateLabel)}</span>
      <button type="button" class="proxy-rule-remove" data-action="proxy-remove" data-proxy-id="${escapeHtml(rule.id)}" aria-label="${tr('Remove')} ${escapeHtml(rule.value)}">${tr('Remove')}</button>
    </div>`).join('');
  }

  function statusText(data, error) {
    if (error) {
      if (error.code === 'helper_unavailable') return tr('Helper not connected. Install the native helper to enable proxy routing.');
      if (error.code === 'protocol_mismatch') return tr('Helper version mismatch. Update the extension and native helper.');
      if (error.code === 'unsupported_profile' || /(?:profile|proxy_group|override|active_config|unsafe)/.test(error.code || '')) {
        return `${tr('Unsupported Clash profile:')} ${tr(error.message || 'Select a profile with a PROXY group.')}`;
      }
      return tr(error.message || 'Proxy routing could not be synchronized.');
    }
    if (data?.status === 'active') return tr('Clash connected · rules active');
    if (data?.status === 'pending') return tr('Rules saved · waiting for Clash to start');
    if (data?.status === 'stored') return tr('Rules stored locally · sync not checked');
    if (data?.status === 'inactive') return tr('Helper installed · proxy routing not yet activated. Add a rule to activate.');
    return tr('Checking native helper…');
  }

  function statusDotClass(data, error) {
    if (error) return 'is-error';
    if (data?.status === 'active') return 'is-active';
    if (data?.status === 'pending' || data?.status === 'stored') return 'is-pending';
    return '';
  }

  function manualAddDisabled(state) {
    return !!state.busy;
  }

  function actionFeedback(data, error) {
    if (error) return globalThis.TabOutI18n?.getLanguage() === 'zh'
      ? `${tr('Proxy routing')}：${tr(error.message || 'operation failed')}`
      : `Proxy routing failed: ${error.message || 'operation failed'}`;
    if (data?.status === 'active') return tr('Change applied in Clash');
    if (data?.status === 'pending') return tr('Rule saved; waiting for Clash');
    if (data?.status === 'stored') return tr('Rule stored; sync not checked');
    return tr('Proxy routing status unverified');
  }

  function createController(transport, clock = globalThis) {
    let data = null;
    let error = null;
    let busy = false;
    let undoRule = null;
    let undoTimer = null;
    let failedAddHost = null;
    let onChange = () => {};

    function state() { return { data, error, busy, undo: undoRule, failedAddHost }; }
    function notify() { onChange(state()); }
    function clearUndo() {
      if (undoTimer !== null) clock.clearTimeout(undoTimer);
      undoTimer = null;
      undoRule = null;
      notify();
    }
    function scheduleUndoExpiry() {
      undoTimer = clock.setTimeout(() => {
        undoRule = null;
        undoTimer = null;
        notify();
      }, 5000);
      notify();
    }
    async function execute(command, payload) {
      busy = true;
      error = null;
      failedAddHost = null;
      notify();
      try {
        const result = await transport(command, payload);
        data = result;
        return result;
      } catch (failure) {
        error = failure;
        if (command === 'add' && payload?.type === 'suffix') {
          failedAddHost = quickAddHost(`https://${payload.value}`);
        }
        throw failure;
      } finally {
        busy = false;
        notify();
      }
    }

    return {
      state,
      subscribe(listener) { onChange = listener; notify(); },
      load() { return execute('status', {}); },
      list() { return execute('list', {}); },
      add(type, value) { return execute('add', { type, value }); },
      async remove(id) {
        const rule = data?.rules?.find(item => item.id === id);
        if (!rule) throw proxyError('missing_rule', 'Rule was not found. Refresh the list and try again.');
        const result = await execute('remove', { id });
        clearUndo();
        undoRule = rule;
        scheduleUndoExpiry();
        return result;
      },
      async undo() {
        if (!undoRule) throw proxyError('undo_expired', 'The undo period has expired.');
        const rule = undoRule;
        if (undoTimer !== null) clock.clearTimeout(undoTimer);
        undoTimer = null;
        try {
          const result = await execute('add', { type: rule.type, value: rule.value });
          clearUndo();
          return result;
        } catch (failure) {
          scheduleUndoExpiry();
          throw failure;
        }
      },
      dispose() { clearUndo(); onChange = () => {}; },
    };
  }

  return { HOST, VERSION, sendRequest, quickAddHost, confirmedQuickAdd, createQuickAddDialog, quickAddButton, applyQuickAddButtonState, isSuffixCovered, normalizedInput, submitManualRule, rulePreview, renderRuleRows, statusText, statusDotClass, manualAddDisabled, actionFeedback, escapeHtml, createController };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = TabOutProxyRouting;
