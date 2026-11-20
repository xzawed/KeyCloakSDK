"""create 의 id 는 201 의 `Location` 을 요청 URL 에 대해 푼(RFC 9110 §10.2.2) 경로의
마지막 조각이다 — 그 앞 조각은 보낸 컬렉션이어야 한다(등록부 `admin-create-relative-location`).

python-keycloak 7.1.1 의 create 는 `Location` 원문의 마지막 `/` 뒤를 id 로 읽는다
(`rindex("/")`) — 상대 `Location` 은 풀지 않고, 쿼리 · 조각이 id 에 남고, 다른 컬렉션의 id 도
받는다. 이 파일은 아홉 SDK 가 같이 쓰는 열세 벡터를 sync · aio 두 레인에서 진짜 HTTP 로 잰다 —
users 는 열셋 전부, clients · groups · roles(roles 는 id 를 돌려주지 않지만 python-keycloak 이
`Location` 을 읽는다)는 L1 · L2 · L4 · L7 · L9.

id 없음(없거나 빈 값 · 다른 컬렉션 · id 없는 경로)은 `Location` 이 없을 때 users 가 내던 그
오류다 — `KeycloakTransportError("Keycloak admin API returned an unusable response (KeyError)")`.
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

#: create → (컬렉션, id 를 돌려주는가, 부르는 법). sync · aio 가 같은 이름이다.
CREATES: dict[str, tuple[str, bool, Callable[[Any], Any]]] = {
    "users.create": ("users", True, lambda a: a.users.create({"username": "alice"})),
    "clients.create": ("clients", True, lambda a: a.clients.create({"clientId": "app"})),
    "groups.create": ("groups", True, lambda a: a.groups.create({"name": "team"})),
    "roles.create": ("roles", False, lambda a: a.roles.create({"name": "reader"})),
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
    """(create, 벡터, `Location`, 돌려줄 id) — users 는 열셋, 나머지는 L1 · L2 · L4 · L7 · L9."""
    for op, (coll, _returns, _run) in CREATES.items():
        other = "users" if coll == "groups" else "groups"
        for name, template, want in LOCATION_VECTORS:
            if coll != "users" and name.split()[0] not in ("L1", "L2", "L4", "L7", "L9"):
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
                _coll, returns, run = CREATES[op]
                cells += 1
                with idp.lock:
                    idp.location = None if location is None else location.replace("{base}", idp.url)
                result, err = await _attempt(lane, kc, lambda c, run=run: run(c.admin))
                got = f"{type(err).__name__}: {err}" if err is not None else f"ok {result}"
                expected = NO_ID if want is None else f"ok {want if returns else None}"
                if got != expected:
                    wrong.append(f"{lane} {op} {name}: {got} — want {expected}")
            posted = set(idp.posted)
    assert cells == 28
    assert posted == {f"/admin/realms/r/{coll}" for coll, _, _ in CREATES.values()}
    assert not wrong, f"{len(wrong)} cell(s) wrong:\n" + "\n".join(wrong)
