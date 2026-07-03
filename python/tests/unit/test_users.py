"""`UsersResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.users import UsersResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


def test_create_returns_id():
    kc = _admin()
    kc.create_user.return_value = "new-id"

    result = UsersResource(kc).create({"username": "a"})

    kc.create_user.assert_called_once_with({"username": "a"})
    assert result == "new-id"


def test_get_returns_representation():
    kc = _admin()
    kc.get_user.return_value = {"id": "u1", "username": "alice"}

    result = UsersResource(kc).get("u1")

    kc.get_user.assert_called_once_with("u1")
    assert result == {"id": "u1", "username": "alice"}


def test_get_missing_translates_notfound():
    kc = _admin()
    kc.get_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        UsersResource(kc).get("missing")


def test_search_builds_query_with_username_first_max():
    kc = _admin()
    kc.get_users.return_value = [{"id": "u1", "username": "alice"}]

    result = UsersResource(kc).search("alice", 0, 20)

    kc.get_users.assert_called_once_with({"username": "alice", "first": 0, "max": 20})
    assert result == [{"id": "u1", "username": "alice"}]


def test_search_without_username_omits_it_from_query():
    kc = _admin()
    kc.get_users.return_value = []

    UsersResource(kc).search(None, 0, 100)

    kc.get_users.assert_called_once_with({"first": 0, "max": 100})


def test_search_translates_error():
    kc = _admin()
    kc.get_users.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        UsersResource(kc).search(None, 0, 10)


def test_update_delegates_and_returns_none():
    kc = _admin()

    result = UsersResource(kc).update("u1", {"firstName": "Alice"})

    kc.update_user.assert_called_once_with("u1", {"firstName": "Alice"})
    assert result is None


def test_update_translates_notfound():
    kc = _admin()
    kc.update_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        UsersResource(kc).update("missing", {})


def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = UsersResource(kc).delete("u1")

    kc.delete_user.assert_called_once_with("u1")
    assert result is None


def test_delete_translates_notfound():
    kc = _admin()
    kc.delete_user.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        UsersResource(kc).delete("missing")
