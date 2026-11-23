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
- 성공 상태(2xx)에 OAuth `error` 를 실은 응답(`success_status_oauth_error` 칸 — 등록부
  auth-2xx-error-code-divergent) — 4xx 가 그 `error` 를 실었을 때와 같은 판정이고, 본문의 나머지
  (`access_token` · `active`)는 쓰지 않는다. 수정 전: B1 은 코드 없는 「없음」 판정, B2 는 그 토큰을
  받아들이고(admin 은 그것으로 요청을 보냈다) introspection 은 활성이었다(실측 2026-11-20).
- 성공은 200 하나다(등록부 token-success-status-range-divergent) — 200 이 아닌 2xx 는 그 레인이 같은
  본문의 400 에 내는 판정이고 그 본문은 보지 않는다. 수정 전: python-keycloak 이 받는 201 은 다섯
  호출 모두 성공, 204 는 빈 본문의 「없음」 판정이었다(실측 2026-11-23).

S5 의 기대는 손으로 적지 않는다 — 같은 칸에서 S1 이 낸 판정과 대조한다.
"""

from __future__ import annotations

import contextlib
import gzip
import threading
import zlib
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakNotFoundError
from tests.unit.conftest import collector_paused

#: 칸마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_INTROSPECT = f"{_OC}/token/introspect"
_LOGOUT = f"{_OC}/logout"
_JSON = "application/json"
_HTML_TYPE = "text/html"
_HTML = b"<html><body><h1>503 Service Unavailable</h1></body></html>"
_GOOD_TOKEN = b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300}'
_GOOD_INTRO = b'{"active":true,"username":"svc"}'
#: JSON 의 `\u` — 짝 없는 서로게이트 이스케이프를 이어 붙인다(등록부
#: token-response-class-residue Q2).
_U = b"\\" + b"u"
#: Content-Type 뒤에 줄을 바꿔 덧붙이는 헤더 — 가짜 IdP 가 그대로 보낸다.
_GZIP = "\nContent-Encoding: gzip"
_CORRUPT_GZIP = b"\x1f\x8b\x08\x00not-a-deflate-stream-at-all-xxxxxxxxxxxx"
#: 200 에 OAuth `error` 를 실은 본문 — 아홉 언어가 같은 바이트를 쓴다(B1 · B2). B2 의 토큰은 쓸 수
#: 있어 보이는 모양이다(IdP 가 스스로 부인한 토큰).
_B1_TOKEN = b'{"error":"invalid_grant","error_description":"d"}'
_B2_TOKEN = (
    b'{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.'
    b'c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}'
)
_B1_INTRO = b'{"error":"invalid_token"}'
_B2_INTRO = b'{"error":"invalid_token","active":true}'
#: `error` 가 비어 있지 않은 문자열이 아니면 예전 그대로다 — 대조군의 멤버들.
_NOT_A_NAMED_ERROR = {
    "a number": b'"error":400',
    "empty": b'"error":""',
    "null": b'"error":null',
    "an object": b'"error":{"code":"invalid_grant"}',
}


def _with(body: bytes, member: bytes) -> bytes:
    """JSON 객체 `body` 끝에 멤버 하나를 더한다."""
    return body[:-1] + b"," + member + b"}"


def _flip(stream: bytes, back: int) -> bytes:
    """gzip 꼬리의 한 바이트를 뒤집는다 — 끝에서 8 이면 CRC-32, 4 면 길이."""
    out = bytearray(stream)
    out[-back] ^= 0xFF
    return bytes(out)


def _raw_deflate(body: bytes) -> bytes:
    """zlib 래퍼 없는 날 deflate."""
    comp = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    return comp.compress(body) + comp.flush()


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
    # 2026-11-11(등록부 token-response-class-residue): sync 는 선언된 charset 으로 풀어
    # TypeError, aio 는 BOM 없는 UTF-16 을 받아들였고, 두 미러 모두 서로게이트는 그대로 · 깨진
    # gzip 은 transport.
    "r11 200 charset=utf-16 over a UTF-8 body": (200, f"{_JSON}; charset=utf-16", _GOOD_TOKEN),
    "r12 200 BOM-less UTF-16 body": (200, _JSON, _GOOD_TOKEN.decode().encode("utf-16-le")),
    "r13 200 unpaired surrogate in an extension member": (
        200,
        _JSON,
        _with(_GOOD_TOKEN, b'"x_ext":"' + _U + b'd800"'),
    ),
    "r14 200 unpaired surrogate in a member name": (
        200,
        _JSON,
        _with(_GOOD_TOKEN, b'"' + _U + b'd800":1'),
    ),
    "r15 200 unpaired surrogate as the access token": (
        200,
        _JSON,
        b'{"access_token":"' + _U + b'd800","token_type":"Bearer","expires_in":300}',
    ),
    "r16 200 corrupt gzip": (200, f"{_JSON}{_GZIP}", _CORRUPT_GZIP),
    "r16t 200 truncated gzip": (200, f"{_JSON}{_GZIP}", gzip.compress(_GOOD_TOKEN)[:-8]),
    "r16e 200 empty body labelled gzip": (200, f"{_JSON}{_GZIP}", b""),
    # 실행 레그(2026-11-11)가 살린 편집들의 칸 — 머리만 온 gzip · CRC · 길이 꼬리 · 날 deflate ·
    # 201 ·
    # 오류 상태의 잘린 gzip(상태가 판정한다).
    "r16h 200 gzip header only": (200, f"{_JSON}{_GZIP}", gzip.compress(_GOOD_TOKEN)[:10]),
    "r16c 200 gzip with a bad CRC": (200, f"{_JSON}{_GZIP}", _flip(gzip.compress(_GOOD_TOKEN), 8)),
    "r16i 200 gzip with a bad length": (
        200,
        f"{_JSON}{_GZIP}",
        _flip(gzip.compress(_GOOD_TOKEN), 4),
    ),
    "r16r 200 raw deflate": (200, f"{_JSON}\nContent-Encoding: deflate", _raw_deflate(_GOOD_TOKEN)),
    "r13c 201 unpaired surrogate": (201, _JSON, _with(_GOOD_TOKEN, b'"x":"' + _U + b'd800"')),
    "r13d 200 unpaired surrogate after 70 KB": (
        200,
        _JSON,
        _with(_GOOD_TOKEN, b'"pad":"' + b"x" * 70_000 + b'","x":"' + _U + b'd800"'),
    ),
    "r16t4 400 truncated gzip error body": (
        400,
        f"{_JSON}{_GZIP}",
        gzip.compress(b'{"error":"invalid_grant"}')[:-8],
    ),
    "r17 200 valid surrogate pair": (
        200,
        _JSON,
        _with(_GOOD_TOKEN, b'"scope":"a' + _U + b"d83d" + _U + b'de00b"'),
    ),
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
    # 객체가 아닌 JSON 오류 본문(등록부 python-auth-error-body-shape-status) — python-keycloak
    # 은 `response.json()["message"]` 에서 `TypeError`(깊은 중첩은 `RecursionError`)로 깨진다.
    # 302 는 이 레인이 따라가지 않는 3xx 다. 401 의 문자열은 코드 모양이어도 코드가 아니다.
    "r18a 400 JSON array": (400, _JSON, b"[]"),
    "r18s 401 JSON string": (401, _JSON, b'"invalid_client"'),
    "r18i 403 JSON number": (403, _JSON, b"42"),
    "r18b 404 JSON boolean": (404, _JSON, b"true"),
    "r18n 500 JSON null": (500, _JSON, b"null"),
    "r18d 400 deeply nested JSON": (400, _JSON, b"[" * 100_000 + b"]" * 100_000),
    "r18r 302 JSON array": (302, _JSON, b"[]"),
    # 성공 상태에 OAuth `error` — 4xx 가 실었을 때와 같은 판정이다(B2 의 토큰은 쓰지 않는다).
    "success_status_oauth_error B1 200": (200, _JSON, _B1_TOKEN),
    "success_status_oauth_error B2 200": (200, _JSON, _B2_TOKEN),
    **{
        f"success_status_oauth_error control: error is {what}": (
            200,
            _JSON,
            _with(_GOOD_TOKEN, member),
        )
        for what, member in _NOT_A_NAMED_ERROR.items()
    },
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
    "r11 200 charset=utf-16 over a UTF-8 body": OK,
    "r12 200 BOM-less UTF-16 body": _auth("token response is not valid JSON"),
    "r13 200 unpaired surrogate in an extension member": _auth(
        "token response holds an unpaired surrogate escape"
    ),
    "r14 200 unpaired surrogate in a member name": _auth(
        "token response holds an unpaired surrogate escape"
    ),
    "r15 200 unpaired surrogate as the access token": _auth(
        "token response holds an unpaired surrogate escape"
    ),
    "r16 200 corrupt gzip": _auth("token response could not be decoded"),
    # 꼬리(CRC · 길이)가 없는 gzip — 잘린 압축은 끊긴 연결과 가를 수 없다(판정 Q1, Go · JVM 과
    # 같다). 전에는 받아들였다. gzip 이라 적은 빈 본문은 빈 본문이다(잘림이 아니다).
    "r16t 200 truncated gzip": ("KeycloakTransportError", "token response was cut short"),
    "r16e 200 empty body labelled gzip": _auth(f"{_UNUSABLE} (TypeError)"),
    "r16h 200 gzip header only": ("KeycloakTransportError", "token response was cut short"),
    "r16c 200 gzip with a bad CRC": _auth("token response could not be decoded"),
    "r16i 200 gzip with a bad length": _auth("token response could not be decoded"),
    "r16r 200 raw deflate": OK,
    # 201 은 성공이 아니다(등록부 token-success-status-range-divergent) — 그 본문은 보지 않고 상태가
    # 판정한다(오류 상태의 본문처럼). 전에는 2xx 라 본문을 검사해 서로게이트로 거부했다.
    "r13c 201 unpaired surrogate": _auth(f"{_HTTP} 201"),
    "r13d 200 unpaired surrogate after 70 KB": _auth(
        "token response holds an unpaired surrogate escape"
    ),
    "r16t4 400 truncated gzip error body": _auth(f"{_HTTP} 400 (invalid_grant)", "invalid_grant"),
    "r17 200 valid surrogate pair": OK,
    "r8u 400 invalid UTF-8 in the error body": _auth(f"{_HTTP} 400"),
    "401 invalid_client": _auth(f"{_HTTP} 401 (invalid_client)", "invalid_client"),
    "403 access_denied": _auth(f"{_HTTP} 403 (access_denied)", "access_denied"),
    # Keycloak's prose is no code — `error` is `[a-z_]{1,64}` only (test_oauth_error_code_echo).
    "404 realm missing": _auth(f"{_HTTP} 404"),
    "409 conflict": _auth(f"{_HTTP} 409 (conflict)", "conflict"),
    "r18a 400 JSON array": _auth(f"{_HTTP} 400"),
    "r18s 401 JSON string": _auth(f"{_HTTP} 401"),
    "r18i 403 JSON number": _auth(f"{_HTTP} 403"),
    "r18b 404 JSON boolean": _auth(f"{_HTTP} 404"),
    "r18n 500 JSON null": _auth(f"{_HTTP} 500"),
    "r18d 400 deeply nested JSON": _auth(f"{_HTTP} 400"),
    "r18r 302 JSON array": _auth(f"{_HTTP} 302"),
    # 수정 전: B1 은 「token response has no usable access_token」(코드 없음), B2 는 성공이었다.
    "success_status_oauth_error B1 200": _auth(f"{_HTTP} 200 (invalid_grant)", "invalid_grant"),
    "success_status_oauth_error B2 200": _auth(f"{_HTTP} 200 (invalid_grant)", "invalid_grant"),
    **{f"success_status_oauth_error control: error is {what}": OK for what in _NOT_A_NAMED_ERROR},
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
    "r11 200 charset=utf-16 over a UTF-8 body": (200, f"{_JSON}; charset=utf-16", _GOOD_INTRO),
    "r12 200 BOM-less UTF-16 body": (200, _JSON, _GOOD_INTRO.decode().encode("utf-16-le")),
    "r13 200 unpaired surrogate in an extension member": (
        200,
        _JSON,
        _with(_GOOD_INTRO, b'"x_ext":"' + _U + b'd800"'),
    ),
    "r16 200 corrupt gzip": (200, f"{_JSON}{_GZIP}", _CORRUPT_GZIP),
    "r16t 200 truncated gzip": (200, f"{_JSON}{_GZIP}", gzip.compress(_GOOD_INTRO)[:-8]),
    "r17 200 valid surrogate pair": (
        200,
        _JSON,
        _with(_GOOD_INTRO, b'"sub":"a' + _U + b"d83d" + _U + b'de00b"'),
    ),
    "r18a 400 JSON array": (400, _JSON, b"[]"),
    "r18n 500 JSON null": (500, _JSON, b"null"),
    "r18d 400 deeply nested JSON": (400, _JSON, b"[" * 100_000 + b"]" * 100_000),
    # 성공 상태에 OAuth `error` — B2 의 `active: true` 는 쓰지 않는다.
    "success_status_oauth_error B1 200": (200, _JSON, _B1_INTRO),
    "success_status_oauth_error B2 200": (200, _JSON, _B2_INTRO),
    **{
        f"success_status_oauth_error control: error is {what}": (
            200,
            _JSON,
            _with(_GOOD_INTRO, member),
        )
        for what, member in _NOT_A_NAMED_ERROR.items()
    },
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
    "r11 200 charset=utf-16 over a UTF-8 body": OK,
    "r12 200 BOM-less UTF-16 body": _auth("introspection response is not valid JSON"),
    "r13 200 unpaired surrogate in an extension member": _auth(
        "introspection response holds an unpaired surrogate escape"
    ),
    "r16 200 corrupt gzip": _auth("introspection response could not be decoded"),
    "r16t 200 truncated gzip": ("KeycloakTransportError", "introspection response was cut short"),
    "r17 200 valid surrogate pair": OK,
    "r18a 400 JSON array": _auth(f"{_HTTP} 400"),
    "r18n 500 JSON null": _auth(f"{_HTTP} 500"),
    "r18d 400 deeply nested JSON": _auth(f"{_HTTP} 400"),
    # 수정 전: B1 은 「introspection response has no active」(코드 없음), B2 는 활성이었다.
    "success_status_oauth_error B1 200": _auth(f"{_HTTP} 200 (invalid_token)", "invalid_token"),
    "success_status_oauth_error B2 200": _auth(f"{_HTTP} 200 (invalid_token)", "invalid_token"),
    **{f"success_status_oauth_error control: error is {what}": OK for what in _NOT_A_NAMED_ERROR},
}

#: introspect 하는 값 — `invalid_token` 의 조각이 아니어야 그 코드가 실린다(보낸 값과 겹치는 코드는
#: 싣지 않는다 — test_oauth_error_code_echo 의 「값」 칸. 예전 값 `tok` 는 그 조각이다).
_INTROSPECTED = "opaque-1"


# --- 각본대로 답하는 가짜 IdP ---------------------------------------------------------------


@dataclass
class _Idp:
    token: _Answer
    introspection: _Answer = INTROSPECTION_CELLS["ok"]
    logout: _Answer = (204, _JSON, b"")
    url: str = ""
    admin: list[str] = field(default_factory=list)
    grants: int = 0  # 토큰 엔드포인트가 받은 요청 수
    lock: threading.Lock = field(default_factory=threading.Lock)

    def answer(self, method: str, path: str) -> _Answer:
        if path == _TOKEN:
            with self.lock:
                self.grants += 1
            return self.token
        if path == _INTROSPECT:
            return self.introspection
        if path == _LOGOUT:
            return self.logout
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
            content_type, *extra = content_type.split("\n")
            self.send_header("Content-Type", content_type)
            for line in extra:
                name, value = line.split(": ", 1)
                self.send_header(name, value)
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
    # 표의 r18d 가 파서를 재귀 한도까지 몬다 — 수집기를 멈춘 채 부른다.
    with collector_paused():
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


#: 그랜트의 성공 상태 — 200 하나다. python-keycloak 은 201 · 204 도 받지만
#: (`raise_error_from_response` 의 기본값) SDK 는 그것을 오류 상태로 판정한다(등록부
#: token-success-status-range-divergent).
_GRANT_SUCCESS = (200,)


def _as_admin_grant(err: BaseException | None, status: int) -> _Verdict:
    """S1 의 판정을 admin 그랜트가 낼 모양으로 — 같은 형 · 같은 코드(`error`)이되 오류 상태의
    메시지는 상태뿐이다(`lower.grant_failure` — 코드는 `error` 에만, 보낸 비밀과의 겹침은
    `admin_grant._sent` · 등록부 oauth-error-code-surface-divergent). 그랜트가 성공으로 받은
    상태에 OAuth `error` 를 실은 응답은 S1 처럼 메시지에도 코드를 싣는다(등록부
    auth-2xx-error-code-divergent)."""
    in_message = status in _GRANT_SUCCESS
    if isinstance(err, KeycloakAuthError) and err.error is not None and not in_message:
        return _auth(str(err).removesuffix(f" ({err.error})"), err.error)
    return _verdict(err)


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

    assert _verdict(err) == _as_admin_grant(auth_err, TOKEN_CELLS[cell][0])
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
    # 유한하지만 세터의 날짜 셈을 넘친다 — `OverflowError` 가 전송 오류로 옮겨졌다(독립 레그가
    # 찾음).
    "1e300": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":1e300}',
        _BAD_EXPIRY,
    ),
    "beyond the calendar": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300000000000}',
        _BAD_EXPIRY,
    ),
    "far negative": (
        b'{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":-1e12}',
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
            result, err = await _attempt(lane, client, lambda c: c.auth.introspect(_INTROSPECTED))

    assert _verdict(err) == INTRO[cell]
    if err is None:
        assert result.active is True
        assert result.username == "svc"


# refresh 와 logout 도 같은 경계(`_wrap`)다 — 객체가 아닌 JSON 오류 본문에 client_credentials
# 와 같은 판정(그 상태)이다. refresh 는 토큰 엔드포인트, logout 은 제 엔드포인트가 그 칸으로
# 답한다.
_NON_OBJECT = ["r18a 400 JSON array", "r18n 500 JSON null", "r18d 400 deeply nested JSON"]


@pytest.mark.parametrize("call", ["refresh", "logout"])
@pytest.mark.parametrize("cell", _NON_OBJECT)
@pytest.mark.parametrize("lane", LANES)
async def test_refresh_and_logout_keep_the_status_of_a_non_object_error_body(
    lane: str, cell: str, call: str
) -> None:
    with _fake_idp(TOKEN_CELLS[cell]) as idp:
        idp.logout = TOKEN_CELLS[cell]
        async with _client(lane, idp) as client:
            _, err = await _attempt(
                lane,
                client,
                lambda c: c.auth.refresh("rt-1") if call == "refresh" else c.auth.logout("rt-1"),
            )

    assert _verdict(err) == S1[cell]


#: 성공 상태에 OAuth `error` 를 실은 토큰 칸(대조군 포함) — refresh 와 교환도 같은 경계(`_wrap`)라
#: client_credentials 와 같은 판정이다.
_SUCCESS_STATUS_OAUTH_ERROR = [c for c in TOKEN_CELLS if c.startswith("success_status_oauth_error")]


@pytest.mark.parametrize("call", ["refresh", "exchange_code"])
@pytest.mark.parametrize("cell", _SUCCESS_STATUS_OAUTH_ERROR)
@pytest.mark.parametrize("lane", LANES)
async def test_success_status_oauth_error_takes_the_same_verdict_on_refresh_and_exchange_code(
    lane: str, cell: str, call: str
) -> None:
    def act(c: Any) -> Any:
        if call == "refresh":
            return c.auth.refresh("rt-1")
        return c.auth.exchange_code("code-1", "http://localhost/cb", "v" * 43)

    with _fake_idp(TOKEN_CELLS[cell]) as idp:
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, act)

    assert _verdict(err) == S1[cell]
    if err is None:
        assert result.access_token == "AT-ok-token"


# --- 성공은 200 하나다(등록부 token-success-status-range-divergent) -------------------------------

#: 200 이 아닌 2xx — python-keycloak 은 그중 201 · 204 를 성공으로 받는다
#: (`raise_error_from_response` 의 기본값 200 · 201 · 204). 204 에는 본문이 없다
#: (RFC 9110 §15.3.5) — 빈 본문으로 답한다.
_NON_200_SUCCESS = (201, 202, 203, 204, 206, 299)


def _status_verdict(call: str, status: int, body: str) -> _Verdict:
    """`call` 이 `status` 의 응답에 내야 할 판정 — 200 의 좋은 본문이면 성공, 아니면 그 레인이 오류
    상태에 내는 것이다: `HTTP <상태>` 와 본문의 코드(`B1` — 토큰 엔드포인트는 `invalid_grant`,
    introspection 은 `invalid_token`). admin 자체 그랜트의 오류 상태는 코드를 메시지에 싣지 않는다
    (`lower.grant_failure`)."""
    if status == 200 and body == "good":
        return OK
    code = None if body == "good" else "invalid_token" if call == "introspect" else "invalid_grant"
    shown = "" if code is None or call == "admin" else f" ({code})"
    return _auth(f"{_HTTP} {status}{shown}", code)


@pytest.mark.parametrize("lane", LANES)
async def test_non_200_success_status_fails_as_the_lanes_error_response(lane: str) -> None:
    """토큰 · introspection 응답의 성공은 200 하나다(토큰은 RFC 6749 §5.1, introspection 은 SDK
    의 규칙 — RFC 7662 §2.2 는 상태를 정하지 않고 그 예와 Keycloak 이 200 이다 · 아홉 언어,
    등록부 token-success-status-range-divergent). 200 이 아닌 2xx 는 그 레인이 같은
    본문의 400 에 내는 판정이다 — `KeycloakAuthError`(`HTTP <상태>`)이고, 본문의 `error` 는
    400 이 실었을 때처럼 싣는다(B1). 토큰도 introspection 결과도 돌려주지 않고, admin 은 요청을
    보내지 않으며 그 토큰을 캐시하지 않는다 — 같은 클라이언트의 다음 호출이 토큰 엔드포인트에
    다시 가서 200 의 토큰으로 요청을 보낸다. 400 행이 그 기준이고 200 행이 대조군이다.
    수정 전(실측 2026-11-23, 두 미러 같다): 201 은 다섯 호출 모두 성공이었다(admin 은 그
    토큰으로 요청을 보냈다). 204 는 python-keycloak 이 빈 본문을 `{}` 로 돌려줘 「없음」
    판정(그랜트 · admin 은 `token response has no usable access_token`, introspection 은
    `introspection response has no active`)이었고, 201 의 B1 은 admin 메시지에 코드를 실었다.
    202 · 203 · 206 · 299 는 이미 오류 상태였다."""
    calls: dict[str, Callable[[Any], Any]] = {
        "client_credentials_token": lambda c: c.auth.client_credentials_token(),
        "refresh": lambda c: c.auth.refresh("rt-1"),
        "exchange_code": lambda c: c.auth.exchange_code("code-1", "http://localhost/cb", "v" * 43),
        "introspect": lambda c: c.auth.introspect(_INTROSPECTED),
        "admin": lambda c: c.admin.users.get("u1"),
    }
    rows = [(status, "good") for status in (200, 400, *_NON_200_SUCCESS)] + [
        (400, "B1"),
        (201, "B1"),
    ]
    wrong: list[str] = []
    for status, body in rows:
        for name, act in calls.items():
            intro = name == "introspect"
            sent = (
                (_B1_INTRO if intro else _B1_TOKEN)
                if body == "B1"
                else _GOOD_INTRO
                if intro
                else _GOOD_TOKEN
            )
            answer: _Answer = (status, _JSON, b"" if status == 204 else sent)
            token, introspection = (
                (TOKEN_CELLS["ok"], answer) if intro else (answer, INTROSPECTION_CELLS["ok"])
            )
            again: tuple[Any, Any] | None = None
            with _fake_idp(token, introspection) as idp:
                async with _client(lane, idp) as client:
                    result, err = await _attempt(lane, client, act)
                    admin_first = idp.admin_requests()
                    if name == "admin" and err is not None:
                        idp.token = TOKEN_CELLS["ok"]
                        again = await _attempt(lane, client, act)
                grants, admin_all = idp.grants, idp.admin_requests()
            label = f"{lane} {status} {body} {name}"
            got, want = _verdict(err), _status_verdict(name, status, body)
            if got != want:
                wrong.append(f"{label}: {got} ≠ {want}")
            elif err is None and name == "admin":
                if result != {"id": "u1"} or admin_first != ["GET /admin/realms/r/users/u1"]:
                    wrong.append(f"{label}: 대조군 — {result} · admin {admin_first}")
            elif err is None:
                value = result.active if intro else result.access_token
                if value != (True if intro else "AT-ok-token"):
                    wrong.append(f"{label}: 대조군 — {value!r}")
            elif name == "admin" and (
                admin_first != []
                or again != ({"id": "u1"}, None)
                or grants != 2
                or len(admin_all) != 1
            ):
                wrong.append(
                    f"{label}: admin {admin_first} · 다음 호출 {again} · 그랜트 {grants} · "
                    f"{admin_all}"
                )

    assert not wrong, f"{len(wrong)} 칸:\n" + "\n".join(wrong)


# --- 짝 없는 서로게이트 판독기 ------------------------------------------------------------------

#: 이스케이프를 판정한다, 글자가 아니라 — JVM `holdsUnpairedSurrogate judges escapes, not text` 와
#: 같은 칸이다.
_UNPAIRED_SCAN: dict[bytes, bool] = {
    b'{"a":"' + _U + b'd800"}': True,
    b'{"a":"' + _U + b'dc00"}': True,
    b'{"' + _U + b'd800":1}': True,
    b'{"a":"x' + _U + b'D800"}': True,
    b'{"a":"' + _U + b"d800" + _U + b'0041"}': True,
    b'{"a":"' + _U + b'dbff"}': True,
    b'{"a":["ok","' + _U + b'dfff"]}': True,
    # 형식이 틀린 이스케이프 뒤도 훑는다(Grok 레그, 2026-11-11)
    b'{"a":"' + _U + b'ZZZZ","b":"' + _U + b'DC00"}': True,
    # 이스케이프된 따옴표가 문자열을 닫지 않는다 — `\\` 만 건너뛰면 여기서 어긋난다(JVM 실행 레그)
    b'{"x":"a' + b'\\"' + b'b","y":"' + _U + b'dc00"}': True,
    # 실행 레그(Go · node)가 살린 편집들 — 범위 위의 비-low · 짝 뒤 다음 문자열 · 대문자 F ·
    # 짝 앞의 `\` 와 `u`
    b'{"a":"' + _U + b"d800" + _U + b'e000"}': True,
    b'{"a":"' + _U + b"d83d" + _U + b'de00","b":"' + _U + b'd800"}': True,
    b'{"a":"' + _U + b'DBFF"}': True,
    b'{"a":"' + _U + b'DFFF"}': True,
    b'{"a":"' + _U + b'd800xudc00"}': True,
    b'{"a":"' + _U + b"d800" + b'\\"' + b'dc00"}': True,
    b'{"a":"' + _U + b"d800" + b"\\\\" + b'dc00"}': True,
    b'{"a":"' + _U + b"d800" + _U + b'dc00"}': False,
    # python 실행 레그가 살린 편집들 — 높은 것 뒤의 높은 것 · 범위 끝의 짝 · 끝에서 잘린
    # 이스케이프 ·
    # 64 KiB 너머
    b'{"a":"' + _U + b"d800" + _U + b'd800"}': True,
    b'{"a":"' + _U + b"dbff" + _U + b'dfff"}': False,
    b'{"a":"x' + _U: False,
    b'{"a":"x' + _U + b"12": False,
    b'{"a":"' + b"x" * 70_000 + _U + b'd800"}': True,
    b'{"a":"' + _U + b"d83d" + _U + b'de00"}': False,
    b'{"a":"' + b"\\\\" + b'ud800"}': False,
    b'{"a":"' + _U + b'0041"}': False,
    b'{"a":"plain"}': False,
    b'{"a":"' + _U + b'zz00"}': False,
    b'{"a":1} ' + _U + b"d800": False,
    b'{"a":"' + b'\\"' + _U + b"d83d" + _U + b'de00"}': False,
}


def test_the_unpaired_surrogate_scan_judges_escapes_not_text() -> None:
    from keycloak_sdk._internal.token_cap import holds_unpaired_surrogate

    assert {json: holds_unpaired_surrogate(json) for json in _UNPAIRED_SCAN} == _UNPAIRED_SCAN


# --- 되울린 비밀 · raw 의 원인 사슬 ------------------------------------------------------------

_CODE_SHAPED_SECRET = "echoed_code_shaped_secret"


@pytest.mark.parametrize("lane", LANES)
async def test_a_code_shaped_secret_echoed_as_the_grant_error_is_not_carried(lane: str) -> None:
    """소문자뿐인 client secret 은 OAuth 코드 모양이다 — 그랜트가 그것을 `error` 자리에 되울리면
    코드 모양 검사로는 거르지 못한다(독립 레그 실측: 메시지 · `args` · `error` 에 실렸다). 그랜트
    실패의 코드는 보낸 비밀과 겹치면 싣지 않는다(`carried_code`)."""
    answer: _Answer = (400, _JSON, b'{"error":"' + _CODE_SHAPED_SECRET.encode() + b'"}')
    with _fake_idp(answer) as idp:
        cfg = KeycloakConfig(
            server_url=idp.url, realm="r", client_id="c", client_secret=_CODE_SHAPED_SECRET
        )
        if lane == "sync":
            with KeycloakClient.create(cfg) as kc:
                _, err = await _attempt(lane, kc, lambda c: c.admin.users.get("u1"))
        else:
            async with AsyncKeycloakClient.create(cfg) as akc:
                _, err = await _attempt(lane, akc, lambda c: c.admin.users.get("u1"))

    assert isinstance(err, KeycloakAuthError)
    assert str(err) == f"{_HTTP} 400"
    for surface in (str(err), repr(err), repr(vars(err)), repr(err.args)):
        assert _CODE_SHAPED_SECRET not in surface


_RAW_CANARY = "CANARY-raw-body-9f3k"
#: raw 탈출구로는 그랜트 래퍼 · 본문 검사의 거부가 경계를 거치지 않고 그대로 나온다.
RAW_CELLS: dict[str, _Answer] = {
    "200 HTML": (200, _HTML_TYPE, f"<html>{_RAW_CANARY}</html>".encode()),
    "200 invalid UTF-8": (
        200,
        _JSON,
        b'{"access_token":"' + _RAW_CANARY.encode() + b'\xff","expires_in":300}',
    ),
}


def _chain(err: BaseException) -> list[BaseException]:
    """`__cause__` · `__context__` 로 닿는 예외 전부 — 억제 여부와 무관하게."""
    seen: list[BaseException] = []
    todo = [err]
    while todo:
        current = todo.pop()
        if any(current is s for s in seen):
            continue
        seen.append(current)
        todo += [e for e in (current.__cause__, current.__context__) if e is not None]
    return seen


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("cell", list(RAW_CELLS))
async def test_raw_refusals_carry_no_body_in_their_chain(cell: str, lane: str) -> None:
    """거부는 `except` **밖**에서 던진다 — 안에서 던지면 python-keycloak 의 본문 인용 `TypeError` 나
    본문 바이트를 쥔 `UnicodeDecodeError` 가 `__context__` 로 매달려 raw 소비자의 사슬에 닿는다(독립
    레그가 변이로 보임 — 경계를 지나는 파사드는 새로 만들어 가리지만 raw 는 그대로다)."""

    def act(c: Any) -> Any:
        return c.admin.raw.get_user("u1") if lane == "sync" else c.admin.raw.a_get_user("u1")

    with _fake_idp(RAW_CELLS[cell]) as idp:
        async with _client(lane, idp) as client:
            _, err = await _attempt(lane, client, act)

    assert err is not None
    for link in _chain(err):
        shown = f"{link!s} {link!r} {getattr(link, 'object', b'')!r}"
        assert _RAW_CANARY not in shown, f"{type(link).__name__} 가 본문을 쥐었다"
