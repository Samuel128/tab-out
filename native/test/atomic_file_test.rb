# frozen_string_literal: true

require_relative 'test_helper'
require 'tab_out_proxy/atomic_file'

class AtomicFileTest < Minitest::Test
  def test_replacement_is_atomic_and_preserves_a_backup
    with_temp_dir do |directory|
      path = File.join(directory, 'nested', 'state.json')
      TabOutProxy::AtomicFile.write(path, 'first')
      TabOutProxy::AtomicFile.write(path, 'second')

      assert_equal 'second', File.binread(path)
      assert_equal 'first', File.binread("#{path}.bak")
      assert_empty Dir.glob("#{path}.tmp.*")
    end
  end

  def test_restore_replaces_from_backup_without_destroying_backup
    with_temp_dir do |directory|
      path = File.join(directory, 'state.json')
      TabOutProxy::AtomicFile.write(path, 'first')
      TabOutProxy::AtomicFile.write(path, 'second')

      TabOutProxy::AtomicFile.restore_backup(path)

      assert_equal 'first', File.binread(path)
      assert_equal 'first', File.binread("#{path}.bak")
    end
  end
end
