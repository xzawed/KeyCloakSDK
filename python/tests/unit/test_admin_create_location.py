"""create 의 id 는 201 의 `Location` 을 요청 URL 에 대해 푼(RFC 9110 §10.2.2) 경로의
마지막 조각이다 — 그 앞 조각은 보낸 컬렉션이어야 한다(등록부 `admin-create-relative-location`).

python-keycloak 7.1.1 의 create 는 `Location` 원문의 마지막 `/` 뒤를 id 로 읽는다
(`rindex("/")`) — 상대 `Location` 은 풀지 않고, 쿼리 · 조각이 id 에 남고, 다른 컬렉션의 id 도
받는다. 이 파일은 아홉 SDK 가 같이 쓰는 열세 벡터를 sync · aio 두 레인에서 진짜 HTTP 로 잰다 —
서버가 id 를 매기는 users 는 열셋 전부, clients · groups 는 L1 · L2 · L4 · L7 · L9.

id 없음(없거나 빈 값 · 다른 컬렉션 · id 없는 경로)은 `Location` 이 없을 때 users 가 내던 그
오류다 — `KeycloakTransportError("Keycloak admin API returned an unusable response (KeyError)")`.
이름으로 주소를 잡는 roles 의 create 는 이 규칙 밖이고 예전 그대로다(맨 아래 대조).
"""

from __future__ import annotations

import contextlib
import json
import threading
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient

from .test_admin_grant import LANES, _attempt

pytestmark = pytest.mark.usefixtures("fast_tls")

_TOKEN = "/realms/r/protocol/openid-connect/token"
_GRANT = {"access_token": "at-location", "token_type": "Bearer", "expires_in": 300}

#: id 없음 — users 가 `Location` 없는 201 에 내던 그 오류(클래스 · 문구).
NO_ID = "KeycloakTransportError: Keycloak admin API returned an unusable response (KeyError)"

#: 아홉 SDK 가 같이 쓰는 벡터 — `{base}` 는 서버, `{path}` 는 보낸 컬렉션 경로, `{coll}` 은 그
#: 마지막 조각, `{other}` 는 다른 컬렉션. (이름, `Location`(None 이면 머리 없음), 돌려줄
#: id(None 이면 id 없음)).
LOCATION_VECTORS: list[tuple[str, str | None, str | None]] = [
    ("L1 absolute", "{base}{path}/abc-123", "abc-123"),
    ("L2 path-absolute", "{path}/abc-123", "abc-123"),
    ("L3 relative path", "{coll}/abc-123", "abc-123"),
    ("L4 relative", "abc-123", None),
    ("L5 another host", "https://internal.example:8443{path}/abc-123", "abc-123"),
    ("L6 gateway prefix", "https://gw.example/kc{path}/abc-123", "abc-123"),
    ("L7 query and fragment", "{base}{path}/abc-123?x=1#f", "abc-123"),
    ("L8 trailing slash", "{base}{path}/abc-123/", "abc-123"),
    ("L9 another collection", "../{other}/abc-123", None),
    ("L10 root", "/", None),
    ("L11 empty value", "", None),
    ("L12 absent", None, None),
    ("L13 percent-encoded", "{base}{path}/abc%20123", "abc%20123"),
]

#: create → (컬렉션, 부르는 법). sync · aio 가 같은 이름이다.
CREATES: dict[str, tuple[str, Callable[[Any], Any]]] = {
    "users.create": ("users", lambda a: a.users.create({"username": "alice"})),
    "clients.create": ("clients", lambda a: a.clients.create({"clientId": "app"})),
    "groups.create": ("groups", lambda a: a.groups.create({"name": "team"})),
}


@dataclass
class _Idp:
    """토큰 엔드포인트는 정상으로, admin POST 는 201 과 지금의 `location`(None 이면 없음)으로
    답한다."""

    url: str = ""
    location: str | None = None
    posted: list[str] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            path = urlsplit(self.path).path
            payload = b""
            if path == _TOKEN:
                payload = json.dumps(_GRANT).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
            else:
                with idp.lock:
                    idp.posted.append(path)
                    location = idp.location
                self.send_response(201)
                if location is not None:
                    self.send_header("Location", location)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


@contextlib.contextmanager
def _fake_idp() -> Iterator[_Idp]:
    idp = _Idp()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


@contextlib.asynccontextmanager
async def _client(lane: str, url: str) -> AsyncIterator[Any]:
    cfg = KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret="s")
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            yield akc


def _cells() -> Iterator[tuple[str, str, str | None, str | None]]:
    """(create, 벡터, `Location`, 돌려줄 id) — users 는 열셋, 나머지는 L1 · L2 · L4 · L7 · L9.
    groups 는 L12 도 — python-keycloak 의 `create_group` 은 `Location` 이 없으면 None 이다."""
    for op, (coll, _run) in CREATES.items():
        other = "users" if coll == "groups" else "groups"
        picked = ["L1", "L2", "L4", "L7", "L9"] + (["L12"] if coll == "groups" else [])
        for name, template, want in LOCATION_VECTORS:
            if coll != "users" and name.split()[0] not in picked:
                continue
            location = template
            if location is not None:
                location = (
                    location.replace("{path}", f"/admin/realms/r/{coll}")
                    .replace("{coll}", coll)
                    .replace("{other}", other)
                )
            yield op, name, location, want


@pytest.mark.parametrize("lane", LANES)
async def test_create_reads_the_id_from_the_location_resolved_against_the_request_url(
    lane: str,
) -> None:
    wrong: list[str] = []
    cells = 0
    with _fake_idp() as idp:
        async with _client(lane, idp.url) as kc:
            for op, name, location, want in _cells():
                _coll, run = CREATES[op]
                cells += 1
                with idp.lock:
                    idp.location = None if location is None else location.replace("{base}", idp.url)
                result, err = await _attempt(lane, kc, lambda c, run=run: run(c.admin))
                got = f"{type(err).__name__}: {err}" if err is not None else f"ok {result}"
                expected = NO_ID if want is None else f"ok {want}"
                if got != expected:
                    wrong.append(f"{lane} {op} {name}: {got} — want {expected}")
            posted = set(idp.posted)
    assert cells == 24
    assert posted == {f"/admin/realms/r/{coll}" for coll, _ in CREATES.values()}
    assert not wrong, f"{len(wrong)} cell(s) wrong:\n" + "\n".join(wrong)


#: 대조 — roles 의 create 가 받는 `Location` 과 예전(python-keycloak 이 읽는 그대로)의 결과.
#: 첫 줄이 `/` 를 품은 이름 `a/b` 의 것이다 — 서버가 만든 뒤 실패하지 않는다.
ROLES_UNCHANGED: list[tuple[str | None, str]] = [
    ("{base}/admin/realms/r/roles/a/b", "ok None"),
    ("{base}/admin/realms/r/roles/reader", "ok None"),
    ("../groups/reader", "ok None"),
    ("{base}/admin/realms/r/roles/reader?x=1#f", "ok None"),
    (
        "reader",
        "KeycloakTransportError: Keycloak admin API returned an unusable response (ValueError)",
    ),
    (None, NO_ID),
]


@pytest.mark.parametrize("lane", LANES)
async def test_a_role_create_reads_its_location_as_before(lane: str) -> None:
    # 이름으로 주소를 잡는 roles 의 create 는 Location 규칙 밖이다 — 서버가 매기는 id 가
    # 없고 `Location` 은 이름으로 끝난다(`a/b` 는 `…/roles/a/b`). python-keycloak 의
    # `create_realm_role` 이 읽는 그대로라 결과가 이 브랜치 전과 같다.
    wrong: list[str] = []
    with _fake_idp() as idp:
        async with _client(lane, idp.url) as kc:
            for location, expected in ROLES_UNCHANGED:
                with idp.lock:
                    idp.location = None if location is None else location.replace("{base}", idp.url)
                result, err = await _attempt(
                    lane, kc, lambda c: c.admin.roles.create({"name": "a/b"})
                )
                got = f"{type(err).__name__}: {err}" if err is not None else f"ok {result}"
                if got != expected:
                    wrong.append(f"{lane} {location}: {got} — want {expected}")
    assert not wrong, f"{len(wrong)} cell(s) wrong:\n" + "\n".join(wrong)


@pytest.mark.parametrize("lane", LANES)
async def test_a_location_that_does_not_parse_names_no_id(lane: str) -> None:
    # 닫히지 않은 IPv6 대괄호 — `urljoin` 이 ValueError 로 거부한다(python-keycloak 은 마지막
    # `/` 뒤를 읽어 성공으로 돌려줬다). 대조: 대괄호를 닫은 같은 값은 id 다.
    with _fake_idp() as idp:
        async with _client(lane, idp.url) as kc:
            got = []
            for location in (
                "http://[::1/admin/realms/r/users/abc-123",
                "http://[::1]/admin/realms/r/users/abc-123",
            ):
                with idp.lock:
                    idp.location = location
                result, err = await _attempt(lane, kc, lambda c: c.admin.users.create({}))
                got.append(f"{type(err).__name__}: {err}" if err is not None else f"ok {result}")
    assert got == [NO_ID, "ok abc-123"]
