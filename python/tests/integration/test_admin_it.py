"""관리 작업 E2E — 실제 Keycloak 컨테이너 대상 (WBS 6.3).

`it-client`의 서비스 계정이 realm JSON에 미리 부여된 `realm-management` 역할
(manage-users/view-users/query-users/manage-clients/view-clients/manage-realm/view-realm)로
users·clients·roles·groups 의 CRUD 와 자기 realm 의 조회·갱신을 수행할 수 있는지, 그리고 `raw`
탈출구가 동작하는지 검증한다.

자원마다 레코드 하나의 생애를 성공 경로로 끝까지 돈다 — create(무작위 접미사 이름) → create 가
돌려준 id·이름으로 get(설정한 필드 단언) → list·search·find 에 포함 → update → get(새 값 단언) →
delete → get 이 `KeycloakNotFoundError`. 단언이 중간에 실패해도 레코드가 남지 않게 `finally` 가
지운다. realm 은 master 관리자로 임시 realm 을 만들어 돈다(`master` 픽스처) — 공유 `it-realm` 은
지우지도 이름을 바꾸지도 않는다.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from testcontainers.keycloak import KeycloakContainer

from keycloak_sdk import KeycloakClient, KeycloakConfig, KeycloakNotFoundError
from keycloak_sdk.admin import AdminClient
from tests.integration.conftest import master_config, unique_name

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


@pytest.fixture
def master(keycloak_url: str, keycloak_container: KeycloakContainer) -> Iterator[AdminClient]:
    """master bootstrap 관리자를 SDK 파사드에 주입한 `AdminClient` — 근거는 `master_config`."""
    admin = AdminClient(master_config(keycloak_url), admin=keycloak_container.get_client())
    try:
        yield admin
    finally:
        admin.close()


def test_user_crud_lifecycle(kc: KeycloakClient) -> None:
    username = unique_name("e2e-user")
    user_id = kc.admin.users.create({"username": username, "enabled": True, "firstName": "Created"})
    assert user_id
    deleted = False
    try:
        fetched = kc.admin.users.get(user_id)
        assert fetched["username"] == username
        assert fetched["firstName"] == "Created"

        results = kc.admin.users.search(username, 0, 10)
        assert any(u["id"] == user_id for u in results)

        kc.admin.users.update(user_id, {"firstName": "Updated"})
        assert kc.admin.users.get(user_id)["firstName"] == "Updated"

        kc.admin.users.delete(user_id)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            kc.admin.users.get(user_id)
    finally:
        if not deleted:
            kc.admin.users.delete(user_id)


def test_raw_escape_hatch_server_info(kc: KeycloakClient) -> None:
    info = kc.admin.raw.get_server_info()
    assert info


def test_client_crud_lifecycle(kc: KeycloakClient) -> None:
    """`id` 는 내부 UUID, `clientId` 는 OAuth2 문자열 — 목록 조회는 `find_by_client_id` 다."""
    client_id = unique_name("e2e-client")
    internal_id = kc.admin.clients.create({"clientId": client_id, "description": "created by e2e"})
    assert internal_id
    deleted = False
    try:
        fetched = kc.admin.clients.get(internal_id)
        assert fetched["clientId"] == client_id
        assert fetched["description"] == "created by e2e"

        assert kc.admin.clients.find_by_client_id(client_id) == internal_id

        kc.admin.clients.update(
            internal_id, {"clientId": client_id, "description": "updated by e2e"}
        )
        assert kc.admin.clients.get(internal_id)["description"] == "updated by e2e"

        kc.admin.clients.delete(internal_id)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            kc.admin.clients.get(internal_id)
        assert kc.admin.clients.find_by_client_id(client_id) is None
    finally:
        if not deleted:
            kc.admin.clients.delete(internal_id)


def test_role_crud_lifecycle(kc: KeycloakClient) -> None:
    """⚠️ update 는 **경로(현재 이름)와 body(새 값)를 분리**해 넘긴다 — 합치면 rename 이 조용한
    no-op 이 된다."""
    name = unique_name("e2e-role")
    kc.admin.roles.create({"name": name, "description": "created by e2e"})
    deleted = False
    try:
        fetched = kc.admin.roles.get(name)
        assert fetched["name"] == name
        assert fetched["description"] == "created by e2e"

        assert any(r["name"] == name for r in kc.admin.roles.list())

        kc.admin.roles.update(name, {"name": name, "description": "updated by e2e"})
        assert kc.admin.roles.get(name)["description"] == "updated by e2e"

        kc.admin.roles.delete(name)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            kc.admin.roles.get(name)
    finally:
        if not deleted:
            kc.admin.roles.delete(name)


def test_group_crud_lifecycle(kc: KeycloakClient) -> None:
    """rename — 경로는 id, body 에 새 이름. 둘을 합치면 새 이름 단언이 깨진다."""
    name = unique_name("e2e-group")
    gid = kc.admin.groups.create({"name": name})
    assert gid
    deleted = False
    try:
        assert kc.admin.groups.get(gid)["name"] == name

        assert any(g["id"] == gid for g in kc.admin.groups.list())

        kc.admin.groups.update(gid, {"name": f"{name}-renamed"})
        assert kc.admin.groups.get(gid)["name"] == f"{name}-renamed"

        kc.admin.groups.delete(gid)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            kc.admin.groups.get(gid)
    finally:
        if not deleted:
            kc.admin.groups.delete(gid)


def test_service_account_lists_and_updates_its_own_realm(kc: KeycloakClient) -> None:
    # 서비스 계정은 보통 자기 realm만 본다 — 전체 목록을 가정하지 않고 포함 여부만 본다.
    assert any(r["realm"] == "it-realm" for r in kc.admin.realms.list())

    kc.admin.realms.update("it-realm", {"realm": "it-realm", "displayName": "updated by e2e"})
    assert kc.admin.realms.get("it-realm")["displayName"] == "updated by e2e"


def test_realm_crud_lifecycle(master: AdminClient) -> None:
    """임시 realm 하나 — 생성·삭제가 master 전용이라 master 관리자로 돈다(`master_config`)."""
    name = unique_name("e2e-realm")
    master.realms.create({"realm": name, "enabled": True, "displayName": "created by e2e"})
    deleted = False
    try:
        fetched = master.realms.get(name)
        assert fetched["realm"] == name
        assert fetched["displayName"] == "created by e2e"

        assert any(r["realm"] == name for r in master.realms.list())

        # 경로(현재 이름)와 body 분리 — 이름은 그대로 두고 displayName 만 바꾼다.
        master.realms.update(name, {"realm": name, "displayName": "updated by e2e"})
        assert master.realms.get(name)["displayName"] == "updated by e2e"

        master.realms.delete(name)
        deleted = True
        with pytest.raises(KeycloakNotFoundError):
            master.realms.get(name)
    finally:
        if not deleted:
            master.realms.delete(name)
