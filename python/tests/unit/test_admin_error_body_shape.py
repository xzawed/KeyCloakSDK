"""admin 오류 응답의 JSON 이 객체가 아니어도 파사드 오류는 그 상태다(등록부
`python-admin-list-error-array-body`).

python-keycloak 의 `raise_error_from_response` 는 오류 본문을 `response.json()["message"]` 로 읽고
`KeyError` · `ValueError` 만 잡는다 — JSON 이 배열 · 문자열 · 수 · 참거짓 · null 이면 `TypeError`,
아주 깊게 중첩되면 `RecursionError` 로 깨진다. 경계는 그것을 「python-keycloak 이 쓸 수 없는
응답」으로 보고 상태 없는 `KeycloakTransportError` 를 냈다 — 응답이 404 든 500 이든.

여기서는 통합 admin 표면 스위트가 도는 25 연산 전부를 배열 본문의 404 · 500 과 sync · aio 두
레인으로 재고(그 호출의 admin 요청 하나 · 그랜트 하나), 본문 모양과 상태 → 클래스는
`users.get` 한 연산으로 잰다. 칸마다 오류 클래스(상태가 고르는 그 클래스 그 자체)와 상태와
본문(`keycloak_error`)을 **함께** 단언한다.

python-keycloak 의 401 재시도(그랜트를 새로 받고 한 번 더 보낸다)는 그대로여야 한다 — 그래서
세션이 오류 응답을 가로채지 않고, 파사드 호출이 받은 **마지막** 응답을 적어 둔다
(`_internal/admin_body.py` 의 `Answer`). 대조 넷: 401 뒤 200 은 성공이다 · 401 뒤 새 그랜트가
실패하면 그랜트 실패다 · 401 뒤 2xx 를 python-keycloak 이 못 쓰면 앞의 401 이 아니라 그 2xx 로
판정한다(상태 없는 전송 오류) · 객체 · JSON 아닌 본문은 수정 전에도 옳았다.

수정 전(실측 2026-11-14, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 · python-keycloak
7.1.1 · requests 2.34.2 · httpx 0.28.1): 140 칸 중 128 칸이 실패했다 — 객체가 아닌 본문의 칸
전부(25 연산에 404 · 500 과 두 레인 100 · 모양 12 · 상태 14 · 401 두 번 2)가
`KeycloakTransportError("Keycloak admin API returned an unusable response (TypeError)")` 였고
깊은 중첩만 `(RecursionError)` 였다. 대조 12 칸은 통과했다.
"""

from __future__ import annotations

import contextlib
import json
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import pytest

from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakTransportError,
)

from .test_admin_3xx_response import _REPS, OPS, _client
from .test_admin_grant import LANES, _attempt, _chain

#: 칸마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

_TOKEN = "/realms/r/protocol/openid-connect/token"
_GRANT = {"access_token": "at-shape", "token_type": "Bearer", "expires_in": 300}
_USER = json.dumps(_REPS["users"]).encode()

#: 객체가 아닌 JSON 오류 본문 — 이름 → 본문. 깊은 중첩(20 만 B, 오류 본문 상한 1 MiB 안)은
#: `TypeError` 가 아닌 `RecursionError` 로 깨지는 몫이다.
SHAPES: dict[str, bytes] = {
    "array": b"[]",
    "string": b'"boom"',
    "number": b"42",
    "boolean": b"true",
    "null": b"null",
    "deep": b"[" * 100_000 + b"]" * 100_000,
}
#: 수정 전에도 옳았던 본문 — 객체(`message` 없음)는 `KeyError`, JSON 이 아니면 `ValueError` 로
#: python-keycloak 이 스스로 잡는다.
CONTROLS: dict[str, bytes] = {
    "object": b'{"error":"unknown_error"}',
    "not-json": b"<html>Bad Gateway</html>",
}
_CLASSES: dict[int, type[KeycloakAdminError]] = {
    403: KeycloakForbiddenError,
    404: KeycloakNotFoundError,
    409: KeycloakConflictError,
}


def _class(status: int) -> type[KeycloakAdminError]:
    return _CLASSES.get(status, KeycloakAdminError)


@dataclass
class _Idp:
    """admin 요청에는 `answers` 를, 토큰 요청에는 `grant_answers` 를 차례로(마지막 것은 되풀어)
    답한다 — 그랜트는 기본이 정상이다."""

    answers: list[tuple[int, bytes]]
    grant_answers: list[tuple[int, bytes]] = field(
        default_factory=lambda: [(200, json.dumps(_GRANT).encode())]
    )
    url: str = ""
    admin: list[str] = field(default_factory=list)
    grants: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)

    def next_answer(self, method: str) -> tuple[int, bytes]:
        with self.lock:
            self.admin.append(method)
            return self.answers[min(len(self.admin), len(self.answers)) - 1]

    def next_grant(self) -> tuple[int, bytes]:
        with self.lock:
            self.grants += 1
            return self.grant_answers[min(self.grants, len(self.grant_answers)) - 1]

    def seen(self) -> tuple[list[str], int]:
        with self.lock:
            return list(self.admin), self.grants


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            if urlsplit(self.path).path == _TOKEN:
                status, payload = idp.next_grant()
            else:
                status, payload = idp.next_answer(self.command)
            self.send_response(status, HTTPStatus(status).phrase)
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
def _fake_idp(
    *answers: tuple[int, bytes], grants: list[tuple[int, bytes]] | None = None
) -> Iterator[_Idp]:
    idp = _Idp(list(answers)) if grants is None else _Idp(list(answers), grants)
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


async def _run(
    lane: str, op: str, *answers: tuple[int, bytes], grants: list[tuple[int, bytes]] | None = None
) -> tuple[Any, Any, list[str], int]:
    """(결과, 오류, admin 요청 동사들, 그랜트 수)."""
    _, act = OPS[op]
    with _fake_idp(*answers, grants=grants) as idp:
        async with _client(lane, idp.url) as kc:
            result, err = await _attempt(lane, kc, lambda c: act(c.admin))
        seen, grants = idp.seen()
    return result, err, seen, grants


def _assert_admin_error(cell: str, err: Any, status: int, body: bytes) -> None:
    assert type(err) is _class(status), f"{cell}: {err!r}"
    assert err.status_code == status, f"{cell}: 상태 {err.status_code}"
    assert err.keycloak_error == body.decode(), f"{cell}: 본문 {err.keycloak_error!r:.80}"
    # python-keycloak 의 실패(본문을 쥔 프레임)는 사슬에 없다 — 원인은 요약뿐이다(`lower.py`).
    assert not any(isinstance(e, (TypeError, RecursionError)) for e in _chain(err)), cell


@pytest.mark.parametrize("op", sorted(OPS))
@pytest.mark.parametrize("status", [404, 500])
@pytest.mark.parametrize("lane", LANES)
async def test_an_error_with_a_json_array_body_keeps_its_status(
    lane: str, status: int, op: str
) -> None:
    body = json.dumps([_REPS[op.partition(".")[0]]]).encode()
    result, err, seen, grants = await _run(lane, op, (status, body))
    cell = f"{lane} {status} {op}"
    assert (seen, grants) == ([OPS[op][0]], 1), f"{cell}: admin {seen} · 그랜트 {grants}"
    assert result is None, f"{cell}: 결과를 돌려줬다 — {result!r}"
    _assert_admin_error(cell, err, status, body)


@pytest.mark.parametrize("shape", sorted(SHAPES))
@pytest.mark.parametrize("lane", LANES)
async def test_every_non_object_json_error_body_keeps_its_status(lane: str, shape: str) -> None:
    result, err, seen, grants = await _run(lane, "users.get", (400, SHAPES[shape]))
    cell = f"{lane} 400 {shape}"
    assert (result, seen, grants) == (None, ["GET"], 1), f"{cell}: {result!r} {seen} {grants}"
    _assert_admin_error(cell, err, 400, SHAPES[shape])


@pytest.mark.parametrize("status", [400, 403, 404, 409, 422, 500, 503])
@pytest.mark.parametrize("lane", LANES)
async def test_the_status_still_picks_the_class(lane: str, status: int) -> None:
    result, err, _, _ = await _run(lane, "users.get", (status, b"[]"))
    assert result is None
    _assert_admin_error(f"{lane} {status}", err, status, b"[]")


# 대조 — 수정 전에도 옳았던 본문(python-keycloak 이 스스로 잡는다). 목록 연산으로 잰다.
@pytest.mark.parametrize("control", sorted(CONTROLS))
@pytest.mark.parametrize("lane", LANES)
async def test_object_and_non_json_error_bodies_were_already_right(lane: str, control: str) -> None:
    result, err, _, _ = await _run(lane, "users.search", (404, CONTROLS[control]))
    assert result is None
    _assert_admin_error(f"{lane} {control}", err, 404, CONTROLS[control])


# 401 은 python-keycloak 이 그랜트를 새로 받고 한 번 더 보낸다 — 경계는 그 재시도를 지우지 않는다.
@pytest.mark.parametrize("lane", LANES)
async def test_a_401_with_a_non_object_body_is_still_retried_once(lane: str) -> None:
    result, err, seen, grants = await _run(lane, "users.get", (401, b"[]"), (200, _USER))
    assert (err, seen, grants) == (None, ["GET", "GET"], 2), (err, seen, grants)
    assert result == _REPS["users"], result


@pytest.mark.parametrize("lane", LANES)
async def test_two_401s_with_a_non_object_body_are_a_401(lane: str) -> None:
    result, err, seen, grants = await _run(lane, "users.get", (401, b"[]"))
    assert (result, seen, grants) == (None, ["GET", "GET"], 2), (result, seen, grants)
    _assert_admin_error(f"{lane} 401 twice", err, 401, b"[]")


# 401 뒤 새 그랜트가 실패하면 그것은 그랜트 실패다(auth 레인과 같은 판정 — `admin_grant.py`) —
# 그 호출이 마지막으로 받은 admin 응답이 401 이어도 그 401 로 보고하지 않는다(독립 레그 Q8:
# 401 뒤의 복구 실패가 새 줄에 닿는가 — 그랜트 실패는 그보다 먼저 갈린다).
@pytest.mark.parametrize("lane", LANES)
async def test_a_failed_regrant_after_a_401_is_a_grant_failure(lane: str) -> None:
    grant = json.dumps(_GRANT).encode()
    result, err, seen, grants = await _run(
        lane, "users.get", (401, b"[]"), grants=[(200, grant), (500, CONTROLS["object"])]
    )
    assert (result, seen, grants) == (None, ["GET"], 2), (result, seen, grants)
    assert type(err) is KeycloakAuthError, repr(err)
    assert "HTTP 500" in str(err), str(err)


# 판정은 **마지막** 응답의 것이다 — 401 뒤 재시도가 받은 2xx 를 python-keycloak 이 못 쓰면(그룹
# 목록의 원소가 객체가 아니다) 그 실패는 상태 없는 전송 오류다(경계의 규칙 — 2xx 를 못 쓴
# 실패). 앞의 401 로 판정하면 받지 않은 오류를 보고한다.
@pytest.mark.parametrize("lane", LANES)
async def test_the_last_answer_decides_not_an_earlier_error(lane: str) -> None:
    result, err, seen, grants = await _run(lane, "groups.list", (401, b"[]"), (200, b'"boom"'))
    assert (result, seen, grants) == (None, ["GET", "GET"], 2), (result, seen, grants)
    assert type(err) is KeycloakTransportError, repr(err)
    assert "unusable response" in str(err), str(err)


# 대조 — `raw` 탈출구는 바뀌지 않는다: python-keycloak 메서드는 제 실패를 그대로 던진다.
@pytest.mark.parametrize("lane", LANES)
async def test_the_raw_escape_hatch_still_sees_the_upstream_failure(lane: str) -> None:
    with _fake_idp((404, b"[]")) as idp:
        async with _client(lane, idp.url) as kc:
            raw = kc.admin.raw
            with pytest.raises(TypeError):
                if lane == "sync":
                    raw.get_realm_roles()
                else:
                    await raw.a_get_realm_roles()
