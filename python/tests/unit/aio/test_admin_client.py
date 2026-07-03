"""`AsyncAdminClient` 골격 단위 테스트. 네트워크 경계라 커버리지 게이트에서 제외되지만
(pyproject omit), 지연 생성·시크릿 가드·`aclose` "행동"은 목으로 증명한다.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
from keycloak import KeycloakAdmin

from keycloak_sdk.aio.admin import AsyncAdminClient
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
    client = AsyncAdminClient(_config(), admin=admin)

    assert client.raw is admin


def test_raw_lazily_constructs_real_keycloak_admin_when_not_injected():
    config = _config()
    client = AsyncAdminClient(config)

    raw = client.raw

    assert isinstance(raw, KeycloakAdmin)
    assert raw.connection.realm_name == "r"
    assert raw.connection.client_id == "app"


def test_raw_raises_config_error_when_secret_missing_and_not_injected():
    config = _config(client_secret=None)
    client = AsyncAdminClient(config)

    with pytest.raises(KeycloakConfigError):
        _ = client.raw


def test_construction_without_secret_does_not_raise_until_raw_accessed():
    """secret 없이도 AsyncAdminClient 구성 자체는 성공해야 한다 — 실제 필요 시점(raw
    접근)까지 지연된다(공개 client가 auth만 쓰는 경우를 지원)."""
    config = _config(client_secret=None)

    client = AsyncAdminClient(config)  # no raise

    assert client is not None


def test_resource_properties_wrap_raw():
    admin = MagicMock(spec=KeycloakAdmin)
    client = AsyncAdminClient(_config(), admin=admin)

    assert client.users._admin is admin
    assert client.clients._admin is admin
    assert client.realms._admin is admin
    assert client.roles._admin is admin
    assert client.groups._admin is admin


async def test_aclose_delegates_when_admin_has_aclose():
    admin = MagicMock(spec=KeycloakAdmin)
    admin.aclose = AsyncMock()
    client = AsyncAdminClient(_config(), admin=admin)

    await client.aclose()

    admin.aclose.assert_awaited_once()


async def test_aclose_is_noop_when_admin_never_constructed():
    """`raw`에 한 번도 접근하지 않았다면 `aclose()`가 억지로 `KeycloakAdmin`을
    생성하지 않고 조용히 넘어가야 한다."""
    client = AsyncAdminClient(_config())  # raw never accessed

    await client.aclose()  # must not raise

    assert client._admin is None


async def test_aclose_is_noop_when_real_keycloakadmin_has_no_aclose():
    admin = MagicMock(spec=KeycloakAdmin)
    client = AsyncAdminClient(_config(), admin=admin)

    await client.aclose()  # must not raise even without aclose attribute
