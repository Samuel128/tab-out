# frozen_string_literal: true

require 'json'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'yaml'
require_relative 'errors'

module TabOutProxy
  class MihomoClient
    def self.local_socket_paths(override: nil, uid: Process.uid, tmpdir: Dir.tmpdir)
      return [File.expand_path(override)] unless override.nil?

      [
        "/var/run/clash-verge-service/users/#{Integer(uid)}/verge-mihomo.sock",
        File.join(tmpdir, 'verge-mihomo.sock'),
        '/tmp/verge/verge-mihomo.sock'
      ].uniq
    end

    def initialize(socket_path:, fallback_socket_paths: [])
      @socket_paths = ([socket_path] + fallback_socket_paths).map { |path| File.expand_path(path) }.uniq
    end

    def available?
      request('GET', '/version')
      true
    rescue ClashUnavailableError
      false
    end

    def proxy_available?(port)
      return false unless port.is_a?(Integer) && port.between?(1, 65_535)

      # Both the Clash API and HTTP listener must be alive, not just its app process.
      Timeout.timeout(1.5) do
        return false unless available?

        Socket.tcp('127.0.0.1', port, connect_timeout: 0.5) { |_connection| true }
      end
    rescue Timeout::Error, SystemCallError, IOError, Error
      false
    end

    def reload_config(active_config_path, inline_rules: nil)
      request('PUT', '/configs?force=true', 'path' => File.expand_path(active_config_path))
    rescue SyncError => error
      raise unless error.code == 'clash_path_restricted' && inline_rules

      payload = inline_config(active_config_path, inline_rules)
      request('PUT', '/configs?force=true', 'payload' => payload)
      { 'inlineProvider' => true }
    end

    def refresh_provider(name)
      request('PUT', "/providers/rules/#{provider_name(name)}")
    end

    def provider(name)
      selected = provider_name(name)
      response = request('GET', '/providers/rules')
      providers = response.is_a?(Hash) ? response['providers'] : nil
      providers.is_a?(Hash) ? providers[selected] : nil
    end

    private

    def inline_config(path, rules)
      unless rules.is_a?(Array) && rules.length <= 2000 && rules.all? { |r| r.is_a?(String) && r.length <= 300 && r.match?(/\ADOMAIN(?:-SUFFIX|-KEYWORD)?,[a-z0-9.:-]+\z/) }
        raise ValidationError.new('invalid_inline_rules', 'Inline whitelist rules are invalid')
      end
      raise ValidationError.new('config_too_large', 'Clash configuration exceeds the inline limit') if File.size(path) > 4 * 1024 * 1024

      config = YAML.safe_load(File.binread(path))
      provider = config.is_a?(Hash) && config.dig('rule-providers', 'need-proxy')
      unless provider.is_a?(Hash) && provider['type'] == 'file' && provider['behavior'] == 'classical'
        raise ValidationError.new('invalid_inline_config', 'Expected the managed classical file provider')
      end
      # Service mode restricts file paths. Use supported inline data, never expand SAFE_PATHS.
      config['rule-providers']['need-proxy'] = { 'type' => 'inline', 'behavior' => 'classical', 'payload' => rules }
      YAML.dump(config)
    rescue SystemCallError, Psych::Exception
      raise ValidationError.new('invalid_inline_config', 'Could not read the validated local Clash configuration')
    end

    def connect_socket
      @socket_paths.each do |path|
        begin
          return UNIXSocket.new(path)
        rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ENOTSOCK, Errno::EACCES
          next
        end
      end
      raise ClashUnavailableError.new('clash_unavailable', 'Clash is not available through its local socket')
    end

    def provider_name(name)
      value = name.to_s
      unless value.match?(/\A[a-z0-9-]+\z/)
        raise ValidationError.new('invalid_provider', 'Provider name is invalid')
      end
      value
    end

    def request(method, path, payload = nil)
      body = payload.nil? ? '' : JSON.generate(payload)
      socket = connect_socket
      socket.write(build_request(method, path, body))
      response = socket.read
      parse_response(response)
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Errno::ENOTSOCK
      raise ClashUnavailableError.new('clash_unavailable', 'Clash is not available through its local socket')
    ensure
      socket.close if defined?(socket) && socket && !socket.closed?
    end

    def build_request(method, path, body)
      headers = [
        "#{method} #{path} HTTP/1.1",
        'Host: localhost',
        'Accept: application/json',
        'Content-Type: application/json',
        "Content-Length: #{body.bytesize}",
        'Connection: close'
      ]
      "#{headers.join("\r\n")}\r\n\r\n#{body}"
    end

    def parse_response(response)
      head, body = response.to_s.split("\r\n\r\n", 2)
      lines = head.to_s.split("\r\n")
      status_match = lines.shift.to_s.match(/\AHTTP\/1\.[01] (\d{3})(?: |\z)/)
      unless status_match
        raise SyncError.new('clash_invalid_response', 'Clash returned an invalid HTTP response')
      end

      status = status_match[1].to_i
      headers = lines.each_with_object({}) do |line, result|
        name, value = line.split(':', 2)
        result[name.to_s.downcase] = value.to_s.strip
      end
      unless status.between?(200, 299)
        if status == 400
          detail = JSON.parse(body.to_s) rescue nil
          if detail.is_a?(Hash) && detail['message'].is_a?(String) && detail['message'].include?('path is not subpath of home directory')
            raise SyncError.new('clash_path_restricted', 'Clash service mode rejected a configuration outside its working directory')
          end
        end
        raise SyncError.new('clash_http_error', "Clash API returned HTTP #{status}")
      end

      decoded = headers['transfer-encoding'].to_s.downcase == 'chunked' ? decode_chunked(body.to_s) : body.to_s
      return {} if decoded.empty?

      JSON.parse(decoded)
    rescue JSON::ParserError
      raise SyncError.new('clash_invalid_response', 'Clash returned invalid JSON')
    end

    def decode_chunked(body)
      decoded = +''
      offset = 0
      loop do
        line_end = body.index("\r\n", offset)
        raise SyncError.new('clash_invalid_response', 'Clash returned invalid chunked data') unless line_end

        size_text = body[offset...line_end].split(';', 2).first
        raise SyncError.new('clash_invalid_response', 'Clash returned invalid chunked data') unless size_text.match?(/\A[0-9a-fA-F]+\z/)

        size = size_text.to_i(16)
        return decoded if size.zero?

        start = line_end + 2
        finish = start + size
        unless body.bytesize >= finish + 2 && body[finish, 2] == "\r\n"
          raise SyncError.new('clash_invalid_response', 'Clash returned truncated chunked data')
        end
        decoded << body.byteslice(start, size)
        offset = finish + 2
      end
    end
  end
end
