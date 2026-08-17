"""관리 작업 E2E — 실제 Keycloak 컨테이너 대상 (WBS 6.3).

`it-client`의 서비스 계정이 realm JSON에 미리 부여된 `realm-management` 역할
(manage-users/view-users/query-users 등)로 사용자 CRUD를 수행할 수 있는지,
그리고 `raw` 탈출구가 동작하는지 검증한다.
"""

from __future__ import annotations

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig, KeycloakNotFoundError

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def kc(keycloak_url: str) -> KeycloakClient:
    config = KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )
    return KeycloakClient.create(config)


def test_user_crud_lifecycle(kc: KeycloakClient) -> None:
    user_id = kc.admin.users.create({"username": "newuser", "enabled": True})
    assert user_id

    fetched = kc.admin.users.get(user_id)
    assert fetched["username"] == "newuser"

    results = kc.admin.users.search("newuser", 0, 10)
    assert any(u["id"] == user_id for u in results)

    kc.admin.users.delete(user_id)
    with pytest.raises(KeycloakNotFoundError):
        kc.admin.users.get(user_id)


def test_raw_escape_hatch_server_info(kc: KeycloakClient) -> None:
    info = kc.admin.raw.get_server_info()
    assert info


def test_roles_groups_realms_list_and_update(kc: KeycloakClient) -> None:
    """list·update가 실서버에 반영되는지.

    ⚠️ update 셋은 전부 **경로(주소)와 body(새 값)를 분리**해 넘긴다 — 합치면 rename이
    조용한 no-op이 된다.
    """
    kc.admin.roles.create({"name": "e2e-role"})
    kc.admin.roles.update("e2e-role", {"name": "e2e-role", "description": "updated by e2e"})
    assert kc.admin.roles.get("e2e-role")["description"] == "updated by e2e"
    kc.admin.roles.delete("e2e-role")

    gid = kc.admin.groups.create({"name": "e2e-group"})
    kc.admin.groups.update(gid, {"name": "e2e-group-renamed"})
    assert kc.admin.groups.get(gid)["name"] == "e2e-group-renamed"
    kc.admin.groups.delete(gid)

    # 서비스 계정은 보통 자기 realm만 본다 — 전체 목록을 가정하지 않고 포함 여부만 본다.
    assert any(r["realm"] == "it-realm" for r in kc.admin.realms.list())

    kc.admin.realms.update("it-realm", {"realm": "it-realm", "displayName": "updated by e2e"})
    assert kc.admin.realms.get("it-realm")["displayName"] == "updated by e2e"
