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

Before opening Tab Out with the host installed, back up your Clash configuration and review the requested domain matches. The current extension sends a `status` request when a new tab opens, and the host may synchronize its managed rules and Clash profile at that point. The **installer itself** never sends `status` or contacts Clash. When ready to activate, reload Tab Out at `chrome://extensions` and open a new tab; then check the Proxy routing status shown on the page.

To roll back the host registration and installed code:

```bash
ruby scripts/uninstall-native-host
```

Uninstalling preserves the managed rules data by default, so reinstalling can reuse it. It does not undo any Clash configuration already applied while the host was running. Restore a Clash configuration backup separately if needed. If the extension cannot connect to the host after installation, check that Chrome's loaded extension path matches the path used during installation, then reload the extension.

### Proxy routing architecture

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

Known internal domains have separate `DIRECT` rules ahead of the Tab Out list. The `*.example` names above are illustrative placeholders, not configured rules. Removing a domain from Tab Out returns it to direct routing; it does **not** block the website. With the macOS system proxy enabled, a `DIRECT` request may still enter local Clash before going out directly. Fully bypassing Clash for non-listed domains would require a separate PAC or system-proxy setup.

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
4. 助手通过 Mihomo 的本地 Unix socket 重载 Clash 当前配置、刷新 <code>need-proxy</code>，并核对 Clash 已加载的规则数量与保存的名单一致。验证通过后，Tab Out 才显示“已生效”；Clash 暂不可用时显示“等待 Clash”，稍后可重试。验证失败时会回滚改动。

当前配置的简化匹配顺序如下：

~~~text
DOMAIN-SUFFIX,internal.example,DIRECT  # 已知内网域名优先直连
RULE-SET,need-proxy,PROXY               # Tab Out 管理的代理名单
MATCH,DIRECT                            # 剩余直连规则之后的兜底
~~~

上面的 <code>*.example</code> 是占位示例，不是实际配置。内网域名有独立的 <code>DIRECT</code> 规则，排在 Tab Out 名单之前。从 Tab Out 删除域名只会让它恢复直连，**不会**封禁网站。开启 macOS 系统代理时，请求也可能先进入本机 Clash，再由 <code>DIRECT</code> 直连出站；如果要让未列入名单的域名完全绕过 Clash，需要另行配置 PAC 或系统代理。

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
