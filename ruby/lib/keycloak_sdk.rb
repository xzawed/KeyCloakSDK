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

# Polyglot Keycloak SDK for Ruby.
# 이후 태스크에서 아래에 require를 추가한다:
#   ... (jwt_validator, auth_client, admin/*, client)
module KeycloakSdk
end
