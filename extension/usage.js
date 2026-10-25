'use strict';

const TabOutUsage = (() => {
  const HOST = 'com.samuel.tabout.proxy';
  const VERSION = 1;
  const FIELDS = ['inputTokens', 'cachedInputTokens', 'outputTokens', 'totalTokens', 'sessionCount', 'turns'];
  const SOURCES = ['server', 'local', 'combined'];
  const COVERAGE = ['complete', 'partial'];

  function requestCommand(chromeApi, command, payload) {
    if (!chromeApi?.runtime?.sendNativeMessage) return Promise.reject(new Error('helper_unavailable'));
    return new Promise((resolve, reject) => {
      chromeApi.runtime.sendNativeMessage(
        HOST, { protocolVersion: VERSION, command, payload },
        response => {
          if (chromeApi.runtime.lastError) return reject(new Error('helper_unavailable'));
          if (response?.protocolVersion !== VERSION || response?.ok !== true) {
            return reject(new Error('usage_unavailable'));
          }
          resolve(response.data);
        }
      );
    });
  }

  function requestUsage(chromeApi) {
    return requestCommand(chromeApi, 'token_usage', {});
  }

  function requestCachedUsage(chromeApi) {
    return requestCommand(chromeApi, 'token_usage_cached', {});
  }

  function validDate(value) {
    return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
      !Number.isNaN(Date.parse(`${value}T00:00:00Z`)) &&
      new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
  }

  function shiftDate(date, days) {
    const value = new Date(`${date}T00:00:00Z`);
    value.setUTCDate(value.getUTCDate() + days);
    return value.toISOString().slice(0, 10);
  }

  function completedThroughDate(now = new Date()) {
    const beijingToday = new Date(now.getTime() + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
    return shiftDate(beijingToday, -1);
  }

  function validateRange(startDate, endDate, throughDate = completedThroughDate()) {
    if (!validDate(startDate) || !validDate(endDate) || startDate > endDate || endDate > throughDate ||
        (Date.parse(`${endDate}T00:00:00Z`) - Date.parse(`${startDate}T00:00:00Z`)) / 86400000 >= 365) {
      throw new Error('invalid_date_range');
    }
    return { startDate, endDate };
  }

  function requestRange(chromeApi, startDate, endDate) {
    return requestCommand(chromeApi, 'token_usage_range', validateRange(startDate, endDate));
  }

  function paginateHistory(days, { startDate = null, endDate = null, page = 1, pageSize = 10 } = {}) {
    const size = [10, 20, 50, 100].includes(pageSize) ? pageSize : 10;
    const filtered = days.filter(day => (!startDate || day.date >= startDate) && (!endDate || day.date <= endDate));
    const pageCount = Math.max(1, Math.ceil(filtered.length / size));
    const currentPage = Math.min(Math.max(1, page), pageCount);
    const offset = (currentPage - 1) * size;
    const rows = filtered.slice(offset, offset + size);
    return {
      rows,
      total: filtered.length,
      page: currentPage,
      pageCount,
      start: filtered.length ? offset + 1 : 0,
      end: offset + rows.length
    };
  }

  function totals(rows) {
    return rows.reduce((sum, row) => {
      for (const field of FIELDS) sum[field] += row[field];
      return sum;
    }, Object.fromEntries(FIELDS.map(field => [field, 0])));
  }

  function prepareUsage(data) {
    if (!data || !['fresh', 'local', 'cached', 'unavailable'].includes(data.status) || !Array.isArray(data.days)) {
      throw new Error('invalid_usage_response');
    }
    const days = data.days.map(row => {
      if (!validDate(row?.date) || !FIELDS.every(field => Number.isSafeInteger(row[field]) && row[field] >= 0)) {
        throw new Error('invalid_usage_day');
      }
      const source = row.source || 'server';
      const coverageStatus = row.coverageStatus || 'complete';
      if (!SOURCES.includes(source) || !COVERAGE.includes(coverageStatus)) throw new Error('invalid_usage_day');
      return { date: row.date, ...Object.fromEntries(FIELDS.map(field => [field, row[field]])), source, coverageStatus };
    }).sort((left, right) => right.date.localeCompare(left.date));
    const throughDate = validDate(data.throughDate) ? data.throughDate : (days[0]?.date || null);
    const last7 = throughDate ? days.filter(row => row.date >= shiftDate(throughDate, -6) && row.date <= throughDate) : [];
    const last30 = throughDate ? days.filter(row => row.date >= shiftDate(throughDate, -29) && row.date <= throughDate) : [];
    const byDate = new Map(days.map(row => [row.date, row]));
    const chartDays = throughDate ? Array.from({ length: 14 }, (_, index) => {
      const date = shiftDate(throughDate, index - 13);
      return byDate.has(date)
        ? { date, totalTokens: byDate.get(date).totalTokens, source: byDate.get(date).source, coverageStatus: byDate.get(date).coverageStatus, hasData: true }
        : { date, totalTokens: null, source: null, coverageStatus: null, hasData: false };
    }) : [];

    return {
      status: data.status,
      person: typeof data.person === 'string' ? data.person : '',
      updatedAt: typeof data.updatedAt === 'string' ? data.updatedAt : null,
      throughDate,
      days,
      chartDays,
      last7: totals(last7),
      last30: totals(last30),
      last7Coverage: { recorded: last7.length, total: 7 },
      last30Coverage: { recorded: last30.length, total: 30 },
      localBackfillDays: days.filter(row => row.source !== 'server').length,
      partialDays: days.filter(row => row.coverageStatus === 'partial').length,
      lifetime: totals(days)
    };
  }

  function start() {
    const select = document.getElementById('languageSelect');
    const refresh = document.getElementById('refreshUsage');
    const filterForm = document.getElementById('historyFilter');
    const startInput = document.getElementById('historyStart');
    const endInput = document.getElementById('historyEnd');
    const queryButton = document.getElementById('queryHistory');
    const pageSizeSelect = document.getElementById('historyPageSize');
    const formatter = () => new Intl.NumberFormat(TabOutI18n.getLanguage() === 'zh' ? 'zh-CN' : 'en-US');
    let model = null;
    let range = null;
    let page = 1;
    let historyMessage = null;
    let refreshPromise = null;

    startInput.max = completedThroughDate();
    endInput.max = completedThroughDate();
    queryButton.disabled = true;

    function renderFeedback() {
      const feedback = document.getElementById('historyFeedback');
      feedback.hidden = !historyMessage;
      feedback.textContent = historyMessage ? TabOutI18n.t(historyMessage) : '';
    }

    function render() {
      if (!model) return;
      TabOutI18n.apply();
      document.title = `${TabOutI18n.t('Token usage')} · Tab Out`;
      const format = value => formatter().format(value);
      document.getElementById('personName').textContent = model.person;
      document.getElementById('total7').textContent = format(model.last7.totalTokens);
      document.getElementById('total30').textContent = format(model.last30.totalTokens);
      document.getElementById('totalAll').textContent = format(model.lifetime.totalTokens);
      document.getElementById('cached7').textContent = format(model.last7.cachedInputTokens);
      document.getElementById('coverage7').textContent = `${format(model.last7Coverage.recorded)} / ${format(model.last7Coverage.total)}`;
      document.getElementById('coverage30').textContent = `${format(model.last30Coverage.recorded)} / ${format(model.last30Coverage.total)}`;
      document.getElementById('localBackfillDays').textContent = format(model.localBackfillDays);
      document.getElementById('partialDays').textContent = format(model.partialDays);
      document.getElementById('throughDate').textContent = model.throughDate || '—';
      document.getElementById('lastUpdated').textContent = model.updatedAt ? new Date(model.updatedAt).toLocaleString(TabOutI18n.getLanguage() === 'zh' ? 'zh-CN' : 'en-US') : '—';
      const status = document.getElementById('usageStatus');
      status.textContent = TabOutI18n.t(
        model.status === 'cached' ? 'Showing saved history; live query unavailable' :
          model.status === 'unavailable' ? 'No usage data available' :
            model.localBackfillDays > 0 ? 'Local backfill included; server upload pending' : 'Up to date'
      );
      status.dataset.state = model.localBackfillDays > 0 && !['cached', 'unavailable'].includes(model.status) ? 'local' : model.status;

      const chart = document.getElementById('usageChart');
      chart.replaceChildren();
      const peak = Math.max(1, ...model.chartDays.filter(day => day.hasData).map(day => day.totalTokens));
      for (const day of model.chartDays) {
        const column = document.createElement('div');
        column.className = `chart-column${day.hasData ? ` ${day.source}${day.coverageStatus === 'partial' ? ' partial' : ''}` : ' missing'}`;
        const bar = document.createElement('div');
        bar.className = 'chart-bar';
        bar.style.height = day.hasData ? `${Math.max(day.totalTokens ? 6 : 2, (day.totalTokens / peak) * 100)}%` : '0%';
        bar.title = day.hasData ? `${day.date}: ${format(day.totalTokens)}` : `${day.date}: ${TabOutI18n.t('No record')}`;
        const label = document.createElement('span');
        label.textContent = day.date.slice(5);
        column.append(bar, label);
        chart.append(column);
      }

      const body = document.getElementById('historyRows');
      body.replaceChildren();
      const history = paginateHistory(model.days, {
        startDate: range?.startDate,
        endDate: range?.endDate,
        page,
        pageSize: Number(pageSizeSelect.value)
      });
      page = history.page;
      for (const day of history.rows) {
        const row = document.createElement('tr');
        for (const value of [day.date, day.inputTokens, day.cachedInputTokens, day.outputTokens, day.totalTokens, day.sessionCount, day.turns, TabOutI18n.t(day.source === 'server' ? 'Server' : day.source === 'local' ? 'Local backfill' : 'Server + local')]) {
          const cell = document.createElement('td');
          cell.textContent = typeof value === 'number' ? format(value) : value;
          row.append(cell);
        }
        body.append(row);
      }
      const empty = document.getElementById('emptyHistory');
      empty.hidden = history.total > 0;
      empty.textContent = TabOutI18n.t(range ? 'No records in the selected date range.' : 'No history yet. Open this page again after TokenCollector reports data.');
      document.getElementById('historyCount').textContent = TabOutI18n.t('Showing {start}-{end} of {total} days')
        .replace('{start}', format(history.start)).replace('{end}', format(history.end)).replace('{total}', format(history.total));
      document.getElementById('historyPage').textContent = TabOutI18n.t('Page {page} of {pages}')
        .replace('{page}', format(history.page)).replace('{pages}', format(history.pageCount));
      document.getElementById('historyPrev').disabled = history.page <= 1;
      document.getElementById('historyNext').disabled = history.page >= history.pageCount;
      renderFeedback();
    }

    async function refreshInBackground() {
      if (refreshPromise) return refreshPromise;
      refresh.disabled = true;
      queryButton.disabled = true;
      const status = document.getElementById('usageStatus');
      if (model) {
        status.textContent = TabOutI18n.t('Refreshing in background…');
        status.dataset.state = 'cached';
      } else {
        status.textContent = TabOutI18n.t('Checking TokenCollector…');
      }
      refreshPromise = (async () => {
        try {
          model = prepareUsage(await requestUsage(chrome));
          render();
        } catch {
          if (model) {
            model = { ...model, status: 'cached' };
            render();
          } else {
            status.textContent = TabOutI18n.t('Native helper unavailable. Check the local installation.');
            status.dataset.state = 'unavailable';
          }
        } finally {
          refreshPromise = null;
          refresh.disabled = false;
          queryButton.disabled = false;
        }
      })();
      return refreshPromise;
    }

    async function load() {
      refresh.disabled = true;
      queryButton.disabled = true;
      document.getElementById('usageStatus').textContent = TabOutI18n.t('Loading saved history…');
      try {
        const cached = prepareUsage(await requestCachedUsage(chrome));
        if (cached.days.length > 0) {
          model = cached;
          render();
        }
      } catch {
        // A missing cache is expected on first use; the background refresh can create it.
      }
      void refreshInBackground();
    }

    select.addEventListener('change', async event => {
      TabOutI18n.setLanguage(event.target.value);
      render();
      if (!model) {
        TabOutI18n.apply();
        renderFeedback();
      }
      await chrome.storage.local.set({ language: TabOutI18n.getLanguage() }).catch(() => {});
    });
    refresh.addEventListener('click', () => { void refreshInBackground(); });
    filterForm.addEventListener('submit', async event => {
      event.preventDefault();
      let dates;
      try {
        dates = validateRange(startInput.value, endInput.value);
      } catch {
        historyMessage = 'Choose a valid range of up to 365 completed days.';
        renderFeedback();
        return;
      }
      range = dates;
      page = 1;
      queryButton.disabled = true;
      refresh.disabled = true;
      historyMessage = 'Querying selected dates…';
      renderFeedback();
      try {
        model = prepareUsage(await requestRange(chrome, dates.startDate, dates.endDate));
        historyMessage = model.status === 'fresh' ? 'Selected range updated from TokenCollector.' : 'Live query unavailable; showing saved history for selected dates.';
      } catch {
        historyMessage = 'Live query unavailable; showing saved history for selected dates.';
        if (model) model = { ...model, status: 'cached' };
      } finally {
        queryButton.disabled = false;
        refresh.disabled = false;
        render();
        renderFeedback();
      }
    });
    document.getElementById('clearHistory').addEventListener('click', () => {
      startInput.value = '';
      endInput.value = '';
      range = null;
      page = 1;
      historyMessage = null;
      render();
    });
    pageSizeSelect.addEventListener('change', () => { page = 1; render(); });
    document.getElementById('historyPrev').addEventListener('click', () => { page -= 1; render(); });
    document.getElementById('historyNext').addEventListener('click', () => { page += 1; render(); });
    chrome.storage.local.get('language')
      .then(({ language }) => {
        TabOutI18n.setLanguage(language);
        select.value = TabOutI18n.getLanguage();
        TabOutI18n.apply();
        load();
      })
      .catch(() => {
        TabOutI18n.setLanguage('en');
        TabOutI18n.apply();
        load();
      });
  }

  return { requestUsage, requestCachedUsage, requestRange, validateRange, paginateHistory, prepareUsage, start };
})();

if (typeof module !== 'undefined') module.exports = TabOutUsage;
if (typeof document !== 'undefined') TabOutUsage.start();
