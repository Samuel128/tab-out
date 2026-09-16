# frozen_string_literal: true

require_relative 'test_helper'
require 'tab_out_proxy/rule'

class RuleTest < Minitest::Test
  def test_suffix_normalizes_a_full_url
    rule = TabOutProxy::Rule.build(
      type: 'suffix',
      value: 'HTTPS://User:Secret@API.OpenAI.com:443/v1?q=1#fragment',
      created_at: '2026-09-16T00:00:00Z'
    )

    assert_equal 'api.openai.com', rule.value
    assert_equal 'DOMAIN-SUFFIX,api.openai.com', rule.provider_line
    assert_equal '2026-09-16T00:00:00Z', rule.to_h.fetch('createdAt')
  end

  def test_keyword_and_exact_use_their_expected_provider_types
    keyword = TabOutProxy::Rule.build(type: 'keyword', value: ' Google ')
    exact = TabOutProxy::Rule.build(type: 'exact', value: 'API.Example.com.')

    assert_equal 'google', keyword.value
    assert_equal 'DOMAIN-KEYWORD,google', keyword.provider_line
    assert_equal 'api.example.com', exact.value
    assert_equal 'DOMAIN,api.example.com', exact.provider_line
  end

  def test_url_input_is_normalized_to_its_lowercase_hostname_for_every_type
    %w[suffix keyword exact].each do |type|
      rule = TabOutProxy::Rule.build(type: type, value: 'https://WWW.Example.COM:8443/path')
      assert_equal 'www.example.com', rule.value
    end
  end

  def test_identifier_is_stable_for_normalized_type_and_value
    first = TabOutProxy::Rule.build(type: 'suffix', value: 'OpenAI.com')
    second = TabOutProxy::Rule.build(type: 'suffix', value: 'https://openai.com/')
    different_type = TabOutProxy::Rule.build(type: 'exact', value: 'openai.com')

    assert_equal first.id, second.id
    refute_equal first.id, different_type.id
    assert_match(/\A[0-9a-f]{20}\z/, first.id)
  end

  def test_rejects_empty_invalid_and_unknown_type_values
    assert_rule_error('empty_value', type: 'suffix', value: '   ')
    assert_rule_error('invalid_domain', type: 'suffix', value: 'bad_domain.example')
    assert_rule_error('invalid_domain', type: 'exact', value: '-bad.example')
    assert_rule_error('invalid_type', type: 'regex', value: 'example.com')
  end

  def test_rejects_short_keywords_and_public_suffix_only_values
    assert_rule_error('short_keyword', type: 'keyword', value: 'ai')

    %w[com net org cn io co.uk com.cn].each do |suffix|
      assert_rule_error('public_suffix', type: 'suffix', value: suffix)
    end
  end

  def test_rejects_localhost_private_and_link_local_targets
    %w[
      localhost sub.localhost 127.0.0.1 10.2.3.4 192.0.2.53
      192.168.1.20 169.254.2.3 ::1 fe80::1 fc00::1
    ].each do |target|
      assert_rule_error('private_target', type: 'exact', value: target)
    end
  end

  def test_rejects_corporate_targets_for_all_match_types
    %w[internal.example app.internal.example corp.example api.llm.prd.corp.example].each do |target|
      %w[suffix keyword exact].each do |type|
        assert_rule_error('corporate_target', type: type, value: target)
      end
    end
  end

  def test_rejects_keywords_that_can_match_protected_corporate_targets
    %w[internal hww corp yum].each do |keyword|
      assert_rule_error('corporate_target', type: 'keyword', value: keyword)
    end
  end

  def test_rejects_original_keyword_examples_containing_protected_corporate_labels
    %w[app.internal prd.corp].each do |keyword|
      assert_rule_error('corporate_target', type: 'keyword', value: keyword)
    end
  end

  def test_rejects_business_domain_and_subdomains_for_suffix_and_exact
    %w[business.example intranet.business.example api.prd.business.example].each do |domain|
      %w[suffix exact].each do |type|
        assert_rule_error('corporate_target', type: type, value: domain)
      end
    end
  end

  def test_rejects_keywords_matching_business_labels_and_fragments
    %w[business corphin china prd.business intranet.business].each do |keyword|
      assert_rule_error('corporate_target', type: 'keyword', value: keyword)
    end
  end

  def test_preserves_legitimate_keywords_without_protected_corporate_fragments
    %w[openai google yummy hardware].each do |keyword|
      rule = TabOutProxy::Rule.build(type: 'keyword', value: keyword)
      assert_equal keyword, rule.value
      assert_equal "DOMAIN-KEYWORD,#{keyword}", rule.provider_line
    end
  end

  def test_rejects_keywords_that_can_match_private_ip_fragments
    %w[192.168 172.31 172.16 169.254 127.0 10.0 fe80 fc00].each do |keyword|
      assert_rule_error('private_target', type: 'keyword', value: keyword)
    end
  end

  private

  def assert_rule_error(code, type:, value:)
    error = assert_raises(TabOutProxy::ValidationError) do
      TabOutProxy::Rule.build(type: type, value: value)
    end
    assert_equal code, error.code
  end
end
