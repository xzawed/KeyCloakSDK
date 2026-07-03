"""`AsyncGroupsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다. sync
`tests/unit/test_groups.py`와 동형.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.aio.admin.groups import AsyncGroupsResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakConflictError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


async def test_create_returns_id():
    kc = _admin()
    kc.a_create_group.return_value = "group-id"

    result = await AsyncGroupsResource(kc).create({"name": "eng"})

    kc.a_create_group.assert_awaited_once_with({"name": "eng"})
    assert result == "group-id"


async def test_create_translates_conflict():
    kc = _admin()
    kc.a_create_group.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        await AsyncGroupsResource(kc).create({"name": "eng"})


async def test_get_returns_representation():
    kc = _admin()
    kc.a_get_group.return_value = {"id": "g1", "name": "eng"}

    result = await AsyncGroupsResource(kc).get("g1")

    kc.a_get_group.assert_awaited_once_with("g1")
    assert result == {"id": "g1", "name": "eng"}


async def test_get_missing_translates_notfound():
    kc = _admin()
    kc.a_get_group.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncGroupsResource(kc).get("missing")


async def test_list_builds_query_with_first_max():
    kc = _admin()
    kc.a_get_groups.return_value = [{"id": "g1", "name": "eng"}]

    result = await AsyncGroupsResource(kc).list(0, 20)

    kc.a_get_groups.assert_awaited_once_with({"first": 0, "max": 20})
    assert result == [{"id": "g1", "name": "eng"}]


async def test_list_translates_error():
    kc = _admin()
    kc.a_get_groups.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        await AsyncGroupsResource(kc).list(0, 10)


async def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncGroupsResource(kc).delete("g1")

    kc.a_delete_group.assert_awaited_once_with("g1")
    assert result is None


async def test_delete_translates_notfound():
    kc = _admin()
    kc.a_delete_group.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncGroupsResource(kc).delete("missing")
