# frozen_string_literal: true

module KeycloakSdk
  # 통합 진입점. auth는 즉시 조립, admin은 지연 조립(전용 캐싱 TokenProvider 주입 — §4).
  class KeycloakClient
    attr_reader :auth

    def initialize(config)
      @config = config
      endpoints = OidcEndpoints.from_config(config)
      @form_http = Http.build(config) do |f|
        f.request :url_encoded
        f.response :json, content_type: /\bjson$/
      end
      @jwks_http = Http.build(config) { |f| f.response :json, content_type: /\bjson$/ }
      jwks_store = JwksStore.new(jwks_url: endpoints.jwks, http: @jwks_http, min_refetch: config.jwks_min_refetch)
      jwt_validator = JwtValidator.from_config(config: config, jwks_store: jwks_store)
      @auth = AuthClient.new(config: config, http: @form_http, jwt_validator: jwt_validator)
      @admin = nil
      @admin_mutex = Mutex.new
    end

    def admin
      @admin_mutex.synchronize do
        @admin ||= Admin::AdminClient.new(
          config: @config,
          token_provider: ClientCredentialsTokenProvider.new(config: @config, http: @form_http)
        )
      end
    end

    def close
      @admin&.close # 지연 생성된 admin의 Faraday 커넥션도 정리(§4 close 계약 — 이전엔 누락)
      [@form_http, @jwks_http].each { |h| h.close if h.respond_to?(:close) }
      nil
    end
  end
end
