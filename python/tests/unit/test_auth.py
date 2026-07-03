"""AuthClient 단위 테스트. python-keycloak `KeycloakOpenID`를 목으로 주입한다.

`auth.py`는 네트워크 경계라 커버리지 게이트(G3)에서 제외되지만(pyproject omit), 이
스위트는 커버리지가 아니라 매핑·PKCE·에러 변환·JWKS 배선 "행동"을 증명하기 위한 것이다.
"""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakAuthenticationError, KeycloakGetError

from keycloak_sdk.auth import AuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError
from keycloak_sdk.oidc import OidcEndpoints


def _config(**overrides: object) -> KeycloakConfig:
    defaults: dict[str, object] = {
        "server_url": "https://kc.example.com",
        "realm": "r",
        "client_id": "app",
        "client_secret": "s3cret",
    }
    defaults.update(overrides)
    return KeycloakConfig(**defaults)  # type: ignore[arg-type]


def _client(openid: MagicMock, config: KeycloakConfig | None = None) -> AuthClient:
    cfg = config or _config()
    endpoints = OidcEndpoints.for_realm(cfg)
    return AuthClient(cfg, endpoints, openid=openid)


def test_constructs_real_openid_when_not_injected():
    """openid 미지정 시 config로부터 실제 KeycloakOpenID를 생성한다(네트워크 호출 없음)."""
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)

    client = AuthClient(config, endpoints)

    assert isinstance(client._openid, KeycloakOpenID)
    assert client._openid.realm_name == "r"
    assert client._openid.client_id == "app"


def test_injected_openid_is_used_verbatim():
    openid = MagicMock(spec=KeycloakOpenID)
    client = _client(openid)

    assert client._openid is openid


def test_wrap_translates_authentication_error_to_auth_error():
    """`_wrap`은 401(KeycloakAuthenticationError)을 KeycloakAuthError로 변환하고
    OAuth `error` 코드를 response_body에서 파싱해 보존한다."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakAuthenticationError(
            error_message=b'{"error": "invalid_grant", "error_description": "bad creds"}',
            response_code=401,
            response_body=b'{"error": "invalid_grant", "error_description": "bad creds"}',
        )

    with pytest.raises(KeycloakAuthError) as excinfo:
        client._wrap(boom)

    assert excinfo.value.error == "invalid_grant"


def test_wrap_translates_error_with_response_code_but_no_json_body():
    """response_body가 JSON이 아니거나 없으면 error 코드는 None으로 남는다(크래시 없음)."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakAuthenticationError(error_message="nope", response_code=400)

    with pytest.raises(KeycloakAuthError) as excinfo:
        client._wrap(boom)

    assert excinfo.value.error is None


def test_wrap_translates_error_without_response_code_to_transport_error():
    """response_code가 없으면(네트워크/전송 계층 오류) KeycloakTransportError로 변환한다."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakGetError(error_message="connection reset")

    with pytest.raises(KeycloakTransportError):
        client._wrap(boom)


def test_wrap_passes_through_successful_result():
    client = _client(MagicMock(spec=KeycloakOpenID))

    assert client._wrap(lambda: 42) == 42
