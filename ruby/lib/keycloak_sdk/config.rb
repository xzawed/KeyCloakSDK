# frozen_string_literal: true

module KeycloakSdk
  # 불변 설정. 생성 시 검증하고 freeze한다. client_secret은 inspect에서 마스킹.
  class Config
    # JWKS 최소 재조회 간격 기본값의 **유일한 정의 자리**(초). DoS 증폭 상한이고 아홉 언어가
    # 같은 값으로 정렬돼 있다 — `scripts/test/test-security-defaults.sh`가 아홉 언어 코드와
    # 소비자 문서를 함께 대조한다.
    #
    # ⚠️ 이 숫자를 다른 곳에 다시 적지 말 것. 예전에는 여기 30.0, `JwksStore#initialize`에 10.0으로
    # **두 번** 적혀 있었다. `JwksStore`는 평범한 public 클래스라 소비자가 직접 생성하면
    # (파사드를 거치지 않으면) 문서가 말하는 30초가 아니라 10초를 받아 **IdP를 3배 자주** 때렸다.
    # 한글 README도 그 10.0을 그대로 옮겨 적고 있었다(2026-08-12 문서 감사 → 2026-08-13 Task D1).
    DEFAULT_JWKS_MIN_REFETCH = 30.0

    # JWT `exp`/`nbf` 검증의 시계 오차 허용치 기본값(초). 이것도 아홉 언어 공동 불변식이다 —
    # 한 언어만 커지면 **그 언어에서만 만료된 토큰이 더 오래 통과한다**.
    # ⚠️ `JwtValidator#initialize`가 같은 값을 두 번째로 적고 있었다(둘 다 30이라 아직 갈리지는
    # 않았으나 JWKS가 10.0/30.0으로 갈린 것과 똑같은 모양이다). 그 자리는 이제 이 상수를 참조한다.
    DEFAULT_CLOCK_SKEW = 30

    attr_reader :server_url, :realm, :client_id, :client_secret,
                :scopes, :signature_algorithms, :connect_timeout, :read_timeout, :clock_skew,
                :jwks_min_refetch, :expected_audience

    def initialize(server_url:, realm:, client_id:, client_secret: nil,
                   scopes: ["openid"], signature_algorithms: ["RS256"],
                   connect_timeout: 10, read_timeout: 10, clock_skew: DEFAULT_CLOCK_SKEW,
                   jwks_min_refetch: DEFAULT_JWKS_MIN_REFETCH, expected_audience: nil)
      @server_url = strip_trailing_slashes(normalize_required("server_url", server_url))
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
      # 미해결 kid로 인한 JWKS 재조회의 최소 간격(초) — DoS 증폭 상한. 기본값은 위 상수.
      @jwks_min_refetch = non_negative("jwks_min_refetch", jwks_min_refetch)
      # 토큰 aud에 들어있어야 할 값(기본 nil = client_id). 기본 realm은 client-credentials 토큰의
      # aud에 client_id를 넣지 않으므로, realm이 실제로 발급하는 리소스/오디언스를 지정한다.
      @expected_audience = expected_audience
      freeze
    end

    def inspect
      "#<KeycloakSdk::Config server_url=#{@server_url.inspect} realm=#{@realm.inspect} " \
        "client_id=#{@client_id.inspect} client_secret=#{Masking.mask(@client_secret).inspect} " \
        "scopes=#{@scopes.inspect}>"
    end
    alias to_s inspect

    private

    # 후행 슬래시 제거. 정규식(`sub(%r{/+\z}, "")`)이 아니라 선형 스캔인 이유는 **동형성**이다 —
    # 같은 일을 하는 아홉 언어 중 go(`TrimRight`)·dotnet(`TrimEnd`)·php(`rtrim`)·rust
    # (`trim_end_matches`)·kotlin(`trimEnd`) 다섯이 선형 문자열 트림을 쓰고, 정규식을 쓰던 것은
    # java·node·ruby 셋뿐이었다. java/node는 SonarCloud S8786(정규식 초선형 백트래킹)으로 지적됐고
    # ruby는 지적되지 않았지만, 셋을 함께 옮겨야 "같은 개념은 같은 모양"이라는 이 저장소의 전제가
    # 유지된다. 동작은 정규식과 동일하다(후행 슬래시 전부 제거, 내부 슬래시 보존).
    def strip_trailing_slashes(str)
      i = str.length
      i -= 1 while i.positive? && str[i - 1] == "/"
      str[0, i]
    end

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
