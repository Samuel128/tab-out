# frozen_string_literal: true

require 'json'
require 'socket'
require_relative 'errors'

module TabOutProxy
  class MihomoClient
    def initialize(socket_path:)
      @socket_path = File.expand_path(socket_path)
    end

    def available?
      request('GET', '/version')
      true
    rescue ClashUnavailableError
      false
    end

    def reload_config(active_config_path)
      request('PUT', '/configs?force=true', 'path' => File.expand_path(active_config_path))
    end

    def refresh_provider(name)
      request('PUT', "/providers/rules/#{provider_name(name)}")
    end

    def provider(name)
      request('GET', "/providers/rules/#{provider_name(name)}")
    end

    private

    def provider_name(name)
      value = name.to_s
      unless value.match?(/\A[a-z0-9-]+\z/)
        raise ValidationError.new('invalid_provider', 'Provider name is invalid')
      end
      value
    end

    def request(method, path, payload = nil)
      body = payload.nil? ? '' : JSON.generate(payload)
      socket = UNIXSocket.new(@socket_path)
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
