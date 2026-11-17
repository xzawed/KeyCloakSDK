# frozen_string_literal: true

require "jwt"

module KeycloakSdk
  # Self-hardened JWT validator. It overrides every unsafe ruby-jwt default:
  # RS256 pin (none/confusion rejected structurally) · exact iss · aud membership · exp required · nbf · clock skew.
  # Keys are looked up through the DoS-safe JwksStore (a forged signature triggers no refetch). The header alg is
  # not used to choose the verification algorithm. `validate` takes access tokens only (token type); an id_token goes
  # through `validate_id_token` (authorized party).
  class JwtValidator
    # 받는 토큰의 길이 상한(아홉 언어 공통). Microsoft.IdentityModel 의 `DefaultMaximumTokenSizeInBytes` 와 같은 수이고,
    # Keycloak 26.6 기본값이 받는 가장 긴 Bearer(65,459 B)의 약 3.9 배라 서버가 낸 토큰은 거부하지 않는다.
    JWT_MAX_BYTES = 256_000
    private_constant :JWT_MAX_BYTES

    # 접근 토큰이 아닌 Keycloak 토큰의 페이로드 `typ`(org.keycloak.util.TokenUtil) — id_token · refresh · offline ·
    # 백채널 logout · 직렬화된 id_token. 접근 토큰은 Bearer · DPoP 다.
    NOT_ACCESS_TOKEN_TYPES = %w[ID Refresh Offline Logout Serialized-ID].freeze
    private_constant :NOT_ACCESS_TOKEN_TYPES

    # ⚠️ Do not write the `clock_skew` default here as a number — `Config` is its single definition site (the same
    # class of issue as Task D1). This class is public too, so a consumer can construct it directly, and if the two
    # sites diverge, expired tokens pass for longer on that path only.
    def initialize(issuer:, audience:, jwks_store:, algorithms: ["RS256"], clock_skew: Config::DEFAULT_CLOCK_SKEW)
      # ruby-jwt's verify_iss/verify_aud builders silently become no-ops when the value is nil, so the checks are
      # skipped even with verify_iss:true/verify_aud:true turned on — guarded fail-closed.
      raise ConfigError, "issuer is required" if issuer.nil? || issuer.to_s.strip.empty?
      raise ConfigError, "audience is required" if audience.nil? || audience.to_s.strip.empty?

      @issuer = issuer
      @audience = audience
      @jwks_store = jwks_store
      @algorithms = algorithms
      @clock_skew = clock_skew
    end

    # The expected aud is config.expected_audience (when set) — when unset, client_id as before.
    def self.from_config(config:, jwks_store:)
      new(issuer: OidcEndpoints.from_config(config).issuer,
          audience: config.expected_audience || config.client_id, jwks_store: jwks_store,
          algorithms: config.signature_algorithms, clock_skew: config.clock_skew)
    end

    # Validates an access token. `audience:` is the expected aud for this call only (default = the value given at
    # construction). A token whose payload `typ` names another kind of Keycloak token — an id_token (`ID`), `Refresh`,
    # `Offline`, `Logout` or `Serialized-ID` — is refused even when every other check passes; any other `typ`, or
    # none, is not looked at. An id_token goes through `validate_id_token`.
    # ⚠️ nil or blank is a ConfigError, as in the constructor — with `aud: nil`, ruby-jwt skips the aud check.
    def validate(token, audience: @audience)
      validated = verify(token, audience)
      reject_other_token_type!(validated.claims)
      validated
    end

    # Validates an id_token, the code exchange's path: every check of `validate` with aud held to `client_id` — not to
    # the configured audience, which restricts access tokens — and no token-type check (an id_token is typed `ID`).
    # Then the authorized party (OIDC Core §3.1.3.7 steps 4-5): an id_token with more than one audience must carry
    # `azp`, and an `azp` that is present must be `client_id`. The key store (cache · refetch limit · backoff) is this
    # instance's single one. ⚠️ nil or blank `client_id` is a ConfigError.
    def validate_id_token(token, client_id:)
      raise ConfigError, "client_id is required" if client_id.nil? || client_id.to_s.strip.empty?

      validated = verify(token, client_id)
      require_authorized_party!(validated.claims, client_id)
      validated
    end

    private

    # 두 진입점이 나누는 검증 본문 — 기대 aud 만 다르다.
    def verify(token, audience)
      reject_oversized!(token) # ⚠️ it comes first — before splitting · decoding · the JWKS load (method below)
      raise ConfigError, "audience is required" if audience.nil? || audience.to_s.strip.empty?
      # ⚠️ ruby-jwt `split`s the token first of all, and with invalid UTF-8 that is a raw ArgumentError (measured).
      if token.is_a?(String) && !token.valid_encoding?
        raise TokenValidationError, "JWT validation failed: token is not valid UTF-8"
      end

      reject_symmetric!(token) # ⚠️ before `JWT.decode` — the alg pin and the key lookup are both inside it

      payload, = JWT.decode(token, nil, true, decode_options(audience))
      to_validated(payload)
    rescue JWT::DecodeError => e
      # ruby-jwt's messages do not quote the input. Their **cause** does — when a segment is not JSON, the
      # JSON::ParserError carries the decoded token segment (measured) — so the chain is cut with `RedactedCause`.
      raise TokenValidationError, "JWT validation failed: #{e.message}", cause: RedactedCause.new(e)
    end

    # 토큰 종류 — 접근 토큰 경로만. 문자열일 때만, 대소문자까지 정확히 견준다. 값을 인용해도 된다 — 위 다섯 상수 중 하나다.
    def reject_other_token_type!(claims)
      typ = claims["typ"]
      return unless typ.is_a?(String) && NOT_ACCESS_TOKEN_TYPES.include?(typ)

      raise TokenValidationError, "JWT validation failed: not an access token (typ \"#{typ}\")"
    end

    # 권한 부여 당사자 — id_token 경로만. 접근 토큰의 azp 는 그것을 요청한 클라이언트라 aud 와 다른 것이 정상이다.
    # azp 는 있으면(JSON null 도 있는 것이다) 문자열이고 client_id 와 같아야 한다.
    def require_authorized_party!(claims, client_id)
      if claims.key?("azp")
        return if claims["azp"].is_a?(String) && claims["azp"] == client_id

        raise TokenValidationError, "JWT validation failed: azp does not match the client id"
      end
      return unless claims["aud"].is_a?(Array) && claims["aud"].length > 1

      raise TokenValidationError, "JWT validation failed: azp is required when aud has more than one value"
    end

    # 길이 상한 — ruby-jwt 는 서명을 보기 전에 토큰을 나누고 base64·JSON 디코드하며(할당이 길이에 비례한다), 키는
    # 그 뒤에 JWKS 에서 찾는다. 단위는 `bytesize`(진짜 JWT 는 ASCII 라 문자 수와 같다)이고, 잘못된 UTF-8 이어도 잴 수
    # 있어 `validate` 의 인코딩 검사보다 앞이다. String 이 아닌 값은 지금처럼 ruby-jwt 가 거부한다.
    def reject_oversized!(token)
      return unless token.is_a?(String) && token.bytesize > JWT_MAX_BYTES

      raise TokenValidationError, "JWT validation failed: token exceeds #{JWT_MAX_BYTES} bytes"
    end

    # ⚠️ 허용 목록에 든 HS(대칭) 알고리즘은 kid · 키 조회 · JWKS 요청 **전에** 거부한다(등록부 hs-refusal-rests-on-libraries)
    # — 검증 키는 realm JWKS(공개 문서)에서만 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다. 설정 핀은 ruby-jwt 가
    # `JWT.decode` 안에서, 키를 찾는 그 호출 안에서 걸므로 헤더 alg 를 여기서 직접 본다. 허용 여부는 ruby-jwt 와 같이
    # 대소문자 없이 견준다(`valid_alg?` 의 `casecmp` — 아니면 `hs256` 이 핀을 지나 키를 찾았다, 실측). 허용 목록 밖의
    # alg 와 읽을 수 없는 헤더는 판정하지 않는다 — 지금처럼 ruby-jwt 가 거부한다.
    def reject_symmetric!(token)
      alg = header_alg(token)
      return unless alg.is_a?(String) && alg.upcase.start_with?("HS")
      return unless Array(@algorithms).any? { |a| a.to_s.casecmp(alg)&.zero? }

      raise TokenValidationError, "JWT validation failed: algorithm not allowed: #{alg} (a JWKS holds public keys only)"
    end

    # 헤더의 `alg` — ruby-jwt 가 `JWT.decode` 에서 읽는 그 해석(`JWT::EncodedToken#header`)으로 읽는다.
    def header_alg(token)
      JWT::EncodedToken.new(token).header["alg"]
    rescue StandardError # 기형 헤더 · String 이 아닌 값 — 판정은 지금의 길(ruby-jwt)에 맡긴다
      nil
    end

    def decode_options(audience)
      {
        algorithms: @algorithms,
        jwks: jwks_loader,
        verify_iss: true, iss: @issuer,
        verify_aud: true, aud: audience,
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
