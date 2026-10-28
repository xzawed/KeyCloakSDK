# frozen_string_literal: true

require_relative "keycloak_sdk/version"
require_relative "keycloak_sdk/masking"
require_relative "keycloak_sdk/errors"
require_relative "keycloak_sdk/config"
require_relative "keycloak_sdk/tokens"
require_relative "keycloak_sdk/oidc_endpoints"
require_relative "keycloak_sdk/http"
require_relative "keycloak_sdk/token_provider"
require_relative "keycloak_sdk/jwks_store"
require_relative "keycloak_sdk/jwt_validator"
require_relative "keycloak_sdk/auth_client"
require_relative "keycloak_sdk/admin/call"
require_relative "keycloak_sdk/admin/bearer_auth"
require_relative "keycloak_sdk/admin/settle_body"
require_relative "keycloak_sdk/admin/users"
require_relative "keycloak_sdk/admin/clients"
require_relative "keycloak_sdk/admin/realms"
require_relative "keycloak_sdk/admin/roles"
require_relative "keycloak_sdk/admin/groups"
require_relative "keycloak_sdk/admin/admin_client"
require_relative "keycloak_sdk/client"

# Polyglot Keycloak SDK for Ruby.
module KeycloakSdk
end

# ⚠️ rack-oauth2 의 HTTP 설정(`Rack::OAuth2.http_config`)은 프로세스 전역이고 먼저 건 쪽이 이긴다 — SDK 는 그것을
# 걸지 않는다. require 때도(과거엔 하드코딩 10초로 전역을 변조했다), AuthClient 생성 때도(걸면 호스트 앱이 나중에 건
# 블록이 조용히 버려진다). SDK 의 요청은 그 연결을 타지 않는다 — 그랜트·introspection·logout·JWKS·admin 은 전부 SDK
# 커넥션(`Http.build`, 클라이언트마다 Config 타임아웃)으로 나가고 인가 URL 조립은 네트워크가 없다
# (`spec/unit/host_http_config_spec.rb`).
require "rack/oauth2"
