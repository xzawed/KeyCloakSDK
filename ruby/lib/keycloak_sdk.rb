# frozen_string_literal: true

require_relative "keycloak_sdk/version"
require_relative "keycloak_sdk/masking"
require_relative "keycloak_sdk/errors"

# Polyglot Keycloak SDK for Ruby.
# 이후 태스크에서 아래에 require를 추가한다:
#   require_relative "keycloak_sdk/config"
#   ... (tokens, oidc_endpoints, token_provider, jwks_store, jwt_validator, auth_client, admin/*, client)
module KeycloakSdk
end
