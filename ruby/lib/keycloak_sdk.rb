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
require_relative "keycloak_sdk/admin/users"
require_relative "keycloak_sdk/admin/clients"
require_relative "keycloak_sdk/admin/realms"
require_relative "keycloak_sdk/admin/roles"
require_relative "keycloak_sdk/admin/groups"
require_relative "keycloak_sdk/admin/admin_client"

# Polyglot Keycloak SDK for Ruby.
# 이후 태스크에서 아래에 require를 추가한다:
#   ... (client)
module KeycloakSdk
end

# rack-oauth2 전역 HTTP 타임아웃(hung IdP 방지) — Faraday 커넥션은 rack-oauth2가 내부 소유하므로
# 전역 훅으로 주입한다. per-Config 타임아웃 미세제어는 불가하므로 보수적 기본(10s)으로 고정
# (introspect/logout은 우리 Faraday라 config 타임아웃 적용).
# ⚠️ 브리프 원안은 블록 인자(Faraday::Connection)에 직접 `.open_timeout=`/`.timeout=`을 호출했으나
# Faraday::Connection에는 그런 메서드가 없다(NoMethodError — 첫 grant 호출 시 실제로 재현·확인됨).
# 타임아웃은 Connection이 아니라 그 `#options`(Faraday::RequestOptions)에 있다.
require "rack/oauth2"
Rack::OAuth2.http_config do |conn|
  conn.options.open_timeout = 10
  conn.options.timeout = 10
end
