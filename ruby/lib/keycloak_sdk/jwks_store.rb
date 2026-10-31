# frozen_string_literal: true

require "faraday"
require "json" # ⚠️ `on_data` 를 쓰면 json 미들웨어가 돌지 않아 여기서 직접 파싱한다

module KeycloakSdk
  # DoS-safe JWKS store. Mutex cache + rate-limit + single-flight.
  # A forged signature (known kid) only gets the cache back and triggers no refetch.
  # Within the lifetime (`JWKS_MAX_AGE_SECONDS`) only an unresolved kid (force:true) triggers a refetch, and the
  # rate-limit gate stamps at the moment the refetch is decided
  # (not on success — this caps refetches even under a flood of forged kids in an IdP outage window).
  # Isomorphic with Go/Rust/Python.
  class JwksStore
    # Lifetime (seconds) of a key set obtained by a successful load — measured on the monotonic clock from when that
    # load **finished**. Once it has fully elapsed the cache is the same as cold: the next lookup fetches again with
    # the same single flight · the same failure backoff, and if that fails it ends with that error. ⚠️ It does not
    # fall back to the stale set — not even during an IdP outage (the SDK cannot tell an unreachable JWKS from
    # withdrawn keys). A successful forced refetch also restarts the lifetime. Common to the nine languages.
    JWKS_MAX_AGE_SECONDS = 300
    private_constant :JWKS_MAX_AGE_SECONDS

    # ⚠️ **Backoff for a failed fetch — a different axis from `min_refetch`.**
    # `min_refetch` (30 seconds) holds back a flood of unresolved kids *once the cache is filled*. The two below
    # hold back **the case where the cache is empty and the fetch keeps failing**. There was no gate there, so
    # as measured, 20 validations sent 20 IdP requests straight through (2026-09-04 · the same in 7 languages).
    #
    # ⚠️ **Do not reuse `min_refetch` (30 seconds) here** — a single transient 503 would become "no token can be
    # validated for 30 seconds". So it starts short, grows exponentially and has a cap.
    #
    # ⚠️ **No sleep.** A library must not hold on to the caller's thread, so inside the backoff window it **fails
    # immediately without hitting the IdP** (negative cache). The retry policy is up to the consumer.
    FAILURE_BACKOFF_BASE = 0.2 # seconds — wait after the first failure
    FAILURE_BACKOFF_CAP  = 5.0 # 초 — 지수 증가의 상한

    # ⚠️ **The cap applies before the body is read whole.** It used to take `resp.body` (the value the json
    # middleware had already parsed) as is and received as much as the server sent — a single compromised IdP could
    # have killed the validation path through memory. 51200 is Nimbus's `RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT`, and
    # go (`jwksMaxBytes`) · rust (`JWKS_MAX_BYTES`) · java · kotlin use the same number.
    # ⚠️ Judging by `Content-Length` alone misses a response whose header is absent or false — the read is cut off
    # the moment the running total passes the cap while chunks arrive (raising inside `on_data` makes the adapter
    # abort).
    JWKS_MAX_BYTES = 51_200

    # ⚠️ Do not write the default here as a number — `Config` is its single definition site. This class is an
    # ordinary public class, so a consumer can construct it directly without going through the facade, and that path
    # used to get 10 seconds instead of the documented 30 and hit the IdP 3 times as often (2026-08-13 Task D1).
    def initialize(jwks_url:, http:, min_refetch: Config::DEFAULT_JWKS_MIN_REFETCH)
      @jwks_url = jwks_url
      @http = http
      @min_refetch = min_refetch
      @mutex = Mutex.new
      @cache = nil        # {"keys" => [...]}
      @last_refetch = nil # monotonic seconds
      @fetched_at = nil   # monotonic seconds — when the load that brought in @cache finished (the lifetime's origin)
      @last_failure = nil # monotonic seconds — time of the last fetch failure
      @failures = 0       # consecutive failure count (reset to 0 on success)
      # Length (seconds) of the window the last failure opened. jitter is drawn once, when that failure is recorded,
      # and fixed here.
      @backoff_window = 0.0
    end

    # Called by the ruby-jwt jwks: loader. force=true requests a refetch for an unresolved kid.
    def key_set(force: false)
      @mutex.synchronize do
        cache = live_cache # nil for a set past its lifetime — everything below flows exactly as with a cold cache
        return cache if cache && !force
        return cache if force && !refetch_allowed?

        # ⚠️ The backoff check comes **right before** the fetch and **after** the 30-second gate. On a cold cache both
        # returns above fall through, so without this line every validation goes out to the IdP (that was the
        # original defect).
        if backing_off?
          raise TransportError,
                "JWKS fetch backing off after #{@failures} consecutive failures " \
                "(retry in #{backoff_remaining.round(2)}s)"
        end

        @last_refetch = monotonic if force # stamp at decision time (a cold load spends no budget)
        @cache = fetch_recording_failure
      end
    end

    private

    # 수명 안의 집합, 아니면 nil. 수명 판정은 이 한 자리다.
    def live_cache
      @cache if @cache && (monotonic - @fetched_at) < JWKS_MAX_AGE_SECONDS
    end

    def refetch_allowed?
      @last_refetch.nil? || (monotonic - @last_refetch) >= @min_refetch
    end

    def backing_off?
      backoff_remaining.positive?
    end

    def backoff_remaining
      return 0.0 if @last_failure.nil?

      @backoff_window - (monotonic - @last_failure)
    end

    # 지수 백오프 + jitter. jitter 는 [0.5, 1.0) 배수 — 여러 인스턴스가 같은 순간에 복구를
    # 시도해 IdP 를 다시 무너뜨리는 것(thundering herd)을 흩는다. ⚠️ 실패를 기록할 때 한 번만 부른다 — 검사마다 부르면
    # 같은 실패가 같은 순간에 한 번은 거부하고 한 번은 IdP 로 내보낸다(창이 0.5× 쪽으로 줄어 장애 중 요청이 최대 두 배).
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
      @fetched_at = monotonic # 수명은 적재가 끝난 이 시각부터다
      @failures = 0
      @last_failure = nil
      body
    rescue StandardError
      @failures += 1
      @last_failure = monotonic
      @backoff_window = backoff_delay
      raise
    end

    def fetch
      # ⚠️ 상한은 **상태와 무관하게** 건다. 200 만 겨누면 오류 응답의 거대 본문이 그대로
      # 들어온다 — php 가 정확히 그 순서였다(상태 검사 전에 `json_decode`). 기제는 토큰 레인과 같은 `Http.read_capped`.
      resp = Http.read_capped(@http, :get, @jwks_url, max_bytes: JWKS_MAX_BYTES, what: "JWKS")
      raise TransportError, "JWKS fetch failed: HTTP #{resp.status}" unless resp.success?

      # ⚠️ `on_data` 를 쓰면 Faraday 는 본문을 누적하지 않으므로 json 미들웨어가 돌지 않는다 —
      # 파싱은 여기서 한다. 파싱 실패도 경계에서 SDK 타입이 되어야 한다(§4).
      # ⚠️ 잘못된 UTF-8 로 풀리는 본문도 해석 실패다(`Http.utf8?`) — n·e 가 그러면 ruby-jwt 의 base64 가 검증 중에
      # raw ArgumentError 를 냈다(실측, 잠긴 json 3.0.2 에서도).
      body = begin
        parsed = JSON.parse(resp.body)
        raise JSON::ParserError, "JSON text decodes to invalid UTF-8" unless Http.utf8?(parsed)

        parsed
      rescue JSON::ParserError => e
        raise TransportError, "JWKS response unparsable (JSON::ParserError)", cause: RedactedCause.new(e)
      end
      validate_key_set!(body)
    rescue Error
      raise
    rescue StandardError => e # Faraday 밖 예외도 — net-http 0.10 의 응답 헤더 검증은 ArgumentError 다(어댑터 목록 밖)
      raise TransportError, "JWKS transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    end

    # 파싱된 본문이 **캐시에 올려도 되는 집합인가**. 통과하면 그 본문을 돌려준다.
    #
    # ⚠️ **빈 집합은 정상 답이 아니고, 설치하면 검증기가 눈이 먼다**(go/jwt.go 와 동형 — 그쪽
    # #380 픽스의 나머지 절반이다). `[]` 는 Array 라 malformed 검사를 그대로 통과한다.
    # 200 + `{"keys":[]}` 를 주는 것은 키를 전부 회수한 IdP 가 아니라 프록시·WAF·반쯤 뜬
    # realm 이고, 좋은 캐시를 그것으로 덮으면 방금 검증되던 토큰이 거부되며 refetch 게이트가
    # 복구까지 막는다. 그래서 쓰기 **전에** 거부한다.
    #
    # ⚠️ 여기서 멈춘다 — `kty`·`n`·`e` 같은 필드 검증으로 번지면 JWKS 스키마 검사가 된다.
    def validate_key_set!(body)
      raise TransportError, "JWKS response malformed" unless body.is_a?(Hash) && body["keys"].is_a?(Array)
      raise TransportError, "JWKS response contains no keys" if body["keys"].empty?

      body
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
