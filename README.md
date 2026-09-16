# Tab Out

**Keep tabs on your tabs.**

Tab Out is a Chrome extension that replaces your new tab page with a dashboard of everything you have open. Tabs are grouped by domain, with homepages (Gmail, X, LinkedIn, etc.) pulled into their own group. Close tabs with a satisfying swoosh + confetti.

The tab dashboard works without a server or account. The optional proxy-routing feature uses a local macOS Native Messaging host; it does not open a network port.

---

## Install with a coding agent

Send your coding agent (Claude Code, Codex, etc.) this repo and say **"install this"**:

```
https://github.com/zarazhangrui/tab-out
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
- **100% local** your tab data never leaves your machine
- **Optional proxy routing** uses a separately installed local Native Messaging host; the tab dashboard needs no host

---

## Manual Setup

**1. Clone the repo**

```bash
git clone https://github.com/zarazhangrui/tab-out.git
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

For the existing unpacked extension at `/Users/Samuel/Desktop/Samuel/Slef/github/tab-out/extension`, first deploy the updated extension files to that same directory and reload it from `chrome://extensions`. Do **not** add a Manifest `key` or load a second copy from a worktree: Chrome derives the existing extension ID from the original absolute path, and changing the path changes its ID and separates its saved storage. The expected ID for the original path is `mjdgpafhcdpdckehldcammdkjcicfdka`.

Then, from this repository:

```bash
ruby scripts/install-native-host
```

To bind a different unpacked extension directory, pass its absolute path:

```bash
ruby scripts/install-native-host --extension-path /absolute/path/to/extension
```

The installer verifies that the extension manifest is named `Tab Out`, includes `nativeMessaging`, and has no `key`. It computes the ID from the absolute extension path passed to the installer and binds `allowed_origins` to **that one ID only**. Use the same path shown in Chrome if you load the extension through a symlink. It copies `native/bin/tab-out-proxy-host` and `native/lib` to `~/Library/Application Support/Tab Out Proxy/native/`, then atomically writes `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.samuel.tabout.proxy.json`. Reinstalling updates code and registration without deleting saved proxy rules or other managed data in `~/Library/Application Support/Tab Out Proxy/`. No service or TCP port is opened.

Before opening Tab Out with the host installed, back up your Clash configuration and review the requested domain matches. The current extension sends a `status` request when a new tab opens, and the host may synchronize its managed rules and Clash profile at that point. The **installer itself** never sends `status` or contacts Clash. When ready to activate, reload Tab Out at `chrome://extensions` and open a new tab; then check the Proxy routing status shown on the page.

To roll back the host registration and installed code:

```bash
ruby scripts/uninstall-native-host
```

Uninstalling preserves the managed rules data by default, so reinstalling can reuse it. It does not undo any Clash configuration already applied while the host was running. Restore a Clash configuration backup separately if needed. If the extension cannot connect to the host after installation, check that Chrome's loaded extension path matches the path used during installation, then reload the extension.

---

## Tech stack

| What | How |
|------|-----|
| Extension | Chrome Manifest V3 |
| Storage | chrome.storage.local |
| Sound | Web Audio API (synthesized, no files) |
| Animations | CSS transitions + JS confetti particles |

---

## License

MIT

---

Built by [Zara](https://x.com/zarazhangrui)
