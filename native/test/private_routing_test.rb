# frozen_string_literal: true

require_relative 'test_helper'
require 'tab_out_proxy/private_routing'

class PrivateRoutingTest < Minitest::Test
  def with_private_path(path)
    previous = ENV['TAB_OUT_PRIVATE_ROUTING_PATH']
    ENV['TAB_OUT_PRIVATE_ROUTING_PATH'] = path
    yield
  ensure
    ENV['TAB_OUT_PRIVATE_ROUTING_PATH'] = previous
  end

  def test_reads_private_rules_and_derives_protected_suffixes
    assert_equal %w[internal.example corp.example business.example], TabOutProxy::PrivateRouting.domain_suffixes
    assert_equal %w[internal corp business], TabOutProxy::PrivateRouting.keyword_markers
  end

  def test_missing_or_world_readable_private_file_fails_closed
    with_temp_dir do |directory|
      path = File.join(directory, 'routing.yaml')
      with_private_path(path) do
        error = assert_raises(TabOutProxy::UnsupportedProfileError) { TabOutProxy::PrivateRouting.direct_rules }
        assert_equal 'private_routing_missing', error.code

        File.write(path, "direct_rules:\n  - DOMAIN-SUFFIX,internal.example,DIRECT\n")
        File.chmod(0o644, path)
        error = assert_raises(TabOutProxy::UnsupportedProfileError) { TabOutProxy::PrivateRouting.direct_rules }
        assert_equal 'private_routing_unsafe', error.code
      end
    end
  end
end
