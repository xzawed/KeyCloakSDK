# frozen_string_literal: true

require "jwt"

module KeycloakSdk
  # 자체강화 JWT 검증기. ruby-jwt의 안전하지 않은 기본값을 전부 오버라이드한다:
  # RS256 핀(none/confusion 구조적 거부)·iss 정확·aud 포함·exp 필수·nbf·클록스큐.
  # 키는 DoS-safe JwksStore로 조회한다(위조 서명은 재조회 미유발). 헤더 alg는 검증 알고리즘 선택에 미사용.
  class JwtValidator
    # ⚠️ `clock_skew` 기본값을 여기 숫자로 적지 말 것 — `Config`가 유일한 정의 자리다(Task D1과
    # 같은 부류). 이 클래스도 public이라 소비자가 직접 생성할 수 있고, 두 자리가 갈리면 그
    # 경로에서만 만료된 토큰이 더 오래 통과한다.
    def initialize(issuer:, audience:, jwks_store:, algorithms: ["RS256"], clock_skew: Config::DEFAULT_CLOCK_SKEW)
      # ruby-jwt의 verify_iss/verify_aud 빌더는 값이 nil이면 조용히 no-op이 되어
      # verify_iss:true/verify_aud:true를 켜도 검사를 건너뛴다 — fail-closed로 방어.
      raise ConfigError, "issuer is required" if issuer.nil? || issuer.to_s.strip.empty?
      raise ConfigError, "audience is required" if audience.nil? || audience.to_s.strip.empty?

      @issuer = issuer
      @audience = audience
      @jwks_store = jwks_store
      @algorithms = algorithms
      @clock_skew = clock_skew
    end

    # 기대 aud는 config.expected_audience(설정 시) — 미설정이면 종전대로 client_id.
    def self.from_config(config:, jwks_store:)
      new(issuer: OidcEndpoints.from_config(config).issuer,
          audience: config.expected_audience || config.client_id, jwks_store: jwks_store,
          algorithms: config.signature_algorithms, clock_skew: config.clock_skew)
    end

    def validate(token)
      payload, = JWT.decode(token, nil, true, decode_options)
      to_validated(payload)
    rescue JWT::DecodeError => e
      raise TokenValidationError, "JWT validation failed: #{e.message}"
    end

    private

    def decode_options
      {
        algorithms: @algorithms,
        jwks: jwks_loader,
        verify_iss: true, iss: @issuer,
        verify_aud: true, aud: @audience,
        verify_expiration: true,
        verify_not_before: true,
        required_claims: %w[exp iss aud],
        leeway: @clock_skew
      }
    end

    # 초기 호출 {kid:}=캐시, 미해결 시 {kid_not_found:true, invalidate:true, kid:}=재조회.
    # JwksStore#key_set(force:)는 cold-cache 재조회가 rate-limit되면 nil을 반환할 수 있으므로
    # 빈 key set으로 폴백한다 — ruby-jwt에 nil을 넘기면 raw NoMethodError가 나므로 반드시 가드한다.
    def jwks_loader
      lambda do |opts|
        force = opts[:kid_not_found] || opts[:invalidate] || false
        @jwks_store.key_set(force: force) || { "keys" => [] }
      end
    end

    def to_validated(payload)
      ValidatedToken.new(
        subject: payload["sub"],
        audience: Array(payload["aud"]),
        issuer: payload["iss"],
        expires_at: payload["exp"],
        issued_at: payload["iat"],
        claims: payload
      )
    end
  end
end
