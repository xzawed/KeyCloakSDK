# frozen_string_literal: true

module Kc
  # Fixture boundary class. The drive spec calls initialize, token("svc") and AuthClient.parse only.
  class AuthClient
    MARK = ->(x) { x * 2 }

    def initialize(config)
      @config = config
    end

    def token(kind)
      if kind.nil?
        "none"
      else
        "#{@config.realm}:#{kind}"
      end
    end

    def logout_url = "#{@config.base}/logout"

    def self.parse(raw)
      raw.to_s.strip
    end

    def self.build(config)
      new(config)
    end

    def introspect(token)
      raise ArgumentError, "empty" if token.empty?

      { active: true }
    end
  end
end
