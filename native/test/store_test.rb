# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'yaml'
require 'tab_out_proxy/store'

class StoreTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('tab-out-store-test')
    @store = TabOutProxy::Store.new(root: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def test_add_persists_authoritative_json_and_classical_provider_yaml
    rule = @store.add(type: 'suffix', value: 'https://OpenAI.com/path')

    state = JSON.parse(File.read(@store.state_path))
    provider = safe_yaml(@store.provider_path)
    assert_equal 1, state.fetch('version')
    assert_equal [rule.to_h], state.fetch('rules')
    assert_equal ['DOMAIN-SUFFIX,openai.com'], provider.fetch('payload')
    assert_equal [rule.id], @store.list.map(&:id)
  end

  def test_ensure_initialized_creates_an_empty_state_and_provider_once
    @store.ensure_initialized
    first_state = File.binread(@store.state_path)
    first_provider = File.binread(@store.provider_path)

    @store.ensure_initialized

    assert_equal({ 'version' => 1, 'synced' => false, 'rules' => [] }, JSON.parse(first_state))
    assert_equal({ 'payload' => [] }, YAML.safe_load(first_provider))
    assert_equal first_state, File.binread(@store.state_path)
    assert_equal first_provider, File.binread(@store.provider_path)
    refute File.exist?("#{@store.state_path}.bak")
  end

  def test_initial_list_is_read_only_and_sync_marker_resets_on_change
    refute @store.initialized?
    assert_empty @store.list
    refute File.exist?(@store.state_path)
    refute File.exist?(File.join(@directory, '.lock'))

    @store.add(type: 'suffix', value: 'openai.com')
    assert @store.initialized?
    refute @store.synced?
    @store.mark_synced!
    assert @store.synced?
    @store.add(type: 'keyword', value: 'google')
    refute @store.synced?
  end

  def test_ensure_initialized_repairs_provider_from_authoritative_json
    @store.add(type: 'suffix', value: 'openai.com')
    File.write(@store.provider_path, YAML.dump('payload' => ['DOMAIN,stale.example']))

    @store.ensure_initialized

    assert_equal ['openai.com'], @store.list.map(&:value)
    assert_equal ['DOMAIN-SUFFIX,openai.com'], safe_yaml(@store.provider_path).fetch('payload')
  end

  def test_duplicate_is_rejected_without_rewriting_files
    @store.add(type: 'keyword', value: 'google')
    before_state = File.binread(@store.state_path)
    before_provider = File.binread(@store.provider_path)

    error = assert_raises(TabOutProxy::ValidationError) do
      @store.add(type: 'keyword', value: 'GOOGLE')
    end

    assert_equal 'duplicate_rule', error.code
    assert_equal before_state, File.binread(@store.state_path)
    assert_equal before_provider, File.binread(@store.provider_path)
  end

  def test_remove_by_id_updates_both_files
    first = @store.add(type: 'exact', value: 'api.example.com')
    second = @store.add(type: 'keyword', value: 'google')

    removed = @store.remove(first.id)

    assert_equal first.id, removed.id
    assert_equal [second.id], @store.list.map(&:id)
    assert_equal ['DOMAIN-KEYWORD,google'], safe_yaml(@store.provider_path).fetch('payload')
  end

  def test_remove_rejects_an_unknown_id_without_rewriting
    @store.add(type: 'suffix', value: 'example.com')
    before = File.binread(@store.state_path)

    error = assert_raises(TabOutProxy::ValidationError) { @store.remove('missing') }

    assert_equal 'rule_not_found', error.code
    assert_equal before, File.binread(@store.state_path)
  end

  def test_each_replacement_keeps_previous_valid_files_as_backups
    first = @store.add(type: 'suffix', value: 'openai.com')
    @store.add(type: 'exact', value: 'api.example.com')

    backup_state = JSON.parse(File.read("#{@store.state_path}.bak"))
    backup_provider = YAML.safe_load(File.read("#{@store.provider_path}.bak"))
    assert_equal [first.id], backup_state.fetch('rules').map { |rule| rule.fetch('id') }
    assert_equal ['DOMAIN-SUFFIX,openai.com'], backup_provider.fetch('payload')
  end

  def test_restore_backup_restores_the_previous_state_and_provider
    first = @store.add(type: 'suffix', value: 'openai.com')
    @store.add(type: 'keyword', value: 'google')

    @store.restore_backup

    assert_equal [first.id], @store.list.map(&:id)
    assert_equal ['DOMAIN-SUFFIX,openai.com'], safe_yaml(@store.provider_path).fetch('payload')
  end

  def test_snapshot_can_restore_the_absence_of_files_after_first_mutation
    snapshot = @store.snapshot
    @store.add(type: 'suffix', value: 'openai.com')

    @store.restore(snapshot)

    refute File.exist?(@store.state_path)
    refute File.exist?(@store.provider_path)
    assert_empty @store.list
  end

  def test_corrupt_or_unsupported_state_is_rejected
    FileUtils.mkdir_p(@directory)
    File.write(@store.state_path, '{not-json')
    assert_store_error('invalid_state') { @store.list }

    File.write(@store.state_path, JSON.generate('version' => 2, 'rules' => []))
    assert_store_error('unsupported_state') { @store.list }
  end

  def test_transaction_lock_blocks_another_process_until_release
    ready_reader, ready_writer = IO.pipe
    entered_reader, entered_writer = IO.pipe
    child_pid = nil

    @store.with_transaction_lock do
      child_pid = fork do
        ready_reader.close
        entered_reader.close
        ready_writer.write('ready')
        ready_writer.close
        @store.with_transaction_lock { entered_writer.write('entered') }
        entered_writer.close
        exit! 0
      end

      ready_writer.close
      entered_writer.close
      assert_equal 'ready', ready_reader.read(5)
      refute IO.select([entered_reader], nil, nil, 0.15), 'child entered while parent held transaction lock'
    end

    assert IO.select([entered_reader], nil, nil, 2), 'child did not enter after transaction lock release'
    assert_equal 'entered', entered_reader.read
    Process.wait(child_pid)
    assert_predicate $?, :success?
  ensure
    [ready_reader, ready_writer, entered_reader, entered_writer].compact.each do |io|
      io.close unless io.closed?
    end
    if child_pid
      Process.kill('KILL', child_pid) rescue nil
      Process.wait(child_pid) rescue nil
    end
  end

  private

  def safe_yaml(path)
    YAML.safe_load(File.read(path))
  end

  def assert_store_error(code)
    error = assert_raises(TabOutProxy::PersistenceError) { yield }
    assert_equal code, error.code
  end
end
