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
    end

    def create_authorization_request(redirect_uri:, scopes: nil, state: SecureRandom.urlsafe_base64(24), nonce: nil)
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      params = {
        scope: (scopes || @config.scopes).join(" "),
        state: state,
        code_challenge: challenge,
        code_challenge_method: :S256
      }
      params[:nonce] = nonce if nonce
      url = oauth_client(redirect_uri: redirect_uri).authorization_uri(params)
      AuthorizationRequest.new(url: url.to_s, state: state, code_verifier: verifier)
    end

    def exchange_code(code:, code_verifier:, redirect_uri:)
      client = oauth_client(redirect_uri: redirect_uri)
      client.authorization_code = code
      to_token_set(client.access_token!(code_verifier: code_verifier))
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("authorization_code exchange failed: #{e.message}", oauth_error: e.response[:error].to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end

    def refresh(refresh_token:)
      client = oauth_client
      client.refresh_token = refresh_token
      to_token_set(client.access_token!)
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("refresh failed: #{e.message}", oauth_error: e.response[:error].to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end

    def client_credentials_token
      to_token_set(oauth_client.access_token!(scope: @config.scopes.join(" ")))
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("client-credentials failed: #{e.message}", oauth_error: e.response[:error].to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
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
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "introspection transport error: #{e.message}"
    end

    def logout(refresh_token:)
      resp = @http.post(@endpoints.end_session, {
                          client_id: @config.client_id, client_secret: @config.client_secret,
                          refresh_token: refresh_token
                        })
      raise AuthError, "logout failed: HTTP #{resp.status}" unless resp.success?

      nil
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "logout transport error: #{e.message}"
    end

    def validate(token)
      @jwt_validator.validate(token)
    end

    private

    def oauth_client(redirect_uri: nil)
      Rack::OAuth2::Client.new(
        identifier: @config.client_id,
        secret: @config.client_secret,
        authorization_endpoint: @endpoints.authorization,
        token_endpoint: @endpoints.token,
        redirect_uri: redirect_uri
      )
    end

    def to_token_set(token)
      raw = token.raw_attributes || {}
      scope = raw[:scope] || raw["scope"]
      TokenSet.new(
        access_token: token.access_token,
        token_type: "Bearer",
        expires_in: token.expires_in,
        refresh_token: token.refresh_token,
        id_token: raw[:id_token] || raw["id_token"],
        scope: scope,
        expires_at: token.expires_in ? Time.now.to_f + token.expires_in : nil
      )
    end
  end
end
