# Tab Out

**Keep tabs on your tabs.**

Tab Out is a Chrome extension that replaces your new tab page with a dashboard of everything you have open. Tabs are grouped by domain, with homepages (Gmail, X, LinkedIn, etc.) pulled into their own group. Close tabs with a satisfying swoosh + confetti.

The tab dashboard works without a server or account. The optional proxy-routing feature uses a local macOS Native Messaging host; it does not open a network port.

---

## Install with a coding agent

Send your coding agent (Claude Code, Codex, etc.) this repo and say **"install this"**:

```
https://github.com/Samuel128/tab-out
```

The agent will walk you through it. Takes about 1 minute.

---

## Features

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

## Manual Setup

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

## How it works

```
You open a new tab
  -> Tab Out shows your open tabs grouped by domain
  -> Homepages (Gmail, X, etc.) get their own group at the top
  -> Click any tab title to jump to it
  -> Close groups you're done with (swoosh + confetti)
  -> Save tabs for later before closing them
```

The tab dashboard runs inside the Chrome extension. It uses no external server or account, and saved tabs stay in `chrome.storage.local`. The optional proxy-routing controls communicate only with the separately installed local Native Messaging host.

## Optional macOS proxy-routing host

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

## Proxy routing architecture

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

## Tech stack

| What | How |
|------|-----|
| Extension | Chrome Manifest V3 |
| Storage | chrome.storage.local |
| Proxy host | Local Ruby Native Messaging executable |
| Proxy rule storage | JSON state plus a Clash YAML rule provider |
| Sound | Web Audio API (synthesized, no files) |
| Animations | CSS transitions + JS confetti particles |

---

## License

MIT

---

Built by [Samuel](https://github.com/Samuel128). Based on the original [Tab Out by Zara](https://github.com/zarazhangrui/tab-out).
