# frozen_string_literal: true

require 'yaml'
require_relative 'errors'

module TabOutProxy
  class PrivateRouting
    RULE_PATTERN = /\A(?:PROCESS-NAME|DOMAIN-SUFFIX),[a-zA-Z0-9.-]+,DIRECT\z/

    def self.path
      home = ENV.fetch('TAB_OUT_PROXY_HOME', File.join(Dir.home, 'Library', 'Application Support', 'Tab Out Proxy'))
      File.expand_path(ENV.fetch('TAB_OUT_PRIVATE_ROUTING_PATH', File.join(home, 'private-routing.yaml')))
    end

    def self.direct_rules
      file = path
      stat = File.lstat(file)
      unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise UnsupportedProfileError.new('private_routing_unsafe', 'Private routing file must be owned by you and readable only by you')
      end
      data = YAML.safe_load(File.binread(file))
      rules = data.is_a?(Hash) && data['direct_rules']
      unless rules.is_a?(Array) && !rules.empty? && rules.all? { |rule| rule.is_a?(String) && rule.match?(RULE_PATTERN) }
        raise UnsupportedProfileError.new('private_routing_invalid', 'Private routing file has invalid direct rules')
      end
      rules.uniq
    rescue Errno::ENOENT, Errno::EACCES
      raise UnsupportedProfileError.new('private_routing_missing', 'Configure the local private routing file before using proxy routing')
    rescue Psych::SyntaxError
      raise UnsupportedProfileError.new('private_routing_invalid', 'Private routing file is not valid YAML')
    end

    def self.domain_suffixes
      direct_rules.each_with_object([]) do |rule, suffixes|
        type, value = rule.split(',', 3)
        suffixes << value.downcase if type == 'DOMAIN-SUFFIX'
      end
    end

    def self.keyword_markers
      domain_suffixes.map { |suffix| suffix.split('.').first }.uniq
    end
  end
end
