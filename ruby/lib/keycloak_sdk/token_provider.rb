# frozen_string_literal: true

require "uri"

module KeycloakSdk
  # 덕 인터페이스: 구현체는 #access_token → String 을 응답한다.
  # admin은 이 인터페이스로만 토큰을 받는다(auth 비의존, §4 결합 규칙).
  module TokenProvider
  end

  # client-credentials 그랜트로 토큰을 발급하고 만료 전까지 캐시한다(Mutex single-flight).
  # admin 파사드가 소비하는 캐싱 provider(무캐시 AuthClient 직접 주입 금지 — §4 캐시 불변식).
  class ClientCredentialsTokenProvider
    include TokenProvider

    def initialize(config:, http:)
      @config = config
      @http = http
      @token_url = OidcEndpoints.from_config(config).token
      @mutex = Mutex.new
      @cached = nil
      @expires_at = 0.0
    end

    def access_token
      @mutex.synchronize do
        now = Time.now.to_f
        return @cached if @cached && now < @expires_at

        ts = request_token
        @cached = ts.access_token
        @expires_at = ts.expires_at ? (ts.expires_at - @config.clock_skew) : (now + 60)
        @cached
      end
    end

    private

    def request_token
      resp = @http.post(@token_url, {
                          grant_type: "client_credentials",
                          client_id: @config.client_id,
                          client_secret: @config.client_secret,
                          scope: @config.scopes.join(" ")
                        })
      unless resp.success?
        oauth = resp.body.is_a?(Hash) ? resp.body["error"] : nil
        raise AuthError.new("client-credentials token request failed: HTTP #{resp.status}", oauth_error: oauth)
      end

      TokenSet.from_response(resp.body, received_at: Time.now.to_f)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end
  end
end
