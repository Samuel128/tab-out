# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require_relative 'atomic_file'
require_relative 'errors'
require_relative 'private_routing'

module TabOutProxy
  class ProfileManager
    PROVIDER_RULE = 'RULE-SET,need-proxy,PROXY'
    SOURCE_TERMINAL = 'MATCH,PROXY'
    TARGET_TERMINAL = 'MATCH,DIRECT'

    attr_reader :active_config_path

    def initialize(config_dir:, provider_path:)
      @config_dir = File.expand_path(config_dir)
      @profiles_dir = File.join(@config_dir, 'profiles')
      @profiles_path = File.join(@config_dir, 'profiles.yaml')
      @active_config_path = File.join(@config_dir, 'clash-verge.yaml')
      @provider_path = File.expand_path(provider_path)
    end

    def profile_info
      context = discover
      validate_remote_profile!(context.fetch(:remote))
      public_profile(context)
    end

    def ensure_integrated!
      context = discover
      validate_remote_profile!(context.fetch(:remote))
      validate_active_config!(context.fetch(:active))
      snapshot = capture_snapshot(context.fetch(:managed_paths))

      merge = integrated_merge(context.fetch(:merge))
      rules = integrated_rule_override(context.fetch(:rules))
      active = integrated_active(context.fetch(:active))

      write_yaml_if_changed(context.fetch(:merge_path), merge)
      write_yaml_if_changed(context.fetch(:rules_path), rules)
      write_yaml_if_changed(active_config_path, active)

      public_profile(context).merge('activeConfigPath' => active_config_path)
    rescue StandardError => error
      restore_snapshot(snapshot) if defined?(snapshot) && snapshot
      raise error if error.is_a?(Error)

      raise UnsupportedProfileError.new('profile_write_failed', "Could not update Clash profile: #{error.class}")
    end

    def snapshot
      context = discover
      capture_snapshot(context.fetch(:managed_paths))
    end

    def restore(snapshot)
      restore_snapshot(snapshot)
    end

    def restore_backups!
      context = discover
      paths = context.fetch(:managed_paths)
      paths.each { |path| assert_safe_path!("#{path}.bak") }
      unless paths.all? { |path| File.exist?("#{path}.bak") }
        raise UnsupportedProfileError.new('profile_backup_missing', 'A complete Clash profile backup is not available')
      end

      paths.each { |path| AtomicFile.restore_backup(path) }
      true
    rescue SystemCallError => error
      raise UnsupportedProfileError.new('profile_restore_failed', "Could not restore Clash profile: #{error.class}")
    end

    private

    def discover
      registry = read_mapping(@profiles_path, 'profiles_registry_invalid')
      items = registry['items']
      current_id = registry['current']
      unless current_id.is_a?(String) && items.is_a?(Array)
        unsupported!('profiles_registry_invalid', 'Clash profile registry has an unsupported shape')
      end

      current = unique_item(items, current_id, 'current_profile_invalid')
      unless current['type'] == 'remote' && current['file'].is_a?(String) && current['option'].is_a?(Hash)
        unsupported!('current_profile_invalid', 'Current Clash profile has an unsupported shape')
      end

      merge_item = unique_item(items, current['option']['merge'], 'merge_override_missing')
      rules_item = unique_item(items, current['option']['rules'], 'rules_override_missing')
      unless merge_item['file'].is_a?(String) && rules_item['file'].is_a?(String)
        unsupported!('override_file_missing', 'Current Clash profile override files are unavailable')
      end

      remote_path = safe_profile_path(current['file'])
      merge_path = safe_profile_path(merge_item['file'])
      rules_path = safe_profile_path(rules_item['file'])
      {
        profile_id: current_id,
        remote: read_mapping(remote_path, 'remote_profile_invalid'),
        merge: read_mapping(merge_path, 'merge_override_invalid'),
        rules: read_mapping(rules_path, 'rules_override_invalid'),
        active: read_mapping(active_config_path, 'active_config_invalid'),
        merge_path: merge_path,
        rules_path: rules_path,
        managed_paths: [merge_path, rules_path, active_config_path]
      }
    end

    def unique_item(items, uid, code)
      unless uid.is_a?(String) && !uid.empty?
        unsupported!(code, 'Current Clash profile references an invalid item')
      end
      matches = items.select { |item| item.is_a?(Hash) && item['uid'] == uid }
      unsupported!(code, 'Current Clash profile item is missing or ambiguous') unless matches.length == 1
      matches.first
    end

    def safe_profile_path(name)
      path = File.expand_path(name, @profiles_dir)
      prefix = "#{@profiles_dir}#{File::SEPARATOR}"
      unsupported!('unsafe_profile_path', 'Current Clash profile contains an unsafe file reference') unless path.start_with?(prefix)
      path
    end

    def read_mapping(path, code)
      assert_safe_path!(path)
      content = File.binread(path)
      value = YAML.safe_load(content)
      unsupported!(code, 'Clash configuration has an unsupported shape') unless value.is_a?(Hash)
      value
    rescue Errno::ENOENT, Errno::EACCES, Psych::SyntaxError
      unsupported!(code, 'Required Clash configuration is unavailable or invalid')
    end

    def validate_remote_profile!(remote)
      groups = remote['proxy-groups']
      rules = remote['rules']
      unless groups.is_a?(Array) && rules.is_a?(Array) && rules.all? { |rule| rule.is_a?(String) }
        unsupported!('remote_profile_invalid', 'Current remote profile has an unsupported shape')
      end

      proxy_groups = groups.select { |group| group.is_a?(Hash) && group['name'] == 'PROXY' }
      unsupported!('proxy_group_missing', 'Current profile does not define an exact PROXY group') if proxy_groups.empty?
      unsupported!('proxy_group_ambiguous', 'Current profile defines more than one PROXY group') if proxy_groups.length > 1

      has_private_direct = rules.any? do |rule|
        rule.match?(/\AIP-CIDR6?,(?:10\.|127\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.|192\.168\.|::1|fc|fd|fe80).*DIRECT/i)
      end
      unless rules.last == SOURCE_TERMINAL && has_private_direct
        unsupported!('unsupported_rule_shape', 'Current profile rules cannot be safely converted to direct-by-default')
      end
    end

    def validate_active_config!(active)
      rules = active['rules']
      unless rules.is_a?(Array) && rules.all? { |rule| rule.is_a?(String) } &&
             [SOURCE_TERMINAL, TARGET_TERMINAL].include?(rules.last)
        unsupported!('active_config_invalid', 'Active Clash rules have an unsupported shape')
      end
    end

    def integrated_merge(original)
      merge = deep_copy(original)
      providers = optional_mapping(
        merge,
        'rule-providers',
        'merge_provider_container_invalid'
      )
      merge['rule-providers'] = providers
      validate_managed_provider!(providers)
      providers['need-proxy'] = provider_definition
      merge
    end

    def integrated_rule_override(original)
      rules = deep_copy(original)
      prepend = array_of_strings(rules['prepend'], 'rules_override_invalid')
      delete = array_of_strings(rules['delete'], 'rules_override_invalid')
      append = array_of_strings(rules['append'], 'rules_override_invalid')
      managed = PrivateRouting.direct_rules + [PROVIDER_RULE]

      rules['prepend'] = managed + prepend.reject do |rule|
        managed.include?(rule) || terminal_rule?(rule)
      end
      rules['delete'] = (delete.reject { |rule| rule == TARGET_TERMINAL } + [SOURCE_TERMINAL]).uniq
      rules['append'] = append.reject { |rule| terminal_rule?(rule) } + [TARGET_TERMINAL]
      rules
    end

    def integrated_active(original)
      active = deep_copy(original)
      providers = optional_mapping(
        active,
        'rule-providers',
        'active_provider_container_invalid'
      )
      active['rule-providers'] = providers
      validate_managed_provider!(providers)
      providers['need-proxy'] = provider_definition

      managed = PrivateRouting.direct_rules + [PROVIDER_RULE]
      preserved = active.fetch('rules').reject do |rule|
        managed.include?(rule) || rule.match?(/\AMATCH,/)
      end
      active['rules'] = managed + preserved + [TARGET_TERMINAL]
      active
    end

    def provider_definition
      {
        'type' => 'file',
        'behavior' => 'classical',
        'format' => 'yaml',
        'path' => @provider_path
      }
    end

    def validate_managed_provider!(providers)
      return unless providers.key?('need-proxy')
      return if providers['need-proxy'] == provider_definition

      unsupported!('provider_collision', 'An unrelated need-proxy provider already exists')
    end

    def assert_safe_path!(path)
      current = File.expand_path(path)
      loop do
        unsupported!('unsafe_profile_path', 'Clash configuration contains a symlinked path') if File.symlink?(current)
        break if current == @config_dir

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
    end

    def array_of_strings(value, code)
      return [] if value.nil?
      return value if value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }

      unsupported!(code, 'Clash rule override has an unsupported shape')
    end

    def optional_mapping(parent, key, code)
      value = parent[key]
      return {} if value.nil?
      return value if value.is_a?(Hash)

      unsupported!(code, 'Clash configuration contains an unsafe managed container')
    end

    def terminal_rule?(rule)
      rule.start_with?('MATCH,')
    end

    def write_yaml_if_changed(path, value)
      assert_safe_path!(path)
      assert_safe_path!("#{path}.bak")
      content = YAML.dump(value)
      return if File.exist?(path) && File.binread(path) == content

      AtomicFile.write(path, content)
    end

    def capture_snapshot(paths)
      paths.each_with_object({}) do |path, snapshot|
        assert_safe_path!(path)
        snapshot[path] = File.exist?(path) ? File.binread(path) : nil
      end
    end

    def restore_snapshot(snapshot)
      snapshot.each do |path, content|
        assert_safe_path!(path)
        if content.nil?
          FileUtils.rm_f(path)
        else
          AtomicFile.replace(path, content, backup: false)
        end
      end
      true
    rescue StandardError => error
      raise UnsupportedProfileError.new('profile_restore_failed', "Could not restore Clash profile: #{error.class}")
    end

    def public_profile(context)
      {
        'profileId' => context.fetch(:profile_id),
        'proxyGroup' => 'PROXY'
      }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def unsupported!(code, message)
      raise UnsupportedProfileError.new(code, message)
    end
  end
end
