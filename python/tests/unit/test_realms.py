"""`RealmsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.realms import RealmsResource
from keycloak_sdk.exceptions import KeycloakConflictError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


def test_create_delegates_and_returns_none():
    kc = _admin()

    result = RealmsResource(kc).create({"realm": "r1", "enabled": True})

    kc.create_realm.assert_called_once_with({"realm": "r1", "enabled": True})
    assert result is None


def test_create_translates_conflict():
    kc = _admin()
    kc.create_realm.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        RealmsResource(kc).create({"realm": "r1"})


def test_get_returns_representation():
    kc = _admin()
    kc.get_realm.return_value = {"realm": "r1", "enabled": True}

    result = RealmsResource(kc).get("r1")

    kc.get_realm.assert_called_once_with("r1")
    assert result == {"realm": "r1", "enabled": True}


def test_get_missing_translates_notfound():
    kc = _admin()
    kc.get_realm.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        RealmsResource(kc).get("missing")


def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = RealmsResource(kc).delete("r1")

    kc.delete_realm.assert_called_once_with("r1")
    assert result is None


def test_delete_translates_notfound():
    kc = _admin()
    kc.delete_realm.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        RealmsResource(kc).delete("missing")


def test_list_delegates():
    kc = _admin()
    kc.get_realms.return_value = [{"realm": "r1"}, {"realm": "r2"}]

    result = RealmsResource(kc).list()

    kc.get_realms.assert_called_once_with()
    assert len(result) == 2


def test_update_keeps_path_and_body_separate():
    """경로(현재 이름)와 body(새 이름)를 분리해 넘겨야 rename이 된다.

    경로 인자를 body의 이름으로 덮어쓰면 rename이 조용한 no-op이 된다 — 종료코드로는
    구분되지 않으므로 어서션으로 못박는다.
    """
    kc = _admin()

    result = RealmsResource(kc).update("r1", {"realm": "r1-renamed", "displayName": "D"})

    kc.update_realm.assert_called_once_with("r1", {"realm": "r1-renamed", "displayName": "D"})
    assert result is None


def test_update_translates_notfound():
    kc = _admin()
    kc.update_realm.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        RealmsResource(kc).update("missing", {})
