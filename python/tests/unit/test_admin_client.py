"""`AdminClient` 골격 단위 테스트. 네트워크 경계라 커버리지 게이트에서 제외되지만
(pyproject omit), 지연 생성·시크릿 가드 "행동"은 목으로 증명한다.
"""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakConfigError


def _config(**overrides: object) -> KeycloakConfig:
    defaults: dict[str, object] = {
        "server_url": "https://kc.example.com",
        "realm": "r",
        "client_id": "app",
        "client_secret": "s3cret",
    }
    defaults.update(overrides)
    return KeycloakConfig(**defaults)  # type: ignore[arg-type]


def test_injected_admin_is_used_verbatim():
    admin = MagicMock(spec=KeycloakAdmin)
    client = AdminClient(_config(), admin=admin)

    assert client.raw is admin


def test_raw_lazily_constructs_real_keycloak_admin_when_not_injected():
    config = _config()
    client = AdminClient(config)

    raw = client.raw

    assert isinstance(raw, KeycloakAdmin)
    assert raw.connection.realm_name == "r"
    assert raw.connection.client_id == "app"


def test_raw_raises_config_error_when_secret_missing_and_not_injected():
    config = _config(client_secret=None)
    client = AdminClient(config)

    with pytest.raises(KeycloakConfigError):
        _ = client.raw


def test_construction_without_secret_does_not_raise_until_raw_accessed():
    """secret 없이도 AdminClient 구성 자체는 성공해야 한다 — 실제 필요 시점(raw
    접근)까지 지연된다(공개 client가 auth만 쓰는 경우를 지원)."""
    config = _config(client_secret=None)

    client = AdminClient(config)  # no raise

    assert client is not None


def test_close_is_noop():
    """`close()`는 `KeycloakClient`(WBS 5.1)의 컨텍스트 매니저 프로토콜과 대칭을
    맞추기 위한 no-op — 호출해도 예외가 없고 `raw` 캐시를 건드리지 않는다."""
    admin = MagicMock(spec=KeycloakAdmin)
    client = AdminClient(_config(), admin=admin)

    client.close()

    assert client.raw is admin
