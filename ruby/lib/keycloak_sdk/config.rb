# frozen_string_literal: true

require "uri"

module KeycloakSdk
  # Immutable configuration. Validated and frozen at construction. client_secret is masked in inspect.
  class Config
    # The **single definition site** of the default minimum JWKS refetch interval (seconds). It is the DoS
    # amplification cap, and the nine languages are aligned on the same value —
    # `scripts/test/test-security-defaults.sh` checks the nine languages' code and the consumer docs together.
    #
    # ⚠️ Do not write this number anywhere else again. It used to be written **twice** — 30.0 here and 10.0 in
    # `JwksStore#initialize`. `JwksStore` is an ordinary public class, so a consumer who constructed it directly
    # (without going through the facade) got 10 seconds instead of the 30 the docs state and hit **the IdP 3 times as
    # often**. The Korean README had copied that 10.0 as is, too (2026-08-12 docs audit → 2026-08-13 Task D1).
    DEFAULT_JWKS_MIN_REFETCH = 30.0

    # The default clock-skew tolerance (seconds) for JWT `exp`/`nbf` validation. This too is an invariant shared by
    # the nine languages — if it grows in one language only, **expired tokens pass for longer in that language only**.
    # ⚠️ `JwtValidator#initialize` used to write the same value a second time (both were 30, so they had not diverged
    # yet, but it had exactly the shape of the JWKS split into 10.0/30.0). That site now references this constant.
    DEFAULT_CLOCK_SKEW = 30

    # 깨진 server_url의 ConfigError 접두사. 뒤에 짧은 사유만 붙인다(입력·파서 메시지 금지).
    SERVER_URL_ERROR_PREFIX = "server_url must be an absolute http(s) URL: "
    private_constant :SERVER_URL_ERROR_PREFIX

    attr_reader :server_url, :realm, :client_id, :client_secret,
                :scopes, :signature_algorithms, :connect_timeout, :read_timeout, :clock_skew,
                :jwks_min_refetch, :expected_audience

    def initialize(server_url:, realm:, client_id:, client_secret: nil,
                   scopes: ["openid"], signature_algorithms: ["RS256"],
                   connect_timeout: 10, read_timeout: 10, clock_skew: DEFAULT_CLOCK_SKEW,
                   jwks_min_refetch: DEFAULT_JWKS_MIN_REFETCH, expected_audience: nil)
      @server_url = strip_trailing_slashes(normalize_required("server_url", server_url))
      # Right after normalization. A relative URL ("kc.example.com") goes out as RuntimeError "No Host Info" on the
      # first token request, and a URL with a space in it ("http://kc example.com") as URI::InvalidURIError. Neither
      # is a ConfigError — both are exceptions leaking out of the public API — so they are closed off at construction.
      # InvalidURIError#message echoes the input verbatim, so only the reason is kept.
      require_absolute_http_url!(@server_url)
      @realm = normalize_required("realm", realm)
      @client_id = normalize_required("client_id", client_id)
      @client_secret = client_secret
      @scopes = Array(scopes).freeze
      # Pin of the algorithms allowed for JWT signature verification (default RS256). Configurable for ES256/PS256
      # realms, but an empty set would disable the alg pin, so it is rejected.
      @signature_algorithms = non_empty_array("signature_algorithms", signature_algorithms).freeze
      @connect_timeout = positive("connect_timeout", connect_timeout)
      @read_timeout = positive("read_timeout", read_timeout)
      @clock_skew = non_negative("clock_skew", clock_skew)
      # Minimum interval (seconds) between JWKS refetches caused by an unresolved kid — the DoS amplification cap.
      # The default is the constant above.
      @jwks_min_refetch = non_negative("jwks_min_refetch", jwks_min_refetch)
      # The value that must be in the token's aud (default nil = client_id). A stock realm does not put client_id in
      # a client-credentials token's aud, so set the resource/audience the realm actually issues.
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

    # URI::HTTP(HTTPS는 하위 클래스)이고 host가 비어 있지 않으며 port <= 65535.
    # 스킴 대소문자는 URI.parse가 가린다("HTTP://" → URI::HTTP). 언더스코어 host
    # ("keycloak_server")도 이 파서가 받으므로 따로 거부하지 않는다.
    def require_absolute_http_url!(url)
      uri = URI.parse(url)
      raise ConfigError, "#{SERVER_URL_ERROR_PREFIX}scheme must be http or https" unless uri.is_a?(URI::HTTP)
      raise ConfigError, "#{SERVER_URL_ERROR_PREFIX}missing host" if uri.host.to_s.empty?
      raise ConfigError, "#{SERVER_URL_ERROR_PREFIX}port out of range" if uri.port > 65_535
    rescue URI::InvalidURIError
      # cause를 끊지 않으면 InvalidURIError#message(입력 에코)가 예외 사슬에 남는다.
      raise ConfigError, "#{SERVER_URL_ERROR_PREFIX}unparseable", cause: nil
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
