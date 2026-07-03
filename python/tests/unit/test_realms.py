"""`RealmsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.realms import RealmsResource
from keycloak_sdk.exceptions import KeycloakNotFoundError


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

    with pytest.raises(Exception):
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
