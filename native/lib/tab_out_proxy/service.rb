# frozen_string_literal: true

require 'time'
require_relative 'errors'
require_relative 'private_routing'

module TabOutProxy
  class Service
    PROTOCOL_VERSION = 1

    def initialize(store:, profile_manager:, mihomo_client:, token_usage: nil, clock: -> { Time.now })
      @store = store
      @profile_manager = profile_manager
      @mihomo_client = mihomo_client
      @token_usage = token_usage
      @clock = clock
    end

    def call(command, payload = {})
      unless payload.is_a?(Hash)
        raise ValidationError.new('invalid_request', 'Command payload must be an object')
      end

      case command
      when 'routing_snapshot'
        raise ValidationError.new('invalid_request', 'Routing snapshot requires an empty payload') unless payload.empty?
        with_transaction_lock do
          info = @profile_manager.browser_proxy_info
          info.merge(
            'clashAvailable' => @mihomo_client.proxy_available?(info.fetch('proxyPort')),
            'rules' => @store.list.map(&:to_h),
            'protectedSuffixes' => PrivateRouting.domain_suffixes
          )
        end
      when 'token_usage', 'token_usage_cached'
        raise ValidationError.new('invalid_request', 'Token usage does not accept filters') unless payload.empty?
        raise ValidationError.new('usage_unavailable', 'Token usage is not configured') unless @token_usage

        command == 'token_usage' ? @token_usage.call : @token_usage.cached
      when 'token_usage_range'
        unless payload.keys.sort == %w[endDate startDate]
          raise ValidationError.new('invalid_request', 'Token usage range accepts only start and end dates')
        end
        raise ValidationError.new('usage_unavailable', 'Token usage is not configured') unless @token_usage

        @token_usage.call_range(start_date: payload.fetch('startDate'), end_date: payload.fetch('endDate'))
      when 'status'
        return response('inactive', nil, nil) unless @store.initialized?

        with_transaction_lock { synchronize_transaction }
      when 'list'
        return response('stored', nil, nil) unless @store.initialized?

        with_transaction_lock do
          response('stored', safe_profile_info, nil)
        end
      when 'add'
        type = payload.fetch('type')
        value = payload.fetch('value')
        with_transaction_lock do
          synchronize_transaction do
            @store.add(type: type, value: value)
          end
        end
      when 'remove'
        id = payload.fetch('id')
        with_transaction_lock do
          synchronize_transaction { @store.remove(id) }
        end
      else
        raise ValidationError.new('unknown_command', 'Unsupported native command')
      end
    rescue KeyError
      raise ValidationError.new('invalid_request', 'Command payload is missing a required field')
    end

    private

    def synchronize_transaction
      store_snapshot = @store.snapshot
      profile_snapshot = @profile_manager.snapshot
      @store.ensure_initialized
      yield if block_given?
      synchronize(store_snapshot, profile_snapshot)
    rescue ClashUnavailableError
      # A socket can disappear between availability and reload. The valid files
      # remain in place so a later status request can finish synchronization.
      profile = safe_profile_info
      response('pending', profile, nil)
    rescue Error => error
      rollback(store_snapshot, profile_snapshot)
      raise error
    rescue StandardError => error
      rollback(store_snapshot, profile_snapshot)
      raise SyncError.new('sync_failed', "Proxy synchronization failed: #{error.class}")
    end

    def synchronize(store_snapshot, profile_snapshot)
      integration = @profile_manager.ensure_integrated!
      profile = public_profile(integration)
      return response('pending', profile, nil) unless @mihomo_client.available?

      unchanged = @store.synced? && @store.snapshot == store_snapshot &&
                  @profile_manager.snapshot == profile_snapshot
      if unchanged && provider_already_healthy?
        return response('active', profile, @clock.call.utc.iso8601)
      end

      applied = @mihomo_client.reload_config(@profile_manager.active_config_path, inline_rules: @store.list.map(&:provider_line))
      @mihomo_client.refresh_provider('need-proxy') unless applied.is_a?(Hash) && applied['inlineProvider']
      provider = @mihomo_client.provider('need-proxy')
      unless healthy_provider?(provider)
        raise SyncError.new('provider_verification_failed', 'Clash did not verify the need-proxy provider')
      end

      @store.mark_synced!

      response('active', profile, @clock.call.utc.iso8601)
    end

    def rollback(store_snapshot, profile_snapshot)
      @profile_manager.restore(profile_snapshot) if profile_snapshot
      @store.restore(store_snapshot) if store_snapshot
      restore_running_config
    rescue StandardError => error
      raise SyncError.new('rollback_failed', "Could not restore the previous proxy configuration: #{error.class}")
    end

    def with_transaction_lock(&block)
      @store.with_transaction_lock(&block)
    end

    def healthy_provider?(provider)
      provider.is_a?(Hash) &&
        provider['name'] == 'need-proxy' &&
        provider['type'] == 'Rule' &&
        provider['behavior'] == 'Classical' &&
        %w[File Inline].include?(provider['vehicleType']) &&
        provider['ruleCount'].is_a?(Integer) &&
        provider['ruleCount'] == @store.list.length
    end

    def provider_already_healthy?
      healthy_provider?(@mihomo_client.provider('need-proxy'))
    rescue SyncError
      false
    end

    def restore_running_config
      return unless @mihomo_client.available?

      applied = @mihomo_client.reload_config(@profile_manager.active_config_path, inline_rules: @store.list.map(&:provider_line))
      @mihomo_client.refresh_provider('need-proxy') if File.exist?(@store.provider_path) && !(applied.is_a?(Hash) && applied['inlineProvider'])
    rescue Error, SystemCallError
      nil
    end

    def safe_profile_info
      @profile_manager.profile_info
    rescue Error
      nil
    end

    def public_profile(profile)
      {
        'profileId' => profile.fetch('profileId'),
        'proxyGroup' => profile.fetch('proxyGroup')
      }
    end

    def response(status, profile, synced_at)
      {
        'protocolVersion' => PROTOCOL_VERSION,
        'status' => status,
        'rules' => @store.list.map(&:to_h),
        'protectedSuffixes' => PrivateRouting.domain_suffixes,
        'profile' => profile && public_profile(profile),
        'syncedAt' => synced_at
      }
    end
  end
end
