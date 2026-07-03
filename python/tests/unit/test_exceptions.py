from keycloak_sdk.exceptions import (
    KeycloakSdkError, KeycloakAdminError, KeycloakNotFoundError, KeycloakConfigError,
)
def test_admin_error_carries_status():
    e = KeycloakNotFoundError(404, "User not found")
    assert e.status_code == 404
    assert e.keycloak_error == "User not found"
    assert isinstance(e, KeycloakAdminError)
    assert isinstance(e, KeycloakSdkError)
def test_config_error_is_sdk_error():
    assert isinstance(KeycloakConfigError("bad"), KeycloakSdkError)
