# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  # DoS-safe JWKS 스토어. Mutex 캐시 + rate-limit + single-flight.
  # 위조 서명(알려진 kid)은 캐시 반환만 하고 재조회를 유발하지 않는다.
  # 미해결 kid(force:true)만 재조회하며, rate-limit gate는 재조회 결정 시점에 stamp한다
  # (성공 아님 — IdP 장애창에서 위조 kid 폭주에도 재조회를 상한한다). Go/Rust/Python 동형.
  class JwksStore
    # ⚠️ **실패한 fetch 의 백오프 — `min_refetch` 와 다른 축이다.**
    # `min_refetch`(30초)는 *캐시가 찬 뒤* 미해결 kid 홍수를 막는다. 아래 둘은 **캐시가 비어
    # 있고 fetch 가 계속 실패할 때**를 막는다. 그 자리에는 게이트가 없어서, 측정상 20회 검증이
    # IdP 요청 20건을 그대로 냈다(2026-09-04 · 7개 언어 동일).
    #
    # ⚠️ **여기에 `min_refetch`(30초)를 재사용하면 안 된다** — 일시적 503 한 번이 「30초간 어떤
    # 토큰도 검증 불가」가 된다. 그래서 짧게 시작해 지수적으로 늘리고 상한을 둔다.
    #
    # ⚠️ **sleep 하지 않는다.** 라이브러리가 호출자의 스레드를 붙잡으면 안 되므로, 백오프 창
    # 안에서는 **IdP 를 때리지 않고 즉시 실패**시킨다(negative cache). 재시도 정책은 소비자 몫이다.
    FAILURE_BACKOFF_BASE = 0.2 # 초 — 첫 실패 후 대기
    FAILURE_BACKOFF_CAP  = 5.0 # 초 — 지수 증가의 상한

    # ⚠️ 기본값을 여기 숫자로 적지 말 것 — `Config`가 유일한 정의 자리다. 이 클래스는 평범한
    # public 클래스라 소비자가 파사드를 거치지 않고 직접 생성할 수 있고, 예전에는 그 경로가
    # 문서의 30초가 아니라 10초를 받아 IdP를 3배 자주 때렸다(2026-08-13 Task D1).
    def initialize(jwks_url:, http:, min_refetch: Config::DEFAULT_JWKS_MIN_REFETCH)
      @jwks_url = jwks_url
      @http = http
      @min_refetch = min_refetch
      @mutex = Mutex.new
      @cache = nil        # {"keys" => [...]}
      @last_refetch = nil # monotonic seconds
      @last_failure = nil # monotonic seconds — 마지막 fetch 실패 시각
      @failures = 0       # 연속 실패 횟수(성공 시 0으로 되돌린다)
    end

    # ruby-jwt jwks: 로더가 호출. force=true는 미해결 kid 재조회 요청.
    def key_set(force: false)
      @mutex.synchronize do
        return @cache if @cache && !force
        return @cache if force && !refetch_allowed?

        # ⚠️ 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다. 콜드 캐시에서는 위 두 return
        # 이 모두 통과하므로, 이 줄이 없으면 매 검증이 IdP 로 나간다(그게 원래 결함이다).
        if backing_off?
          raise TransportError,
                "JWKS fetch backing off after #{@failures} consecutive failures " \
                "(retry in #{backoff_remaining.round(2)}s)"
        end

        @last_refetch = monotonic if force # 결정 시점 stamp(cold load는 예산 미소모)
        @cache = fetch_recording_failure
      end
    end

    private

    def refetch_allowed?
      @last_refetch.nil? || (monotonic - @last_refetch) >= @min_refetch
    end

    def backing_off?
      backoff_remaining.positive?
    end

    def backoff_remaining
      return 0.0 if @last_failure.nil?

      backoff_delay - (monotonic - @last_failure)
    end

    # 지수 백오프 + jitter. jitter 는 [0.5, 1.0) 배수 — 여러 인스턴스가 같은 순간에 복구를
    # 시도해 IdP 를 다시 무너뜨리는 것(thundering herd)을 흩는다.
    #
    # ⚠️ **PRNG API 를 쓰지 않고 나노초 시계에서 뽑는다.** 이 값은 비밀이 아니지만, 보안 민감
    # 코드에서 약한 PRNG 를 호출하면 정적분석이 정당하게 막는다(실측: sonar S2245 · gosec G404).
    # 일곱 언어가 **같은 관용**을 쓴다 — 하나만 `rand` 로 남으면 그 자체가 드리프트다.
    def backoff_delay
      raw = FAILURE_BACKOFF_BASE * (2**([@failures, 1].max - 1))
      [raw, FAILURE_BACKOFF_CAP].min * jitter
    end

    def jitter
      0.5 + ((Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) % 1_000_000) / 2_000_000.0)
    end

    def fetch_recording_failure
      body = fetch
      @failures = 0
      @last_failure = nil
      body
    rescue StandardError
      @failures += 1
      @last_failure = monotonic
      raise
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
