"""세션 스코프 Keycloak 컨테이너 하네스 (WBS 6.1).

`testcontainers[keycloak]`의 `KeycloakContainer`로 실제 Keycloak을 기동하고
`it-realm-realm.json`(Java SDK의 통합 테스트 realm 재사용)을 임포트한다. 모든
`integration` 마커 테스트가 세션 동안 컨테이너 1개를 공유한다.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import replace
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit

import pytest
from testcontainers.keycloak import KeycloakContainer

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.auth import AuthorizationUrl

_REALM_IMPORT_FILE = Path(__file__).parent / "it-realm-realm.json"

# 인가 코드 흐름용 — realm JSON 의 `it-web`(RS256)·`it-web-hs256`(id_token 을 HS256 서명)과 짝.
# ⚠️ `it-web` 의 audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은
# 발급한 그 클라이언트가 물어도 `{"active": false}` 로 답한다(실측; aud=it-web 을 넣으면 true).
REDIRECT_URI = "http://localhost/it-callback"
WEB_CLIENT_SECRETS = {"it-web": "it-web-secret", "it-web-hs256": "it-web-hs256-secret"}
ALICE = ("alice", "alice-password")


def web_config(
    keycloak_url: str, client_id: str = "it-web", algorithms: tuple[str, ...] = ("RS256",)
) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id=client_id,
        client_secret=WEB_CLIENT_SECRETS[client_id],
        signature_algorithms=algorithms,
    )


def strip_nonce(request: AuthorizationUrl) -> AuthorizationUrl:
    """인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다."""
    url = urlsplit(request.url)
    query = urlencode([(k, v) for k, v in parse_qsl(url.query) if k != "nonce"])
    return replace(request, url=url._replace(query=query).geturl())


@pytest.fixture(scope="session")
def keycloak_url() -> Iterator[str]:
    """`it-realm`을 임포트한 Keycloak 26.6 컨테이너를 세션 동안 1회 기동하고
    base auth-server URL(예: `http://localhost:32819`)을 반환한다."""
    container = KeycloakContainer("quay.io/keycloak/keycloak:26.6").with_realm_import_file(
        str(_REALM_IMPORT_FILE)
    )
    with container as started:
        yield started.get_url()


@pytest.fixture(scope="session")
def alice_id(keycloak_url: str) -> str:
    """`alice` 의 사용자 id — 토큰의 `sub` 와 대조할 **독립 원천**(admin API)에서 읽는다."""
    admin = KeycloakConfig(
        server_url=keycloak_url, realm="it-realm", client_id="it-client", client_secret="it-secret"
    )
    with KeycloakClient.create(admin) as kc:
        (user,) = [u for u in kc.admin.users.search(ALICE[0], 0, 10) if u["username"] == ALICE[0]]
    return str(user["id"])
