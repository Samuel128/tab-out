# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'atomic_file'
require_relative 'errors'
require_relative 'rule'

module TabOutProxy
  class Store
    VERSION = 1

    attr_reader :state_path, :provider_path

    def initialize(root:, provider_path: nil)
      @root = File.expand_path(root)
      @state_path = File.join(@root, 'state.json')
      @provider_path = File.expand_path(provider_path || File.join(@root, 'need-proxy.yaml'))
      @lock_path = File.join(@root, '.lock')
      @transaction_lock_path = File.join(@root, '.transaction.lock')
    end

    def with_transaction_lock
      FileUtils.mkdir_p(@root)
      File.open(@transaction_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def list
      return [] unless File.exist?(state_path)

      with_lock { load_rules }
    end

    def initialized?
      File.exist?(state_path)
    end

    def synced?
      return false unless initialized?

      with_lock do
        state = JSON.parse(File.binread(state_path))
        parse_state(JSON.generate(state))
        state['synced'] == true
      end
    rescue JSON::ParserError
      raise PersistenceError.new('invalid_state', 'Rule state is not valid JSON rule data')
    end

    def mark_synced!
      with_lock do
        state = JSON.parse(File.binread(state_path))
        parse_state(JSON.generate(state))
        return if state['synced'] == true

        state['synced'] = true
        AtomicFile.write(state_path, JSON.pretty_generate(state) + "\n")
      end
    rescue JSON::ParserError
      raise PersistenceError.new('invalid_state', 'Rule state is not valid JSON rule data')
    end

    def ensure_initialized
      with_lock do
        rules = load_rules
        expected_provider = provider_content(rules)
        if File.exist?(state_path)
          return if File.exist?(provider_path) && File.binread(provider_path) == expected_provider

          AtomicFile.write(provider_path, expected_provider)
        else
          persist(rules)
        end
      end
      true
    end

    def add(type:, value:)
      with_lock do
        rules = load_rules
        rule = Rule.build(type: type, value: value)
        if rules.any? { |existing| existing.id == rule.id }
          raise ValidationError.new('duplicate_rule', 'This proxy rule already exists')
        end

        persist(rules + [rule])
        rule
      end
    end

    def remove(id)
      with_lock do
        rules = load_rules
        removed = rules.find { |rule| rule.id == id.to_s }
        raise ValidationError.new('rule_not_found', 'Proxy rule was not found') unless removed

        persist(rules.reject { |rule| rule.id == removed.id })
        removed
      end
    end

    def snapshot
      with_lock { capture_snapshot }
    end

    def restore(snapshot)
      with_lock { restore_snapshot(snapshot) }
    end

    def restore_backup
      with_lock do
        state_backup = "#{state_path}.bak"
        provider_backup = "#{provider_path}.bak"
        unless File.exist?(state_backup) && File.exist?(provider_backup)
          raise PersistenceError.new('backup_not_found', 'A complete rule backup is not available')
        end

        parse_state(File.binread(state_backup))
        validate_provider(File.binread(provider_backup))
        AtomicFile.restore_backup(state_path)
        AtomicFile.restore_backup(provider_path)
      end
    rescue SystemCallError => error
      raise PersistenceError.new('restore_failed', "Could not restore rule backup: #{error.class}")
    end

    private

    def with_lock
      FileUtils.mkdir_p(@root)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def load_rules
      return [] unless File.exist?(state_path)

      parse_state(File.binread(state_path))
    end

    def parse_state(content)
      state = JSON.parse(content)
      unless state.is_a?(Hash) && state['version'] == VERSION && state['rules'].is_a?(Array)
        raise PersistenceError.new('unsupported_state', 'Rule state has an unsupported shape or version')
      end

      state['rules'].map do |entry|
        unless entry.is_a?(Hash)
          raise PersistenceError.new('invalid_state', 'Rule state contains an invalid entry')
        end

        rule = Rule.build(
          type: entry.fetch('type'),
          value: entry.fetch('value'),
          created_at: entry.fetch('createdAt')
        )
        unless entry.fetch('id') == rule.id
          raise PersistenceError.new('invalid_state', 'Rule state contains an invalid identifier')
        end
        rule
      end
    rescue JSON::ParserError, KeyError, ValidationError
      raise PersistenceError.new('invalid_state', 'Rule state is not valid JSON rule data')
    end

    def persist(rules)
      state = JSON.pretty_generate(
        'version' => VERSION,
        'synced' => false,
        'rules' => rules.map(&:to_h)
      ) + "\n"
      provider = provider_content(rules)
      previous = capture_snapshot

      AtomicFile.write(state_path, state)
      AtomicFile.write(provider_path, provider)
    rescue StandardError => error
      restore_snapshot(previous) if previous
      raise error if error.is_a?(Error)

      raise PersistenceError.new('write_failed', "Could not persist proxy rules: #{error.class}")
    end

    def validate_provider(content)
      provider = YAML.safe_load(content)
      unless provider.is_a?(Hash) && provider['payload'].is_a?(Array)
        raise PersistenceError.new('invalid_backup', 'Rule provider backup is invalid')
      end
    rescue Psych::SyntaxError
      raise PersistenceError.new('invalid_backup', 'Rule provider backup is invalid')
    end

    def provider_content(rules)
      YAML.dump('payload' => rules.map(&:provider_line))
    end

    def managed_paths
      [state_path, provider_path, "#{state_path}.bak", "#{provider_path}.bak"]
    end

    def capture_snapshot
      managed_paths.each_with_object({}) do |path, result|
        result[path] = File.exist?(path) ? File.binread(path) : nil
      end
    end

    def restore_snapshot(snapshot)
      managed_paths.each do |path|
        content = snapshot[path]
        if content.nil?
          FileUtils.rm_f(path)
        else
          AtomicFile.replace(path, content, backup: false)
        end
      end
    rescue StandardError => error
      raise PersistenceError.new('restore_failed', "Could not restore proxy rules: #{error.class}")
    end
  end
end
