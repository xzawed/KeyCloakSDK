"""`AsyncRolesResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다. sync
`tests/unit/test_roles.py`와 동형.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.aio.admin.roles import AsyncRolesResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakConflictError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


async def test_create_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncRolesResource(kc).create({"name": "admin"})

    kc.a_create_realm_role.assert_awaited_once_with({"name": "admin"})
    assert result is None


async def test_create_translates_conflict():
    kc = _admin()
    kc.a_create_realm_role.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        await AsyncRolesResource(kc).create({"name": "admin"})


async def test_get_returns_representation():
    kc = _admin()
    kc.a_get_realm_role.return_value = {"name": "admin", "id": "role1"}

    result = await AsyncRolesResource(kc).get("admin")

    kc.a_get_realm_role.assert_awaited_once_with("admin")
    assert result == {"name": "admin", "id": "role1"}


async def test_get_missing_translates_notfound():
    kc = _admin()
    kc.a_get_realm_role.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncRolesResource(kc).get("missing")


async def test_list_delegates():
    kc = _admin()
    kc.a_get_realm_roles.return_value = [{"name": "admin"}, {"name": "user"}]

    result = await AsyncRolesResource(kc).list()

    kc.a_get_realm_roles.assert_awaited_once_with()
    assert result == [{"name": "admin"}, {"name": "user"}]


async def test_list_translates_error():
    kc = _admin()
    kc.a_get_realm_roles.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        await AsyncRolesResource(kc).list()


async def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncRolesResource(kc).delete("admin")

    kc.a_delete_realm_role.assert_awaited_once_with("admin")
    assert result is None


async def test_delete_translates_notfound():
    kc = _admin()
    kc.a_delete_realm_role.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncRolesResource(kc).delete("missing")


async def test_update_keeps_path_and_body_separate():
    """경로(현재 이름)와 body(새 이름)를 분리해 넘겨야 rename이 된다."""
    kc = _admin()

    result = await AsyncRolesResource(kc).update("r1", {"name": "r1-renamed", "description": "d"})

    kc.a_update_realm_role.assert_awaited_once_with(
        "r1", {"name": "r1-renamed", "description": "d"}
    )
    assert result is None


async def test_update_translates_notfound():
    kc = _admin()
    kc.a_update_realm_role.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncRolesResource(kc).update("missing", {})
