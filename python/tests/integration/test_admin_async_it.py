"""async 관리 작업 E2E — 실제 Keycloak 컨테이너 대상 (WBS 5, `keycloak_sdk.aio`).

sync `test_admin_it.py`의 async 미러다 — 같은 생애(create → get → list·search·find → update →
get → delete → get 이 `KeycloakNotFoundError`, 실패해도 `finally` 가 지운다)를 같은 자원 다섯에
돈다. 근거·권한은 sync 쪽 머리말이 소유한다.

`raw`는 sync/async 메서드를 모두 가진 `KeycloakAdmin` 인스턴스다 — 이벤트 루프를
블로킹하지 않으려면 async 경계에서는 `a_get_server_info()`를 써야 한다(동기
`get_server_info()`가 아님, `inspect.iscoroutinefunction`로 확인됨).
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from testcontainers.keycloak import KeycloakContainer

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakNotFoundError
from tests.integration.conftest import master_config, unique_name

pytestmark = pytest.mark.integration


def _config(keycloak_url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )


@pytest.fixture
async def master(
    keycloak_url: str, keycloak_container: KeycloakContainer
) -> AsyncIterator[AsyncAdminClient]:
    """sync `master` 와 같다 — master bootstrap 관리자를 `AsyncAdminClient` 에 주입한다."""
    admin = AsyncAdminClient(master_config(keycloak_url), admin=keycloak_container.get_client())
    try:
        yield admin
    finally:
        await admin.aclose()


async def test_user_crud_lifecycle(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        username = unique_name("e2e-user-async")
        user_id = await kc.admin.users.create(
            {"username": username, "enabled": True, "firstName": "Created"}
        )
        assert user_id
        deleted = False
        try:
            fetched = await kc.admin.users.get(user_id)
            assert fetched["username"] == username
            assert fetched["firstName"] == "Created"

            results = await kc.admin.users.search(username, 0, 10)
            assert any(u["id"] == user_id for u in results)

            await kc.admin.users.update(user_id, {"firstName": "Updated"})
            updated = await kc.admin.users.get(user_id)
            assert updated["firstName"] == "Updated"

            await kc.admin.users.delete(user_id)
            deleted = True
            with pytest.raises(KeycloakNotFoundError):
                await kc.admin.users.get(user_id)
        finally:
            if not deleted:
                await kc.admin.users.delete(user_id)


async def test_raw_escape_hatch_server_info(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        info = await kc.admin.raw.a_get_server_info()
        assert info


async def test_client_crud_lifecycle(keycloak_url: str) -> None:
    """sync 와 같다 — `id` 는 내부 UUID, 목록 조회는 `find_by_client_id` 다."""
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        client_id = unique_name("e2e-client-async")
        internal_id = await kc.admin.clients.create(
            {"clientId": client_id, "description": "created by e2e"}
        )
        assert internal_id
        deleted = False
        try:
            fetched = await kc.admin.clients.get(internal_id)
            assert fetched["clientId"] == client_id
            assert fetched["description"] == "created by e2e"

            assert await kc.admin.clients.find_by_client_id(client_id) == internal_id

            await kc.admin.clients.update(
                internal_id, {"clientId": client_id, "description": "updated by e2e"}
            )
            updated = await kc.admin.clients.get(internal_id)
            assert updated["description"] == "updated by e2e"

            await kc.admin.clients.delete(internal_id)
            deleted = True
            with pytest.raises(KeycloakNotFoundError):
                await kc.admin.clients.get(internal_id)
            assert await kc.admin.clients.find_by_client_id(client_id) is None
        finally:
            if not deleted:
                await kc.admin.clients.delete(internal_id)


async def test_role_crud_lifecycle(keycloak_url: str) -> None:
    """sync 와 같다 — 경로(현재 이름)와 body 분리(rename 가능)."""
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        name = unique_name("e2e-role-async")
        await kc.admin.roles.create({"name": name, "description": "created by e2e"})
        deleted = False
        try:
            fetched = await kc.admin.roles.get(name)
            assert fetched["name"] == name
            assert fetched["description"] == "created by e2e"

            roles = await kc.admin.roles.list()
            assert any(r["name"] == name for r in roles)

            await kc.admin.roles.update(name, {"name": name, "description": "updated by e2e"})
            role = await kc.admin.roles.get(name)
            assert role["description"] == "updated by e2e"

            await kc.admin.roles.delete(name)
            deleted = True
            with pytest.raises(KeycloakNotFoundError):
                await kc.admin.roles.get(name)
        finally:
            if not deleted:
                await kc.admin.roles.delete(name)


async def test_group_crud_lifecycle(keycloak_url: str) -> None:
    """sync 와 같다 — rename 은 경로 id, body 새 이름."""
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        name = unique_name("e2e-group-async")
        gid = await kc.admin.groups.create({"name": name})
        assert gid
        deleted = False
        try:
            fetched = await kc.admin.groups.get(gid)
            assert fetched["name"] == name

            groups = await kc.admin.groups.list()
            assert any(g["id"] == gid for g in groups)

            await kc.admin.groups.update(gid, {"name": f"{name}-renamed"})
            group = await kc.admin.groups.get(gid)
            assert group["name"] == f"{name}-renamed"

            await kc.admin.groups.delete(gid)
            deleted = True
            with pytest.raises(KeycloakNotFoundError):
                await kc.admin.groups.get(gid)
        finally:
            if not deleted:
                await kc.admin.groups.delete(gid)


async def test_service_account_lists_and_updates_its_own_realm(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        realms = await kc.admin.realms.list()
        assert any(r["realm"] == "it-realm" for r in realms)

        await kc.admin.realms.update(
            "it-realm", {"realm": "it-realm", "displayName": "updated by e2e async"}
        )
        realm = await kc.admin.realms.get("it-realm")
        assert realm["displayName"] == "updated by e2e async"


async def test_realm_crud_lifecycle(master: AsyncAdminClient) -> None:
    """sync 와 같다 — 임시 realm 하나를 master 관리자로 돈다."""
    name = unique_name("e2e-realm-async")
    await master.realms.create({"realm": name, "enabled": True, "displayName": "created by e2e"})
    deleted = False
    try:
        fetched = await master.realms.get(name)
        assert fetched["realm"] == name
        assert fetched["displayName"] == "created by e2e"

        realms = await master.realms.list()
        assert any(r["realm"] == name for r in realms)

        await master.realms.update(name, {"realm": name, "displayName": "updated by e2e"})
        realm = await master.realms.get(name)
        assert realm["displayName"] == "updated by e2e"

        await master.realms.delete(name)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            await master.realms.get(name)
    finally:
        if not deleted:
            await master.realms.delete(name)
