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


async def test_aclose_closes_admin_connection():
    """admin이 생성돼 있으면 하위 `ConnectionManager.aclose()`로 httpx.AsyncClient 풀을
    닫는다(FD/소켓 누수 방지). `KeycloakAdmin`엔 `aclose`가 없고 실제 자원은 `connection`에
    있으므로 `admin.connection.aclose()`를 호출해야 한다(async auth 미러와 동형)."""
    admin = MagicMock(spec=KeycloakAdmin)
    admin.connection.aclose = AsyncMock()
    client = AsyncAdminClient(_config(), admin=admin)

    await client.aclose()

    admin.connection.aclose.assert_awaited_once()


async def test_aclose_is_noop_when_admin_never_constructed():
    """`raw`에 한 번도 접근하지 않았다면 `aclose()`가 억지로 `KeycloakAdmin`을
    생성하지 않고 조용히 넘어가야 한다(`self._admin`이 None → conn None → no-op)."""
    client = AsyncAdminClient(_config())  # raw never accessed

    await client.aclose()  # must not raise

    assert client._admin is None


async def test_construction_is_refused_when_connection_is_missing():
    """⚠️ 의도된 계약 변경 — 예전에는 `connection`이 없어도 조용히 넘어갔다.

    지금은 **생성 자체를 거부**한다. 리다이렉트 하드닝이 `connection._s`에 걸리므로, 그 구조가
    없는데도 클라이언트를 만들어주면 하드닝이 조용히 사라진 채 동작하는 객체가 나온다 —
    그 상태에서 3xx를 만나면 `client_secret`이 실린 POST 바디가 리다이렉트 대상으로 간다.
    "조용히 무방비"보다 "시끄럽게 실패"가 맞다.
    """
    admin = MagicMock(spec=KeycloakAdmin)
    admin.connection = None

    with pytest.raises(KeycloakConfigError, match="cannot harden"):
        AsyncAdminClient(_config(), admin=admin)


async def test_aclose_is_noop_when_connection_disappears_after_construction():
    """원래 의도(내부 구조 변경에 대한 aclose의 관용)는 그대로 보존한다.

    생성 시점에는 구조가 온전했고 그 뒤에 사라진 경우 — 정리 경로는 여전히 조용히 넘어가야 한다.
    """
    admin = MagicMock(spec=KeycloakAdmin)  # 잘 갖춰진 목이라 생성 시 하드닝을 통과한다
    client = AsyncAdminClient(_config(), admin=admin)
    admin.connection = None  # 생성 이후 내부 구조가 바뀐 상황

    await client.aclose()  # must not raise
