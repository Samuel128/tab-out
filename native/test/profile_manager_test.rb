# frozen_string_literal: true

require_relative 'test_helper'
require 'yaml'
require 'tab_out_proxy/profile_manager'

class ProfileManagerTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures', __dir__)
  CORPORATE_RULES = [
    'PROCESS-NAME,internal-agent,DIRECT',
    'PROCESS-NAME,internal-assistant,DIRECT',
    'DOMAIN-SUFFIX,internal.example,DIRECT',
    'DOMAIN-SUFFIX,corp.example,DIRECT',
    'DOMAIN-SUFFIX,business.example,DIRECT'
  ].freeze

  def setup
    @directory = Dir.mktmpdir('tab-out-profile-test')
    @profiles_directory = File.join(@directory, 'profiles')
    FileUtils.mkdir_p(@profiles_directory)
    %w[profiles.yaml active-config.yaml].each do |name|
      source = File.join(FIXTURES, name)
      target = name == 'active-config.yaml' ? File.join(@directory, 'clash-verge.yaml') : File.join(@directory, name)
      FileUtils.cp(source, target)
    end
    %w[remote-profile.json merge-override.yaml rules-override.yaml].each do |name|
      FileUtils.cp(File.join(FIXTURES, name), File.join(@profiles_directory, name))
    end
    @provider_path = File.join(@directory, 'managed', 'need-proxy.yaml')
    @manager = TabOutProxy::ProfileManager.new(
      config_dir: @directory,
      provider_path: @provider_path
    )
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def test_integration_preserves_existing_configuration_and_orders_managed_rules
    remote_before = File.binread(profile_path('remote-profile.json'))

    result = @manager.ensure_integrated!

    assert_equal 'current-profile', result.fetch('profileId')
    assert_equal 'PROXY', result.fetch('proxyGroup')
    assert_equal File.join(@directory, 'clash-verge.yaml'), result.fetch('activeConfigPath')
    assert_equal remote_before, File.binread(profile_path('remote-profile.json'))

    merge = load_yaml(profile_path('merge-override.yaml'))
    assert_equal ['192.0.2.53'], merge.dig('dns', 'nameserver-policy', '+.internal.example')
    assert_equal ['192.0.2.54'], merge.dig('dns', 'nameserver-policy', '+.corp.example')
    assert_equal true, merge.dig('custom-merge-key', 'preserved')
    assert_equal 'domain', merge.dig('rule-providers', 'existing-provider', 'behavior')
    assert_equal(
      {
        'type' => 'file',
        'behavior' => 'classical',
        'format' => 'yaml',
        'path' => @provider_path
      },
      merge.dig('rule-providers', 'need-proxy')
    )

    rules = load_yaml(profile_path('rules-override.yaml'))
    assert_equal CORPORATE_RULES + [
      'RULE-SET,need-proxy,PROXY',
      'DOMAIN-SUFFIX,existing.example,DIRECT'
    ], rules.fetch('prepend')
    assert_operator rules.fetch('prepend').index('DOMAIN-SUFFIX,business.example,DIRECT'), :<,
                    rules.fetch('prepend').index('RULE-SET,need-proxy,PROXY')
    assert_includes rules.fetch('delete'), 'DOMAIN-SUFFIX,obsolete.example,PROXY'
    assert_includes rules.fetch('delete'), 'MATCH,PROXY'
    assert_equal ['DOMAIN-SUFFIX,fallback.example,DIRECT', 'MATCH,DIRECT'], rules.fetch('append')
    assert_equal true, rules.dig('custom-rules-key', 'preserved')

    active = load_yaml(File.join(@directory, 'clash-verge.yaml'))
    assert_equal true, active.dig('custom-active-key', 'preserved')
    assert_equal ['192.0.2.53'], active.dig('dns', 'nameserver-policy', '+.internal.example')
    assert_equal 'domain', active.dig('rule-providers', 'existing-provider', 'behavior')
    assert_equal CORPORATE_RULES, active.fetch('rules').first(CORPORATE_RULES.length)
    assert_operator active.fetch('rules').index('DOMAIN-SUFFIX,business.example,DIRECT'), :<,
                    active.fetch('rules').index('RULE-SET,need-proxy,PROXY')
    assert_equal 'RULE-SET,need-proxy,PROXY', active.fetch('rules')[CORPORATE_RULES.length]
    assert_includes active.fetch('rules'), 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
    assert_equal 'MATCH,DIRECT', active.fetch('rules').last
    refute_includes active.fetch('rules'), 'MATCH,PROXY'
  end

  def test_second_integration_is_byte_identical
    @manager.ensure_integrated!
    paths = managed_paths
    first = paths.to_h { |path| [path, File.binread(path)] }

    @manager.ensure_integrated!

    paths.each { |path| assert_equal first.fetch(path), File.binread(path) }
  end

  def test_only_managed_whitelist_can_select_a_proxy_and_reject_rules_survive
    outbound = ['DOMAIN-SUFFIX,other.example,PROXY', 'RULE-SET,remote-list,OtherGroup', 'AND,((NETWORK,TCP),(DST-PORT,443)),OtherGroup']
    safe = ['DOMAIN-SUFFIX,blocked.example,REJECT', 'IP-CIDR,192.0.2.0/24,REJECT-DROP,no-resolve']
    remote_path = profile_path('remote-profile.json')
    remote = load_yaml(remote_path)
    remote['rules'].insert(0, *outbound, *safe)
    File.write(remote_path, YAML.dump(remote))
    remote_before = File.binread(remote_path)
    active_path = File.join(@directory, 'clash-verge.yaml')
    active = load_yaml(active_path)
    active['rules'].insert(0, *outbound, *safe)
    File.write(active_path, YAML.dump(active))
    overrides = load_yaml(profile_path('rules-override.yaml'))
    overrides['prepend'].concat(outbound + safe)
    overrides['append'].concat(outbound + safe)
    File.write(profile_path('rules-override.yaml'), YAML.dump(overrides))

    @manager.ensure_integrated!

    integrated = load_yaml(active_path)
    outbound.each { |rule| refute_includes integrated['rules'], rule }
    safe.each { |rule| assert_includes integrated['rules'], rule }
    override = load_yaml(profile_path('rules-override.yaml'))
    outbound.each do |rule|
      assert_includes override['delete'], rule
      refute_includes override['prepend'], rule
      refute_includes override['append'], rule
    end
    safe.each { |rule| assert_includes override['prepend'], rule }
    assert_equal remote_before, File.binread(remote_path)
    assert_equal 'MATCH,DIRECT', integrated['rules'].last
  end

  def test_unrelated_need_proxy_provider_in_merge_or_active_is_rejected_without_writes
    managed_paths.first(1).concat([managed_paths.last]).each do |path|
      original = File.binread(path)
      config = load_yaml(path)
      config['rule-providers'] ||= {}
      config['rule-providers']['need-proxy'] = {
        'type' => 'http', 'behavior' => 'classical', 'format' => 'yaml',
        'url' => 'https://example.com/rules.yaml'
      }
      File.write(path, YAML.dump(config))
      before = managed_paths.to_h { |managed| [managed, File.binread(managed)] }

      error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

      assert_equal 'provider_collision', error.code
      before.each { |managed, content| assert_equal content, File.binread(managed) }
      File.binwrite(path, original)
    end
  end

  def test_matching_managed_provider_is_idempotent
    @manager.ensure_integrated!
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    @manager.ensure_integrated!

    assert_equal before, managed_paths.to_h { |path| [path, File.binread(path)] }
  end

  def test_need_proxy_provider_with_different_path_is_not_adopted
    merge_path = profile_path('merge-override.yaml')
    merge = load_yaml(merge_path)
    merge['rule-providers'] ||= {}
    merge['rule-providers']['need-proxy'] = {
      'type' => 'file', 'behavior' => 'classical', 'format' => 'yaml',
      'path' => File.join(@directory, 'other', 'need-proxy.yaml')
    }
    File.write(merge_path, YAML.dump(merge))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'provider_collision', error.code
    assert_equal before, managed_paths.to_h { |path| [path, File.binread(path)] }
  end

  def test_symlinked_managed_configs_are_rejected_without_following_or_replacing_links
    managed_paths.each do |path|
      target = "#{path}.outside"
      FileUtils.mv(path, target)
      File.symlink(target, path)
      before = managed_paths.to_h { |managed| [managed, File.binread(managed)] }

      error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

      assert_equal 'unsafe_profile_path', error.code
      assert File.symlink?(path)
      assert_equal before.fetch(path), File.binread(target)
      before.each { |managed, content| assert_equal content, File.binread(managed) }
      FileUtils.rm(path)
      FileUtils.mv(target, path)
    end
  end

  def test_terminal_rules_in_overrides_cannot_defeat_final_direct_default
    rules = load_yaml(profile_path('rules-override.yaml'))
    rules['prepend'].concat(['MATCH,PROXY', 'MATCH,DIRECT'])
    rules['delete'].concat(['MATCH,DIRECT', 'MATCH,REJECT'])
    rules['append'].concat(['MATCH,REJECT', 'MATCH,PROXY'])
    File.write(profile_path('rules-override.yaml'), YAML.dump(rules))

    @manager.ensure_integrated!

    integrated = load_yaml(profile_path('rules-override.yaml'))
    refute integrated.fetch('prepend').any? { |rule| rule.start_with?('MATCH,') }
    refute_includes integrated.fetch('delete'), 'MATCH,DIRECT'
    assert_includes integrated.fetch('delete'), 'MATCH,PROXY'
    assert_equal ['DOMAIN-SUFFIX,fallback.example,DIRECT', 'MATCH,DIRECT'], integrated.fetch('append')
    assert_equal 'MATCH,DIRECT', load_yaml(File.join(@directory, 'clash-verge.yaml')).fetch('rules').last
  end

  def test_non_hash_merge_rule_providers_are_rejected_without_writes
    merge = load_yaml(profile_path('merge-override.yaml'))
    merge['rule-providers'] = ['unsafe-provider-container']
    File.write(profile_path('merge-override.yaml'), YAML.dump(merge))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'merge_provider_container_invalid', error.code
    before.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_non_hash_active_rule_providers_are_rejected_without_writes
    active_path = File.join(@directory, 'clash-verge.yaml')
    active = load_yaml(active_path)
    active['rule-providers'] = 'unsafe-provider-container'
    File.write(active_path, YAML.dump(active))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'active_provider_container_invalid', error.code
    before.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_non_array_rule_override_container_is_rejected_without_writes
    rules = load_yaml(profile_path('rules-override.yaml'))
    rules['prepend'] = { 'unsafe' => true }
    File.write(profile_path('rules-override.yaml'), YAML.dump(rules))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'rules_override_invalid', error.code
    before.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_missing_proxy_group_is_rejected_without_writes
    remote = load_yaml(profile_path('remote-profile.json'))
    remote['proxy-groups'][0]['name'] = 'Fallback'
    File.write(profile_path('remote-profile.json'), YAML.dump(remote))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'proxy_group_missing', error.code
    before.each { |path, content| assert_equal content, File.binread(path) }
    refute_match(/redacted|subscription/i, error.message)
  end

  def test_ambiguous_proxy_group_is_rejected
    remote = load_yaml(profile_path('remote-profile.json'))
    remote['proxy-groups'] << Marshal.load(Marshal.dump(remote['proxy-groups'][0]))
    File.write(profile_path('remote-profile.json'), YAML.dump(remote))

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }
    assert_equal 'proxy_group_ambiguous', error.code
  end

  def test_unpredictable_terminal_rules_are_rejected_without_writes
    remote = load_yaml(profile_path('remote-profile.json'))
    remote['rules'][-1] = 'MATCH,DIRECT'
    File.write(profile_path('remote-profile.json'), YAML.dump(remote))
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }

    assert_equal 'unsupported_rule_shape', error.code
    before.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_missing_private_direct_rule_is_rejected
    remote = load_yaml(profile_path('remote-profile.json'))
    remote['rules'].reject! { |rule| rule.start_with?('IP-CIDR,') }
    File.write(profile_path('remote-profile.json'), YAML.dump(remote))

    error = assert_raises(TabOutProxy::UnsupportedProfileError) { @manager.ensure_integrated! }
    assert_equal 'unsupported_rule_shape', error.code
  end

  def test_backup_restore_recovers_all_managed_profile_files
    originals = managed_paths.to_h { |path| [path, File.binread(path)] }
    @manager.ensure_integrated!

    @manager.restore_backups!

    originals.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_snapshot_restore_supports_service_transactions
    snapshot = @manager.snapshot
    @manager.ensure_integrated!

    @manager.restore(snapshot)

    snapshot.each { |path, content| assert_equal content, File.binread(path) }
  end

  def test_profile_info_is_public_and_does_not_write
    before = managed_paths.to_h { |path| [path, File.binread(path)] }

    info = @manager.profile_info

    assert_equal({ 'profileId' => 'current-profile', 'proxyGroup' => 'PROXY' }, info)
    before.each { |path, content| assert_equal content, File.binread(path) }
  end

  private

  def profile_path(name)
    File.join(@profiles_directory, name)
  end

  def managed_paths
    [
      profile_path('merge-override.yaml'),
      profile_path('rules-override.yaml'),
      File.join(@directory, 'clash-verge.yaml')
    ]
  end

  def load_yaml(path)
    YAML.safe_load(File.read(path))
  end
end
