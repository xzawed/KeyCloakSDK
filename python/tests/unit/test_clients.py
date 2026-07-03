"""`ClientsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.admin.clients import ClientsResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


def test_create_returns_id():
    kc = _admin()
    kc.create_client.return_value = "client-uuid"

    result = ClientsResource(kc).create({"clientId": "my-app"})

    kc.create_client.assert_called_once_with({"clientId": "my-app"})
    assert result == "client-uuid"


def test_get_returns_representation():
    kc = _admin()
    kc.get_client.return_value = {"id": "c1", "clientId": "my-app"}

    result = ClientsResource(kc).get("c1")

    kc.get_client.assert_called_once_with("c1")
    assert result == {"id": "c1", "clientId": "my-app"}


def test_get_missing_translates_notfound():
    kc = _admin()
    kc.get_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        ClientsResource(kc).get("missing")


def test_find_by_client_id_returns_uuid():
    kc = _admin()
    kc.get_client_id.return_value = "c1"

    result = ClientsResource(kc).find_by_client_id("my-app")

    kc.get_client_id.assert_called_once_with("my-app")
    assert result == "c1"


def test_find_by_client_id_returns_none_when_absent():
    kc = _admin()
    kc.get_client_id.return_value = None

    result = ClientsResource(kc).find_by_client_id("missing-app")

    assert result is None


def test_find_by_client_id_translates_error():
    kc = _admin()
    kc.get_client_id.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        ClientsResource(kc).find_by_client_id("my-app")


def test_update_delegates_and_returns_none():
    kc = _admin()

    result = ClientsResource(kc).update("c1", {"enabled": False})

    kc.update_client.assert_called_once_with("c1", {"enabled": False})
    assert result is None


def test_update_translates_notfound():
    kc = _admin()
    kc.update_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        ClientsResource(kc).update("missing", {})


def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = ClientsResource(kc).delete("c1")

    kc.delete_client.assert_called_once_with("c1")
    assert result is None


def test_delete_translates_notfound():
    kc = _admin()
    kc.delete_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        ClientsResource(kc).delete("missing")
