from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.oidc import OidcEndpoints


def test_for_realm_composes_urls():
    config = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")
    ep = OidcEndpoints.for_realm(config)
    assert ep.issuer == "https://kc/realms/r"
    assert ep.authorization == "https://kc/realms/r/protocol/openid-connect/auth"
    assert ep.token == "https://kc/realms/r/protocol/openid-connect/token"
    assert ep.introspection == "https://kc/realms/r/protocol/openid-connect/token/introspect"
    assert ep.end_session == "https://kc/realms/r/protocol/openid-connect/logout"
    assert ep.jwks == "https://kc/realms/r/protocol/openid-connect/certs"


def test_for_realm_strips_trailing_slash():
    config = KeycloakConfig(server_url="https://kc/", realm="r", client_id="app")
    ep = OidcEndpoints.for_realm(config)
    assert ep.issuer == "https://kc/realms/r"
