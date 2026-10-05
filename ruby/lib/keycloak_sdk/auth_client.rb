# frozen_string_literal: true

require "rack/oauth2"
require "securerandom"
require "digest"
require "base64"
require "uri"

module KeycloakSdk
  # 인증 파사드. 인가 URL(PKCE)은 rack-oauth2 로 만들고, 세 그랜트·introspection(RFC7662)·logout 은 SDK 의 Faraday
  # 커넥션으로 직접 보낸다 — 토큰 응답 본문을 상한까지만 읽어야 하는데 rack-oauth2 는 자기 커넥션으로 통째로 읽는다.
  # TokenProvider를 구현하지만(직접 사용용), admin은 캐싱 ClientCredentialsTokenProvider를 별도로 쓴다(§4).
  class AuthClient
    include TokenProvider

    # 메시지에 실어도 되는 OAuth 오류 코드 모양 — RFC 6749·OIDC 등록 코드와 Keycloak 코드는 전부 이 모양이고,
    # 토큰·시크릿(JWT·base64·hex·UUID)은 대문자·숫자·점·하이픈 때문에 걸러진다.
    OAUTH_CODE = /\A[a-z_]{1,64}\z/

    def initialize(config:, http:, jwt_validator:)
      @config = config
      @http = http
      @jwt_validator = jwt_validator
      @endpoints = OidcEndpoints.from_config(config)
      configure_rack_oauth2_timeouts(config)
    end

    def create_authorization_request(redirect_uri:, scopes: nil, state: SecureRandom.urlsafe_base64(24),
                                     nonce: SecureRandom.urlsafe_base64(24))
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      params = {
        scope: (scopes || @config.scopes).join(" "),
        state: state,
        nonce: nonce,
        code_challenge: challenge,
        code_challenge_method: :S256
      }
      url = oauth_client(redirect_uri: redirect_uri).authorization_uri(params)
      AuthorizationRequest.new(url: url.to_s, state: state, code_verifier: verifier, nonce: nonce)
    end

    # `expected_nonce`가 주어지면(create_authorization_request가 항상 돌려주는 nonce) 응답 id_token을
    # realm JWKS로 서명·iss·aud(client_id)·exp까지 강화 검증한 뒤 nonce 클레임을 대조한다 — OIDC nonce 재생
    # 방지. 불일치·부재·검증실패는 모두 거부(fail-closed). 생략 시 id_token 검증을 건너뛴다
    # (여덟 언어 공통 — exchange에서 nonce를 필수로 만들지 않는다).
    def exchange_code(code:, code_verifier:, redirect_uri:, expected_nonce: nil)
      token_set = token_request("authorization_code exchange",
                                { grant_type: "authorization_code", code: code, redirect_uri: redirect_uri,
                                  code_verifier: code_verifier }, required: :code)
      verify_nonce!(token_set.id_token, expected_nonce) unless expected_nonce.nil?
      token_set
    end

    def refresh(refresh_token:)
      token_request("refresh", { grant_type: "refresh_token", refresh_token: refresh_token }, required: :refresh_token)
    end

    def client_credentials_token
      token_request("client-credentials", { grant_type: "client_credentials", scope: @config.scopes.join(" ") })
    end

    # TokenProvider 계약(직접 사용용). admin은 캐싱 provider를 별도로 쓴다.
    def access_token
      client_credentials_token.access_token
    end

    def introspect(token)
      form = form!("introspection", token: token, client_id: @config.client_id, client_secret: @config.client_secret)
      resp = Http.decode_json(Http.read_capped(@http, :post, @endpoints.introspection,
                                               body: form, max_bytes: Http::TOKEN_RESPONSE_MAX_BYTES,
                                               what: "introspection"))
      raise AuthError, "introspection failed: HTTP #{resp.status}" unless resp.success?

      IntrospectionResult.from_response(resp.body)
    rescue Faraday::Error => e
      raise TransportError, "introspection transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    end

    # 본문은 쓰지 않지만 읽는다 — `TOKEN_RESPONSE_MAX_BYTES` 까지만(넘으면 상태와 무관하게 TransportError).
    # 해석은 커넥션의 json 미들웨어가 하던 그대로 남긴다: JSON 이라면서 JSON 이 아닌 본문은 지금처럼 TransportError 다.
    # UTF-8 검사는 걸지 않는다(`check_utf8: false`) — 값을 쓰지 않아 지킬 것이 없고, 걸면 400 이 오류 본문의 바이트에
    # 따라 AuthError 에서 TransportError 로 바뀐다(hostile_token_response_spec 의 u2). 해석은 상태 검사보다 먼저다.
    def logout(refresh_token:)
      form = form!("logout", client_id: @config.client_id, client_secret: @config.client_secret,
                             refresh_token: refresh_token)
      resp = Http.read_capped(@http, :post, @endpoints.end_session,
                              body: form, max_bytes: Http::TOKEN_RESPONSE_MAX_BYTES, what: "logout")
      raise AuthError, "logout failed: HTTP #{resp.status}" unless Http.decode_json(resp, check_utf8: false).success?

      nil
    rescue Faraday::Error => e
      raise TransportError, "logout transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    end

    def validate(token)
      @jwt_validator.validate(token)
    end

    private

    # rack-oauth2의 프로세스 전역 HTTP 타임아웃을 Config로 설정한다(require 시점 하드코딩 대신).
    # 타임아웃은 Faraday::Connection이 아니라 그 #options(Faraday::RequestOptions)에 있다
    # (Connection에 open_timeout=/timeout= 세터가 없어 NoMethodError — 게차 참조).
    # ⚠️ SDK 의 토큰 요청은 이제 rack-oauth2 의 연결을 타지 않는다(그랜트는 `token_request` 가 직접 보낸다) — 이 등록이
    # 닿는 것은 같은 프로세스의 다른 rack-oauth2 사용자뿐이다. 등록은 first-wins(`@@http_config ||= block`)다.
    def configure_rack_oauth2_timeouts(config)
      Rack::OAuth2.http_config do |conn|
        conn.options.open_timeout = config.connect_timeout
        conn.options.timeout = config.read_timeout
      end
    end

    # id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다.
    # aud 는 `expected_audience` 재정의가 아니라 **client_id** 다(OIDC Core §2·§3.1.3.7) — 재정의는 액세스 토큰의 것.
    # 검증기(=키 저장소)는 `validate` 와 같은 하나를 쓴다.
    def verify_nonce!(id_token, expected_nonce)
      raise AuthError, "authorization_code exchange failed: missing id_token for nonce validation" if id_token.nil?

      validated = @jwt_validator.validate(id_token, audience: @config.client_id)
      return if validated.claims["nonce"] == expected_nonce

      raise AuthError, "authorization_code exchange failed: unexpected nonce"
    rescue TokenValidationError => e
      raise AuthError, "authorization_code exchange failed: invalid id_token: #{e.message}"
    end

    # 토큰 그랜트 하나와 그 오류 경계(§4). 하위 예외는 SDK 타입이 되고 `cause` 에는 원본 대신 `RedactedCause` 가 달린다.
    # ⚠️ OAuth 오류는 **코드와 HTTP 상태만** 싣는다 — `error_description` 은 서버가 고른 자유 문장이라 토큰을
    # 되울릴 수 있고, 오류 본문이 JSON 이 아니면 rack-oauth2 가 본문 전체를 거기 넣는다. 코드 자리도 서버 값이라
    # **코드 모양**(`OAUTH_CODE` — 등록 코드는 전부 소문자·밑줄)일 때만 메시지에 싣는다(`oauth_error` 에는 그대로).
    # ⚠️ 마지막 `StandardError` 는 형식이 틀린 200 을 읽다 나는 것(NoMethodError·AttrMissing·'Unknown Token Type')과
    # `to_token_set` 의 형 변환 실패다 — 원본이 새면 Ruby 3.2 의 NoMethodError 가 본문을 인용한다.
    # ⚠️ 필수 값(`code`·`refresh_token`)이 비면 보내지 않는다 — rack-oauth2 의 그랜트가 하던 검사이고, 그때는 이 경계
    # 밖에서 raw `AttrRequired::AttrMissing` 으로 샜다.
    def token_request(operation, params, required: nil)
      raise AuthError, "#{operation} failed: #{required} is required" if required && missing?(params[required])

      to_token_set(oauth_token(post_grant(operation, params)))
    rescue Error
      raise
    rescue Rack::OAuth2::Client::Error => e
      code = e.response[:error].is_a?(String) ? e.response[:error] : ""
      shown = code.match?(OAUTH_CODE) ? code : "non-standard error code"
      raise AuthError.new("#{operation} failed: #{shown} (HTTP #{e.status})", oauth_error: code),
            cause: RedactedCause.new(e)
    rescue Faraday::Error => e
      raise TransportError, "token endpoint transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    rescue StandardError => e
      raise AuthError, "#{operation} failed: unusable token response (#{e.class})", cause: RedactedCause.new(e)
    end

    # 그랜트를 SDK 커넥션으로 보낸다 — 클라이언트 인증은 rack-oauth2 의 기본(`:basic`)과 같은 모양(id·secret 을
    # 각각 form-url-encode 한 뒤 base64)이고, 빈 값은 rack-oauth2 의 `Util.compact_hash` 처럼 보내지 않는다.
    # 본문은 `TOKEN_RESPONSE_MAX_BYTES` 까지만 읽는다.
    def post_grant(operation, params)
      form = form!(operation, **params).reject { |_, v| v.nil? || v.to_s.match?(/\A[[:space:]]*\z/) }
      pair = [@config.client_id, @config.client_secret].map { |v| URI.encode_www_form_component(v) }.join(":")
      basic = { "Authorization" => "Basic #{Base64.strict_encode64(pair)}" }
      Http.decode_json(Http.read_capped(@http, :post, @endpoints.token,
                                        body: form, headers: basic,
                                        max_bytes: Http::TOKEN_RESPONSE_MAX_BYTES, what: "token"))
    end

    # rack-oauth2 의 응답 규칙(`Client#handle_response` — 2.3.0 client.rb:205-240)을 SDK 가 읽은 본문에 그대로 건다:
    # 200·201 은 token_type 이 bearer 인 `AccessToken::Bearer`, 그 밖은 `Client::Error`(본문이 객체가 아니면 'Unknown').
    # 그 메서드는 private 이라 규칙만 옮겼다 — 결과·오류는 rack-oauth2 의 공개 타입이라 위 오류 대응이 그대로다.
    # 객체가 아닌 200 본문은 rack-oauth2 처럼 NoMethodError 로 떨어져 `token_request` 가 AuthError 로 바꾼다.
    def oauth_token(resp)
      body = resp.body
      unless (200..201).cover?(resp.status)
        error = body.is_a?(Hash) ? body.transform_keys(&:to_sym) : { error: "Unknown", error_description: body }
        raise Rack::OAuth2::Client::Error.new(resp.status, error)
      end

      token_hash = body.transform_keys(&:to_sym)
      raise "Unknown Token Type" unless token_hash[:token_type]&.downcase == "bearer"

      Rack::OAuth2::AccessToken::Bearer.new(token_hash)
    end

    # rack-oauth2 의 `attr_required` 와 같은 「비었다」 — nil 이거나 빈 값(공백뿐인 문자열은 비지 않았다).
    def missing?(value)
      value.respond_to?(:empty?) ? value.empty? : value.nil?
    end

    # 폼 값이 잘못된 UTF-8 이면 요청 없이 거부하고(어느 자리인지만 말한다) 아니면 폼을 돌려준다. Faraday 의 폼
    # 인코더(`Faraday::Utils.escape` 의 `gsub`)가 그것에서 raw ArgumentError 를 냈다(실측: logout·introspect 는 요청 0 건에
    # raw, 그랜트는 「unusable token response (ArgumentError)」라는 틀린 말). 고쳐 쓰지 않는다.
    def form!(operation, **form)
      bad = form.find { |_, v| v.is_a?(String) && !v.valid_encoding? }
      raise AuthError, "#{operation} failed: #{bad.first} is not valid UTF-8" if bad

      form
    end

    def oauth_client(redirect_uri: nil)
      Rack::OAuth2::Client.new(
        identifier: @config.client_id,
        secret: @config.client_secret,
        authorization_endpoint: @endpoints.authorization,
        token_endpoint: @endpoints.token,
        redirect_uri: redirect_uri
      )
    end

    # `expires_in` 은 `TokenSet.from_response` 와 같이 정수로 읽는다(문자열 "300" 허용) — 예전에는 문자열이면
    # `Float + String` 의 TypeError 가 경계를 뚫었다. 변환 실패는 `token_request` 가 AuthError 로 바꾼다.
    def to_token_set(token)
      raw = token.raw_attributes || {}
      expires_in = token.expires_in && Integer(token.expires_in)
      TokenSet.new(
        access_token: token.access_token,
        token_type: "Bearer",
        expires_in: expires_in,
        refresh_token: token.refresh_token,
        id_token: raw[:id_token] || raw["id_token"],
        scope: raw[:scope] || raw["scope"],
        expires_at: expires_in ? Time.now.to_f + expires_in : nil
      )
    end
  end
end
