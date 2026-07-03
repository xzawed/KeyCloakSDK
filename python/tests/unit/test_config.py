import pytest
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakConfigError
def test_defaults():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")
    assert c.clock_skew == 30.0
    assert c.scopes == ("openid",)
def test_missing_realm_raises():
    with pytest.raises(KeycloakConfigError):
        KeycloakConfig(server_url="https://kc", realm="", client_id="app")
def test_repr_masks_secret():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="supersecret")
    assert "supersecret" not in repr(c)
