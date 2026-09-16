# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

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
