from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConfigError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakSdkError,
    KeycloakTransportError,
    TokenValidationError,
)


def test_admin_error_carries_status():
    e = KeycloakNotFoundError(404, "User not found")
    assert e.status_code == 404
    assert e.keycloak_error == "User not found"
    assert isinstance(e, KeycloakAdminError)
    assert isinstance(e, KeycloakSdkError)


def test_config_error_is_sdk_error():
    assert isinstance(KeycloakConfigError("bad"), KeycloakSdkError)


def test_auth_error_carries_error_code():
    e = KeycloakAuthError("invalid grant", error="invalid_grant")
    assert e.error == "invalid_grant"
    assert isinstance(e, KeycloakSdkError)
    assert str(e) == "invalid grant"


def test_auth_error_default_error_is_none():
    e = KeycloakAuthError("boom")
    assert e.error is None


def test_conflict_error_is_admin_error():
    e = KeycloakConflictError(409, "already exists")
    assert isinstance(e, KeycloakAdminError)
    assert isinstance(e, KeycloakSdkError)


def test_forbidden_error_is_admin_error():
    e = KeycloakForbiddenError(403, "forbidden")
    assert isinstance(e, KeycloakAdminError)
    assert isinstance(e, KeycloakSdkError)


def test_transport_error_is_sdk_error():
    assert isinstance(KeycloakTransportError("network down"), KeycloakSdkError)


def test_token_validation_error_is_sdk_error():
    assert isinstance(TokenValidationError("bad claims"), KeycloakSdkError)
