'use strict';

const TabOutI18n = (() => {
  const zh = {
    'Language': '语言', 'You have': '你打开了', 'Tab Out tabs open. Keep just this one?': '个 Tab Out 页面。只保留当前页面吗？',
    'Close extras': '关闭多余页面', 'Open tabs': '打开的标签页', 'Saved for later': '稍后查看',
    'Nothing saved. Living in the moment.': '暂无保存的标签页。', 'Archive': '归档',
    'Search archived tabs...': '搜索归档标签页...', 'Recently visited': '最近访问',
    'Proxy routing': '代理分流', 'Retry': '重试', 'Match': '匹配方式', 'Domain suffix': '域名后缀',
    'How routing works': '分流原理', 'Routing architecture': '代理分流架构',
    'Back to Tab Out': '返回 Tab Out', 'Architecture / 01': '架构说明 / 01',
    'Only selected domains use the proxy.': '只有选中的域名走代理。',
    'Tab Out is the editor, not the proxy engine. A local helper turns your list into Clash rules; Clash makes the final routing decision.': 'Tab Out 负责编辑名单，而不是代理引擎。本地助手将名单写成 Clash 规则，由 Clash 最终决定流量去向。',
    'Control path': '控制链路', 'From a click to a verified rule.': '从点击操作到规则验证。',
    'Browser extension': '浏览器插件', 'Add or remove a suffix, exact domain, or contains match. The page shows the returned sync status.': '添加或删除域名后缀、精确域名或包含匹配；页面展示返回的同步状态。',
    'Native Messaging': '原生消息通道', 'Chrome sends a versioned request to the fixed Tab Out helper. The page does not edit Clash files directly.': 'Chrome 将带版本号的请求发送给固定的 Tab Out 本地助手；页面不直接修改 Clash 文件。',
    'Local helper': '本地助手', 'The Ruby helper validates the input, stores the list, writes a rule-provider file, and keeps backups for rollback.': 'Ruby 助手验证输入、保存名单、生成规则提供器文件，并保留备份以便回滚。',
    'Clash / Mihomo': 'Clash / Mihomo', 'The helper reloads the active Clash configuration, refreshes need-proxy, and checks that Clash loaded the expected rule count.': '助手重新加载当前生效的 Clash 配置、刷新 need-proxy，并检查 Clash 是否载入了预期数量的规则。',
    'File handoff': '文件交接', 'How Clash reads your list.': 'Clash 如何读取名单。',
    'Clash never reads the Tab Out form directly. The local helper saves your input, generates a provider file, then tells Clash to reload and verify it.': 'Clash 不会直接读取 Tab Out 的输入框。本地助手先保存你的输入并生成规则文件，再通知 Clash 重载和验证。',
    'Send and save': '发送并保存', 'The extension sends an add or remove request through chrome.runtime.sendNativeMessage. The helper validates it and saves the list locally.': '插件通过 chrome.runtime.sendNativeMessage 发送添加或删除请求；本地助手校验后将名单保存到本机。',
    'Generate provider file': '生成规则文件', 'The helper turns each match type into a Clash rule. This is an example, not your current live list.': '本地助手将每种匹配方式转换为 Clash 规则。下面仅为示例，并非当前实时名单。',
    'Register and use': '注册并引用', 'The active Clash configuration registers that local file as rule-providers.need-proxy, then sends matches to PROXY.': 'Clash 当前生效的配置把本地文件注册为 rule-providers.need-proxy，再将命中的域名交给 PROXY。',
    'After every change, the helper reloads the active Clash configuration, refreshes need-proxy, and compares the loaded rule count with the saved list. Only then does Tab Out show Applied; if Clash is unavailable, it shows Pending instead.': '每次增删后，本地助手都会重载 Clash 配置、刷新 need-proxy，并将已载入的规则数量与保存的名单核对。验证通过后 Tab Out 才显示“已生效”；Clash 不可用时则显示“等待 Clash”。',
    'Decision path': '分流顺序', 'First matching rule wins.': '按顺序匹配，首条命中生效。',
    'Company traffic stays direct': '公司流量优先直连', 'Protected processes and internal domains come from a local private file and precede the proxy list. This domain is only an example.': '受保护的进程和内网域名来自本机私有文件，排在代理名单之前。这里的域名仅为示例。',
    'Your list goes to PROXY': '名单命中才走 PROXY', 'The need-proxy provider contains the domains you manage in Tab Out. Its match types become DOMAIN-SUFFIX, DOMAIN, or DOMAIN-KEYWORD rules.': 'need-proxy 提供器保存你在 Tab Out 管理的域名；匹配方式分别生成 DOMAIN-SUFFIX、DOMAIN 或 DOMAIN-KEYWORD 规则。',
    'Everything else goes direct': '其他流量默认直连', 'If no earlier rule matches, Clash uses DIRECT. Removing a domain from Tab Out does not block the site; it returns to direct routing.': '未命中前面的规则时，Clash 使用 DIRECT。从 Tab Out 删除域名不会屏蔽网站，而是恢复直连。',
    'What the status means': '如何理解同步状态', 'Applied means Clash accepted and verified the rule-provider count. Pending means the list was saved but Clash was unavailable; retry when Clash is running.': '“已生效”表示 Clash 已接收并验证规则数量；“等待 Clash”表示名单已保存，但 Clash 暂时不可用，启动后可重试。',
    'Two kinds of direct': '两种“直连”', 'With macOS system proxy enabled, a request may still enter local Clash first and then exit via DIRECT. Bypassing Clash entirely requires a separate PAC or system-proxy setup.': '开启 macOS 系统代理时，请求可能先进入本机 Clash，再以 DIRECT 出站。若要完全绕过 Clash，需要另配 PAC 或系统代理。',
    'One important boundary': '一条重要边界', 'This page explains the architecture, not your live domain list. Use the routing panel on the main page to inspect the current list and sync status.': '本页介绍架构，不展示实时域名清单。请在主页“代理分流”区域查看当前名单和同步状态。',
    'Domain contains': '域名包含', 'Exact domain': '精确域名', 'Domain or keyword': '域名或关键词',
    'Add rule': '添加规则', 'Rule preview:': '规则预览：', 'Routing list': '分流规则',
    'Automatic sync': '自动同步', 'Rule removed.': '规则已删除。', 'Undo (5s)': '撤销（5秒）',
    'Before routing': '添加代理前', 'Add to proxy?': '加入代理？', 'The domain': '域名',
    'will be sent through Clash. A public-looking name may still be a company site.': '将通过 Clash 代理。看似公开的域名也可能是公司网站。',
    'This is not a company/internal domain': '这不是公司或内网域名', 'Cancel': '取消', 'Confirm and add': '确认添加',
    'Contains matching is broad and may match unrelated domains. Tab Out cannot automatically identify all company domains; check the target before adding.': '“域名包含”匹配范围较广，可能命中无关网站。Tab Out 无法识别所有公司域名，添加前请核对。',
    'Good morning': '早上好', 'Good afternoon': '下午好', 'Good evening': '晚上好',
    'Inbox zero, but for tabs.': '标签页已清空。', "You're free.": '可以轻松一下了。',
    'Homepages': '首页', 'Local Files': '本地文件', 'Save for later': '稍后查看', 'Close this tab': '关闭此标签页',
    'Dismiss': '移除', 'No results': '没有结果', 'just now': '刚刚', 'yesterday': '昨天',
    'Closed extra Tab Out tabs': '已关闭多余的 Tab Out 页面', 'Tab closed': '标签页已关闭',
    'Failed to save tab': '保存标签页失败',
    'Closed duplicates, kept one copy each': '已关闭重复标签页，每个保留一个',
    'All tabs closed. Fresh start.': '所有标签页已关闭，全新开始。',
    'Choose a match and enter a value': '请选择匹配方式并输入内容',
    'Last sync:': '上次同步：', 'e.g. google': '例如 google', 'tabs': '标签页',
    'by': '作者', 'forked by': '分支维护者', 'YouTube Video': 'YouTube 视频',
    'Connect the native helper to view rules.': '连接本地程序后查看规则。',
    'No proxy rules yet. Other sites stay direct.': '暂无代理规则，其他网站保持直连。',
    'Applied': '已生效', 'Waiting for Clash': '等待 Clash', 'Unverified': '未验证',
    'Remove': '删除', 'Suffix': '后缀', 'Contains': '包含', 'Exact': '精确',
    'Sync failed': '同步失败', '+ Add proxy': '+ 添加代理', 'Proxy added': '已加入代理',
    'Sync not checked': '未检查同步', 'Rule verified active in Clash': '规则已在 Clash 中生效',
    'Rule saved; waiting for Clash to start': '规则已保存，等待 Clash 启动',
    'Rule stored locally; Clash sync not checked': '规则已存储，尚未检查 Clash 同步',
    'Rule exists, but its Clash status could not be verified': '规则已存在，但无法验证 Clash 状态',
    'Proxy rule could not be synchronized; click to retry': '代理规则同步失败，点击重试',
    'Add domain suffix to proxy routing': '将域名后缀加入代理分流',
    'Helper not connected. Install the native helper to enable proxy routing.': '本地程序未连接，请安装后再管理代理分流。',
    'Helper version mismatch. Update the extension and native helper.': '本地程序版本不匹配，请更新扩展和本地程序。',
    'Proxy routing could not be synchronized.': '代理分流同步失败。',
    'Clash connected · rules active': 'Clash 已连接 · 规则已生效',
    'Rules saved · waiting for Clash to start': '规则已保存 · 等待 Clash 启动',
    'Rules stored locally · sync not checked': '规则已本地存储 · 尚未检查同步',
    'Helper installed · proxy routing not yet activated. Add a rule to activate.': '本地程序已安装 · 代理分流尚未启用，添加规则后启用。',
    'Checking native helper…': '正在检查本地程序…',
    'Change applied in Clash': '变更已在 Clash 中生效', 'Rule saved; waiting for Clash': '规则已保存，等待 Clash',
    'Rule stored; sync not checked': '规则已存储，尚未检查同步',
    'Proxy routing status unverified': '代理分流状态未验证', 'operation failed': '操作失败',
    'Unsupported Clash profile:': '不支持的 Clash 配置：',
    'Select a profile with a PROXY group.': '请选择包含 PROXY 策略组的配置。',
    'Contains accepts a keyword, not a URL or path. Remove the scheme, path, port, query, or fragment.': '“域名包含”只接受关键词，请去掉协议、路径、端口、查询或片段。',
  };
  let language = 'en';

  function setLanguage(value) { language = value === 'zh' ? 'zh' : 'en'; }
  function getLanguage() { return language; }
  function t(key) { return language === 'zh' ? (zh[key] || key) : key; }
  function count(n, unit) {
    if (language === 'zh') return `${n} ${({ tab: '个标签页', domain: '个域名', item: '项', rule: '条规则', duplicate: '个重复标签页' })[unit]}`;
    return `${n} ${unit}${n === 1 ? '' : 's'}`;
  }
  function apply(root = document) {
    root.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    root.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = t(el.dataset.i18n); });
    root.querySelectorAll('[data-i18n-placeholder]').forEach(el => { el.placeholder = t(el.dataset.i18nPlaceholder); });
    root.querySelectorAll('[data-i18n-aria-label]').forEach(el => { el.setAttribute('aria-label', t(el.dataset.i18nAriaLabel)); });
  }
  return { setLanguage, getLanguage, t, count, apply };
})();

globalThis.TabOutI18n = TabOutI18n;
if (typeof module !== 'undefined' && module.exports) module.exports = TabOutI18n;
