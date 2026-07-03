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
