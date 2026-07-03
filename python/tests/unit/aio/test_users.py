"""`AsyncUsersResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다(`a_*`는 실제
클래스에서 async로 정의돼 있어 spec을 통해 자동으로 AsyncMock이 된다). sync
`tests/unit/test_users.py`와 동형.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.aio.admin.users import AsyncUsersResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


async def test_create_returns_id():
    kc = _admin()
    kc.a_create_user.return_value = "new-id"

    result = await AsyncUsersResource(kc).create({"username": "a"})

    kc.a_create_user.assert_awaited_once_with({"username": "a"})
    assert result == "new-id"


async def test_get_returns_representation():
    kc = _admin()
    kc.a_get_user.return_value = {"id": "u1", "username": "alice"}

    result = await AsyncUsersResource(kc).get("u1")

    kc.a_get_user.assert_awaited_once_with("u1")
    assert result == {"id": "u1", "username": "alice"}


async def test_get_missing_translates_notfound():
    kc = _admin()
    kc.a_get_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncUsersResource(kc).get("missing")


async def test_search_builds_query_with_username_first_max():
    kc = _admin()
    kc.a_get_users.return_value = [{"id": "u1", "username": "alice"}]

    result = await AsyncUsersResource(kc).search("alice", 0, 20)

    kc.a_get_users.assert_awaited_once_with({"username": "alice", "first": 0, "max": 20})
    assert result == [{"id": "u1", "username": "alice"}]


async def test_search_without_username_omits_it_from_query():
    kc = _admin()
    kc.a_get_users.return_value = []

    await AsyncUsersResource(kc).search(None, 0, 100)

    kc.a_get_users.assert_awaited_once_with({"first": 0, "max": 100})


async def test_search_translates_error():
    kc = _admin()
    kc.a_get_users.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        await AsyncUsersResource(kc).search(None, 0, 10)


async def test_update_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncUsersResource(kc).update("u1", {"firstName": "Alice"})

    kc.a_update_user.assert_awaited_once_with("u1", {"firstName": "Alice"})
    assert result is None


async def test_update_translates_notfound():
    kc = _admin()
    kc.a_update_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncUsersResource(kc).update("missing", {})


async def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncUsersResource(kc).delete("u1")

    kc.a_delete_user.assert_awaited_once_with("u1")
    assert result is None


async def test_delete_translates_notfound():
    kc = _admin()
    kc.a_delete_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncUsersResource(kc).delete("missing")
