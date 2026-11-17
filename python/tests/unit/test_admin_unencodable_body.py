"""admin 쓰기의 representation 을 JSON 으로 쓸 수 없으면 요청도 토큰 그랜트도 없이
전송 오류다 — 문구가 그 사실을 말한다(등록부
`python-admin-unencodable-body-message-false`).

python-keycloak 7.1.1 의 쓰기 열 메서드(create · update, 다섯 자원)는 모두 본문을
`data=json.dumps(payload)` 로 쓴다. 그 `TypeError`(set · bytes · 문자열이 아닌 키) ·
`ValueError`(순환) · `RecursionError`(지나친 중첩)를 경계가 「python-keycloak 이 쓸 수
없는 응답」으로 분류해, 나가지도 않은 요청을 `KeycloakTransportError("Keycloak admin
API returned an unusable response (TypeError)")` 라고 했다 — 도달할 수 없는 서버에서도
같은 문구였다(실측 2026-11-17: 같은 서버에서 쓸 수 있는 본문은 「Can't connect to
server」). 문구는 node 의 `UNENCODABLE_BODY`(#1129)와 같다.

두 축으로 잰다 — 쓰기 연산마다(본문 하나: 배선 — 그 연산이 요청 전에 본문을 재는가)와
본문 종류마다(연산 하나: 인코더 — 그 종류를 거부하는가). 검사는 공용 `encodable`
하나라 두 축이 곱 전수를 대신한다(칸마다 클라이언트를 새로 만들어 칸이 비싸다 — 곱
120 칸 대신 32 칸). 칸마다 오류 클래스 · 문구 · 가짜 IdP 에 닿은 요청 수(그랜트 ·
admin 둘 다 0) · 사슬(`__cause__` · `__context__` 없음) · python-keycloak 프레임 없음을
함께 단언한다. 대조: 같은 연산에 쓸 수 있는 본문은 admin 요청 하나에 닿는다(하네스가
공허하지 않다).
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
from keycloak_sdk.exceptions import KeycloakTransportError
from tests.unit.conftest import collector_paused

from .test_admin_3xx_response import OPS
from .test_admin_grant import LANES, _attempt, _chain, _inner_frames

#: 칸마다 새 클라이언트를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

UNENCODABLE = "admin request failed: the request body could not be encoded as JSON"
_TOKEN = "/realms/r/protocol/openid-connect/token"
_GRANT = {"access_token": "at-unencodable", "token_type": "Bearer", "expires_in": 300}

#: 쓰기 연산 → (동사, 본문을 받아 부르는 법). sync · aio 가 같은 이름이다(aio 는
#: 코루틴 — `_attempt` 가 기다린다).
WRITES: dict[str, tuple[str, Callable[[Any, Any], Any]]] = {
    "users.create": ("POST", lambda a, rep: a.users.create(rep)),
    "users.update": ("PUT", lambda a, rep: a.users.update("u1", rep)),
    "clients.create": ("POST", lambda a, rep: a.clients.create(rep)),
    "clients.update": ("PUT", lambda a, rep: a.clients.update("c1", rep)),
    "groups.create": ("POST", lambda a, rep: a.groups.create(rep)),
    "groups.update": ("PUT", lambda a, rep: a.groups.update("g1", rep)),
    "roles.create": ("POST", lambda a, rep: a.roles.create(rep)),
    "roles.update": ("PUT", lambda a, rep: a.roles.update("ro", rep)),
    "realms.create": ("POST", lambda a, rep: a.realms.create(rep)),
    "realms.update": ("PUT", lambda a, rep: a.realms.update("re", rep)),
}


def _cyclic() -> dict[str, Any]:
    rep: dict[str, Any] = {"name": "x"}
    rep["self"] = rep
    return rep


def _deep() -> list[Any]:
    rep: list[Any] = []
    for _ in range(100_000):
        rep = [rep]
    return rep


class _Raising(dict):  # type: ignore[type-arg]
    """순회가 실패하는 사용자 정의 컨테이너 — json 의 C 인코더는 dict 하위 클래스의 `items()` 를
    부른다. 좁은 `except`(TypeError · ValueError · RecursionError)면 이 예외가 SDK 밖으로 샌다 —
    고치기 전에는 python-keycloak 프레임 안이라 SDK 오류였다(Grok 레그 Q2 를 실행으로 가른다)."""

    def items(self) -> Any:  # type: ignore[override]
        raise RuntimeError("the container cannot be iterated")


#: 본문 → 그것을 만드는 법(칸마다 새로). 주석은 `json.dumps` 가 내는 예외다.
BODIES: dict[str, Callable[[], Any]] = {
    "set": lambda: {"name": "x", "attributes": {"a": {1, 2}}},  # TypeError
    "bytes": lambda: {"name": b"x"},  # TypeError
    "tuple-key": lambda: {("a", 1): "x"},  # TypeError
    "cyclic": _cyclic,  # ValueError
    "deep": lambda: {"name": "x", "attributes": _deep()},  # RecursionError
    "raising-container": lambda: _Raising(name="x"),  # RuntimeError
}


@dataclass
class _Idp:
    """토큰 엔드포인트는 정상으로, 그 밖의 요청은 201(+`Location`) · 204 로 답하고 센다."""

    url: str = ""
    grants: int = 0
    admin: list[str] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)


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
            payload = b""
            if path == _TOKEN:
                with idp.lock:
                    idp.grants += 1
                payload = json.dumps(_GRANT).encode()
                self.send_response(200)
            else:
                with idp.lock:
                    idp.admin.append(self.command)
                self.send_response(201 if self.command == "POST" else 204)
                self.send_header("Location", f"{idp.url}{path}/new-id")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_POST = _serve
        do_PUT = _serve

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


def test_the_table_is_every_write_operation() -> None:
    # 쓰기 연산이 새로 생기면 이 표에 칸이 생길 때까지 운다 — 파사드 전수 표(OPS)에서
    # 본문을 받는 것을 뽑는다.
    takes_a_body = {op for op in OPS if op.rpartition(".")[2] in {"create", "update"}}
    assert takes_a_body == set(WRITES)


async def _refused(lane: str, op: str, body: str) -> None:
    rep = BODIES[body]()
    with _fake_idp() as idp:
        async with _client(lane, idp.url) as kc:
            with collector_paused():
                _result, err = await _attempt(lane, kc, lambda c: WRITES[op][1](c.admin, rep))
    assert type(err) is KeycloakTransportError, repr(err)
    assert str(err) == UNENCODABLE
    assert (idp.grants, idp.admin) == (0, []), "본문을 못 쓰면 토큰도 요청도 없다"
    assert _chain(err) == [], "인코더의 예외는 사슬로 닿지 않는다"
    assert _inner_frames(err) == [], "python-keycloak 은 불리지 않는다"


@pytest.mark.parametrize("op", sorted(WRITES))
@pytest.mark.parametrize("lane", LANES)
async def test_every_write_operation_checks_its_body_before_any_request(lane: str, op: str) -> None:
    await _refused(lane, op, "set")


@pytest.mark.parametrize("body", sorted(BODIES))
@pytest.mark.parametrize("lane", LANES)
async def test_every_unencodable_kind_is_refused_the_same_way(lane: str, body: str) -> None:
    await _refused(lane, "users.create", body)


@pytest.mark.parametrize("op", sorted(WRITES))
@pytest.mark.parametrize("lane", LANES)
async def test_an_encodable_body_still_reaches_the_admin_api(lane: str, op: str) -> None:
    with _fake_idp() as idp:
        async with _client(lane, idp.url) as kc:
            _result, err = await _attempt(lane, kc, lambda c: WRITES[op][1](c.admin, {"name": "x"}))
    assert err is None, repr(err)
    assert idp.admin == [WRITES[op][0]]
