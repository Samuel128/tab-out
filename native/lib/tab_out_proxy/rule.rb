# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require 'time'
require 'uri'
require_relative 'errors'

module TabOutProxy
  class Rule
    TYPES = {
      'suffix' => 'DOMAIN-SUFFIX',
      'keyword' => 'DOMAIN-KEYWORD',
      'exact' => 'DOMAIN'
    }.freeze
    CORPORATE_SUFFIXES = %w[internal.example corp.example].freeze
    CORPORATE_KEYWORD_MARKERS = %w[internal corp].freeze
    PUBLIC_SUFFIX_ONLY = %w[
      com net org edu gov mil int io ai app dev cloud xyz top
      cn com.cn net.cn org.cn uk co.uk jp co.jp local
    ].freeze
    PRIVATE_RANGES = %w[
      10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.168.0.0/16 ::1/128 fc00::/7 fe80::/10
    ].map { |cidr| IPAddr.new(cidr) }.freeze
    PRIVATE_KEYWORD_TARGETS = (
      %w[localhost 10. 127. 169.254 192.168 ::1 fe80 fc00 fd00] +
      (16..31).map { |octet| "172.#{octet}" }
    ).freeze

    attr_reader :id, :type, :value, :created_at

    def self.build(type:, value:, created_at: Time.now.utc.iso8601)
      new(type: type, value: value, created_at: created_at)
    end

    def initialize(type:, value:, created_at:)
      @type = type.to_s
      unless TYPES.key?(@type)
        raise ValidationError.new('invalid_type', 'Match type must be suffix, keyword, or exact')
      end

      @value = normalize(value.to_s)
      validate!
      @id = Digest::SHA256.hexdigest("#{@type}:#{@value}")[0, 20]
      @created_at = created_at.to_s
    end

    def provider_line
      "#{TYPES.fetch(type)},#{value}"
    end

    def to_h
      {
        'id' => id,
        'type' => type,
        'value' => value,
        'createdAt' => created_at
      }
    end

    private

    def normalize(raw)
      text = raw.strip.downcase.sub(/\.+\z/, '')
      return text if text.empty?
      return text if ip_address?(text)

      url_like = text.include?('://') || text.include?('/') || text.include?(':')
      return text if type == 'keyword' && !url_like

      candidate = text.sub(/\A\*\./, '')
      uri = URI.parse(candidate.include?('://') ? candidate : "https://#{candidate}")
      host = uri.host.to_s.downcase.sub(/\.+\z/, '')
      host.empty? ? text : host
    rescue URI::InvalidURIError
      text
    end

    def validate!
      raise ValidationError.new('empty_value', 'Rule value cannot be empty') if value.empty?
      if type == 'keyword' && value.length < 3
        raise ValidationError.new('short_keyword', 'Keyword rules require at least 3 characters')
      end
      if PUBLIC_SUFFIX_ONLY.include?(value)
        raise ValidationError.new('public_suffix', 'A public suffix alone is too broad')
      end
      if corporate_target?
        raise ValidationError.new('corporate_target', 'Corporate domains must remain direct')
      end
      if type == 'keyword' && private_keyword_target?
        raise ValidationError.new('private_target', 'Keywords that can match private addresses are not allowed')
      end

      ip = parse_ip(value)
      if ip && PRIVATE_RANGES.any? { |range| range.include?(ip) }
        raise ValidationError.new('private_target', 'Private and local addresses must remain direct')
      end
      if value == 'localhost' || value.end_with?('.localhost')
        raise ValidationError.new('private_target', 'Private and local addresses must remain direct')
      end

      return if ip

      valid = type == 'keyword' ? valid_keyword? : valid_hostname?
      raise ValidationError.new('invalid_domain', 'Domain contains unsupported characters') unless valid
    end

    def corporate_target?
      if type == 'keyword'
        CORPORATE_KEYWORD_MARKERS.any? do |marker|
          marker.include?(value) || value.include?(marker)
        end
      else
        CORPORATE_SUFFIXES.any? { |suffix| value == suffix || value.end_with?(".#{suffix}") }
      end
    end

    def valid_keyword?
      value.match?(/\A[a-z0-9.-]+\z/) && !value.include?('..')
    end

    def private_keyword_target?
      PRIVATE_KEYWORD_TARGETS.any? do |target|
        target.include?(value) || value.include?(target)
      end
    end

    def valid_hostname?
      return false if value.length > 253 || !value.include?('.') || value.include?('..')

      value.split('.').all? do |label|
        label.length.between?(1, 63) &&
          label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
      end
    end

    def ip_address?(text)
      !parse_ip(text).nil?
    end

    def parse_ip(text)
      IPAddr.new(text)
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end
