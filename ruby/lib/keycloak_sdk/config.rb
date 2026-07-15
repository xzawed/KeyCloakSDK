# frozen_string_literal: true

module KeycloakSdk
  # 불변 설정. 생성 시 검증하고 freeze한다. client_secret은 inspect에서 마스킹.
  class Config
    attr_reader :server_url, :realm, :client_id, :client_secret,
                :scopes, :signature_algorithms, :connect_timeout, :read_timeout, :clock_skew,
                :jwks_min_refetch

    def initialize(server_url:, realm:, client_id:, client_secret: nil,
                   scopes: ["openid"], signature_algorithms: ["RS256"],
                   connect_timeout: 10, read_timeout: 10, clock_skew: 30,
                   jwks_min_refetch: 10.0)
      @server_url = normalize_required("server_url", server_url).sub(%r{/+\z}, "")
      @realm = normalize_required("realm", realm)
      @client_id = normalize_required("client_id", client_id)
      @client_secret = client_secret
      @scopes = Array(scopes).freeze
      # JWT 서명 검증 허용 알고리즘 핀(기본 RS256). ES256/PS256 realm을 위해 설정 가능하되
      # 빈 집합은 alg 핀을 무력화하므로 거부한다.
      @signature_algorithms = non_empty_array("signature_algorithms", signature_algorithms).freeze
      @connect_timeout = positive("connect_timeout", connect_timeout)
      @read_timeout = positive("read_timeout", read_timeout)
      @clock_skew = non_negative("clock_skew", clock_skew)
      # 미해결 kid로 인한 JWKS 재조회의 최소 간격(초, 기본 10.0) — DoS 증폭 상한.
      @jwks_min_refetch = non_negative("jwks_min_refetch", jwks_min_refetch)
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

    def non_empty_array(name, value)
      arr = Array(value)
      raise ConfigError, "#{name} must be non-empty" if arr.empty?

      arr
    end
  end
end
