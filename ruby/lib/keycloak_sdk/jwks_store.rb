# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  # DoS-safe JWKS 스토어. Mutex 캐시 + rate-limit + single-flight.
  # 위조 서명(알려진 kid)은 캐시 반환만 하고 재조회를 유발하지 않는다.
  # 미해결 kid(force:true)만 재조회하며, rate-limit gate는 재조회 결정 시점에 stamp한다
  # (성공 아님 — IdP 장애창에서 위조 kid 폭주에도 재조회를 상한한다). Go/Rust/Python 동형.
  class JwksStore
    def initialize(jwks_url:, http:, min_refetch: 10.0)
      @jwks_url = jwks_url
      @http = http
      @min_refetch = min_refetch
      @mutex = Mutex.new
      @cache = nil        # {"keys" => [...]}
      @last_refetch = nil # monotonic seconds
    end

    # ruby-jwt jwks: 로더가 호출. force=true는 미해결 kid 재조회 요청.
    def key_set(force: false)
      @mutex.synchronize do
        return @cache if @cache && !force
        return @cache if force && !refetch_allowed?

        @last_refetch = monotonic if force # 결정 시점 stamp(cold load는 예산 미소모)
        @cache = fetch
      end
    end

    private

    def refetch_allowed?
      @last_refetch.nil? || (monotonic - @last_refetch) >= @min_refetch
    end

    def fetch
      resp = @http.get(@jwks_url)
      raise TransportError, "JWKS fetch failed: HTTP #{resp.status}" unless resp.success?

      body = resp.body
      raise TransportError, "JWKS response malformed" unless body.is_a?(Hash) && body["keys"].is_a?(Array)

      body
    rescue Faraday::Error => e
      raise TransportError, "JWKS transport error: #{e.message}"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
