# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'stringio'
require 'tab_out_proxy/protocol'

class ProtocolTest < Minitest::Test
  def test_read_consumes_little_endian_native_messaging_frame
    payload = JSON.generate('protocolVersion' => 1, 'command' => 'list', 'payload' => {})
    io = StringIO.new([payload.bytesize].pack('L<') + payload)

    message = TabOutProxy::Protocol.read(io)

    assert_equal 'list', message.fetch('command')
  end

  def test_write_emits_exactly_one_little_endian_frame
    io = StringIO.new(+'')
    object = { 'ok' => true, 'protocolVersion' => 1, 'data' => { 'status' => 'active' } }

    TabOutProxy::Protocol.write(io, object)

    io.rewind
    length = io.read(4).unpack1('L<')
    assert_equal length, io.string.bytesize - 4
    assert_equal object, JSON.parse(io.read(length))
    assert_equal '', io.read.to_s
  end

  def test_malformed_json_is_rejected_with_stable_code
    error = assert_raises(TabOutProxy::ProtocolError) do
      TabOutProxy::Protocol.read(StringIO.new([5].pack('L<') + '{bad}'))
    end
    assert_equal 'invalid_json', error.code
  end

  def test_oversized_input_is_rejected_before_payload_is_read
    io = CountingIO.new([TabOutProxy::Protocol::MAX_MESSAGE_SIZE + 1].pack('L<'))

    error = assert_raises(TabOutProxy::ProtocolError) { TabOutProxy::Protocol.read(io) }

    assert_equal 'message_too_large', error.code
    assert_equal [4], io.read_sizes
  end

  def test_truncated_header_and_payload_are_rejected
    header_error = assert_raises(TabOutProxy::ProtocolError) do
      TabOutProxy::Protocol.read(StringIO.new("\x01\x00"))
    end
    assert_equal 'invalid_frame', header_error.code

    payload_error = assert_raises(TabOutProxy::ProtocolError) do
      TabOutProxy::Protocol.read(StringIO.new([12].pack('L<') + '{}'))
    end
    assert_equal 'invalid_frame', payload_error.code
  end

  def test_request_validation_requires_supported_version_command_and_payload
    valid = TabOutProxy::Protocol.validate_request(
      'protocolVersion' => 1,
      'command' => 'status',
      'payload' => {}
    )
    assert_equal ['status', {}], valid

    assert_protocol_error('protocol_mismatch') do
      TabOutProxy::Protocol.validate_request('protocolVersion' => 2, 'command' => 'status')
    end
    assert_protocol_error('invalid_request') do
      TabOutProxy::Protocol.validate_request(['status'])
    end
    assert_protocol_error('invalid_request') do
      TabOutProxy::Protocol.validate_request('protocolVersion' => 1, 'command' => '', 'payload' => [])
    end
  end

  def test_success_and_error_envelopes_are_stable
    success = TabOutProxy::Protocol.success('status' => 'active')
    assert_equal(
      { 'ok' => true, 'protocolVersion' => 1, 'data' => { 'status' => 'active' } },
      success
    )

    error = TabOutProxy::ValidationError.new('invalid_type', 'Safe public message')
    assert_equal(
      {
        'ok' => false,
        'protocolVersion' => 1,
        'error' => { 'code' => 'invalid_type', 'message' => 'Safe public message' }
      },
      TabOutProxy::Protocol.failure(error)
    )
  end

  def test_write_rejects_an_oversized_response
    object = { 'data' => 'x' * TabOutProxy::Protocol::MAX_MESSAGE_SIZE }
    error = assert_raises(TabOutProxy::ProtocolError) do
      TabOutProxy::Protocol.write(StringIO.new(+''), object)
    end
    assert_equal 'message_too_large', error.code
  end

  class CountingIO
    attr_reader :read_sizes

    def initialize(data)
      @io = StringIO.new(data)
      @read_sizes = []
    end

    def read(size)
      @read_sizes << size
      @io.read(size)
    end
  end

  private

  def assert_protocol_error(code)
    error = assert_raises(TabOutProxy::ProtocolError) { yield }
    assert_equal code, error.code
  end
end
