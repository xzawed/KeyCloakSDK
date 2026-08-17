"""`GroupsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.groups import GroupsResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakConflictError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


def test_create_returns_id():
    kc = _admin()
    kc.create_group.return_value = "group-id"

    result = GroupsResource(kc).create({"name": "eng"})

    kc.create_group.assert_called_once_with({"name": "eng"})
    assert result == "group-id"


def test_create_translates_conflict():
    kc = _admin()
    kc.create_group.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        GroupsResource(kc).create({"name": "eng"})


def test_get_returns_representation():
    kc = _admin()
    kc.get_group.return_value = {"id": "g1", "name": "eng"}

    result = GroupsResource(kc).get("g1")

    kc.get_group.assert_called_once_with("g1")
    assert result == {"id": "g1", "name": "eng"}


def test_get_missing_translates_notfound():
    kc = _admin()
    kc.get_group.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        GroupsResource(kc).get("missing")


def test_list_builds_query_with_first_max():
    kc = _admin()
    kc.get_groups.return_value = [{"id": "g1", "name": "eng"}]

    result = GroupsResource(kc).list(0, 20)

    kc.get_groups.assert_called_once_with({"first": 0, "max": 20})
    assert result == [{"id": "g1", "name": "eng"}]


def test_list_translates_error():
    kc = _admin()
    kc.get_groups.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        GroupsResource(kc).list(0, 10)


def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = GroupsResource(kc).delete("g1")

    kc.delete_group.assert_called_once_with("g1")
    assert result is None


def test_delete_translates_notfound():
    kc = _admin()
    kc.delete_group.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        GroupsResource(kc).delete("missing")


def test_update_keeps_path_and_body_separate():
    """경로(id)와 body(새 이름)를 분리해 넘겨야 rename이 된다."""
    kc = _admin()

    result = GroupsResource(kc).update("g-1", {"name": "team-renamed"})

    kc.update_group.assert_called_once_with("g-1", {"name": "team-renamed"})
    assert result is None


def test_update_translates_notfound():
    kc = _admin()
    kc.update_group.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        GroupsResource(kc).update("missing", {})
