# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'stringio'
require 'yaml'
require 'tab_out_proxy/protocol'

class HostTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures', __dir__)
  HOST = File.expand_path('../bin/tab-out-proxy-host', __dir__)

  def test_host_uses_environment_paths_and_emits_only_one_protocol_frame
    with_temp_dir do |directory|
      clash_directory = prepare_clash_directory(directory)
      env = {
        'TAB_OUT_PROXY_HOME' => File.join(directory, 'state'),
        'TAB_OUT_CLASH_CONFIG_DIR' => clash_directory,
        'TAB_OUT_MIHOMO_SOCKET' => File.join(directory, 'missing.sock')
      }
      request = {
        'protocolVersion' => 1,
        'command' => 'list',
        'payload' => {}
      }

      output = run_host(env, framed(request))
      response, trailing = decode_one_frame(output)

      assert_equal true, response.fetch('ok')
      assert_equal 'stored', response.dig('data', 'status')
      assert_equal [], response.dig('data', 'rules')
      assert_equal '', trailing
      refute File.exist?(File.join(directory, 'state', 'state.json'))
    end
  end

  def test_host_returns_a_framed_error_for_malformed_json
    with_temp_dir do |directory|
      env = {
        'TAB_OUT_PROXY_HOME' => File.join(directory, 'state'),
        'TAB_OUT_CLASH_CONFIG_DIR' => File.join(directory, 'unused-clash'),
        'TAB_OUT_MIHOMO_SOCKET' => File.join(directory, 'missing.sock')
      }

      output = run_host(env, [5].pack('L<') + '{bad}')
      response, trailing = decode_one_frame(output)

      assert_equal false, response.fetch('ok')
      assert_equal 'invalid_json', response.dig('error', 'code')
      assert_equal '', trailing
    end
  end

  def test_host_writes_rule_provider_inside_clash_config_directory
    with_temp_dir do |directory|
      clash_directory = prepare_clash_directory(directory)
      env = {
        'TAB_OUT_PROXY_HOME' => File.join(directory, 'state'),
        'TAB_OUT_CLASH_CONFIG_DIR' => clash_directory,
        'TAB_OUT_MIHOMO_SOCKET' => File.join(directory, 'missing.sock')
      }
      request = { 'protocolVersion' => 1, 'command' => 'add', 'payload' => { 'type' => 'suffix', 'value' => 'chatgpt.com' } }

      response, = decode_one_frame(run_host(env, framed(request)))

      assert_equal true, response.fetch('ok')
      assert_equal 'pending', response.dig('data', 'status')
      provider = File.join(clash_directory, 'tab-out-need-proxy.yaml')
      assert_equal ['DOMAIN-SUFFIX,chatgpt.com'], YAML.safe_load(File.read(provider)).fetch('payload')
      refute File.exist?(File.join(directory, 'state', 'need-proxy.yaml'))
    end
  end

  private

  def run_host(env, input)
    output = +''
    IO.popen(env, ['/usr/bin/ruby', HOST], 'r+b', err: File::NULL) do |io|
      io.binmode
      io.write(input)
      io.close_write
      output = io.read
    end
    assert_predicate $CHILD_STATUS, :success? if defined?($CHILD_STATUS) && $CHILD_STATUS
    output
  end

  def framed(object)
    payload = JSON.generate(object)
    [payload.bytesize].pack('L<') + payload
  end

  def decode_one_frame(output)
    io = StringIO.new(output)
    length = io.read(4).unpack1('L<')
    [JSON.parse(io.read(length)), io.read.to_s]
  end

  def prepare_clash_directory(directory)
    clash = File.join(directory, 'clash')
    profiles = File.join(clash, 'profiles')
    FileUtils.mkdir_p(profiles)
    FileUtils.cp(File.join(FIXTURES, 'profiles.yaml'), File.join(clash, 'profiles.yaml'))
    FileUtils.cp(File.join(FIXTURES, 'active-config.yaml'), File.join(clash, 'clash-verge.yaml'))
    %w[remote-profile.json merge-override.yaml rules-override.yaml].each do |name|
      FileUtils.cp(File.join(FIXTURES, name), File.join(profiles, name))
    end
    clash
  end
end
