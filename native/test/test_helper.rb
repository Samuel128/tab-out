# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

private_routing_dir = Dir.mktmpdir('tab-out-private-routing-test')
private_routing_path = File.join(private_routing_dir, 'private-routing.yaml')
FileUtils.cp(File.expand_path('fixtures/private-routing.yaml', __dir__), private_routing_path)
File.chmod(0o600, private_routing_path)
ENV['TAB_OUT_PRIVATE_ROUTING_PATH'] = private_routing_path
at_exit { FileUtils.remove_entry(private_routing_dir) if File.exist?(private_routing_dir) }
require 'minitest/autorun'

module TempDirectory
  def with_temp_dir
    directory = Dir.mktmpdir('tab-out-proxy-test')
    yield directory
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end
end

class Minitest::Test
  include TempDirectory
end
