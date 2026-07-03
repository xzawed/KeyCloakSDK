"""`AsyncRealmsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다. sync
`tests/unit/test_realms.py`와 동형.
"""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.aio.admin.realms import AsyncRealmsResource
from keycloak_sdk.exceptions import KeycloakConflictError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


async def test_create_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncRealmsResource(kc).create({"realm": "r1", "enabled": True})

    kc.a_create_realm.assert_awaited_once_with({"realm": "r1", "enabled": True})
    assert result is None


async def test_create_translates_conflict():
    kc = _admin()
    kc.a_create_realm.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        await AsyncRealmsResource(kc).create({"realm": "r1"})


async def test_get_returns_representation():
    kc = _admin()
    kc.a_get_realm.return_value = {"realm": "r1", "enabled": True}

    result = await AsyncRealmsResource(kc).get("r1")

    kc.a_get_realm.assert_awaited_once_with("r1")
    assert result == {"realm": "r1", "enabled": True}


async def test_get_missing_translates_notfound():
    kc = _admin()
    kc.a_get_realm.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncRealmsResource(kc).get("missing")


async def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncRealmsResource(kc).delete("r1")

    kc.a_delete_realm.assert_awaited_once_with("r1")
    assert result is None


async def test_delete_translates_notfound():
    kc = _admin()
    kc.a_delete_realm.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncRealmsResource(kc).delete("missing")
