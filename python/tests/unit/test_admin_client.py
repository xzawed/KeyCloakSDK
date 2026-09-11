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


def test_raw_passes_subsecond_timeout_without_truncating_to_zero(monkeypatch):
    """`int(0.5) == 0` → urllib3가 timeout=0을 매 요청마다 ValueError로 거부한다.
    float 타임아웃(초)이 잘리지 않고 그대로 전달돼야 한다."""
    captured: dict[str, object] = {}

    def fake_admin(**kwargs: object):
        captured.update(kwargs)
        return MagicMock(spec=KeycloakAdmin)

    monkeypatch.setattr("keycloak_sdk.admin.KeycloakAdmin", fake_admin)
    client = AdminClient(_config(read_timeout=0.5))

    _ = client.raw

    assert captured["timeout"] == 0.5


def _admin_with_sessions() -> tuple[MagicMock, MagicMock, MagicMock]:
    """`KeycloakAdmin` 목 — 실 구조와 같이 **ConnectionManager 둘**을 단다.

    ⚠️ 둘째(`connection.keycloak_openid.connection`)는 admin 자신의 client-credentials
    토큰 그랜트가 쓰는 **지연 프로퍼티**라 눈에 잘 띄지 않는다. 하나만 닫으면 나머지
    `requests.Session`이 열린 채 남아 admin을 쓰는 클라이언트마다 FD가 하나씩 샌다.
    aio 미러(`aio/admin/__init__.py:aclose`)가 이미 그 구조를 다루고 둘 다 닫는다.
    """
    admin = MagicMock(spec=KeycloakAdmin)
    outer, nested = MagicMock(), MagicMock()
    admin.connection = outer
    outer.keycloak_openid.connection = nested
    return admin, outer, nested


def test_close_closes_both_sync_sessions():
    """⚠️ 이 예제는 예전에 `test_close_is_noop`이었다 — **결함을 의도로 고정**하고 있었다.

    sync `close()`가 `return None`이라 `requests.Session`이 GC까지 살아 있었고, aio
    미러는 같은 자리에서 닫고 있었다(sync/aio 비대칭).
    """
    admin, outer, nested = _admin_with_sessions()
    client = AdminClient(_config(), admin=admin)

    client.close()

    outer._s.close.assert_called_once()
    nested._s.close.assert_called_once()


def test_close_keeps_the_raw_cache():
    """정리 훅이 `raw` 캐시를 버리지는 않는다(기존 계약을 깨지 않는다)."""
    admin, _outer, _nested = _admin_with_sessions()
    client = AdminClient(_config(), admin=admin)

    client.close()

    assert client.raw is admin


def test_close_without_raw_ever_created_does_not_build_admin():
    """⚠️ 대조군 — `close()` 호출 자체가 admin 생성(네트워크 연결)을 유발하면 안 된다.
    aio `aclose()`와 같은 계약이다."""
    client = AdminClient(_config())

    client.close()

    assert client._admin is None


def test_close_still_closes_outer_when_nested_close_raises():
    """⚠️ 대조군 — 둘 중 하나가 깨졌다고 나머지 FD까지 함께 잃으면 안 된다.
    실패 자체는 숨기지 않는다(조용한 누수보다 시끄러운 실패가 낫다)."""
    admin, outer, nested = _admin_with_sessions()
    nested._s.close.side_effect = RuntimeError("boom")
    client = AdminClient(_config(), admin=admin)

    with pytest.raises(RuntimeError):
        client.close()

    outer._s.close.assert_called_once()


# ⚠️ **「중첩 매니저가 없을 때」는 테스트하지 않는다 — 도달 불가능하기 때문이다.**
# `harden_admin`(생성자에서 호출)이 `keycloak_openid` 지연 프로퍼티를 **강제로 실체화**하고,
# 없으면 `KeycloakConfigError`로 fail-closed 한다. 그래서 `close()`가 도는 시점에는 둘 다
# 반드시 있다. 이 예제를 만들어 보니 `AdminClient(...)` 생성 자체가 거부됐다 — 그래서 뺐다.
# (`close()` 구현의 `getattr` 방어는 그럼에도 남겨 둔다: admin 미생성 경로가 있다.)
