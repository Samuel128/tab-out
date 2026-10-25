# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'socket'
require 'yaml'
require 'tab_out_proxy/mihomo_client'

class MihomoClientTest < Minitest::Test
  def test_socket_discovery_supports_service_mode_and_preserves_explicit_override
    paths = TabOutProxy::MihomoClient.local_socket_paths(uid: 502, tmpdir: '/tmp/local-clash-fixture')
    assert_equal '/var/run/clash-verge-service/users/502/verge-mihomo.sock', paths.first
    assert_includes paths, '/tmp/local-clash-fixture/verge-mihomo.sock'
    assert_includes paths, '/tmp/verge/verge-mihomo.sock'
    assert_equal ['/tmp/explicit-fixture.sock'], TabOutProxy::MihomoClient.local_socket_paths(override: '/tmp/explicit-fixture.sock')
  end

  def test_missing_old_socket_falls_back_to_the_available_controller
    with_fake_server([json_response(200, 'version' => '1.19.0')]) do |socket_path, requests|
      client = TabOutProxy::MihomoClient.new(socket_path: File.join(File.dirname(socket_path), 'absent.sock'), fallback_socket_paths: [socket_path])
      assert client.available?
      assert_match(/\AGET \/version HTTP\/1\.1/, requests.fetch(0))
    end
  end

  def test_proxy_health_requires_both_clash_api_and_listening_http_port
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    with_fake_server([json_response(200, 'version' => '1.19.0')]) do |socket_path, _requests|
      assert TabOutProxy::MihomoClient.new(socket_path: socket_path).proxy_available?(port)
    end
    listener.close
    closed_port = Socket.new(:INET, :STREAM)
    closed_port.bind(Socket.sockaddr_in(0, '127.0.0.1'))
    port = Socket.unpack_sockaddr_in(closed_port.getsockname)[0]
    with_fake_server([json_response(200, 'version' => '1.19.0')]) do |socket_path, _requests|
      refute TabOutProxy::MihomoClient.new(socket_path: socket_path).proxy_available?(port)
    end
    refute TabOutProxy::MihomoClient.new(socket_path: '/tmp/tab-out-missing-test.sock').proxy_available?(port)
  ensure
    listener.close if listener && !listener.closed?
    closed_port.close if closed_port && !closed_port.closed?
  end

  def test_unresponsive_clash_api_is_bounded_and_reported_offline
    with_temp_dir do |directory|
      server = UNIXServer.new(File.join(directory, 'hung.sock'))
      thread = Thread.new do
        connection = server.accept
        sleep 5
      ensure
        connection.close if connection && !connection.closed?
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      refute TabOutProxy::MihomoClient.new(socket_path: File.join(directory, 'hung.sock')).proxy_available?(7897)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    ensure
      thread.kill if thread
      server.close if server && !server.closed?
    end
  end

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

  def test_service_path_restriction_uses_inline_config_and_inline_whitelist_without_source_writes
    with_temp_dir do |dir|
      path = File.join(dir, 'config.yaml')
      config = { 'mode' => 'rule', 'tun' => { 'enable' => false }, 'dns' => { 'nameserver' => ['192.0.2.53'] }, 'rule-providers' => { 'need-proxy' => { 'type' => 'file', 'behavior' => 'classical', 'format' => 'yaml', 'path' => '/tmp/unavailable-provider.yaml' } }, 'rules' => ['RULE-SET,need-proxy,PROXY', 'MATCH,DIRECT'] }
      File.write(path, YAML.dump(config))
      before = File.binread(path)
      denied = json_response(400, 'message' => 'path is not subpath of home directory or SAFE_PATHS: private-location')
      with_fake_server([denied, empty_response(204)]) do |socket_path, requests|
        client = TabOutProxy::MihomoClient.new(socket_path: socket_path)
        result = client.reload_config(path, inline_rules: ['DOMAIN-SUFFIX,proxy.example'])
        assert_equal true, result.fetch('inlineProvider')
        body = JSON.parse(requests.last.split("\r\n\r\n", 2).last)
        refute body.key?('path')
        loaded = YAML.safe_load(body.fetch('payload'))
        assert_equal({ 'type' => 'inline', 'behavior' => 'classical', 'payload' => ['DOMAIN-SUFFIX,proxy.example'] }, loaded.dig('rule-providers', 'need-proxy'))
        assert_equal config['dns'], loaded['dns']
        assert_equal config['tun'], loaded['tun']
        assert_equal config['rules'], loaded['rules']
        assert_equal before, File.binread(path)
      end
    end
  end

  def test_path_restriction_error_is_classified_without_exposing_private_paths
    with_fake_server([json_response(400, 'message' => 'path is not subpath of home directory or SAFE_PATHS: secret-private-path')]) do |socket_path, _requests|
      error = assert_raises(TabOutProxy::SyncError) { TabOutProxy::MihomoClient.new(socket_path: socket_path).reload_config('/tmp/fixture.yaml') }
      assert_equal 'clash_path_restricted', error.code
      refute_match(/secret-private-path/, error.message)
    end
  end

  def test_other_http_errors_do_not_attempt_inline_reload
    [400, 500].each do |status|
      with_fake_server([json_response(status, 'message' => 'unrelated private validation failure')]) do |socket_path, requests|
        client = TabOutProxy::MihomoClient.new(socket_path: socket_path)
        error = assert_raises(TabOutProxy::SyncError) { client.reload_config('/tmp/nonexistent-fixture.yaml', inline_rules: []) }
        assert_equal 'clash_http_error', error.code
        assert_equal 1, requests.length
        refute_match(/private validation/, error.message)
      end
    end
  end

  def test_inline_fallback_rejects_invalid_rules_before_reading_the_config
    with_fake_server([json_response(400, 'message' => 'path is not subpath of home directory')]) do |socket_path, requests|
      client = TabOutProxy::MihomoClient.new(socket_path: socket_path)
      error = assert_raises(TabOutProxy::ValidationError) { client.reload_config('/tmp/nonexistent-fixture.yaml', inline_rules: ['DOMAIN,example.com,PROXY']) }
      assert_equal 'invalid_inline_rules', error.code
      assert_equal 1, requests.length
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
