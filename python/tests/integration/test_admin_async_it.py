"""async 관리 작업 E2E — 실제 Keycloak 컨테이너 대상 (WBS 5, `keycloak_sdk.aio`).

sync `test_admin_it.py`의 async 미러다. `it-client`의 서비스 계정이 realm JSON에
미리 부여된 `realm-management` 역할(manage-users/view-users/query-users 등)로
사용자 CRUD를 수행할 수 있는지, 그리고 `raw` 탈출구가 동작하는지 검증한다.

`raw`는 sync/async 메서드를 모두 가진 `KeycloakAdmin` 인스턴스다 — 이벤트 루프를
블로킹하지 않으려면 async 경계에서는 `a_get_server_info()`를 써야 한다(동기
`get_server_info()`가 아님, `inspect.iscoroutinefunction`로 확인됨).
"""

from __future__ import annotations

import pytest

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakNotFoundError

pytestmark = pytest.mark.integration


def _config(keycloak_url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )


async def test_user_crud_lifecycle(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        user_id = await kc.admin.users.create({"username": "newuser-async", "enabled": True})
        assert user_id

        fetched = await kc.admin.users.get(user_id)
        assert fetched["username"] == "newuser-async"

        results = await kc.admin.users.search("newuser-async", 0, 10)
        assert any(u["id"] == user_id for u in results)

        await kc.admin.users.delete(user_id)
        with pytest.raises(KeycloakNotFoundError):
            await kc.admin.users.get(user_id)


async def test_raw_escape_hatch_server_info(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        info = await kc.admin.raw.a_get_server_info()
        assert info


async def test_roles_groups_realms_list_and_update(keycloak_url: str) -> None:
    """sync `test_admin_it.py`와 동형 — 경로/body 분리(rename 가능)."""
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        await kc.admin.roles.create({"name": "e2e-role-async"})
        await kc.admin.roles.update(
            "e2e-role-async", {"name": "e2e-role-async", "description": "updated by e2e"}
        )
        role = await kc.admin.roles.get("e2e-role-async")
        assert role["description"] == "updated by e2e"
        await kc.admin.roles.delete("e2e-role-async")

        gid = await kc.admin.groups.create({"name": "e2e-group-async"})
        await kc.admin.groups.update(gid, {"name": "e2e-group-async-renamed"})
        group = await kc.admin.groups.get(gid)
        assert group["name"] == "e2e-group-async-renamed"
        await kc.admin.groups.delete(gid)

        realms = await kc.admin.realms.list()
        assert any(r["realm"] == "it-realm" for r in realms)

        await kc.admin.realms.update(
            "it-realm", {"realm": "it-realm", "displayName": "updated by e2e async"}
        )
        realm = await kc.admin.realms.get("it-realm")
        assert realm["displayName"] == "updated by e2e async"
