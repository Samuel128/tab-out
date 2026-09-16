# frozen_string_literal: true

module TabOutProxy
  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  class ValidationError < Error; end
  class PersistenceError < Error; end
  class UnsupportedProfileError < Error; end
  class ClashUnavailableError < Error; end
  class SyncError < Error; end
  class ProtocolError < Error; end
end
