# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'socket'
require 'tab_out_proxy/mihomo_client'

class MihomoClientTest < Minitest::Test
  def test_availability_uses_version_endpoint_and_parses_json
    with_fake_server([json_response(200, 'version' => '1.19.0')]) do |socket_path, requests|
      client = TabOutProxy::MihomoClient.new(socket_path: socket_path)

      assert client.available?
      assert_match(/\AGET \/version HTTP\/1\.1\r\n/, requests.fetch(0))
    end
  end

  def test_reload_refresh_and_provider_verification_use_expected_requests
    responses = [
      empty_response(204),
      empty_response(204),
      json_response(200, 'providers' => { 'need-proxy' => { 'name' => 'need-proxy', 'vehicleType' => 'File' } })
    ]
    with_fake_server(responses) do |socket_path, requests|
      client = TabOutProxy::MihomoClient.new(socket_path: socket_path)
      config_path = '/tmp/sanitized clash/config.yaml'

      client.reload_config(config_path)
      client.refresh_provider('need-proxy')
      provider = client.provider('need-proxy')

      reload_request = requests.fetch(0)
      assert_match(/\APUT \/configs\?force=true HTTP\/1\.1/, reload_request)
      assert_includes reload_request, JSON.generate('path' => config_path)
      assert_match(/\APUT \/providers\/rules\/need-proxy HTTP\/1\.1/, requests.fetch(1))
      assert_match(/\AGET \/providers\/rules HTTP\/1\.1/, requests.fetch(2))
      assert_equal 'need-proxy', provider.fetch('name')
    end
  end

  def test_chunked_json_response_is_decoded
    body = JSON.generate('providers' => { 'need-proxy' => { 'name' => 'need-proxy' } })
    chunks = [body[0, 5], body[5..-1]].map { |part| "#{part.bytesize.to_s(16)}\r\n#{part}\r\n" }.join
    response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n#{chunks}0\r\n\r\n"

    with_fake_server([response]) do |socket_path, _requests|
      result = TabOutProxy::MihomoClient.new(socket_path: socket_path).provider('need-proxy')
      assert_equal 'need-proxy', result.fetch('name')
    end
  end

  def test_missing_rule_provider_returns_nil_from_collection
    with_fake_server([json_response(200, 'providers' => {})]) do |socket_path, requests|
      assert_nil TabOutProxy::MihomoClient.new(socket_path: socket_path).provider('need-proxy')
      assert_match(/\AGET \/providers\/rules HTTP\/1\.1/, requests.fetch(0))
    end
  end

  def test_non_success_response_raises_typed_error_without_exposing_body
    response = json_response(500, 'secret' => 'must-not-leak')
    with_fake_server([response]) do |socket_path, _requests|
      error = assert_raises(TabOutProxy::SyncError) do
        TabOutProxy::MihomoClient.new(socket_path: socket_path).provider('need-proxy')
      end

      assert_equal 'clash_http_error', error.code
      refute_match(/must-not-leak/, error.message)
      assert_match(/500/, error.message)
    end
  end

  def test_missing_socket_reports_unavailable
    with_temp_dir do |directory|
      client = TabOutProxy::MihomoClient.new(socket_path: File.join(directory, 'missing.sock'))

      refute client.available?
      error = assert_raises(TabOutProxy::ClashUnavailableError) { client.provider('need-proxy') }
      assert_equal 'clash_unavailable', error.code
    end
  end

  def test_malformed_http_response_is_a_sync_error
    with_fake_server(["NOT HTTP\r\n\r\n"]) do |socket_path, _requests|
      error = assert_raises(TabOutProxy::SyncError) do
        TabOutProxy::MihomoClient.new(socket_path: socket_path).provider('need-proxy')
      end
      assert_equal 'clash_invalid_response', error.code
    end
  end

  private

  def with_fake_server(responses)
    with_temp_dir do |directory|
      socket_path = File.join(directory, 'mihomo.sock')
      server = UNIXServer.new(socket_path)
      requests = []
      thread = Thread.new do
        responses.each do |response|
          connection = server.accept
          requests << read_request(connection)
          connection.write(response)
          connection.close
        end
      end

      yield socket_path, requests
      thread.join(2)
      refute thread.alive?, 'fake Unix server did not finish'
    ensure
      server.close if server && !server.closed?
      thread.kill if thread && thread.alive?
    end
  end

  def read_request(connection)
    request = +''
    request << connection.gets until request.end_with?("\r\n\r\n")
    length = request[/Content-Length:\s*(\d+)/i, 1].to_i
    request << connection.read(length) if length.positive?
    request
  end

  def json_response(status, object)
    body = JSON.generate(object)
    "HTTP/1.1 #{status} Result\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def empty_response(status)
    "HTTP/1.1 #{status} Result\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  end
end
