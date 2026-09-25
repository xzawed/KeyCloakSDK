# frozen_string_literal: true

require "erb"

module KeycloakSdk
  # Keycloak realm의 OIDC 엔드포인트를 규약대로 조립한다(네트워크 없음).
  class OidcEndpoints
    attr_reader :issuer, :authorization, :token, :introspection, :end_session, :jwks

    def initialize(server_url, realm)
      # issuer는 토큰 iss 클레임과 그대로 비교하므로 realm을 인코딩하지 않는다.
      @issuer = "#{server_url}/realms/#{realm}"
      # 엔드포인트의 realm은 경로 세그먼트 하나다. "my realm"을 그대로 두면
      # client_credentials_token / create_authorization_request가 URI::InvalidURIError를
      # SDK 밖으로 흘린다(자매 SDK는 이 세그먼트를 퍼센트 인코딩한다).
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
