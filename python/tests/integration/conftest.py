"""세션 스코프 Keycloak 컨테이너 하네스 (WBS 6.1).

`testcontainers[keycloak]`의 `KeycloakContainer`로 실제 Keycloak을 기동하고
`it-realm-realm.json`(Java SDK의 통합 테스트 realm 재사용)을 임포트한다. 모든
`integration` 마커 테스트가 세션 동안 컨테이너 1개를 공유한다.
"""

from __future__ import annotations

import time
import traceback
import uuid
from collections.abc import Awaitable, Callable, Iterator
from dataclasses import dataclass, replace
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit

import pytest
import requests
from testcontainers.keycloak import KeycloakContainer

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.auth import AuthorizationUrl

_REALM_IMPORT_FILE = Path(__file__).parent / "it-realm-realm.json"

#: 준비 탐침이 404 를 다시 묻는 한도(초) — Keycloak 기동은 CI 에서 수십 초다.
_READINESS_SECONDS = 180.0


class _Keycloak(KeycloakContainer):  # type: ignore[misc]
    """⚠️ testcontainers 의 준비 탐침은 관리 포트(9000)가 연결 오류면 주 포트(8080)의
    `/health/ready` 로 넘어가는데, Keycloak 25+ 의 주 포트에는 health 가 없어 404 이고 그 404 는
    다시 묻지 않는다(`raise_for_status` — 데코레이터는 ConnectionError·ReadTimeout 만 재시도한다).
    기동 중 주 포트가 관리 포트보다 먼저 열리면 세션 전체가 setup 오류로 끝났다(CI 실측
    2026-10-29: 31 개가 그 URL 의 404 · 같은 코드로 실패 잡만 다시 돌리니 통과). 404 면 관리
    포트가 열릴 때까지 다시 묻는다."""

    def _readiness_probe(self) -> None:
        deadline = time.monotonic() + _READINESS_SECONDS
        while True:
            try:
                super()._readiness_probe()
                return
            except requests.exceptions.HTTPError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(1)


# 인가 코드 흐름용 — realm JSON 의 `it-web`(RS256)·`it-web-hs256`(id_token 을 HS256 서명)과 짝.
# ⚠️ `it-web` 의 audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은
# 발급한 그 클라이언트가 물어도 `{"active": false}` 로 답한다(실측; aud=it-web 을 넣으면 true).
# `it-web` 의 둘째 매퍼는 리소스 서버 `extra-api` 를 **접근 토큰에만** 넣는다 — `expected_audience`
# 재정의를 실서버로 재는 자리다. `it-web-foreign-aud` 는 id_token `aud` 를 `extra-api` 로 덮어써
# client_id 가 **빠진** id_token 을 낸다(하드코딩 클레임 매퍼 — 실서버로 그것을 만드는 유일한 길).
REDIRECT_URI = "http://localhost/it-callback"
WEB_CLIENT_SECRETS = {
    "it-web": "it-web-secret",
    "it-web-hs256": "it-web-hs256-secret",
    "it-web-foreign-aud": "it-web-foreign-aud-secret",
}
EXTRA_API = "extra-api"
ALICE = ("alice", "alice-password")


def web_config(
    keycloak_url: str,
    client_id: str = "it-web",
    algorithms: tuple[str, ...] = ("RS256",),
    expected_audience: str | None = None,
) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id=client_id,
        client_secret=WEB_CLIENT_SECRETS[client_id],
        signature_algorithms=algorithms,
        expected_audience=expected_audience,
    )


@dataclass(frozen=True)
class Sealed:
    """호출에 넘길 비밀을 쥐되 `repr` 로 드러내지 않는다 — 호출을 싼 람다의 자유 변수도 프레임
    로컬로 찍히므로, 원문을 그대로 두면 누출을 **테스트 자신이** 만든다."""

    code: str
    verifier: str
    nonce: str

    def __repr__(self) -> str:
        return "Sealed(***)"


def render_with_locals(err: BaseException) -> str:
    """오류 수집기(Sentry Python 기본값)가 모으는 것 — 사슬까지, 프레임마다 로컬을 찍는다."""
    return "".join(traceback.TracebackException.from_exception(err, capture_locals=True).format())


def catch(call: Callable[[], object]) -> BaseException:
    """호출을 **여기서** 잡는다 — traceback 의 첫 프레임 로컬은 `call`(람다) 뿐이다."""
    try:
        call()
    except Exception as exc:
        return exc
    raise AssertionError("the call did not fail")


async def acatch(call: Callable[[], Awaitable[object]]) -> BaseException:
    try:
        await call()
    except Exception as exc:
        return exc
    raise AssertionError("the call did not fail")


def strip_nonce(request: AuthorizationUrl) -> AuthorizationUrl:
    """인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다."""
    url = urlsplit(request.url)
    query = urlencode([(k, v) for k, v in parse_qsl(url.query) if k != "nonce"])
    return replace(request, url=url._replace(query=query).geturl())


def unique_name(prefix: str) -> str:
    """관리 E2E 레코드 이름 — 무작위 접미사로 실행·미러(sync·aio)끼리 겹치지 않게 한다."""
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def master_config(keycloak_url: str) -> KeycloakConfig:
    """master realm 의 `admin-cli` — `keycloak_container.get_client()`(bootstrap 관리자의 비밀번호
    그랜트)가 인증하는 자리다. 신규 realm 의 생성·삭제는 master 전용 권한이라 it-client 서비스
    계정으로는 403 이다(Kotlin `FullFlowIT` 8b). 그 클라이언트를 `AdminClient`·`AsyncAdminClient` 에
    주입해 realm CRUD 도 SDK 파사드를 지나게 한다 — 주입된 admin 이 있으면 SDK 는 이 설정으로
    아무것도 만들지 않는다."""
    return KeycloakConfig(server_url=keycloak_url, realm="master", client_id="admin-cli")


@pytest.fixture(scope="session")
def keycloak_container() -> Iterator[KeycloakContainer]:
    """`it-realm`을 임포트한 Keycloak 26.6 컨테이너를 세션 동안 1회 기동한다. master 관리자
    클라이언트(`get_client()` — Kotlin `container.keycloakAdminClient` 와 같은 자리)도
    여기서 얻는다."""
    container = _Keycloak("quay.io/keycloak/keycloak:26.6").with_realm_import_file(
        str(_REALM_IMPORT_FILE)
    )
    with container as started:
        yield started


@pytest.fixture(scope="session")
def keycloak_url(keycloak_container: KeycloakContainer) -> str:
    """base auth-server URL(예: `http://localhost:32819`)."""
    return str(keycloak_container.get_url())


@pytest.fixture(scope="session")
def alice_id(keycloak_url: str) -> str:
    """`alice` 의 사용자 id — 토큰의 `sub` 와 대조할 **독립 원천**(admin API)에서 읽는다."""
    admin = KeycloakConfig(
        server_url=keycloak_url, realm="it-realm", client_id="it-client", client_secret="it-secret"
    )
    with KeycloakClient.create(admin) as kc:
        (user,) = [u for u in kc.admin.users.search(ALICE[0], 0, 10) if u["username"] == ALICE[0]]
    return str(user["id"])
