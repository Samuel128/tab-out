# Need-Proxy Native Messaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Tab Out interface that automatically maintains suffix, keyword, and exact `need-proxy` rules for the current Clash Verge Rev profile through a secure Chrome Native Messaging helper.

**Architecture:** A browser module renders and manages proxy rules but has no filesystem or Clash-control access. An on-demand Ruby Native Messaging host validates commands, atomically maintains JSON state and a classical YAML rule provider, integrates the provider into the selected Clash profile, and reloads/verifies Mihomo through its existing Unix socket.

**Tech Stack:** Chrome Manifest V3 and `chrome.runtime.sendNativeMessage`, browser JavaScript, macOS system Ruby 2.6 with JSON/YAML/Minitest, Clash Verge Rev enhancement profiles, Mihomo Unix-socket HTTP API.

---

## File Structure

- Create `native/lib/tab_out_proxy/errors.rb`: typed helper errors and stable error codes.
- Create `native/lib/tab_out_proxy/rule.rb`: rule normalization, validation, identifiers, and provider serialization.
- Create `native/lib/tab_out_proxy/atomic_file.rb`: locked atomic file replacement and backups.
- Create `native/lib/tab_out_proxy/store.rb`: authoritative JSON state and generated classical provider.
- Create `native/lib/tab_out_proxy/profile_manager.rb`: selected-profile discovery and idempotent Clash override/active-config integration.
- Create `native/lib/tab_out_proxy/mihomo_client.rb`: minimal Unix-socket HTTP client.
- Create `native/lib/tab_out_proxy/service.rb`: command orchestration, synchronization, verification, and rollback.
- Create `native/lib/tab_out_proxy/protocol.rb`: Native Messaging framing and response envelopes.
- Create `native/bin/tab-out-proxy-host`: executable host entry point.
- Create `native/test/*_test.rb` and `native/test/fixtures/*`: unit and integration-style tests with isolated directories.
- Create `native/com.samuel.tabout.proxy.json.template`: Native Messaging host-manifest template.
- Create `scripts/generate-extension-key.sh`: one-time stable unpacked-extension key generator.
- Create `scripts/extension_id.rb`: derive Chrome's extension ID from the manifest public key.
- Create `scripts/install-native-host.sh`: idempotent per-user installer and profile bootstrap.
- Create `scripts/uninstall-native-host.sh`: remove registration/helper while preserving rule data by default.
- Create `extension/proxy-routing.js`: browser/native messaging adapter and Proxy routing UI controller.
- Create `tests/proxy-routing.test.cjs`: browser-module unit tests.
- Modify `extension/manifest.json`: add stable public key and `nativeMessaging` permission.
- Modify `extension/index.html`: add Proxy routing markup and load the controller.
- Modify `extension/style.css`: style the new section in the existing visual language.
- Modify `extension/app.js`: add domain quick-actions and initialize status refresh without disturbing existing history work.
- Modify `README.md`: installation, security model, usage, and recovery instructions.

The four `extension/` files listed as modified already contain user-owned uncommitted work. Capture their initial diffs before implementation, preserve them, and do not stage or commit an overlapping dirty file without explicit approval.

### Task 1: Build and Test the Rule Model

**Files:**
- Create: `native/lib/tab_out_proxy/errors.rb`
- Create: `native/lib/tab_out_proxy/rule.rb`
- Create: `native/test/test_helper.rb`
- Create: `native/test/rule_test.rb`

- [ ] **Step 1: Write failing normalization and validation tests**

Create `native/test/test_helper.rb`:

```ruby
# frozen_string_literal: true

require 'minitest/autorun'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
```

Create `native/test/rule_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'tab_out_proxy/rule'

class RuleTest < Minitest::Test
  def test_suffix_normalizes_a_full_url
    rule = TabOutProxy::Rule.build(type: 'suffix', value: 'https://API.OpenAI.com:443/v1?q=1')
    assert_equal 'api.openai.com', rule.value
    assert_equal 'DOMAIN-SUFFIX,api.openai.com', rule.provider_line
  end

  def test_keyword_serializes_as_domain_keyword
    rule = TabOutProxy::Rule.build(type: 'keyword', value: ' Google ')
    assert_equal 'google', rule.value
    assert_equal 'DOMAIN-KEYWORD,google', rule.provider_line
  end

  def test_exact_serializes_as_domain
    rule = TabOutProxy::Rule.build(type: 'exact', value: 'api.example.com')
    assert_equal 'DOMAIN,api.example.com', rule.provider_line
  end

  def test_rejects_corporate_suffix
    error = assert_raises(TabOutProxy::ValidationError) do
      TabOutProxy::Rule.build(type: 'suffix', value: 'app.internal.example')
    end
    assert_equal 'corporate_target', error.code
  end

  def test_rejects_private_ip_and_short_keyword
    assert_raises(TabOutProxy::ValidationError) do
      TabOutProxy::Rule.build(type: 'exact', value: '192.0.2.53')
    end
    assert_raises(TabOutProxy::ValidationError) do
      TabOutProxy::Rule.build(type: 'keyword', value: 'ai')
    end
  end

  def test_identifier_is_stable_for_type_and_value
    first = TabOutProxy::Rule.build(type: 'suffix', value: 'OpenAI.com')
    second = TabOutProxy::Rule.build(type: 'suffix', value: 'openai.com')
    assert_equal first.id, second.id
  end
end
```

- [ ] **Step 2: Run the tests and verify the implementation is missing**

```bash
ruby -I native/lib native/test/rule_test.rb
```

Expected: FAIL with `cannot load such file -- tab_out_proxy/rule`.

- [ ] **Step 3: Implement typed errors**

Create `native/lib/tab_out_proxy/errors.rb`:

```ruby
# frozen_string_literal: true

module TabOutProxy
  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  class ValidationError < Error; end
  class UnsupportedProfileError < Error; end
  class ClashUnavailableError < Error; end
  class SyncError < Error; end
end
```

- [ ] **Step 4: Implement the immutable rule model**

Create `native/lib/tab_out_proxy/rule.rb` with this public interface:

```ruby
# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require 'time'
require 'uri'
require_relative 'errors'

module TabOutProxy
  class Rule
    TYPES = { 'suffix' => 'DOMAIN-SUFFIX', 'keyword' => 'DOMAIN-KEYWORD', 'exact' => 'DOMAIN' }.freeze
    CORPORATE_SUFFIXES = %w[internal.example corp.example].freeze
    PUBLIC_SUFFIX_ONLY = %w[com net org cn local].freeze
    PRIVATE_RANGES = %w[
      10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16
      ::1/128 fc00::/7 fe80::/10
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    attr_reader :id, :type, :value, :created_at

    def self.build(type:, value:, created_at: Time.now.utc.iso8601)
      new(type: type, value: value, created_at: created_at)
    end

    def initialize(type:, value:, created_at:)
      @type = type.to_s
      raise ValidationError.new('invalid_type', 'Match type must be suffix, keyword, or exact') unless TYPES.key?(@type)

      @value = normalize(value.to_s)
      validate!
      @id = Digest::SHA256.hexdigest("#{@type}:#{@value}")[0, 20]
      @created_at = created_at
    end

    def provider_line
      "#{TYPES.fetch(type)},#{value}"
    end

    def to_h
      { 'id' => id, 'type' => type, 'value' => value, 'createdAt' => created_at }
    end

    private

    def normalize(raw)
      text = raw.strip.downcase.sub(/\.+\z/, '')
      url_like = text.include?('://') || text.include?('/') || text.include?(':')
      return text if type == 'keyword' && !url_like

      uri = URI.parse(text.include?('://') ? text : "https://#{text}")
      uri.host.to_s.downcase.sub(/\.+\z/, '')
    rescue URI::InvalidURIError
      text
    end

    def validate!
      raise ValidationError.new('empty_value', 'Rule value cannot be empty') if value.empty?
      raise ValidationError.new('short_keyword', 'Keyword rules require at least 3 characters') if type == 'keyword' && value.length < 3
      raise ValidationError.new('public_suffix', 'A public suffix alone is too broad') if PUBLIC_SUFFIX_ONLY.include?(value)
      raise ValidationError.new('invalid_domain', 'Domain contains unsupported characters') unless value.match?(/\A[a-z0-9.-]+\z/)
      raise ValidationError.new('corporate_target', 'Corporate domains must remain direct') if CORPORATE_SUFFIXES.any? { |suffix| value == suffix || value.end_with?(".#{suffix}") }

      begin
        ip = IPAddr.new(value)
        if PRIVATE_RANGES.any? { |range| range.include?(ip) }
          raise ValidationError.new('private_target', 'Private and local addresses must remain direct')
        end
      rescue IPAddr::InvalidAddressError
        nil
      end
    end
  end
end
```

- [ ] **Step 5: Run tests and syntax checks**

```bash
ruby -I native/lib native/test/rule_test.rb
ruby -c native/lib/tab_out_proxy/rule.rb
```

Expected: 6 tests pass and syntax is OK.

- [ ] **Step 6: Commit the isolated rule model**

```bash
git add native/lib/tab_out_proxy/errors.rb native/lib/tab_out_proxy/rule.rb native/test/test_helper.rb native/test/rule_test.rb
git diff --cached --check
git commit -m "feat: add validated proxy rule model"
```

### Task 2: Add Atomic State and Provider Persistence

**Files:**
- Create: `native/lib/tab_out_proxy/atomic_file.rb`
- Create: `native/lib/tab_out_proxy/store.rb`
- Create: `native/test/store_test.rb`

- [ ] **Step 1: Write failing store tests**

Create `native/test/store_test.rb`:

```ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'tab_out_proxy/store'

class StoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = TabOutProxy::Store.new(root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_persists_json_and_classical_yaml
    rule = @store.add(type: 'suffix', value: 'openai.com')
    assert_equal [rule.id], @store.list.map(&:id)

    provider = YAML.safe_load(File.read(@store.provider_path))
    assert_equal ['DOMAIN-SUFFIX,openai.com'], provider.fetch('payload')
  end

  def test_duplicate_is_rejected_without_rewriting_state
    @store.add(type: 'keyword', value: 'google')
    before = File.read(@store.state_path)
    error = assert_raises(TabOutProxy::ValidationError) { @store.add(type: 'keyword', value: 'GOOGLE') }
    assert_equal 'duplicate_rule', error.code
    assert_equal before, File.read(@store.state_path)
  end

  def test_remove_returns_removed_rule_and_updates_provider
    rule = @store.add(type: 'exact', value: 'api.example.com')
    removed = @store.remove(rule.id)
    assert_equal rule.id, removed.id
    assert_empty YAML.safe_load(File.read(@store.provider_path)).fetch('payload')
  end
end
```

- [ ] **Step 2: Run and verify failure**

```bash
ruby -I native/lib native/test/store_test.rb
```

Expected: FAIL because `tab_out_proxy/store` is missing.

- [ ] **Step 3: Implement locked atomic writes**

Create `native/lib/tab_out_proxy/atomic_file.rb`:

```ruby
# frozen_string_literal: true

require 'fileutils'

module TabOutProxy
  module AtomicFile
    module_function

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.tmp.#{$$}"
      backup = "#{path}.bak"
      File.open(temp, 'wb') do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      FileUtils.cp(path, backup) if File.exist?(path)
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if defined?(temp)
    end
  end
end
```

- [ ] **Step 4: Implement the store**

Create `native/lib/tab_out_proxy/store.rb`. Its public methods are
`list`, `add(type:, value:)`, `remove(id)`, `restore_backup`, `state_path`, and
`provider_path`. Use one lock file with `File::LOCK_EX`, serialize state as:

```json
{
  "version": 1,
  "rules": []
}
```

Generate provider YAML through `YAML.dump('payload' => rules.map(&:provider_line))`.
Parse persisted entries back through `Rule.build`, preserving `createdAt`. Reject
duplicates with code `duplicate_rule` and unknown removals with code
`rule_not_found`. Both the JSON and YAML writes must occur while the same lock is
held.

- [ ] **Step 5: Run all native tests**

```bash
ruby -I native/lib native/test/rule_test.rb
ruby -I native/lib native/test/store_test.rb
```

Expected: 9 tests pass, 0 fail.

- [ ] **Step 6: Commit persistence files**

```bash
git add native/lib/tab_out_proxy/atomic_file.rb native/lib/tab_out_proxy/store.rb native/test/store_test.rb
git diff --cached --check
git commit -m "feat: persist need-proxy rules atomically"
```

### Task 3: Integrate the Selected Clash Profile Safely

**Files:**
- Create: `native/lib/tab_out_proxy/profile_manager.rb`
- Create: `native/test/profile_manager_test.rb`
- Create: `native/test/fixtures/profiles.yaml`
- Create: `native/test/fixtures/remote-profile.json`
- Create: `native/test/fixtures/merge-override.yaml`
- Create: `native/test/fixtures/rules-override.yaml`
- Create: `native/test/fixtures/active-config.yaml`

- [ ] **Step 1: Create sanitized fixtures matching the current profile shape**

The fixture profile must contain a selected remote item with `option.merge` and
`option.rules`, a `PROXY` group, private `DIRECT` rules, and terminal
`MATCH,PROXY`. Use fake proxy names and no credentials. The merge fixture must
contain the existing corporate DNS policies so preservation is testable.

- [ ] **Step 2: Write failing profile-integration tests**

Create tests that copy the fixtures into a temporary Clash directory and assert:

```ruby
manager = TabOutProxy::ProfileManager.new(config_dir: temp_dir, provider_path: provider_path)
result = manager.ensure_integrated!

assert_equal 'current-profile', result.fetch('profileId')
assert_equal 'PROXY', result.fetch('proxyGroup')

merge = YAML.safe_load(File.read(File.join(temp_dir, 'profiles', 'merge.yaml')))
assert_equal ['192.0.2.53'], merge.dig('dns', 'nameserver-policy', '+.internal.example')
assert_equal 'classical', merge.dig('rule-providers', 'need-proxy', 'behavior')

rules = YAML.safe_load(File.read(File.join(temp_dir, 'profiles', 'rules.yaml')))
assert_includes rules.fetch('prepend'), 'RULE-SET,need-proxy,PROXY'
assert_includes rules.fetch('delete'), 'MATCH,PROXY'
assert_equal 'MATCH,DIRECT', rules.fetch('append').last

active = YAML.safe_load(File.read(File.join(temp_dir, 'clash-verge.yaml')))
assert_equal 'MATCH,DIRECT', active.fetch('rules').last
assert_operator active.fetch('rules').index('DOMAIN-SUFFIX,internal.example,DIRECT'), :<,
                active.fetch('rules').index('RULE-SET,need-proxy,PROXY')
```

Add a second test where `PROXY` is absent and assert
`UnsupportedProfileError` without any changed fixture files. Add a third test
calling `ensure_integrated!` twice and asserting byte-identical second-run files.

- [ ] **Step 3: Run and verify failure**

```bash
ruby -I native/lib native/test/profile_manager_test.rb
```

Expected: FAIL because `ProfileManager` is missing.

- [ ] **Step 4: Implement profile discovery and integration**

Implement `ProfileManager` using `YAML.safe_load` for YAML/JSON files. Resolve:

1. `profiles.yaml.current`;
2. the matching remote item;
3. `option.merge` and `option.rules` IDs;
4. the selected remote profile file;
5. the profile's exact `PROXY` group.

Before writes, reject profiles without the group or without a predictable
direct/private-rules plus terminal `MATCH,PROXY` shape. This prevents an unknown
subscription rule graph from being silently rewritten.

Merge the provider definition without replacing `dns` or other keys:

```ruby
merge['rule-providers'] ||= {}
merge['rule-providers']['need-proxy'] = {
  'type' => 'file',
  'behavior' => 'classical',
  'format' => 'yaml',
  'path' => provider_path
}
```

For the rule override, preserve unmanaged entries, remove earlier copies of
managed rules, prepend corporate direct rules followed by
`RULE-SET,need-proxy,PROXY`, add the detected terminal `MATCH,PROXY` to `delete`,
and make `MATCH,DIRECT` the final append entry.

Patch `clash-verge.yaml` for immediate reload by adding the same provider,
placing corporate direct rules first, retaining private `DIRECT` CIDRs, adding
the provider rule, and ending with `MATCH,DIRECT`. Write all three files through
`AtomicFile.write` and expose `restore_backups!`.

- [ ] **Step 5: Run profile and regression tests**

```bash
ruby -I native/lib native/test/profile_manager_test.rb
ruby -I native/lib -e 'Dir["native/test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Expected: all tests pass and the real Clash directory has not been touched.

- [ ] **Step 6: Commit profile integration**

```bash
git add native/lib/tab_out_proxy/profile_manager.rb native/test/profile_manager_test.rb native/test/fixtures
git diff --cached --check
git commit -m "feat: integrate need-proxy provider with Clash profiles"
```

### Task 4: Add Mihomo Unix-Socket Refresh and Verification

**Files:**
- Create: `native/lib/tab_out_proxy/mihomo_client.rb`
- Create: `native/lib/tab_out_proxy/service.rb`
- Create: `native/test/mihomo_client_test.rb`
- Create: `native/test/service_test.rb`

- [ ] **Step 1: Write failing client parsing tests**

Use a temporary `UNIXServer` that returns controlled HTTP responses. Test:

- `GET /version` parses a 200 JSON response;
- non-2xx responses raise `SyncError` with code `clash_http_error`;
- a missing socket raises `ClashUnavailableError` with code `clash_unavailable`.

- [ ] **Step 2: Implement a minimal Unix HTTP client**

Use Ruby `UNIXSocket`, write HTTP/1.1 requests with `Connection: close`, parse the
status line and headers, and decode JSON bodies. Expose:

```ruby
client.available?
client.reload_config(active_config_path)
client.refresh_provider('need-proxy')
client.provider('need-proxy')
```

`reload_config` sends `PUT /configs?force=true` with JSON
`{"path":"<absolute active config path>"}`. `refresh_provider` sends
`PUT /providers/rules/need-proxy`. Never log request bodies from configuration
reloads.

- [ ] **Step 3: Write failing service transaction tests**

Use fake store, profile manager, and client objects. Cover:

- add persists, integrates, reloads, refreshes, verifies, and returns `active`;
- offline Clash persists and returns `pending`;
- reload failure restores store/profile backups and returns/raises `failed`;
- status retries a pending synchronization;
- list returns only public rule data and no Clash configuration.

- [ ] **Step 4: Implement `Service` orchestration**

The service public method is:

```ruby
def call(command, payload = {})
  case command
  when 'status' then status
  when 'list'   then list
  when 'add'    then add(payload.fetch('type'), payload.fetch('value'))
  when 'remove' then remove(payload.fetch('id'))
  else
    raise ValidationError.new('unknown_command', 'Unsupported native command')
  end
end
```

Return envelopes containing `status`, `rules`, `profile`, `syncedAt`, and a
protocol version. For add/remove, perform store and profile writes before Clash
reload. If the socket is absent, retain valid files and return `pending`. If the
socket exists but reload or verification fails, restore backups and raise
`SyncError`.

- [ ] **Step 5: Run the native suite**

```bash
ruby -I native/lib -e 'Dir["native/test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Expected: all tests pass with no access to the real Clash directory or socket.

- [ ] **Step 6: Commit synchronization code**

```bash
git add native/lib/tab_out_proxy/mihomo_client.rb native/lib/tab_out_proxy/service.rb native/test/mihomo_client_test.rb native/test/service_test.rb
git diff --cached --check
git commit -m "feat: synchronize proxy rules through Mihomo socket"
```

### Task 5: Implement the Native Messaging Protocol

**Files:**
- Create: `native/lib/tab_out_proxy/protocol.rb`
- Create: `native/bin/tab-out-proxy-host`
- Create: `native/test/protocol_test.rb`

- [ ] **Step 1: Write failing framing tests**

Use `StringIO` to verify that `Protocol.read` consumes a four-byte little-endian
length followed by JSON, `Protocol.write` emits the same framing, malformed JSON
returns code `invalid_json`, and payloads larger than 1 MiB are rejected.

- [ ] **Step 2: Implement framing and response envelopes**

`Protocol.read(io)` and `Protocol.write(io, object)` must use:

```ruby
length = io.read(4).unpack1('L<')
payload = io.read(length)
```

Successful responses are:

```json
{"ok":true,"protocolVersion":1,"data":{}}
```

Failures are:

```json
{"ok":false,"protocolVersion":1,"error":{"code":"...","message":"..."}}
```

- [ ] **Step 3: Create the executable host**

`native/bin/tab-out-proxy-host` must use `/usr/bin/ruby`, add the installed
`lib` directory to `$LOAD_PATH`, construct production paths under:

```text
~/Library/Application Support/Tab Out Proxy/
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/
/tmp/verge/verge-mihomo.sock
```

It reads one request, calls `Service`, writes one response, logs only error code
and timestamp to stderr, and exits. It must never print non-protocol text to
stdout.

- [ ] **Step 4: Run protocol and full native tests**

```bash
ruby -I native/lib native/test/protocol_test.rb
ruby -I native/lib -e 'Dir["native/test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
ruby -c native/bin/tab-out-proxy-host
```

Expected: all tests pass and syntax is OK.

- [ ] **Step 5: Commit the host**

```bash
chmod +x native/bin/tab-out-proxy-host
git add native/lib/tab_out_proxy/protocol.rb native/bin/tab-out-proxy-host native/test/protocol_test.rb
git diff --cached --check
git commit -m "feat: add native messaging host protocol"
```

### Task 6: Add Stable Extension Identity and Installer

**Files:**
- Create: `scripts/generate-extension-key.sh`
- Create: `scripts/extension_id.rb`
- Create: `scripts/install-native-host.sh`
- Create: `scripts/uninstall-native-host.sh`
- Create: `native/com.samuel.tabout.proxy.json.template`
- Modify: `extension/manifest.json`

- [ ] **Step 1: Create the one-time key generator**

The script must fail if the manifest already contains `key`, generate a temporary
2048-bit RSA key, print the base64 DER public key, securely delete the temporary
private key, and instruct the implementer to add the printed public value to the
manifest. Never commit the private key.

Run it once during implementation, add the resulting literal public key to
`extension/manifest.json`, then rerun it and expect a safe refusal.

- [ ] **Step 2: Add and test extension-ID derivation**

`scripts/extension_id.rb` reads the manifest key, decodes DER, computes SHA-256,
takes the first 16 bytes, and maps each hexadecimal nibble `0..f` to `a..p`,
which is Chrome's extension-ID algorithm. Add a `--self-test` fixture whose
expected ID is hard-coded from a known public-key fixture before using it in the
installer.

- [ ] **Step 3: Add Native Messaging permission without losing current permissions**

Preserve `tabs`, `activeTab`, `storage`, and the user's uncommitted `history`
permission. Add only:

```json
"nativeMessaging"
```

and the generated literal `key` field.

- [ ] **Step 4: Create the host-manifest template**

```json
{
  "name": "com.samuel.tabout.proxy",
  "description": "Tab Out need-proxy rule helper",
  "path": "__HOST_PATH__",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://__EXTENSION_ID__/"]
}
```

- [ ] **Step 5: Implement the idempotent installer**

`scripts/install-native-host.sh` must:

1. require macOS, `/usr/bin/ruby`, and the Clash application-support directory;
2. derive the extension ID from the manifest key;
3. copy `native/bin` and `native/lib` beneath
   `~/Library/Application Support/Tab Out Proxy/native/`;
4. make the installed host executable;
5. render the template with the absolute installed host path and derived ID;
6. install it at
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.samuel.tabout.proxy.json`;
7. invoke the installed host with a framed `status` request to bootstrap and
   validate the current profile;
8. print the extension ID and tell the user to reload the unpacked extension.

Use `mktemp`, quoted paths, `set -euo pipefail`, and atomic `mv` for the host
manifest. Re-running must upgrade code without deleting state.

- [ ] **Step 6: Implement uninstall behavior**

The uninstaller removes Chrome registration and installed executable/library
files. It preserves managed JSON/YAML data unless invoked with
`--remove-data`, and it clearly prints that Clash overrides remain until the
optional cleanup path succeeds.

- [ ] **Step 7: Validate scripts without installing**

```bash
bash -n scripts/generate-extension-key.sh
ruby -c scripts/extension_id.rb
bash -n scripts/install-native-host.sh
bash -n scripts/uninstall-native-host.sh
ruby scripts/extension_id.rb extension/manifest.json
```

Expected: syntax checks pass and the final command prints a 32-character ID.

- [ ] **Step 8: Commit only new installer files and approved manifest changes**

Because `extension/manifest.json` was already dirty before this work, do not
stage it without explicit approval. Commit new installer files separately:

```bash
git add native/com.samuel.tabout.proxy.json.template scripts/generate-extension-key.sh scripts/extension_id.rb scripts/install-native-host.sh scripts/uninstall-native-host.sh
git diff --cached --check
git commit -m "feat: add native host installer"
```

### Task 7: Build the Browser Proxy-Routing Controller

**Files:**
- Create: `extension/proxy-routing.js`
- Create: `tests/proxy-routing.test.cjs`
- Modify: `extension/index.html`
- Modify: `extension/style.css`
- Modify: `extension/app.js`

- [ ] **Step 1: Write failing browser-adapter tests**

Create `tests/proxy-routing.test.cjs` covering:

```javascript
test('native request uses the fixed host name and command envelope', async () => {
  const calls = [];
  const runtime = {
    sendNativeMessage(host, message, callback) {
      calls.push({ host, message });
      callback({ ok: true, protocolVersion: 1, data: { rules: [] } });
    },
    lastError: null,
  };

  const data = await sendNative(runtime, 'list', {});
  assert.deepEqual(calls, [{
    host: 'com.samuel.tabout.proxy',
    message: { protocolVersion: 1, command: 'list', payload: {} },
  }]);
  assert.deepEqual(data.rules, []);
});

test('quick-add payload always uses suffix matching', () => {
  assert.deepEqual(quickAddPayload('API.OpenAI.com'), {
    type: 'suffix',
    value: 'api.openai.com',
  });
});
```

Also test native `lastError`, helper `ok:false`, and protocol mismatch responses.

- [ ] **Step 2: Run and verify the module is missing**

```bash
node --test tests/proxy-routing.test.cjs
```

Expected: FAIL because `extension/proxy-routing.js` is missing.

- [ ] **Step 3: Implement a UMD browser controller**

Expose pure `sendNative`, `quickAddPayload`, and `formatRuleLabel` functions to
Node and expose `TabOutProxyRouting` to the browser. `sendNative` must reject
Chrome runtime errors, helper errors, and protocol versions other than 1.

The browser initializer must:

- request `status` and render helper/Clash state;
- render rule rows from helper data;
- send `add` for manual and quick-add actions;
- send `remove` and retain removed rule data for a 5-second undo;
- disable only the affected control while a request is in flight;
- keep all existing Tab Out features usable if the helper is absent.

- [ ] **Step 4: Add Proxy routing markup**

In `extension/index.html`, after the user's existing `historySection` and before
the footer, add stable IDs for:

```html
<section class="proxy-routing" id="proxyRouting">
  <div class="section-header">
    <h2>Proxy routing</h2>
    <div class="section-line"></div>
    <div class="proxy-status" id="proxyStatus">Checking...</div>
  </div>
  <form class="proxy-rule-form" id="proxyRuleForm">
    <select id="proxyRuleType" aria-label="Match type">
      <option value="suffix">Domain suffix</option>
      <option value="keyword">Domain contains</option>
      <option value="exact">Exact domain</option>
    </select>
    <input id="proxyRuleValue" autocomplete="off" placeholder="openai.com or keyword">
    <button type="submit">Add rule</button>
  </form>
  <p class="proxy-rule-help" id="proxyRuleHelp"></p>
  <div class="proxy-rule-list" id="proxyRuleList"></div>
</section>
```

Load `proxy-routing.js` after `app.js`, preserving current script order.

- [ ] **Step 5: Add quick-add hooks to domain and history rendering**

In `renderDomainCard`, add the real hostname as `data-proxy-domain` only when the
group represents one real domain. Do not offer quick-add for Homepages,
custom-group synthetic keys, local files, localhost, or corporate domains.
For eligible groups, append this control to `actionsHtml`:

```javascript
actionsHtml += `
  <button class="action-btn proxy-quick-add" data-action="add-proxy-domain" data-proxy-domain="${group.domain}">
    Route domain through proxy
  </button>`;
```

In `renderHistorySection`, preserve the user's current link and favicon behavior,
and add a sibling button carrying `data-action="add-proxy-domain"` and the
hostname. The controller listens through event delegation, so rerenders do not
lose handlers.

- [ ] **Step 6: Add styles using existing variables**

Use `--paper`, `--card-bg`, `--warm-gray`, `--muted`, `--accent-amber`, and
`--status-active`. Include responsive wrapping below 700 px, visible keyboard
focus, pending/failed status colors, compact mode badges, and no new font or
remote asset.

- [ ] **Step 7: Run browser-module tests and syntax checks**

```bash
node --test tests/proxy-routing.test.cjs tests/tab-state.test.cjs
node --check extension/proxy-routing.js
node --check extension/app.js
```

Expected: all tests pass and syntax checks exit 0.

- [ ] **Step 8: Preserve dirty extension work**

```bash
git diff -- extension/app.js extension/index.html extension/manifest.json extension/style.css
git status --short
```

Expected: history-domain work remains present. Commit the new controller and
tests independently; leave pre-existing dirty files unstaged unless approved:

```bash
git add extension/proxy-routing.js tests/proxy-routing.test.cjs
git commit -m "feat: add proxy routing browser controller"
```

### Task 8: Install and Verify End to End on the Target Mac

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Back up and record current state**

```bash
git status --short
cp "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles.yaml" /tmp/tab-out-profiles.before.yaml
cp "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml" /tmp/tab-out-clash.before.yaml
curl --silent --show-error --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/rules > /tmp/tab-out-rules.before.json
```

Expected: backups exist and the current rules response is valid JSON.

- [ ] **Step 2: Run all automated tests before installation**

```bash
node --test tests/*.test.cjs
ruby -I native/lib -e 'Dir["native/test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
bash -n scripts/install-native-host.sh
bash -n scripts/uninstall-native-host.sh
git diff --check
```

Expected: all tests and checks pass.

- [ ] **Step 3: Install the host and reload the extension**

```bash
./scripts/install-native-host.sh
```

Expected: the script prints the derived extension ID, reports a compatible Clash
profile, and does not expose credentials. Reload Tab Out at `chrome://extensions`.

- [ ] **Step 4: Verify each match mode**

Add one suffix, keyword, and exact test rule through the UI. After each addition:

```bash
curl --silent --show-error --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/providers/rules/need-proxy
curl --silent --show-error --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/rules
```

Expected: the provider is healthy, the managed rule set appears before final
`MATCH,DIRECT`, and no proxy credentials are printed by the helper.

- [ ] **Step 5: Verify routing behavior**

Open a listed external domain and an unlisted domain. Inspect Clash connections
or logs.

Expected: listed domain uses `PROXY`; unlisted domain uses `DIRECT`; `.internal.example`,
`.corp.example`, `dawn`, and `internal-assistant` remain direct and company DNS policy remains
present.

- [ ] **Step 6: Verify offline and rollback behavior**

Stop Clash, add a harmless test rule, and confirm the UI shows `pending`. Restart
Clash and reopen Tab Out; expect automatic activation. Then use an isolated test
fixture to force an invalid reload and verify backups restore. Do not inject an
invalid rule into the live company profile.

- [ ] **Step 7: Verify restart and subscription persistence**

Restart Chrome and Clash, then refresh the current subscription from Clash Verge.

Expected: managed rules and direct-by-default order remain. If the subscription
shape becomes incompatible, the UI reports `unsupported_profile` and leaves the
last valid configuration intact.

- [ ] **Step 8: Verify the tab-count plan remains green**

Repeat single, duplicate, and final-tab closure checks from
`2026-09-16-tab-count-sync.md`.

- [ ] **Step 9: Document installation and recovery**

Add README sections containing:

- `./scripts/install-native-host.sh` installation;
- reload instructions for the unpacked extension;
- suffix/keyword/exact semantics and keyword warning;
- `active`, `pending`, and `failed` meanings;
- `./scripts/uninstall-native-host.sh` behavior;
- backup locations and how to restore without exposing configuration secrets.

- [ ] **Step 10: Run final verification and review scope**

```bash
node --test tests/*.test.cjs
ruby -I native/lib -e 'Dir["native/test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
node --check extension/app.js
node --check extension/proxy-routing.js
git diff --check
git status --short
```

Expected: all tests pass. Review `git diff` to ensure no subscription URL, proxy
password, UUID, company credential, or unrelated user change is staged. Commit
only approved files and report any intentionally uncommitted overlapping changes.
