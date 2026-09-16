# frozen_string_literal: true

require_relative 'test_helper'
require 'time'
require 'tab_out_proxy/profile_manager'
require 'tab_out_proxy/service'
require 'tab_out_proxy/store'

class ServiceTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures', __dir__)
  FIXED_TIME = Time.utc(2026, 9, 16, 8, 30, 0)
  HEALTHY_PROVIDER = {
    'name' => 'need-proxy',
    'type' => 'Rule',
    'behavior' => 'Classical',
    'vehicleType' => 'File',
    'ruleCount' => 1
  }.freeze

  class FakeClient
    attr_accessor :online, :provider_result
    attr_reader :calls

    def initialize(online: true, provider_result: HEALTHY_PROVIDER.dup)
      @online = online
      @provider_result = provider_result
      @calls = []
      @failures = {}
    end

    def fail_next(method, error)
      (@failures[method] ||= []) << error
    end

    def available?
      @calls << [:available]
      raise_failure(:available)
      online
    end

    def reload_config(path)
      @calls << [:reload_config, path]
      raise_failure(:reload_config)
      {}
    end

    def refresh_provider(name)
      @calls << [:refresh_provider, name]
      raise_failure(:refresh_provider)
      {}
    end

    def provider(name)
      @calls << [:provider, name]
      raise_failure(:provider)
      provider_result
    end

    private

    def raise_failure(method)
      failure = @failures.fetch(method, []).shift
      raise failure if failure
    end
  end

  class BlockingFailClient < FakeClient
    attr_reader :entered, :release

    def initialize
      super
      @entered = Queue.new
      @release = Queue.new
      @reload_count = 0
    end

    def reload_config(path)
      @calls << [:reload_config, path]
      @reload_count += 1
      return {} unless @reload_count == 1

      entered << true
      release.pop
      raise TabOutProxy::SyncError.new('clash_http_error', 'HTTP 500')
    end
  end

  def setup
    @directory = Dir.mktmpdir('tab-out-service-test')
    prepare_clash_directory
    @store = TabOutProxy::Store.new(root: File.join(@directory, 'state'))
    @manager = TabOutProxy::ProfileManager.new(
      config_dir: @clash_directory,
      provider_path: @store.provider_path
    )
    @client = FakeClient.new
    @service = build_service(@client)
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def test_add_persists_integrates_reloads_refreshes_and_verifies
    result = @service.call('add', 'type' => 'suffix', 'value' => 'OpenAI.com')

    assert_equal 1, result.fetch('protocolVersion')
    assert_equal 'active', result.fetch('status')
    assert_equal '2026-09-16T08:30:00Z', result.fetch('syncedAt')
    assert_equal ['openai.com'], result.fetch('rules').map { |rule| rule.fetch('value') }
    assert_equal({ 'profileId' => 'current-profile', 'proxyGroup' => 'PROXY' }, result.fetch('profile'))
    assert_equal [
      [:available],
      [:reload_config, File.join(@clash_directory, 'clash-verge.yaml')],
      [:refresh_provider, 'need-proxy'],
      [:provider, 'need-proxy']
    ], @client.calls
  end

  def test_first_run_status_and_list_do_not_create_state_or_touch_clash
    before = profile_contents

    %w[status list].each do |command|
      result = @service.call(command)
      assert_includes %w[inactive stored], result.fetch('status')
      assert_empty result.fetch('rules')
      assert_nil result.fetch('syncedAt')
    end

    refute File.exist?(@store.state_path)
    refute File.exist?(@store.provider_path)
    refute File.exist?(File.dirname(@store.state_path))
    assert_equal before, profile_contents
    assert_empty @client.calls
  end

  def test_status_after_verified_activation_does_not_reload_unchanged_config
    @service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    @client.calls.clear

    result = @service.call('status')

    assert_equal 'active', result.fetch('status')
    refute_includes @client.calls.map(&:first), :reload_config
    refute_includes @client.calls.map(&:first), :refresh_provider
  end

  def test_status_reloads_when_previously_verified_provider_is_unavailable
    @service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    @client.calls.clear
    @client.fail_next(
      :provider,
      TabOutProxy::SyncError.new('clash_http_error', 'HTTP 404')
    )

    result = @service.call('status')

    assert_equal 'active', result.fetch('status')
    assert_includes @client.calls.map(&:first), :reload_config
    assert_includes @client.calls.map(&:first), :refresh_provider
  end

  def test_offline_add_retains_valid_files_as_pending
    @client.online = false

    result = @service.call('add', 'type' => 'keyword', 'value' => 'google')

    assert_equal 'pending', result.fetch('status')
    assert_nil result.fetch('syncedAt')
    assert_equal ['google'], @store.list.map(&:value)
    assert_equal 'MATCH,DIRECT', load_active.fetch('rules').last
    assert_equal [[:available]], @client.calls
  end

  def test_socket_disappearing_during_reload_keeps_changes_pending
    @client.fail_next(
      :reload_config,
      TabOutProxy::ClashUnavailableError.new('clash_unavailable', 'offline')
    )

    result = @service.call('add', 'type' => 'exact', 'value' => 'api.example.com')

    assert_equal 'pending', result.fetch('status')
    assert_equal ['api.example.com'], @store.list.map(&:value)
    assert_equal 'MATCH,DIRECT', load_active.fetch('rules').last
  end

  def test_reload_failure_restores_store_and_every_profile_file
    profile_before = profile_contents
    @client.fail_next(
      :reload_config,
      TabOutProxy::SyncError.new('clash_http_error', 'HTTP 500')
    )

    error = assert_raises(TabOutProxy::SyncError) do
      @service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    end

    assert_equal 'clash_http_error', error.code
    assert_empty @store.list
    assert_equal profile_before, profile_contents
    assert_operator @client.calls.count { |call| call.first == :reload_config }, :>=, 2
  end

  def test_refresh_failure_restores_a_removed_rule
    existing = @store.add(type: 'suffix', value: 'openai.com')
    @manager.ensure_integrated!
    @client.fail_next(
      :refresh_provider,
      TabOutProxy::SyncError.new('clash_http_error', 'HTTP 500')
    )

    assert_raises(TabOutProxy::SyncError) { @service.call('remove', 'id' => existing.id) }

    assert_equal [existing.id], @store.list.map(&:id)
  end

  def test_empty_provider_verification_rolls_back
    @client.provider_result = {}

    error = assert_raises(TabOutProxy::SyncError) do
      @service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    end

    assert_equal 'provider_verification_failed', error.code
    assert_empty @store.list
  end

  def test_provider_verification_rejects_nonempty_but_unhealthy_or_wrong_identity_responses
    invalid_responses = [
      { 'anything' => true },
      HEALTHY_PROVIDER.merge('name' => 'other-provider'),
      HEALTHY_PROVIDER.merge('vehicleType' => 'HTTP'),
      HEALTHY_PROVIDER.merge('behavior' => 'Domain'),
      HEALTHY_PROVIDER.merge('ruleCount' => 0)
    ]

    invalid_responses.each do |provider|
      client = FakeClient.new(provider_result: provider)
      service = build_service(client)
      error = assert_raises(TabOutProxy::SyncError) do
        service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
      end
      assert_equal 'provider_verification_failed', error.code
      assert_empty @store.list
    end
  end

  def test_failed_transaction_cannot_rollback_a_later_successful_transaction
    failing_client = BlockingFailClient.new
    successful_client = FakeClient.new
    failing_service = build_service(failing_client)
    successful_service = build_service(successful_client)
    failures = Queue.new
    successes = Queue.new

    first = Thread.new do
      failing_service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    rescue StandardError => error
      failures << error
    end
    failing_client.entered.pop

    second = Thread.new do
      successes << successful_service.call('add', 'type' => 'keyword', 'value' => 'google')
    rescue StandardError => error
      failures << error
    end

    begin
      sleep 0.15
      blocked_while_first_active = second.alive? && successful_client.calls.empty?
    ensure
      failing_client.release << true
      first.join(2)
      second.join(2)
    end

    assert blocked_while_first_active, 'second transaction was not serialized behind the first'
    assert_equal 'clash_http_error', failures.pop.code
    assert failures.empty?, 'successful transaction unexpectedly failed'
    assert_equal 'active', successes.pop.fetch('status')
    assert_equal ['google'], @store.list.map(&:value)
  ensure
    failing_client.release << true if failing_client && failing_client.release.empty?
    first.kill if first && first.alive?
    second.kill if second && second.alive?
  end

  def test_status_retries_pending_synchronization
    @client.online = false
    pending = @service.call('add', 'type' => 'suffix', 'value' => 'openai.com')
    assert_equal 'pending', pending.fetch('status')
    @client.calls.clear
    @client.online = true

    active = @service.call('status')

    assert_equal 'active', active.fetch('status')
    assert_equal '2026-09-16T08:30:00Z', active.fetch('syncedAt')
    assert_equal [:available, :reload_config, :refresh_provider, :provider], @client.calls.map(&:first)
  end

  def test_list_returns_only_public_rule_and_profile_data_without_contacting_clash
    @store.add(type: 'suffix', value: 'openai.com')

    result = @service.call('list')

    assert_equal 'stored', result.fetch('status')
    assert_nil result.fetch('syncedAt')
    assert_empty @client.calls
    assert_equal %w[createdAt id type value], result.fetch('rules').first.keys.sort
    assert_equal %w[profileId proxyGroup], result.fetch('profile').keys.sort
    refute_includes result.to_s, @clash_directory
    refute_includes result.to_s, 'redacted.invalid'
  end

  def test_unknown_command_and_missing_payload_are_validation_errors
    unknown = assert_raises(TabOutProxy::ValidationError) { @service.call('reload', {}) }
    assert_equal 'unknown_command', unknown.code

    invalid = assert_raises(TabOutProxy::ValidationError) { @service.call('add', 'type' => 'suffix') }
    assert_equal 'invalid_request', invalid.code
  end

  private

  def build_service(client)
    TabOutProxy::Service.new(
      store: @store,
      profile_manager: @manager,
      mihomo_client: client,
      clock: -> { FIXED_TIME }
    )
  end

  def prepare_clash_directory
    @clash_directory = File.join(@directory, 'clash')
    profiles = File.join(@clash_directory, 'profiles')
    FileUtils.mkdir_p(profiles)
    FileUtils.cp(File.join(FIXTURES, 'profiles.yaml'), File.join(@clash_directory, 'profiles.yaml'))
    FileUtils.cp(File.join(FIXTURES, 'active-config.yaml'), File.join(@clash_directory, 'clash-verge.yaml'))
    %w[remote-profile.json merge-override.yaml rules-override.yaml].each do |name|
      FileUtils.cp(File.join(FIXTURES, name), File.join(profiles, name))
    end
  end

  def profile_contents
    %w[profiles/merge-override.yaml profiles/rules-override.yaml clash-verge.yaml].to_h do |relative|
      [relative, File.binread(File.join(@clash_directory, relative))]
    end
  end

  def load_active
    YAML.safe_load(File.read(File.join(@clash_directory, 'clash-verge.yaml')))
  end
end
