# frozen_string_literal: true

module KeycloakSdk
  # 불변 설정. 생성 시 검증하고 freeze한다. client_secret은 inspect에서 마스킹.
  class Config
    attr_reader :server_url, :realm, :client_id, :client_secret,
                :scopes, :connect_timeout, :read_timeout, :clock_skew

    def initialize(server_url:, realm:, client_id:, client_secret: nil,
                   scopes: ["openid"], connect_timeout: 10, read_timeout: 10, clock_skew: 30)
      @server_url = normalize_required("server_url", server_url).sub(%r{/+\z}, "")
      @realm = normalize_required("realm", realm)
      @client_id = normalize_required("client_id", client_id)
      @client_secret = client_secret
      @scopes = Array(scopes).freeze
      @connect_timeout = positive("connect_timeout", connect_timeout)
      @read_timeout = positive("read_timeout", read_timeout)
      @clock_skew = non_negative("clock_skew", clock_skew)
      freeze
    end

    def inspect
      "#<KeycloakSdk::Config server_url=#{@server_url.inspect} realm=#{@realm.inspect} " \
        "client_id=#{@client_id.inspect} client_secret=#{Masking.mask(@client_secret).inspect} " \
        "scopes=#{@scopes.inspect}>"
    end
    alias to_s inspect

    private

    def normalize_required(name, value)
      raise ConfigError, "#{name} is required" if value.nil?

      str = value.to_s
      raise ConfigError, "#{name} must not be blank" if str.strip.empty?

      str
    end

    def positive(name, value)
      raise ConfigError, "#{name} must be > 0" unless value.is_a?(Numeric) && value.positive?

      value
    end

    def non_negative(name, value)
      raise ConfigError, "#{name} must be >= 0" unless value.is_a?(Numeric) && value >= 0

      value
    end
  end
end
