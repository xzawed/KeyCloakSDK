"""``AsyncKeycloakClient`` 통합 진입점 단위 테스트 — sync ``test_client.py``의 async 미러.

이 모듈은 (sync ``client.py``와 달리) 커버리지 omit 대상이 아니다 — 네트워크
경계(``AsyncAuthClient``/``AsyncAdminClient`` 생성 자체)는 여기서 패칭으로 우회하고,
지연 생성·시크릿 없는 public client 경로·수명주기(``aclose``/``__aenter__``/``__aexit__``)
로직을 목으로 증명한다.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.auth import AsyncAuthClient
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


async def test_async_context_manager_and_wiring() -> None:
    config = _config()
    async with AsyncKeycloakClient.create(config) as kc:
        assert kc.auth is not None
        assert isinstance(kc.auth, AsyncAuthClient)


async def test_create_with_public_client_no_secret_auth_ok() -> None:
    """secret 없는 public client 설정으로도 ``create()``+``auth`` 접근은 성공해야 한다
    (admin 지연 생성이므로 secret 검증은 트리거되지 않는다)."""
    config = _config(client_secret=None)

    kc = AsyncKeycloakClient.create(config)

    assert kc.auth is not None
    await kc.aclose()


async def test_of_aclose_delegates() -> None:
    auth = MagicMock()
    auth.aclose = AsyncMock()
    admin = MagicMock()
    admin.aclose = AsyncMock()

    kc = AsyncKeycloakClient._of(auth, admin)

    assert kc.admin is admin
    await kc.aclose()

    auth.aclose.assert_awaited_once()  # auth 세션도 항상 정리(FD 누수 방지)
    admin.aclose.assert_awaited_once()


async def test_aclose_is_noop_when_admin_never_accessed() -> None:
    config = _config()
    kc = AsyncKeycloakClient.create(config)

    await kc.aclose()  # must not raise, must not construct admin


async def test_admin_is_lazily_constructed_on_first_access() -> None:
    config = _config()
    kc = AsyncKeycloakClient.create(config)

    with patch("keycloak_sdk.aio.client.AsyncAdminClient") as admin_cls:
        instance = MagicMock()
        admin_cls.return_value = instance

        admin1 = kc.admin
        admin2 = kc.admin

    admin_cls.assert_called_once_with(config)
    assert admin1 is instance
    assert admin2 is instance


async def test_admin_lazy_then_aclose_delegates() -> None:
    config = _config()
    kc = AsyncKeycloakClient.create(config)

    with patch("keycloak_sdk.aio.client.AsyncAdminClient") as admin_cls:
        instance = MagicMock()
        instance.aclose = AsyncMock()
        admin_cls.return_value = instance

        _ = kc.admin
        await kc.aclose()

    instance.aclose.assert_awaited_once()


def test_of_is_package_private_seam_type() -> None:
    auth = MagicMock()
    admin = MagicMock()

    kc = AsyncKeycloakClient._of(auth, admin)

    assert isinstance(kc, AsyncKeycloakClient)
    assert kc.auth is auth
    assert kc.admin is admin


def test_admin_without_config_raises_config_error() -> None:
    """방어적 가드 — `_of()`/`create()` 경로에서는 발생하지 않지만, config 없이
    구성된 인스턴스가 지연 admin 생성을 시도하면 명확한 SDK 예외로 실패해야 한다."""
    auth = MagicMock()
    kc = AsyncKeycloakClient(None, auth)

    with pytest.raises(KeycloakConfigError):
        _ = kc.admin
