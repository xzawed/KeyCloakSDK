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
require_relative "keycloak_sdk/client"

# Polyglot Keycloak SDK for Ruby.
module KeycloakSdk
end

# ⚠️ rack-oauth2 HTTP 타임아웃은 프로세스 전역(Rack::OAuth2.http_config)이라 per-client 미세제어가
# 불가하다. 과거엔 require 시점에 하드코딩 10초로 박아 (a) 단순 require만으로 전역 상태를 변조하고
# (b) Config 타임아웃을 무시했다. 이제는 AuthClient#initialize에서 Config의 connect/read 타임아웃으로
# 설정한다(auth_client.rb) — require 부작용 제거 + config 반영. 전역이라는 근본 한계는 남지만
# "SDK auth를 실제로 쓸 때"로 스코프가 좁혀진다(require 시점 아님).
# ⚠️ SDK 자신의 토큰 요청은 이 전역 연결을 타지 않는다 — 그랜트는 SDK 커넥션(`Http.build`, 클라이언트마다 Config
# 타임아웃)으로 직접 보낸다(응답 상한 때문). rack-oauth2 의 HTTP 연결을 쓰는 SDK 경로는 이제 없다(인가 URL 조립은 네트워크가 없다).
require "rack/oauth2"
