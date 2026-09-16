# frozen_string_literal: true

require 'json'
require_relative 'errors'

module TabOutProxy
  module Protocol
    PROTOCOL_VERSION = 1
    MAX_MESSAGE_SIZE = 1024 * 1024
    module_function

    def read(io)
      header = read_exact(io, 4)
      raise ProtocolError.new('invalid_frame', 'Native message header is incomplete') unless header

      length = header.unpack1('L<')
      if length > MAX_MESSAGE_SIZE
        raise ProtocolError.new('message_too_large', 'Native message exceeds the 1 MiB limit')
      end

      payload = read_exact(io, length)
      raise ProtocolError.new('invalid_frame', 'Native message payload is incomplete') unless payload

      JSON.parse(payload)
    rescue JSON::ParserError
      raise ProtocolError.new('invalid_json', 'Native message is not valid JSON')
    end

    def write(io, object)
      payload = JSON.generate(object)
      if payload.bytesize > MAX_MESSAGE_SIZE
        raise ProtocolError.new('message_too_large', 'Native response exceeds the 1 MiB limit')
      end

      io.write([payload.bytesize].pack('L<'))
      io.write(payload)
      io.flush if io.respond_to?(:flush)
      true
    end

    def validate_request(message)
      unless message.is_a?(Hash)
        raise ProtocolError.new('invalid_request', 'Native request must be a JSON object')
      end
      unless message['protocolVersion'] == PROTOCOL_VERSION
        raise ProtocolError.new('protocol_mismatch', 'Native messaging protocol version is not supported')
      end

      command = message['command']
      payload = message.key?('payload') ? message['payload'] : {}
      unless command.is_a?(String) && !command.empty? && payload.is_a?(Hash)
        raise ProtocolError.new('invalid_request', 'Native request command or payload is invalid')
      end
      [command, payload]
    end

    def success(data)
      {
        'ok' => true,
        'protocolVersion' => PROTOCOL_VERSION,
        'data' => data
      }
    end

    def failure(error)
      public_error = if error.is_a?(Error)
                       error
                     else
                       Error.new('internal_error', 'Native helper encountered an internal error')
                     end
      {
        'ok' => false,
        'protocolVersion' => PROTOCOL_VERSION,
        'error' => {
          'code' => public_error.code,
          'message' => public_error.message
        }
      }
    end

    def read_exact(io, length)
      return +'' if length.zero?

      result = +''
      while result.bytesize < length
        chunk = io.read(length - result.bytesize)
        return nil if chunk.nil? || chunk.empty?

        result << chunk
      end
      result
    end
    private_class_method :read_exact
  end
end
