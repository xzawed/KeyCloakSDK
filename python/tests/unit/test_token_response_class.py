"""토큰 응답의 오류 계급 — 끝까지 온 토큰·introspection 응답을 쓸 수 없으면 `KeycloakAuthError` 다
(등록부 `token-response-class-divergent` · 판정 2026-11-10, PM · Grok · 독립 서브에이전트 일치).

같은 가짜 IdP 로 세 면을 잰다 — auth 레인의 client_credentials(S1), introspection(INTRO), admin 의
자체 그랜트(S5 — admin 첫 호출이 보낸다). 칸은 아홉 언어 실측표의 것(503 HTML · 200 HTML ·
`access_token`/`active` 없음 · 400 HTML · 문자열 안의 잘못된 UTF-8 · 모르는 charset)에 「JSON 이라고
적은 비-JSON」 둘과 토큰 엔드포인트의 401·403·404·409 를 더했다.

- D1 잘못된 UTF-8 — RFC 8259 §8.1: 시스템 사이 JSON 은 UTF-8 이다. sync 는 requests 가 U+FFFD 로
  바꿔 **받아들였다**(IdP 가 내지 않은 토큰 · 바뀐 클레임). 두 미러가 같은 메시지로 거부한다.
- D2 모르는 charset — RFC 8259 §11: application/json 의 charset 은 효과가 없다. 받아들인다(대조군).
- D3 introspection 의 `active` 없음 — RFC 7662 §2.2 REQUIRED: 「비활성」이 아니라 깨진 응답이다.
- D4 admin 자체 그랜트 — 끝까지 온 응답이면 S1 과 **같은 판정**이다. 토큰 엔드포인트의 상태로
  admin 형을 골라 404 가 `KeycloakNotFoundError` 였고, 토큰을 받지 못한 `users.delete` 가 admin
  요청 0 번에 「이미 없음」으로 읽혔다(go #952 · php #1003 과 같은 모양).

S5 의 기대는 손으로 적지 않는다 — 같은 칸에서 S1 이 낸 판정과 대조한다.
"""

from __future__ import annotations

import contextlib
import threading
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.lower import _OAUTH_ERROR_CODE
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakNotFoundError

#: 칸마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_INTROSPECT = f"{_OC}/token/introspect"
_JSON = "application/json"
_HTML_TYPE = "text/html"
_HTML = b"<html><body><h1>503 Service Unavailable</h1></body></html>"
_GOOD_TOKEN = b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300}'

_Answer = tuple[int, str, bytes]

#: 토큰 엔드포인트의 칸 — (상태, Content-Type, 본문).
TOKEN_CELLS: dict[str, _Answer] = {
    "ok": (200, _JSON, _GOOD_TOKEN),
    "r1 503 HTML": (503, _HTML_TYPE, _HTML),
    "r2 200 HTML": (200, _HTML_TYPE, _HTML),
    "r2j 200 HTML typed as JSON": (200, _JSON, _HTML),
    "r4 200 JSON without access_token": (200, _JSON, b'{"token_type":"Bearer","expires_in":300}'),
    "r8 400 HTML": (400, _HTML_TYPE, _HTML),
    "r8j 400 HTML typed as JSON": (400, _JSON, _HTML),
    "r9 200 invalid UTF-8 inside a string": (
        200,
        _JSON,
        b'{"access_token":"AT-\xff\xfe-token","token_type":"Bearer","expires_in":300}',
    ),
    "r10 200 unknown charset": (200, f"{_JSON}; charset=x-no-such-charset", _GOOD_TOKEN),
    # 오류 응답의 본문은 UTF-8 검사를 받지 않는다 — 판정은 상태가 한다(코드는 못 읽어 없다).
    "r8u 400 invalid UTF-8 in the error body": (
        400,
        _JSON,
        b'{"error":"invalid_grant","error_description":"\xff"}',
    ),
    "401 invalid_client": (401, _JSON, b'{"error":"invalid_client"}'),
    "403 access_denied": (403, _JSON, b'{"error":"access_denied"}'),
    "404 realm missing": (404, _JSON, b'{"error":"Realm does not exist"}'),
    "409 conflict": (409, _JSON, b'{"error":"conflict"}'),
}

_HTTP = "Keycloak request failed: HTTP"
_UNUSABLE = "Keycloak returned an unusable response"
_Verdict = tuple[str, ...]
OK: _Verdict = ("ok",)


def _auth(message: str, error: str | None = None) -> _Verdict:
    return ("KeycloakAuthError", message, repr(error))


#: S1 의 기대 — 두 미러가 같다.
S1: dict[str, _Verdict] = {
    "ok": OK,
    "r1 503 HTML": _auth(f"{_HTTP} 503"),
    "r2 200 HTML": _auth(f"{_UNUSABLE} (TypeError)"),
    "r2j 200 HTML typed as JSON": _auth(f"{_UNUSABLE} (TypeError)"),
    "r4 200 JSON without access_token": _auth("token response has no usable access_token"),
    "r8 400 HTML": _auth(f"{_HTTP} 400"),
    "r8j 400 HTML typed as JSON": _auth(f"{_HTTP} 400"),
    "r9 200 invalid UTF-8 inside a string": _auth("token response is not valid UTF-8"),
    "r10 200 unknown charset": OK,
    "r8u 400 invalid UTF-8 in the error body": _auth(f"{_HTTP} 400"),
    "401 invalid_client": _auth(f"{_HTTP} 401 (invalid_client)", "invalid_client"),
    "403 access_denied": _auth(f"{_HTTP} 403 (access_denied)", "access_denied"),
    "404 realm missing": _auth(f"{_HTTP} 404", "Realm does not exist"),
    "409 conflict": _auth(f"{_HTTP} 409 (conflict)", "conflict"),
}

#: introspection 엔드포인트의 칸 — 토큰 엔드포인트는 정상이다.
INTROSPECTION_CELLS: dict[str, _Answer] = {
    "ok": (200, _JSON, b'{"active":true,"username":"svc"}'),
    "r1 503 HTML": (503, _HTML_TYPE, _HTML),
    "r2 200 HTML": (200, _HTML_TYPE, _HTML),
    "r2j 200 HTML typed as JSON": (200, _JSON, _HTML),
    "r4 200 JSON without active": (200, _JSON, b'{"username":"svc"}'),
    "r8 400 HTML": (400, _HTML_TYPE, _HTML),
    "r8j 400 HTML typed as JSON": (400, _JSON, _HTML),
    "r9 200 invalid UTF-8 inside a string": (
        200,
        _JSON,
        b'{"active":true,"username":"s\xff\xfevc"}',
    ),
    "r10 200 unknown charset": (
        200,
        f"{_JSON}; charset=x-no-such-charset",
        b'{"active":true,"username":"svc"}',
    ),
}

INTRO: dict[str, _Verdict] = {
    "ok": OK,
    "r1 503 HTML": _auth(f"{_HTTP} 503"),
    "r2 200 HTML": _auth(f"{_UNUSABLE} (TypeError)"),
    "r2j 200 HTML typed as JSON": _auth(f"{_UNUSABLE} (TypeError)"),
    "r4 200 JSON without active": _auth("introspection response has no active"),
    "r8 400 HTML": _auth(f"{_HTTP} 400"),
    "r8j 400 HTML typed as JSON": _auth(f"{_HTTP} 400"),
    "r9 200 invalid UTF-8 inside a string": _auth("introspection response is not valid UTF-8"),
    "r10 200 unknown charset": OK,
}


# --- 각본대로 답하는 가짜 IdP ---------------------------------------------------------------


@dataclass
class _Idp:
    token: _Answer
    introspection: _Answer = INTROSPECTION_CELLS["ok"]
    url: str = ""
    admin: list[str] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def answer(self, method: str, path: str) -> _Answer:
        if path == _TOKEN:
            return self.token
        if path == _INTROSPECT:
            return self.introspection
        if path.startswith("/admin/"):
            with self.lock:
                self.admin.append(f"{method} {path}")
            return (204, _JSON, b"") if method == "DELETE" else (200, _JSON, b'{"id":"u1"}')
        return 404, _JSON, b"{}"

    def admin_requests(self) -> list[str]:
        with self.lock:
            return list(self.admin)


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            status, content_type, body = idp.answer(self.command, urlsplit(self.path).path)
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = _serve
        do_POST = _serve
        do_DELETE = _serve

    return Handler


@contextlib.contextmanager
def _fake_idp(token: _Answer, introspection: _Answer = INTROSPECTION_CELLS["ok"]) -> Iterator[_Idp]:
    idp = _Idp(token=token, introspection=introspection)
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


@contextlib.asynccontextmanager
async def _client(lane: str, idp: _Idp) -> AsyncIterator[Any]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret="cs")
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            yield akc


async def _attempt(lane: str, client: Any, act: Callable[[Any], Any]) -> tuple[Any, Any]:
    try:
        result = act(client)
        return (await result if lane == "aio" else result), None
    except Exception as exc:
        return None, exc


def _verdict(err: BaseException | None) -> _Verdict:
    if err is None:
        return OK
    if isinstance(err, KeycloakAuthError):
        return _auth(str(err), err.error)
    return (type(err).__name__, str(err))


def _as_admin_grant(err: BaseException | None) -> _Verdict:
    """S1 의 판정을 admin 그랜트가 낼 모양으로 — 같은 형·같은 메시지이되 `error` 는 코드 모양일
    때만 남는다(그랜트의 오류 본문은 폼의 `client_secret` 을 되울릴 수 있다 —
    `lower.grant_failure`)."""
    shaped = (
        not isinstance(err, KeycloakAuthError)
        or err.error is None
        or _OAUTH_ERROR_CODE.fullmatch(err.error) is not None
    )
    return _verdict(err) if shaped else _auth(str(err))


# --- S1 · S5 ------------------------------------------------------------------------------


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("cell", list(TOKEN_CELLS))
async def test_client_credentials_verdict(cell: str, lane: str) -> None:
    with _fake_idp(TOKEN_CELLS[cell]) as idp:
        async with _client(lane, idp) as client:
            _, err = await _attempt(lane, client, lambda c: c.auth.client_credentials_token())

    assert _verdict(err) == S1[cell]


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("cell", list(TOKEN_CELLS))
async def test_admin_grant_gets_the_auth_lane_verdict_and_sends_no_admin_request(
    cell: str, lane: str
) -> None:
    """D4 — admin 자체 그랜트가 받은 응답의 판정은 같은 응답에서 S1 이 낸 것과 같다. 실패면 admin
    REST 요청은 하나도 나가지 않는다."""
    with _fake_idp(TOKEN_CELLS[cell]) as idp:
        async with _client(lane, idp) as client:
            _, auth_err = await _attempt(lane, client, lambda c: c.auth.client_credentials_token())
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
        sent = idp.admin_requests()

    assert _verdict(err) == _as_admin_grant(auth_err)
    if err is None:
        assert result == {"id": "u1"}
        assert sent == ["GET /admin/realms/r/users/u1"]
    else:
        assert sent == []


#: python-keycloak 의 세터가 `int(0.9 * value["expires_in"])` 로 쓰지 못하는 그랜트 응답 — auth
#: 레인은 숫자 문자열을 받지만(소비자가 세터가 아니다) admin 그랜트는 세터 앞에서 거부한다.
_NO_EXPIRY = "token response has no expires_in"
#: auth 레인(`tokens._expires_at`)과 같은 문구.
_BAD_EXPIRY = "token response has an invalid expires_in"
EXPIRY_CELLS: dict[str, tuple[bytes, str]] = {
    "missing": (b'{"access_token":"AT-ok-token","token_type":"Bearer"}', _NO_EXPIRY),
    "null": (b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":null}', _NO_EXPIRY),
    "numeric string": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":"300"}',
        _BAD_EXPIRY,
    ),
    "word": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":"soon"}',
        _BAD_EXPIRY,
    ),
    "Infinity": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":Infinity}',
        _BAD_EXPIRY,
    ),
}


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("cell", list(EXPIRY_CELLS))
async def test_admin_grant_whose_expires_in_the_setter_cannot_use_is_an_auth_error(
    cell: str, lane: str
) -> None:
    """수정 전: 없으면 세터의 `KeyError`, 문자열·null 은 `TypeError`, 무한대는
    `OverflowError` — 셋 다 `KeycloakTransportError` 였다(끝까지 온 응답인데 전송 계급)."""
    body, message = EXPIRY_CELLS[cell]
    with _fake_idp((200, _JSON, body)) as idp:
        async with _client(lane, idp) as client:
            _, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
        sent = idp.admin_requests()

    assert _verdict(err) == _auth(message)
    assert sent == []


@pytest.mark.parametrize("lane", LANES)
async def test_a_delete_whose_token_request_404s_is_not_already_gone(lane: str) -> None:
    """토큰 엔드포인트의 404 는 리소스가 없다는 말이 아니다 — `KeycloakNotFoundError` 를 「이미
    지워졌다」로 처리하는 소비자에게 이것은 지우지 않은 사용자를 지운 것으로 만들었다."""
    with _fake_idp(TOKEN_CELLS["404 realm missing"]) as idp:
        async with _client(lane, idp) as client:
            _, err = await _attempt(lane, client, lambda c: c.admin.users.delete("u1"))
        sent = idp.admin_requests()

    assert not isinstance(err, KeycloakNotFoundError)
    assert isinstance(err, KeycloakAuthError)
    assert sent == []


# --- INTRO ---------------------------------------------------------------------------------


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("cell", list(INTROSPECTION_CELLS))
async def test_introspection_verdict(cell: str, lane: str) -> None:
    with _fake_idp(TOKEN_CELLS["ok"], INTROSPECTION_CELLS[cell]) as idp:
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, lambda c: c.auth.introspect("tok"))

    assert _verdict(err) == INTRO[cell]
    if err is None:
        assert result.active is True
        assert result.username == "svc"
