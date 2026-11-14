"""Location 없는 3xx 는 admin 파사드 호출의 결과가 아니다 — 오류다(등록부
`go-admin-3xx-read-as-success` 부류 재스캔, python 칸).

go 는 파사드 호출 25 중 24 가 3xx 에 0 값을 돌려줬고 php 는 302 에 User 를 돌려줬다. python 은
2026-10-26/27 에 한 칸(`test_admin_response_body.py` 의 300 행 — users.get, 객체 본문)만 쟀다.
여기서는 통합 admin 표면 스위트가 도는 25 연산 전부(다섯 리소스마다 create · get · list/search ·
update · delete)를 300 · 302(Location 없음) · 399 와 sync · aio 두 레인으로 잰다. 본문은 그
호출의 성공 본문 모양인 유효한 JSON 이다(get · create · update · delete 는 객체, list · search 는
배열). 토큰 엔드포인트는 정상으로 답한다 — 칸마다 진짜 그랜트를 거친다.

칸마다 오류 클래스(`KeycloakAdminError` 그 자체 — 404 가 받는 계층, 하위 클래스 아님)와 그
상태를 **함께** 단언한다. 전송 · 해석 오류는 실패다 — 본문 모양이 어긋나 난 오류가 거짓 초록을
내지 않게. 호출이 그 동사의 admin 요청 하나로 서버에 닿았는지, 오류가 4xx 처럼 본문을
`keycloak_error` 에 싣는지도 본다.

수정 전(실측 2026-11-13, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 · python-keycloak
7.1.1 · requests 2.34.2 · httpx 0.28.1): 레인 둘 · 상태 셋 모두 25 중 19 칸만 통과했다(150 중
114). 실패 여섯 칸이 셋 다 같았다 — `groups.get` 은 3xx 의 객체를 그룹으로 **돌려줬고**
(python-keycloak `get_group` 은 400 이상만 오류로 본다), 목록 다섯(`users.search` ·
`clients.find_by_client_id` · `groups.list` · `roles.list` · `realms.list`)은
`KeycloakTransportError("Keycloak admin API returned an unusable response (TypeError)")` —
`raise_error_from_response` 가 배열 본문의 `response.json()["message"]` 에서 깨져 상태를 잃었다.
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
from keycloak_sdk.admin.clients import ClientsResource
from keycloak_sdk.admin.groups import GroupsResource
from keycloak_sdk.admin.realms import RealmsResource
from keycloak_sdk.admin.roles import RolesResource
from keycloak_sdk.admin.users import UsersResource
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.admin.clients import AsyncClientsResource
from keycloak_sdk.aio.admin.groups import AsyncGroupsResource
from keycloak_sdk.aio.admin.realms import AsyncRealmsResource
from keycloak_sdk.aio.admin.roles import AsyncRolesResource
from keycloak_sdk.aio.admin.users import AsyncUsersResource
from keycloak_sdk.exceptions import KeycloakAdminError

from .test_admin_grant import LANES, _attempt

#: 칸마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

_TOKEN = "/realms/r/protocol/openid-connect/token"
_GRANT = {"access_token": "at-3xx", "token_type": "Bearer", "expires_in": 300}
#: 상태 → 이유 구(399 는 등록된 것이 없다).
STATUSES = {300: "Multiple Choices", 302: "Found", 399: "Unassigned"}

#: 리소스마다 성공 본문의 representation.
_REPS: dict[str, dict[str, object]] = {
    "users": {"id": "u1", "username": "alice", "enabled": True},
    "clients": {"id": "c1", "clientId": "c"},
    "groups": {"id": "g1", "name": "g", "path": "/g"},
    "roles": {"id": "ro1", "name": "ro"},
    "realms": {"id": "re", "realm": "re", "enabled": True},
}

#: 연산 → (동사, 부르는 법). sync · aio 가 같은 이름이다(aio 는 코루틴 — `_attempt` 가 기다린다).
OPS: dict[str, tuple[str, Callable[[Any], Any]]] = {
    "users.create": ("POST", lambda a: a.users.create({"username": "alice"})),
    "users.get": ("GET", lambda a: a.users.get("u1")),
    "users.search": ("GET", lambda a: a.users.search("alice", 0, 10)),
    "users.update": ("PUT", lambda a: a.users.update("u1", {"username": "alice"})),
    "users.delete": ("DELETE", lambda a: a.users.delete("u1")),
    "clients.create": ("POST", lambda a: a.clients.create({"clientId": "c"})),
    "clients.get": ("GET", lambda a: a.clients.get("c1")),
    "clients.find_by_client_id": ("GET", lambda a: a.clients.find_by_client_id("c")),
    "clients.update": ("PUT", lambda a: a.clients.update("c1", {"clientId": "c"})),
    "clients.delete": ("DELETE", lambda a: a.clients.delete("c1")),
    "groups.create": ("POST", lambda a: a.groups.create({"name": "g"})),
    "groups.get": ("GET", lambda a: a.groups.get("g1")),
    "groups.list": ("GET", lambda a: a.groups.list(0, 10)),
    "groups.update": ("PUT", lambda a: a.groups.update("g1", {"name": "g"})),
    "groups.delete": ("DELETE", lambda a: a.groups.delete("g1")),
    "roles.create": ("POST", lambda a: a.roles.create({"name": "ro"})),
    "roles.get": ("GET", lambda a: a.roles.get("ro")),
    "roles.list": ("GET", lambda a: a.roles.list()),
    "roles.update": ("PUT", lambda a: a.roles.update("ro", {"name": "ro"})),
    "roles.delete": ("DELETE", lambda a: a.roles.delete("ro")),
    "realms.create": ("POST", lambda a: a.realms.create({"realm": "re"})),
    "realms.get": ("GET", lambda a: a.realms.get("re")),
    "realms.list": ("GET", lambda a: a.realms.list()),
    "realms.update": ("PUT", lambda a: a.realms.update("re", {"realm": "re"})),
    "realms.delete": ("DELETE", lambda a: a.realms.delete("re")),
}
#: 성공 본문이 배열인 연산(list · search) — 나머지는 객체다.
LISTS = {"users.search", "clients.find_by_client_id", "groups.list", "roles.list", "realms.list"}


def _body(op: str) -> bytes:
    rep = _REPS[op.partition(".")[0]]
    return json.dumps([rep] if op in LISTS else rep).encode()


#: 따라갈 수 있는 리다이렉트의 표적 — 이 경로에 온 요청은 admin 요청으로 세지 않는다.
_TARGET = "/redirected-target"


@dataclass
class _Idp:
    """토큰 엔드포인트는 정상으로, 그 밖의 모든 요청은 정한 3xx 와 본문으로 답한다.

    `follow_to` 가 있으면 3xx 에 표적을 가리키는 `Location` 을 달고, 표적은 `follow_to` 를
    200 으로 준다(따라갈 수 있는 리다이렉트)."""

    status: int
    body: bytes
    follow_to: bytes | None = None
    url: str = ""
    admin: list[tuple[str, str]] = field(default_factory=list)
    grants: int = 0
    targets: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)

    def admin_methods(self) -> list[str]:
        with self.lock:
            return [method for method, _ in self.admin]


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            path = urlsplit(self.path).path
            location = None
            if path == _TOKEN:
                with idp.lock:
                    idp.grants += 1
                status, reason, payload = 200, "OK", json.dumps(_GRANT).encode()
            elif path == _TARGET and idp.follow_to is not None:
                with idp.lock:
                    idp.targets += 1
                status, reason, payload = 200, "OK", idp.follow_to
            else:
                with idp.lock:
                    idp.admin.append((self.command, path))
                status, reason, payload = idp.status, STATUSES[idp.status], idp.body
                if idp.follow_to is not None:
                    location = idp.url + _TARGET
            self.send_response(status, reason)
            if location is not None:
                self.send_header("Location", location)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve
        do_PUT = _serve
        do_DELETE = _serve

    return Handler


@contextlib.contextmanager
def _fake_idp(status: int, body: bytes, follow_to: bytes | None = None) -> Iterator[_Idp]:
    idp = _Idp(status, body, follow_to)
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


# 표가 파사드의 공개 연산 전부인가 — 새 연산이 생기면 이 표에 칸이 생길 때까지 운다.
_RESOURCES: dict[str, tuple[type, type]] = {
    "users": (UsersResource, AsyncUsersResource),
    "clients": (ClientsResource, AsyncClientsResource),
    "groups": (GroupsResource, AsyncGroupsResource),
    "roles": (RolesResource, AsyncRolesResource),
    "realms": (RealmsResource, AsyncRealmsResource),
}


@pytest.mark.parametrize("resource", sorted(_RESOURCES))
def test_the_table_is_every_public_facade_operation(resource: str) -> None:
    table = {op.partition(".")[2] for op in OPS if op.startswith(f"{resource}.")}
    for cls in _RESOURCES[resource]:
        public = {name for name in vars(cls) if not name.startswith("_")}
        assert public == table, f"{cls.__name__}: 공개 {sorted(public)} ≠ 표 {sorted(table)}"
    assert len(OPS) == 25 and len(LISTS) == 5 and set(OPS) >= LISTS


@pytest.mark.parametrize("op", sorted(OPS))
@pytest.mark.parametrize("status", sorted(STATUSES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_3xx_without_location_is_an_admin_error(lane: str, status: int, op: str) -> None:
    method, act = OPS[op]
    with _fake_idp(status, _body(op)) as idp:
        async with _client(lane, idp.url) as kc:
            result, err = await _attempt(lane, kc, lambda c: act(c.admin))
        seen = idp.admin_methods()
        grants = idp.grants
    cell = f"{lane} {status} {op}"
    assert grants == 1, f"{cell}: 그랜트 {grants} 번"
    assert seen == [method], f"{cell}: admin 요청 {seen}(기대 [{method}])"
    assert result is None, f"{cell}: 결과를 돌려줬다 — {result!r}"
    assert type(err) is KeycloakAdminError, f"{cell}: {err!r}"
    assert err.status_code == status, f"{cell}: 상태 {err.status_code}"
    assert err.keycloak_error == _body(op).decode(), f"{cell}: 본문 {err.keycloak_error!r}"


# 따라갈 수 있는 리다이렉트도 결과가 아니다(등록부 admin-followable-redirect-class-divergent).
# `Location` 이 있는 302 에 파사드는 그 상태의 `KeycloakAdminError` 이고 따라가지 않는다. 표적은
# 그 호출의 성공 본문을 200 으로 준다 — 따라가면 결과가 나오거나 표적에 요청이 남는다.
# 실측 2026-11-14: 25 연산에 두 레인 50/50 — 이미 옳았다(아홉 중 go 만 상태 없는 전송 오류였다).
@pytest.mark.parametrize("op", sorted(OPS))
@pytest.mark.parametrize("lane", LANES)
async def test_a_followable_302_is_an_admin_error_and_not_followed(lane: str, op: str) -> None:
    method, act = OPS[op]
    with _fake_idp(302, b"{}", follow_to=_body(op)) as idp:
        async with _client(lane, idp.url) as kc:
            result, err = await _attempt(lane, kc, lambda c: act(c.admin))
        seen = idp.admin_methods()
        targets = idp.targets
    cell = f"{lane} 302+Location {op}"
    assert (seen, targets) == ([method], 0), f"{cell}: admin 요청 {seen} · 표적 요청 {targets}"
    assert result is None, f"{cell}: 결과를 돌려줬다 — {result!r}"
    assert type(err) is KeycloakAdminError, f"{cell}: {err!r}"
    assert err.status_code == 302, f"{cell}: 상태 {err.status_code}"


# 대조 — `raw` 탈출구는 바뀌지 않는다: 같은 세션의 저수준 `raw_get` 은 3xx 응답을 그대로 받고,
# python-keycloak 메서드는 제 판정 그대로다(`get_group` 은 400 이상만 오류로 봐 3xx 의 객체를
# 돌려준다 — 파사드만 그것을 결과로 넘기지 않는다).
@pytest.mark.parametrize("lane", LANES)
async def test_the_raw_escape_hatch_still_receives_the_3xx(lane: str) -> None:
    path = "admin/realms/r/groups/g1"
    with _fake_idp(302, _body("groups.get")) as idp:
        async with _client(lane, idp.url) as kc:
            raw = kc.admin.raw
            if lane == "sync":
                held = raw.connection.raw_get(path)
                group = raw.get_group("g1")
            else:
                held = await raw.connection.a_raw_get(path)
                group = await raw.a_get_group("g1")
    assert (held.status_code, held.json()) == (302, _REPS["groups"]), held
    assert group == _REPS["groups"], group
