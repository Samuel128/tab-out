# Tab Out

[English](#english) | [简体中文](#简体中文)

## English

**Keep tabs on your tabs.**

Tab Out is a Chrome extension that replaces your new tab page with a dashboard of everything you have open. Tabs are grouped by domain, with homepages (Gmail, X, LinkedIn, etc.) pulled into their own group. Close tabs with a satisfying swoosh + confetti.

The tab dashboard works without a server or account. The optional proxy-routing feature uses a local macOS Native Messaging host; it does not open a network port.

---

### Install with a coding agent

Send your coding agent (Claude Code, Codex, etc.) this repo and say **"install this"**:

```
https://github.com/Samuel128/tab-out
```

The agent will walk you through it. Takes about 1 minute.

---

### Features

- **See all your tabs at a glance** on a clean grid, grouped by domain
- **Homepages group** pulls Gmail inbox, X home, YouTube, LinkedIn, GitHub homepages into one card
- **Close tabs with style** with swoosh sound + confetti burst
- **Duplicate detection** flags when you have the same page open twice, with one-click cleanup
- **Live tab counts** update domain cards, duplicate indicators, and totals whenever Chrome tabs change
- **Click any tab to jump to it** across windows, no new tab opened
- **Save for later** bookmark tabs to a checklist before closing them
- **Localhost grouping** shows port numbers next to each tab so you can tell your vibe coding projects apart
- **Expandable groups** show the first 8 tabs with a clickable "+N more"
- **English and Chinese UI** with a language preference shared by the dashboard and routing guide
- **Token usage ledger** opens a separate read-only page with completed-day totals and local history
- **100% local** your tab data never leaves your machine
- **Optional proxy routing** uses a separately installed local host to manage Clash's `need-proxy` list; the current profile falls back to `DIRECT`

---

### Manual Setup

**1. Clone the repo**

```bash
git clone https://github.com/Samuel128/tab-out.git
```

**2. Load the Chrome extension**

1. Open Chrome and go to `chrome://extensions`
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked**
4. Navigate to the `extension/` folder inside the cloned repo and select it

**3. Open a new tab**

You'll see Tab Out.

---

### How it works

```
You open a new tab
  -> Tab Out shows your open tabs grouped by domain
  -> Homepages (Gmail, X, etc.) get their own group at the top
  -> Click any tab title to jump to it
  -> Close groups you're done with (swoosh + confetti)
  -> Save tabs for later before closing them
```

The tab dashboard runs inside the Chrome extension. It uses no external server or account, and saved tabs stay in `chrome.storage.local`. The optional proxy-routing controls communicate only with the separately installed local Native Messaging host.

### Token usage page

The **Token usage** link in the dashboard header opens a separate page. It first reads `token-usage-history.md` through the lightweight `token_usage_cached` native command and renders it immediately. The page then starts TokenCollector's `--query-local` completed-day scan and read-only `--query-wide` server query in the background; fresh results replace the cached view without a page reload. TokenCollector must already be installed and configured. Opening the page updates only private local cache files; it does not upload usage, change the normal upload schedule, or change proxy/VPN settings. Today's incomplete usage is excluded.

Local collection fingerprints only the stable `~/.codex/skills` and `~/.codex/plugins` trees, so temporary Codex caches cannot stall a refresh. Each background collector runs in its own process group; if it exceeds the native host timeout, the host terminates the whole group instead of leaving a child scan running.

The first successful visit scans and queries up to 365 completed days; subsequent page loads and manual refreshes update the latest 30 days. Server values remain authoritative. Local values fill a missing server date or raise a stale field by taking the larger value, never by adding the two sources together. Rows remain marked as `server`, `local`, or `combined` until a later scheduled upload is processed. Successful results atomically update `~/Library/Application Support/Tab Out Proxy/token-usage-history.md` (owner-only `0600`), outside Git. The archive is tied to an anonymous hash of the configured person, so switching people never merges their totals. Cached input is included in input tokens, not added a second time. Reload the extension and reinstall the native host after updating this feature: `ruby scripts/install-native-host`.

Daily history can scan and query a selected range of up to 365 completed days; successful results update that date range in the local archive. The table can show 10, 20, 50, or 100 rows per page. Filtering and pagination do not change the summary totals above. A date missing from both sources remains blank rather than being invented as zero usage.

The 7-day and 30-day summaries show recorded-day coverage, local-backfill days, and partial days. A missing date is left blank. Locally backfilled bars use an amber outline so provisional data is never presented as server-confirmed. The server upload still occurs only on TokenCollector's normal schedule; opening or refreshing this page never uploads data.

TokenCollector keeps V2 upload outcomes in its private run history. After a successful daily upload, it automatically retries the oldest failed date range, one chunk of up to 30 completed days at a time. A retry is removed only after V2 accepts it. Exact manual recovery is also available through `python3 scripts/upgrade.py --run --start-date YYYY-MM-DD --end-date YYYY-MM-DD`; both dates are required.

### Optional macOS proxy-routing host

This feature is for macOS Chrome/Chromium with Clash Verge Rev. Installing the host only registers a local executable; it does **not** contact Clash or change proxy rules. The extension must contain the `nativeMessaging` permission before installation.

If you already loaded the unpacked extension, keep using that same `extension/` directory and reload it from `chrome://extensions` after updating the files. Do **not** add a Manifest `key` or load a second copy from a worktree: Chrome derives the extension ID from its absolute path, and changing the path changes its ID and separates its saved storage.

Then, from this repository:

```bash
ruby scripts/install-native-host
```

To bind a different unpacked extension directory, pass its absolute path:

```bash
ruby scripts/install-native-host --extension-path /absolute/path/to/extension
```

The installer verifies that the extension manifest is named `Tab Out`, includes `nativeMessaging`, and has no `key`. It computes the ID from the absolute extension path passed to the installer and binds `allowed_origins` to **that one ID only**. Use the same path shown in Chrome if you load the extension through a symlink. It stages `native/bin/tab-out-proxy-host` and `native/lib` under `~/Library/Application Support/Tab Out Proxy/`, then atomically writes `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.samuel.tabout.proxy.json`. A cross-process lock serializes installations. Reinstalling keeps the old code and snapshots the existing registration until the new registration succeeds; if installation fails, it restores the previous code and registration bytes and permissions (or removes a failed first install). Saved proxy rules and other managed data in `~/Library/Application Support/Tab Out Proxy/` are never part of this replacement. No service or TCP port is opened.

Before using proxy routing, create `~/Library/Application Support/Tab Out Proxy/private-routing.yaml` outside the repository. It must be owned by your account and have mode `0600`. List your own `PROCESS-NAME` and `DOMAIN-SUFFIX` direct rules, for example:

```yaml
direct_rules:
  - PROCESS-NAME,internal-agent,DIRECT
  - DOMAIN-SUFFIX,internal.example,DIRECT
```

Run `chmod 600 "$HOME/Library/Application Support/Tab Out Proxy/private-routing.yaml"` after creating it. The host refuses to route without a valid private file. Its domain suffixes protect the native rule store and are returned to the extension at runtime to hide quick-add buttons; the file and its real values must never be committed. Existing Clash DNS policy stays in your local Clash configuration.

Before opening Tab Out with the host installed, back up your Clash configuration and review the requested domain matches. The current extension sends a `status` request when a new tab opens, and the host may synchronize its managed rules and Clash profile at that point. The **installer itself** never sends `status` or contacts Clash. When ready to activate, reload Tab Out at `chrome://extensions` and open a new tab; then check the Proxy routing status shown on the page.

To roll back the host registration and installed code:

```bash
ruby scripts/uninstall-native-host
```

Uninstalling preserves the managed rules data by default, so reinstalling can reuse it. It does not undo any Clash configuration already applied while the host was running. Restore a Clash configuration backup separately if needed. If the extension cannot connect to the host after installation, check that Chrome's loaded extension path matches the path used during installation, then reload the extension.

### Proxy routing architecture

#### Browser Whitelist (Optional)

Reload the existing unpacked Tab Out extension after updating, then click **Enable browser whitelist** in the proxy panel and approve Chrome's optional `proxy` permission. This is a separate opt-in: installing the native host or reading the whitelist never enables browser proxy control automatically.

The inline browser PAC returns `DIRECT` for non-listed hosts, local/private addresses and protected internal suffixes. When Clash's API and configured HTTP listener are available, exact, suffix or keyword whitelist matches return `PROXY 127.0.0.1:<configured HTTP port>; DIRECT`. Matching uses the hostname, not the URL path, and performs no DNS lookups inside PAC. DIRECT fallback handles a proxy stopping between health checks. If Clash is unavailable, Tab Out keeps browser proxy ownership using Chrome's explicit `direct` mode for **all** domains, bypassing even a stopped system HTTP proxy. This availability-first policy intentionally allows listed domains to connect without a proxy; it is not a fail-closed privacy boundary.

The read-only `routing_snapshot` native command reads validated local rules, protected suffixes and the configured proxy port, checks the local Clash API and TCP listener within a bounded timeout, and never reloads or changes profiles. An `alarms` permission supports periodic health checks (scheduled every 30 seconds; Chrome may delay them), also refreshed on worker startup, new tabs and list changes. Unchanged checks do not reset the PAC. A missing, outdated or unresponsive helper switches to explicit browser DIRECT with a visible warning and automatic recovery on a later successful check. Fatal PAC errors also recover to DIRECT. Browser settings are verified after applying and refused when controlled by another extension or enterprise policy. **Return to system proxy** deliberately releases Tab Out's browser setting; if the original system proxy is still enabled but stopped, ordinary websites may fail again.

Scope is Chrome's proxy layer, not macOS networking. A system-wide TUN, VPN, firewall or DNS interceptor can still affect DIRECT connections. Internal sites require the appropriate corporate network/VPN and DNS. This feature does not change those settings or guarantee that every non-listed website is reachable. Live activation requires reloading the extension and granting permission; code tests alone do not prove the active user profile has enabled it.

For **browser-only whitelisting with other apps direct**, keep Clash running as a local HTTP proxy but switch off its **system proxy** and **TUN**. Chrome's opt-in PAC then sends only listed browser domains to its local port; other apps do not automatically inherit this browser whitelist. This setup must be chosen explicitly, not silently applied by installing the host. Corporate DNS previously configured only inside Clash must be provided independently for internal domains, with corporate network/VPN access retained. A successful DNS lookup alone does not prove the internal service is reachable.

The native host discovers current Clash Verge service-mode sockets under `/var/run/clash-verge-service/users/<uid>/`, then checks the user's temporary socket and the older `/tmp/verge/` location. `TAB_OUT_MIHOMO_SOCKET` remains an exclusive explicit override, with no automatic fallback, including in isolated tests. The helper must not infer that Clash is stopped merely because its old socket path is absent.

The dashboard reads the saved list before attempting synchronization, so an unavailable core or failed sync does not hide local rules or mark them applied. If service mode rejects the config file as outside its working directory, the helper retries only that classified error using Mihomo's supported inline YAML payload and an inline classical whitelist provider. It does not expand `SAFE_PATHS`, relocate private config, or change DNS/TUN settings. Only the managed whitelist may select a proxy: other subscription and override proxy rules are removed from the effective rules and suppressed in overrides; DIRECT and REJECT rules remain, and the downloaded subscription is untouched. This assumes Clash's **Rule** mode; Global mode bypasses rule-based routing. Reload the extension after updating its worker; a missing receiver now explicitly requests a reload instead of presenting a cryptic connection error.

浏览器白名单分流：更新后在 `chrome://extensions` 重载原 Tab Out；尚未启用时，在分流面板点击“启用浏览器白名单”，授予一次可选代理权限。名单外、私有地址及受保护内网域名始终直连；名单内仅在 Clash 本地代理可用时优先代理，连接失败允许回退直连。Clash 关闭或助手检测失败时，由扩展接管浏览器为全直连，而不是恢复失效的系统代理；恢复后自动切回白名单分流。后台定期检测，页面展示代理在线状态与分流生效状态。此规则优先保障可用性，不适合要求代理故障时禁止直连的隐私场景。不会修改系统代理、VPN、TUN 或 DNS，企业策略和底层网络仍可能影响访问。

The **Proxy routing** panel is below **Open tabs** on the new-tab page. Its **[How routing works](extension/architecture.html)** link opens a separate architecture guide inside the extension. The guide and dashboard use the same English/Chinese preference. The panel shows the current list and sync status; the guide explains the design, not a snapshot of your live list.

Clash does not read text from the Tab Out form directly. A change follows this path:

1. The extension sends an `add` or `remove` request to the fixed `com.samuel.tabout.proxy` host through Chrome Native Messaging (`chrome.runtime.sendNativeMessage`).
2. The Ruby host validates the match and saves the authoritative list in `~/Library/Application Support/Tab Out Proxy/state.json`. It also generates `tab-out-need-proxy.yaml` inside the Clash Verge Rev configuration directory. For example, a domain-suffix entry could produce:

   ```yaml
   payload:
     - DOMAIN-SUFFIX,ai.example
   ```

3. The active Clash configuration registers that file as a local, classical `rule-providers.need-proxy` provider. `RULE-SET,need-proxy,PROXY` sends matching domains to the profile's `PROXY` group. Tab Out supports suffix (`DOMAIN-SUFFIX`), exact (`DOMAIN`), and contains (`DOMAIN-KEYWORD`) matches; contains matching is intentionally broad.
4. The host reloads the active Clash configuration through Mihomo's local Unix socket, refreshes `need-proxy`, and verifies that Clash loaded the same number of rules as the saved list. Tab Out shows **Applied** only after that check. If Clash is unavailable, the change is saved as **Pending** for a later retry. A failed verification rolls back the change.

The simplified rule order in this setup is:

```text
DOMAIN-SUFFIX,internal.example,DIRECT  # known internal domains are protected first
RULE-SET,need-proxy,PROXY       # domains managed in Tab Out
MATCH,DIRECT                    # fallback after the remaining direct rules
```

Known internal domains have separate `DIRECT` rules from the local private file ahead of the Tab Out list. The `*.example` names above are illustrative placeholders, not configured rules. Removing a domain from Tab Out returns it to direct routing; it does **not** block the website. Legacy Clash-only routing may still enter local Clash through the macOS system proxy. Enable the optional Browser Whitelist above to bypass that HTTP proxy for non-listed domains; system-wide TUN/VPN/DNS handling remains separate.

### Privacy check before commits

Create `.git/tab-out-sensitive-patterns` with one case-insensitive regular expression per line for private company names, domains, and email identifiers. This file stays outside version control. Then run `git config --local core.hooksPath .githooks`. The hook scans the entire staged repository snapshot and the Git author/committer identity; it blocks changed binary files pending manual review. Existing tracked sensitive text blocks all new commits until removed. New clones must set up their own private patterns and enable the hook. The check cannot identify undisclosed company terms automatically; review changes manually too. Existing public Git history is **not** scrubbed by this check.

---

### Tech stack

| What | How |
|------|-----|
| Extension | Chrome Manifest V3 |
| Storage | chrome.storage.local |
| Proxy host | Local Ruby Native Messaging executable |
| Proxy rule storage | JSON state plus a Clash YAML rule provider |
| Sound | Web Audio API (synthesized, no files) |
| Animations | CSS transitions + JS confetti particles |

---

### License

MIT

---

Built by [Samuel](https://github.com/Samuel128). Based on the original [Tab Out by Zara](https://github.com/zarazhangrui/tab-out).

---

## 简体中文

**让打开的标签页一目了然。**

Tab Out 是一款 Chrome 扩展，用仪表盘替换新标签页。它按域名整理当前打开的页面，将 Gmail、X、LinkedIn 等网站的首页集中展示，并提供关闭标签页、重复页清理和稍后查看等功能。

标签页仪表盘不需要服务器或账号。可选的代理分流功能通过 macOS 本地 Native Messaging 助手与 Clash Verge Rev 协作；助手不会开放网络端口。

### 使用编程助手安装

将本仓库地址发给 Codex、Claude Code 等编程助手，并说明“帮我安装”：

~~~text
https://github.com/Samuel128/tab-out
~~~

也可以按下方步骤手动安装。

### 功能

- **标签页总览**：按域名分组查看当前打开的页面。
- **首页分组**：将 Gmail、X、YouTube、LinkedIn、GitHub 等首页集中到一张卡片。
- **快捷关闭**：关闭标签页时有音效和纸屑动画。
- **重复页检测**：识别重复打开的页面，并支持一键清理。
- **实时数量**：标签页变化时，同步更新分组、重复页标记和总数。
- **跨窗口跳转**：点击页面标题即可切换到已有标签页，不再重复打开。
- **稍后查看**：关闭前将页面保存到本地清单。
- **本地服务分组**：显示 localhost 的端口，便于区分开发项目。
- **展开更多**：每组先显示 8 个页面，其余可展开查看。
- **中英双语**：仪表盘与分流原理页共用语言偏好。
- **Token 使用记录**：从顶部入口打开独立页面，查看完整自然日的汇总和本机历史。
- **数据留在本机**：标签页数据不依赖云端账号或服务器。
- **可选代理分流**：通过单独安装的本地助手管理 Clash 的 <code>need-proxy</code> 名单；当前配置的兜底规则为 <code>DIRECT</code>。

### 手动安装

1. 克隆你自己的仓库：

   ~~~bash
   git clone https://github.com/Samuel128/tab-out.git
   ~~~

2. 打开 Chrome 的 <code>chrome://extensions</code>，开启“开发者模式”，点击“加载已解压的扩展程序”，选择仓库内的 <code>extension/</code> 目录。
3. 打开一个新标签页，即可看到 Tab Out。

### 工作方式

~~~text
打开新标签页
  -> 按域名查看所有已打开的页面
  -> 常用网站首页集中到一组
  -> 点击标题跳转到已有页面
  -> 关闭不再需要的分组，或先保存到“稍后查看”
~~~

仪表盘运行在 Chrome 扩展内部，不需要外部服务器或账号。“稍后查看”的数据存放在 <code>chrome.storage.local</code>。代理分流控制仅与另行安装的本地 Native Messaging 助手通信。

### Token 使用情况页面

点击仪表盘顶部的“Token 使用情况”，会打开独立页面。页面先通过轻量的 <code>token_usage_cached</code> 本地命令读取 <code>token-usage-history.md</code> 并立即展示，再在后台执行 TokenCollector 的完整自然日本机扫描 <code>--query-local</code> 和只读服务端查询 <code>--query-wide</code>；新结果返回后原位更新，无需重新加载页面。TokenCollector 需事先安装并配置好。打开页面只更新私有本机缓存，不会上报用量、不改变原有定时上报计划，也不会修改代理/VPN。**当天未结束的数据不计入**。

本机统计只为稳定的 <code>~/.codex/skills</code> 与 <code>~/.codex/plugins</code> 目录建立指纹，不会遍历 Codex 临时缓存而拖慢刷新。每个后台采集器都运行在独立进程组中；超过本机助手的超时时间后会清理整组进程，不会残留子扫描任务。

首次成功打开时，本机扫描和服务端查询最多覆盖 365 个完整自然日；之后每次打开和手动刷新都会更新最近 30 天。服务端值保持权威；本地值只补服务端缺失日期，或通过逐字段取较大值抬升尚未处理的旧值，不会把两份数据相加。记录会标记为 <code>server</code>、<code>local</code> 或 <code>combined</code>，直到后续定时上报完成处理。本机历史文件为 <code>~/Library/Application Support/Tab Out Proxy/token-usage-history.md</code>，位于 Git 仓库外，原子写入且仅当前用户可读（<code>0600</code>）。历史以人员匿名哈希隔离，缓存输入 Token 不重复计入总量。更新此功能后，请重新加载扩展，并再次运行 <code>ruby scripts/install-native-host</code> 更新本地助手。

“每日历史”可对最多 365 个完整自然日的指定日期段发起本机扫描和服务端查询；成功后会更新本机历史中对应日期段的数据。表格每页可选 10、20、50 或 100 条。筛选与翻页不会改变上方汇总；两个来源都缺失的日期不会被编造成零用量。

最近 7 天和 30 天汇总同时显示有记录天数、本地回补天数和部分覆盖天数。缺失日期在图表中留空；本地回补柱使用琥珀色描边，不会伪装成服务端已确认数据。服务端上报仍只按 TokenCollector 原有计划执行，打开或刷新页面不会触发上报。

TokenCollector 会在私有运行历史中保留 V2 上传结果。每日正常上传成功后，会自动补报最早的失败日期范围，每次最多处理 30 个完整自然日；只有 V2 接收成功才会移除该缺口。也可通过 <code>python3 scripts/upgrade.py --run --start-date YYYY-MM-DD --end-date YYYY-MM-DD</code> 手动精确补报，开始和结束日期必须同时提供。

### 可选的 macOS 代理分流助手

此功能适用于 macOS 上的 Chrome/Chromium 和 Clash Verge Rev。安装助手只会注册本地可执行文件，**不会**主动连接 Clash 或修改代理规则。安装前，扩展清单必须具有 <code>nativeMessaging</code> 权限。

如果已经加载了扩展，更新文件后请继续使用同一个 <code>extension/</code> 目录，并在 <code>chrome://extensions</code> 重新加载。**不要**给 Manifest 增加 <code>key</code>，也不要从工作树加载第二份扩展：Chrome 根据绝对路径计算扩展 ID；路径变化会产生新的 ID，并隔离已保存的数据。

在仓库目录运行：

~~~bash
ruby scripts/install-native-host
~~~

如需绑定另一处已解压的扩展目录，请传入该目录的绝对路径：

~~~bash
ruby scripts/install-native-host --extension-path /absolute/path/to/extension
~~~

安装器会检查扩展名称、权限，并确认 Manifest 未设置 <code>key</code>；只有指定路径对应的扩展 ID 能连接本地助手。如果通过符号链接加载扩展，安装时应使用 Chrome 中显示的同一路径。安装器会把可执行文件和 Ruby 代码暂存到 <code>~/Library/Application Support/Tab Out Proxy/</code>，再原子写入 Chrome 的 Native Messaging 注册文件。跨进程锁可避免同时安装；重新安装失败时会恢复先前的代码与注册配置。已有代理规则数据不参与替换，也不会开启服务或 TCP 端口。

使用代理分流前，在仓库外创建 <code>~/Library/Application Support/Tab Out Proxy/private-routing.yaml</code>，由当前用户持有并设置权限为 <code>0600</code>。填入自己的进程和域名直连规则，例如：

~~~yaml
direct_rules:
  - PROCESS-NAME,internal-agent,DIRECT
  - DOMAIN-SUFFIX,internal.example,DIRECT
~~~

创建后运行 <code>chmod 600 "$HOME/Library/Application Support/Tab Out Proxy/private-routing.yaml"</code>。缺少有效私有文件时，助手会拒绝分流。文件中的域名后缀既保护本地规则库，也会在运行时告知扩展隐藏对应的“添加代理”按钮；不要把实际值提交到仓库。已有的 Clash DNS 策略仍保留在本机 Clash 配置中。

在安装助手后首次打开 Tab Out 之前，请备份 Clash 配置并检查准备添加的域名。扩展在打开新标签页时发送 <code>status</code> 请求，助手可能在此时同步它管理的规则与 Clash 配置；**安装器本身不会**发送该请求或连接 Clash。准备启用时，在 <code>chrome://extensions</code> 重新加载扩展并打开新标签页，检查“代理分流”的状态。

如需卸载助手的注册信息与代码：

~~~bash
ruby scripts/uninstall-native-host
~~~

卸载默认保留规则数据，方便重新安装后继续使用。卸载不会撤销先前已写入 Clash 的配置；必要时请单独恢复 Clash 备份。如果扩展无法连接助手，先检查 Chrome 加载的扩展路径是否与安装时使用的路径一致，再重新加载扩展。

### 代理分流架构

“代理分流”位于新标签页的“打开的标签页”模块下方。点击“[分流原理](extension/architecture.html)”可在独立标签页查看架构说明。仪表盘与说明页共用中英语言设置。实时规则和同步状态以仪表盘为准；说明页介绍的是工作原理，不是当前名单的快照。

Clash 不会直接读取 Tab Out 输入框。新增或删除规则时，链路如下：

1. 扩展通过 Chrome Native Messaging 的 <code>chrome.runtime.sendNativeMessage</code>，向固定的 <code>com.samuel.tabout.proxy</code> 助手发送 <code>add</code> 或 <code>remove</code> 请求。
2. Ruby 助手校验匹配规则，把名单保存到 <code>~/Library/Application Support/Tab Out Proxy/state.json</code>，并在 Clash Verge Rev 配置目录生成 <code>tab-out-need-proxy.yaml</code>。以下只是示例：

   ~~~yaml
   payload:
     - DOMAIN-SUFFIX,ai.example
   ~~~

3. Clash 的当前配置把该文件注册为本地 <code>rule-providers.need-proxy</code>，通过 <code>RULE-SET,need-proxy,PROXY</code> 将命中的域名交给 <code>PROXY</code> 策略组。支持“域名后缀”(<code>DOMAIN-SUFFIX</code>)、“精确域名”(<code>DOMAIN</code>) 和“域名包含”(<code>DOMAIN-KEYWORD</code>)；“包含”的匹配范围较广。
4. 助手通过 Mihomo 的本地 Unix socket 重载 Clash 当前配置，核对已加载规则数量。若服务模式拒绝工作目录外的配置路径，仅对该错误改用官方支持的内联 YAML 和内联名单，不扩大安全路径权限；文件型名单刷新，内联型无需文件刷新。验证通过后才显示“已生效”；Clash 暂不可用时显示“等待 Clash”，验证失败回滚。界面先读取本地名单，同步失败仍可查看，状态不会冒充已生效。

当前配置的简化匹配顺序如下：

~~~text
DOMAIN-SUFFIX,internal.example,DIRECT  # 已知内网域名优先直连
RULE-SET,need-proxy,PROXY               # Tab Out 管理的代理名单
MATCH,DIRECT                            # 剩余直连规则之后的兜底
~~~

上面的 <code>*.example</code> 是占位示例，不是实际配置。内网域名从本机私有文件读取，形成排在 Tab Out 名单之前的 <code>DIRECT</code> 规则。从 Tab Out 删除域名只会让它恢复直连，**不会**封禁网站。旧的 Clash 规则模式仍可能先经过系统 HTTP 代理；启用新增的“浏览器白名单分流”后，名单外请求可绕过该 HTTP 代理。系统 TUN、VPN 和 DNS 不属于浏览器分流的控制范围。

仅管理的白名单能指定代理：生效配置与覆盖文件会排除订阅、覆盖规则中的其他代理策略，保留 DIRECT 和 REJECT 规则，不修改下载的订阅原件。这以 Clash 的规则模式为前提，全局模式会绕过规则。公司 DNS 如果只在 Clash 里配置，关 TUN 后系统可能无法解析内网域名；需要独立的公司域名 DNS 分流，不能用“加入代理白名单”代替。该助手不自动修改系统 DNS。若显示“浏览器分流后台未响应”，请在扩展管理页重载原 Tab Out，再刷新页面。

### 提交前隐私检查

在本地 `.git/tab-out-sensitive-patterns` 中逐行写入公司名称、域名和邮箱标识的正则表达式（不区分大小写），不要提交这个私有文件。再运行 `git config --local core.hooksPath .githooks` 启用钩子。钩子会扫描整个暂存区快照和 Git 作者/提交者身份；新增或修改的二进制文件也会拦下，等待人工检查。仓库中已有的敏感文本会持续阻止提交，直到清理完毕。新克隆的仓库需要自行配置私有词表并启用钩子。未知的公司信息无法自动识别，提交前仍需人工核对；此检查**不会**清除既有的公开 Git 历史。

### 技术栈

| 模块 | 技术 |
|------|------|
| 扩展 | Chrome Manifest V3 |
| 本地存储 | chrome.storage.local |
| 代理助手 | Ruby Native Messaging 可执行文件 |
| 代理规则 | JSON 状态文件与 Clash YAML rule provider |
| 音效 | Web Audio API，实时合成 |
| 动画 | CSS 过渡与 JavaScript 纸屑粒子 |

### 许可证

MIT

由 [Samuel](https://github.com/Samuel128) 构建；基于 [Zara 的原版 Tab Out](https://github.com/zarazhangrui/tab-out)。
