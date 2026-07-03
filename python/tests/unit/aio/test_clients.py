"""`AsyncClientsResource` 단위 테스트. `KeycloakAdmin`을 목으로 주입한다. sync
`tests/unit/test_clients.py`와 동형.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError

from keycloak_sdk.aio.admin.clients import AsyncClientsResource
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakNotFoundError


def _admin() -> MagicMock:
    return MagicMock(spec=KeycloakAdmin)


async def test_create_returns_id():
    kc = _admin()
    kc.a_create_client.return_value = "client-uuid"

    result = await AsyncClientsResource(kc).create({"clientId": "my-app"})

    kc.a_create_client.assert_awaited_once_with({"clientId": "my-app"})
    assert result == "client-uuid"


async def test_get_returns_representation():
    kc = _admin()
    kc.a_get_client.return_value = {"id": "c1", "clientId": "my-app"}

    result = await AsyncClientsResource(kc).get("c1")

    kc.a_get_client.assert_awaited_once_with("c1")
    assert result == {"id": "c1", "clientId": "my-app"}


async def test_get_missing_translates_notfound():
    kc = _admin()
    kc.a_get_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncClientsResource(kc).get("missing")


async def test_find_by_client_id_returns_uuid():
    kc = _admin()
    kc.a_get_client_id.return_value = "c1"

    result = await AsyncClientsResource(kc).find_by_client_id("my-app")

    kc.a_get_client_id.assert_awaited_once_with("my-app")
    assert result == "c1"


async def test_find_by_client_id_returns_none_when_absent():
    kc = _admin()
    kc.a_get_client_id.return_value = None

    result = await AsyncClientsResource(kc).find_by_client_id("missing-app")

    assert result is None


async def test_find_by_client_id_translates_error():
    kc = _admin()
    kc.a_get_client_id.side_effect = KeycloakGetError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError):
        await AsyncClientsResource(kc).find_by_client_id("my-app")


async def test_update_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncClientsResource(kc).update("c1", {"enabled": False})

    kc.a_update_client.assert_awaited_once_with("c1", {"enabled": False})
    assert result is None


async def test_update_translates_notfound():
    kc = _admin()
    kc.a_update_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncClientsResource(kc).update("missing", {})


async def test_delete_delegates_and_returns_none():
    kc = _admin()

    result = await AsyncClientsResource(kc).delete("c1")

    kc.a_delete_client.assert_awaited_once_with("c1")
    assert result is None


async def test_delete_translates_notfound():
    kc = _admin()
    kc.a_delete_client.side_effect = KeycloakGetError("no", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        await AsyncClientsResource(kc).delete("missing")
