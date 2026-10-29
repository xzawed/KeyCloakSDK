# frozen_string_literal: true

require "erb"

module KeycloakSdk
  # Assembles a Keycloak realm's OIDC endpoints by convention (no network).
  class OidcEndpoints
    attr_reader :issuer, :authorization, :token, :introspection, :end_session, :jwks

    def initialize(server_url, realm)
      # The issuer is compared as is with the token's iss claim, so the realm is not encoded.
      @issuer = "#{server_url}/realms/#{realm}"
      # In the endpoints the realm is a single path segment. Left as is, "my realm" makes
      # client_credentials_token / create_authorization_request leak a URI::InvalidURIError
      # out of the SDK (the sibling SDKs percent-encode this segment).
      oidc = "#{server_url}/realms/#{escape_realm_segment(realm)}/protocol/openid-connect"
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

    private

    # admin `esc`와 같은 stdlib 인코더. unreserved(A-Za-z0-9\-_.~)만 남기고 나머지
    # UTF-8 바이트는 %XX(대문자). CGI.escape는 공백을 `+`로 내므로 경로 세그먼트에 못 쓴다.
    def escape_realm_segment(realm)
      ERB::Util.url_encode(realm.to_s)
    end
  end
end
