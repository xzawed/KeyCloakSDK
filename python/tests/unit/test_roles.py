"""`RolesResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.roles import RolesResource
from keycloak_sdk.exceptions import KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


def test_create_delegates_and_returns_none():
    kc = _admin()

    result = RolesResource(kc).create({"name": "admin"})

    kc.create_realm_role.assert_called_once_with({"name": "admin"})
    assert result is None


def test_create_translates_conflict():
    kc = _admin()
    kc.create_realm_role.side_effect = KeycloakGetError("dup", response_code=409)

    with pytest.raises(Exception):
        RolesResource(kc).create({"name": "admin"})


def test_get_returns_representation():
    kc = _admin()
    kc.get_realm_role.return_value = {"name": "admin", "id": "role1"}

    result = RolesResource(kc).get("admin")

    kc.get_realm_role.assert_called_once_with("admin")
    assert result == {"name": "admin", "id": "role1"}


def test_get_missing_translates_notfound():
    kc = _admin()
    kc.get_realm_role.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        RolesResource(kc).get("missing")


def test_list_delegates():
    kc = _admin()
    kc.get_realm_roles.return_value = [{"name": "admin"}, {"name": "user"}]

    result = RolesResource(kc).list()

    kc.get_realm_roles.assert_called_once_with()
    assert result == [{"name": "admin"}, {"name": "user"}]


def test_list_translates_error():
    kc = _admin()
    kc.get_realm_roles.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(Exception):
        RolesResource(kc).list()


def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = RolesResource(kc).delete("admin")

    kc.delete_realm_role.assert_called_once_with("admin")
    assert result is None


def test_delete_translates_notfound():
    kc = _admin()
    kc.delete_realm_role.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        RolesResource(kc).delete("missing")
