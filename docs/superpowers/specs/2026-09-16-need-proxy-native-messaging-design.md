# Need-Proxy Native Messaging Design

## Summary

Tab Out will gain a local management interface for the system-wide Clash
`need-proxy` domain list. The browser extension owns the user interface, while a
restricted Chrome Native Messaging host owns filesystem access and Clash reloads.

The resulting Clash policy is corporate-first and direct-by-default:

1. Corporate applications, domains, DNS zones, and private networks use
   `DIRECT`.
2. Rules explicitly listed in `need-proxy` use `PROXY`.
3. All remaining traffic uses `DIRECT`.

This design also fixes the existing Tab Out behavior where closing a single tab
does not update the domain card count, its close-all label, duplicate indicators,
or the global tab count.

## Scope

The first release supports macOS and unpacked Chrome/Chromium extensions. It
automatically applies rule changes to the currently selected Clash Verge Rev
profile. It does not expose a local HTTP service, manage proxy nodes, change the
selected proxy node, or provide a general-purpose Clash control interface.

## Architecture

### Browser extension

The extension renders the proxy-rule interface and sends structured requests
with `chrome.runtime.sendNativeMessage()`. It cannot choose filesystem paths,
write Clash configuration directly, invoke shell commands, or access the Clash
Unix socket.

Supported commands are:

- `status`: return helper, Clash, profile, and synchronization status.
- `list`: return the normalized managed rules.
- `add`: validate, persist, and activate one rule.
- `remove`: remove and deactivate one rule by stable identifier.

The extension treats responses from the helper as authoritative. It may cache
the most recent response in `chrome.storage.local` for rendering during startup,
but that cache is not a source of truth.

### Native Messaging host

Chrome launches the helper on demand. The helper processes one length-prefixed
JSON request, writes one length-prefixed JSON response, and exits. No daemon,
TCP port, or `launchd` service is required.

The helper:

- accepts only the four documented commands;
- validates and normalizes all user input;
- owns the managed state and generated rule-provider files;
- discovers the current Clash profile from `profiles.yaml`;
- ensures the current profile references the managed provider;
- refreshes and verifies Clash through its existing Unix socket;
- never returns proxy credentials or unrelated Clash configuration to Chrome.

### Clash integration

The helper maintains a dedicated classical rule provider at a stable path under
the Clash Verge application-support directory:

```yaml
payload:
  - DOMAIN-SUFFIX,openai.com
  - DOMAIN-KEYWORD,google
  - DOMAIN,api.example.com
```

The current profile's merge override references this provider as
`need-proxy`. Its rule override applies rules in this order:

```yaml
rules:
  - PROCESS-NAME,internal-agent,DIRECT
  - PROCESS-NAME,internal-assistant,DIRECT
  - DOMAIN-SUFFIX,internal.example,DIRECT
  - DOMAIN-SUFFIX,corp.example,DIRECT
  - RULE-SET,need-proxy,PROXY
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - MATCH,DIRECT
```

The exact generated configuration may use Clash Verge's `prepend`, `append`,
and `delete` enhancement format, but the effective order must match the example.
The provider remains separate from downloaded subscription files so subscription
updates cannot erase the managed list.

Corporate DNS routing remains in the merge override. In particular,
`+.internal.example` and `+.corp.example` continue to use the internal DNS servers rather
than public resolvers.

## Rule Model

Each managed rule contains:

```json
{
  "id": "stable-generated-id",
  "type": "suffix | keyword | exact",
  "value": "openai.com",
  "createdAt": "ISO-8601 timestamp"
}
```

The supported match modes are:

| UI mode | Clash rule | Behavior |
| --- | --- | --- |
| Domain suffix | `DOMAIN-SUFFIX` | Matches the domain and all subdomains. |
| Domain contains | `DOMAIN-KEYWORD` | Matches any hostname containing the value. |
| Exact domain | `DOMAIN` | Matches one exact hostname only. |

Manual entry supports all three modes. Quick-add actions from an open tab or
history item use domain suffix matching because it is safer than keyword
matching.

Input normalization removes schemes, credentials, ports, paths, query strings,
fragments, trailing dots, and leading wildcard notation where the meaning is
unambiguous. Domain values are converted to lowercase and IDNs are normalized
consistently. Duplicate normalized rules are rejected without rewriting files.

The helper rejects localhost, private IP addresses, corporate suffixes, empty
values, public-suffix-only values, and dangerously short keyword rules. Corporate
direct rules are also ordered before the provider as defense in depth.

## User Interface

A new **Proxy routing** section appears after **Recently visited** and before the
footer. It follows the existing warm-paper visual language and contains:

- helper and Clash connection status;
- active rule count and latest successful synchronization time;
- a match-mode selector, value input, and `Add rule` button;
- a list of rules with match-mode badges, values, status, and remove actions;
- an explanatory warning for broad keyword matching;
- pending and failure messages with actionable descriptions.

Adding or removing a rule applies it immediately; there is no separate apply
button. Removal offers a short-lived undo action. Open-domain cards and history
domain chips receive a lightweight quick-add action that creates a suffix rule.
Already managed domains display an active state instead of a second add action.

Rule status is one of:

- `active`: persisted and verified in the running Clash configuration;
- `pending`: persisted locally while Clash is unavailable;
- `failed`: persistence or Clash validation failed and the prior active file was
  restored.

## Tab Count Synchronization

The current close handlers mutate individual DOM elements without rebuilding
the count badges and action labels. The revised implementation makes Chrome's
tab list the only source of truth.

The new-tab page listens to `chrome.tabs.onCreated`, `chrome.tabs.onRemoved`,
and `chrome.tabs.onUpdated`. Events are debounced and invoke a focused open-tab
rendering path that:

- queries Chrome for the current tab list;
- rebuilds domain groups;
- updates each `N tabs open` badge;
- updates each `Close all N tabs` action;
- recalculates duplicate counts and duplicate actions;
- updates the open-domain count and global real-tab count;
- removes a domain card when its final tab closes.

Existing close animations remain. After the animation, rendering reconciles the
view with Chrome's actual state. If one of two identical URLs closes, the row
remains and its duplicate count changes from `2x` to one normal row.

The renderer is split so tab events do not unnecessarily re-query and rebuild
the saved-for-later archive or browser history section.

## Persistence and Atomicity

The helper maintains a small managed-state JSON file and generates the classical
provider YAML from it. The JSON state is authoritative because it preserves rule
IDs, types, values, and timestamps without depending on YAML comment parsing.

For every mutation, the helper:

1. obtains an exclusive lock;
2. reads and validates the existing state;
3. applies the requested mutation in memory;
4. writes and validates temporary JSON and YAML files;
5. atomically renames the temporary files into place;
6. refreshes the provider through the Clash Unix socket;
7. queries Clash to verify that the provider loaded;
8. reports the final status to the extension.

The most recent valid files are retained as backups. If generation or Clash
loading fails, the helper restores the previous files and attempts to restore the
previous running provider before returning a failure.

If Clash is not running, valid state and provider files are retained and marked
pending. Loading the Tab Out page calls `status`, which retries pending
synchronization automatically.

## Profile Handling

On every mutation and synchronization attempt, the helper reads the currently
selected profile rather than storing a profile ID in the extension. It resolves
that profile's configured merge and rules overrides and idempotently ensures the
provider and effective rule order are installed.

The helper only proceeds when the selected profile has an unambiguous `PROXY`
group. If the group is missing, the helper reports an unsupported-profile error
and does not guess another group or modify node selection. Switching back to a
compatible profile allows the next status check to synchronize automatically.

Unmanaged entries in existing merge and rules overrides must be preserved. The
installer creates backups before the first bootstrap, and subsequent updates
modify only entries owned by this feature.

## Security Boundaries

- The extension manifest uses a stable extension ID and requests only the added
  `nativeMessaging` capability needed for this feature.
- The Native Messaging host manifest permits only that exact extension origin.
- The helper does not listen on a network interface.
- Requests cannot specify paths, executables, raw YAML, arbitrary Clash methods,
  or proxy group names.
- Files are written only beneath predetermined user application-support paths.
- Logs omit subscription URLs, server addresses, UUIDs, passwords, and full
  Clash configuration bodies.
- Domain validation and the corporate denylist are enforced in the helper, not
  only in browser JavaScript.

## Installation

The repository includes an idempotent macOS installer that:

1. installs the helper executable in a user-owned application-support directory;
2. installs the Native Messaging host manifest for supported Chromium browsers;
3. binds the manifest to Tab Out's stable extension ID;
4. creates and validates the managed state/provider directory;
5. bootstraps the current compatible Clash profile with backups;
6. prints a concise success result and any manual Chrome reload step.

Running the installer again upgrades the helper without deleting rules. An
uninstaller removes Native Messaging registration and helper files but preserves
the user's managed rule list unless explicitly asked to remove data.

## Error Handling

The extension presents specific, recoverable failures:

- helper not installed: show the installer command and keep the rest of Tab Out
  functional;
- Clash unavailable: save valid changes as pending and retry on the next status
  check;
- unsupported profile: preserve files and ask the user to select a profile with
  a `PROXY` group;
- invalid or dangerous input: reject before any write and explain the rule;
- write or validation failure: restore backups and leave the active Clash rules
  unchanged;
- reload verification failure: restore the prior provider and report failure;
- extension/helper protocol mismatch: request a helper upgrade without sending
  mutation commands.

All proxy-management failures are isolated from existing tab management, saved
items, and history rendering.

## Testing

Automated tests cover:

- URL and domain normalization;
- suffix, keyword, and exact rule generation;
- duplicate and conflict detection;
- corporate and private-address rejection;
- request schema and command allowlisting;
- state-to-YAML generation;
- locking, atomic replacement, backup, and rollback;
- profile discovery and idempotent override integration using fixtures;
- helper responses for offline Clash and unsupported profiles;
- tab-group rebuilding and all derived counts after tab events.

Integration verification on the target Mac covers:

1. installing and connecting the Native Messaging host;
2. adding one rule of each match type;
3. observing the provider through the Clash Unix socket;
4. verifying a listed domain uses `PROXY` and an unlisted domain uses `DIRECT`;
5. removing and undoing a rule;
6. restarting Clash and confirming persistence;
7. refreshing the subscription and confirming persistence;
8. closing a single, duplicate, and final domain tab and checking every count;
9. confirming existing saved-for-later and history behavior still works.

## Acceptance Criteria

- Users can add and remove suffix, keyword, and exact proxy rules from Tab Out.
- Valid changes are automatically active in Clash without opening Clash Verge.
- The default unmatched route is `DIRECT`.
- Corporate direct and DNS behavior continues to work.
- Rules survive browser restarts, Clash restarts, and subscription updates.
- No local TCP control port or persistent background daemon is introduced.
- Invalid input and profile incompatibility cannot corrupt Clash configuration.
- Closing tabs immediately and accurately updates all domain and global counts.
- Existing uncommitted history-section work and existing Tab Out features remain
  intact.
