# frozen_string_literal: true

require 'time'
require_relative 'errors'

module TabOutProxy
  class Service
    PROTOCOL_VERSION = 1

    def initialize(store:, profile_manager:, mihomo_client:, clock: -> { Time.now })
      @store = store
      @profile_manager = profile_manager
      @mihomo_client = mihomo_client
      @clock = clock
    end

    def call(command, payload = {})
      unless payload.is_a?(Hash)
        raise ValidationError.new('invalid_request', 'Command payload must be an object')
      end

      case command
      when 'status'
        synchronize_transaction
      when 'list'
        response('stored', @profile_manager.profile_info, nil)
      when 'add'
        type = payload.fetch('type')
        value = payload.fetch('value')
        synchronize_transaction do
          @store.add(type: type, value: value)
        end
      when 'remove'
        id = payload.fetch('id')
        synchronize_transaction { @store.remove(id) }
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
      synchronize
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

    def synchronize
      integration = @profile_manager.ensure_integrated!
      profile = public_profile(integration)
      return response('pending', profile, nil) unless @mihomo_client.available?

      @mihomo_client.reload_config(@profile_manager.active_config_path)
      @mihomo_client.refresh_provider('need-proxy')
      provider = @mihomo_client.provider('need-proxy')
      unless provider.is_a?(Hash) && !provider.empty? &&
             (!provider.key?('name') || provider['name'] == 'need-proxy')
        raise SyncError.new('provider_verification_failed', 'Clash did not verify the need-proxy provider')
      end

      response('active', profile, @clock.call.utc.iso8601)
    end

    def rollback(store_snapshot, profile_snapshot)
      @profile_manager.restore(profile_snapshot) if profile_snapshot
      @store.restore(store_snapshot) if store_snapshot
      restore_running_config
    rescue StandardError => error
      raise SyncError.new('rollback_failed', "Could not restore the previous proxy configuration: #{error.class}")
    end

    def restore_running_config
      return unless @mihomo_client.available?

      @mihomo_client.reload_config(@profile_manager.active_config_path)
      @mihomo_client.refresh_provider('need-proxy') if File.exist?(@store.provider_path)
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
        'profile' => profile && public_profile(profile),
        'syncedAt' => synced_at
      }
    end
  end
end
