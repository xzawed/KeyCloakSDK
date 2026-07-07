# frozen_string_literal: true

module KeycloakSdk
  # Keycloak realm의 OIDC 엔드포인트를 규약대로 조립한다(네트워크 없음).
  class OidcEndpoints
    attr_reader :issuer, :authorization, :token, :introspection, :end_session, :jwks

    def initialize(server_url, realm)
      base = "#{server_url}/realms/#{realm}"
      oidc = "#{base}/protocol/openid-connect"
      @issuer = base
      @authorization = "#{oidc}/auth"
      @token = "#{oidc}/token"
      @introspection = "#{oidc}/token/introspect"
      @end_session = "#{oidc}/logout"
      @jwks = "#{oidc}/certs"
      freeze
    end

    def self.from_config(config)
      new(config.server_url, config.realm)
    end
  end
end
