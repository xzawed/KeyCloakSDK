# frozen_string_literal: true

require "rack/oauth2"
require "securerandom"
require "digest"
require "base64"

module KeycloakSdk
  # 인증 파사드. rack-oauth2를 래핑(그랜트·PKCE)하고 introspection(RFC7662)·logout은 Faraday로 손수 수행한다.
  # TokenProvider를 구현하지만(직접 사용용), admin은 캐싱 ClientCredentialsTokenProvider를 별도로 쓴다(§4).
  class AuthClient
    include TokenProvider

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
    # realm JWKS로 서명·iss·aud·exp까지 강화 검증한 뒤 nonce 클레임을 대조한다 — OIDC nonce 재생
    # 방지. 불일치·부재·검증실패는 모두 거부(fail-closed). 생략 시 id_token 검증을 건너뛴다
    # (여덟 언어 공통 — exchange에서 nonce를 필수로 만들지 않는다).
    def exchange_code(code:, code_verifier:, redirect_uri:, expected_nonce: nil)
      client = oauth_client(redirect_uri: redirect_uri)
      client.authorization_code = code
      token_set = token_request("authorization_code exchange") { client.access_token!(code_verifier: code_verifier) }
      verify_nonce!(token_set.id_token, expected_nonce) unless expected_nonce.nil?
      token_set
    end

    def refresh(refresh_token:)
      client = oauth_client
      client.refresh_token = refresh_token
      token_request("refresh") { client.access_token! }
    end

    def client_credentials_token
      token_request("client-credentials") { oauth_client.access_token!(scope: @config.scopes.join(" ")) }
    end

    # TokenProvider 계약(직접 사용용). admin은 캐싱 provider를 별도로 쓴다.
    def access_token
      client_credentials_token.access_token
    end

    def introspect(token)
      resp = @http.post(@endpoints.introspection, {
                          token: token, client_id: @config.client_id, client_secret: @config.client_secret
                        })
      raise AuthError, "introspection failed: HTTP #{resp.status}" unless resp.success?

      IntrospectionResult.from_response(resp.body)
    rescue Faraday::Error => e
      raise TransportError, "introspection transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    end

    def logout(refresh_token:)
      resp = @http.post(@endpoints.end_session, {
                          client_id: @config.client_id, client_secret: @config.client_secret,
                          refresh_token: refresh_token
                        })
      raise AuthError, "logout failed: HTTP #{resp.status}" unless resp.success?

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
    def configure_rack_oauth2_timeouts(config)
      Rack::OAuth2.http_config do |conn|
        conn.options.open_timeout = config.connect_timeout
        conn.options.timeout = config.read_timeout
      end
    end

    # id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다
    # (액세스 토큰과 id_token 모두 aud=client_id이므로 검증기를 공유해도 안전 — Kotlin/.NET 동형).
    # ⚠️ `config.expected_audience`를 설정하면 이 공유 검증기가 id_token에도 그 값을 요구한다 —
    # 이 흐름을 쓴다면 해당 오디언스를 id_token에도 매핑해야 한다(audience 매퍼의 "Add to ID token").
    def verify_nonce!(id_token, expected_nonce)
      raise AuthError, "authorization_code exchange failed: missing id_token for nonce validation" if id_token.nil?

      validated = @jwt_validator.validate(id_token)
      return if validated.claims["nonce"] == expected_nonce

      raise AuthError, "authorization_code exchange failed: unexpected nonce"
    rescue TokenValidationError => e
      raise AuthError, "authorization_code exchange failed: invalid id_token: #{e.message}"
    end

    # rack-oauth2 토큰 호출의 오류 경계(§4). 하위 예외는 SDK 타입이 되고 `cause` 에는 원본 대신 `RedactedCause` 가 달린다.
    # ⚠️ OAuth 오류는 **코드와 HTTP 상태만** 싣는다 — `error_description` 은 서버가 고른 자유 문장이라 토큰을
    # 되울릴 수 있고, 오류 본문이 JSON 이 아니면 rack-oauth2 가 본문 전체를 거기 넣는다.
    # ⚠️ 마지막 `StandardError` 는 rack-oauth2 가 형식이 틀린 200 을 읽다 내는 것(NoMethodError·AttrMissing·
    # 'Unknown Token Type')과 `to_token_set` 의 형 변환 실패다 — 원본이 새면 Ruby 3.2 의 NoMethodError 가 본문을 인용한다.
    def token_request(operation)
      to_token_set(yield)
    rescue Error
      raise
    rescue Rack::OAuth2::Client::Error => e
      code = e.response[:error].is_a?(String) ? e.response[:error] : ""
      raise AuthError.new([operation, "failed:", code, "(HTTP #{e.status})"].reject(&:empty?).join(" "),
                          oauth_error: code), cause: RedactedCause.new(e)
    rescue Faraday::Error => e
      raise TransportError, "token endpoint transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    rescue StandardError => e
      raise AuthError, "#{operation} failed: unusable token response (#{e.class})", cause: RedactedCause.new(e)
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
