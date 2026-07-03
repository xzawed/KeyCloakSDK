"""`KeycloakClient` 파사드 단위 테스트.

`auth`는 실제 `AuthClient`(네트워크 없음 — `KeycloakOpenID` 생성은 순수 객체 구성)로
검증하고, `admin`은 지연 생성/캐시 동작을 `keycloak_sdk.client.AdminClient`를
패치해 실제 `KeycloakAdmin` 네트워크 호출 없이 증명한다.
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.auth import AuthClient
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


# --- create() wires auth eagerly -------------------------------------------------


def test_create_wires_auth():
    config = _config()

    with KeycloakClient.create(config) as kc:
        assert kc.auth is not None
        assert isinstance(kc.auth, AuthClient)


def test_public_client_no_secret_auth_ok():
    """secret 없는 public client 설정도 `create()`+`.auth` 접근은 성공해야 한다 —
    admin은 실제 접근 시에만 secret이 필요하다."""
    config = _config(client_secret=None)

    kc = KeycloakClient.create(config)

    assert kc.auth is not None


# --- context manager ---------------------------------------------------------------


def test_enter_returns_self():
    config = _config()
    kc = KeycloakClient.create(config)

    with kc as entered:
        assert entered is kc


def test_exit_calls_close():
    config = _config()
    kc = KeycloakClient.create(config)

    with patch.object(kc, "close") as mock_close:
        with kc:
            mock_close.assert_not_called()
        mock_close.assert_called_once()


# --- close() delegates to admin only when created ---------------------------------


def test_injected_close_delegates():
    auth = MagicMock()
    admin = MagicMock()
    kc = KeycloakClient._of(auth, admin)

    kc.close()

    admin.close.assert_called_once()


def test_close_without_admin_access_is_noop():
    """admin이 한 번도 접근되지 않았으면 close()가 admin을 생성/호출하지 않는다."""
    config = _config()
    kc = KeycloakClient.create(config)

    kc.close()  # must not raise, must not lazily construct admin


def test_close_guards_admin_without_close_method():
    """AdminClient가 close()를 갖지 않는 경우에도(hasattr 가드) close()는 안전해야
    한다 — 향후 AdminClient 구현이 바뀌어도 KeycloakClient.close()가 깨지지 않는다."""

    class NoCloseAdmin:
        pass

    kc = KeycloakClient._of(MagicMock(), NoCloseAdmin())  # type: ignore[arg-type]

    kc.close()  # no raise


# --- _of() test seam ----------------------------------------------------------------


def test_of_sets_auth_and_admin_verbatim():
    auth = MagicMock()
    admin = MagicMock()

    kc = KeycloakClient._of(auth, admin)

    assert kc.auth is auth
    assert kc.admin is admin


def test_of_bypasses_lazy_admin_construction():
    auth = MagicMock()
    admin = MagicMock()
    kc = KeycloakClient._of(auth, admin)

    with patch("keycloak_sdk.client.AdminClient") as mock_cls:
        assert kc.admin is admin

    mock_cls.assert_not_called()


# --- lazy admin: construct once, cache thereafter -----------------------------------


def test_admin_is_lazily_constructed_once_and_cached():
    config = _config()
    kc = KeycloakClient.create(config)
    fake_admin = MagicMock(spec=AdminClient)

    with patch("keycloak_sdk.client.AdminClient", return_value=fake_admin) as mock_cls:
        first = kc.admin
        second = kc.admin

    mock_cls.assert_called_once_with(config)
    assert first is fake_admin
    assert second is fake_admin


def test_admin_lazy_construction_succeeds_without_secret_until_raw_used():
    """`.admin` 프로퍼티 자체는 secret 없이도 지연 생성에 성공한다(AdminClient 구성은
    저렴하다) — 실제 secret 요구는 `AdminClient.raw`(WBS 4.1) 접근 시점이다."""
    config = _config(client_secret=None)
    kc = KeycloakClient.create(config)

    admin_facade = kc.admin

    assert isinstance(admin_facade, AdminClient)
    with pytest.raises(KeycloakConfigError):
        _ = admin_facade.raw


def test_admin_without_config_raises_config_error():
    """방어적 가드 — `_of()`/`create()` 경로에서는 발생하지 않지만, config 없이
    구성된 인스턴스가 지연 admin 생성을 시도하면 명확한 SDK 예외로 실패해야 한다."""
    auth = MagicMock()
    kc = KeycloakClient(None, auth)

    with pytest.raises(KeycloakConfigError):
        _ = kc.admin
