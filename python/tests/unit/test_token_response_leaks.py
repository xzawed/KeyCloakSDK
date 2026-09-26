"""적대적·형식이 틀린 토큰/introspect/logout 응답에서 난 오류가 **비밀을 찍지 않는다**.

Node #603 과 같은 부류다. 거기서는 oauth4webapi 가 형식이 틀린 토큰 응답의 본문 전체(살아 있는
토큰)를 오류의 `cause` 에 실었고, SDK 가 그 하위 오류를 자기 `cause` 로 달아 `console.log(err)`
가 그것을 찍었다. Python 에서 같은 자리는 **예외 사슬**이다 — `logging.exception` 은
`traceback.format_exception` 과 같은 것을 찍고, 그것은 `__cause__`·`__context__` 를 따라간다.

찍는 길 셋(sync·aio 파사드 둘 다): `"".join(traceback.format_exception(e))`, `str(e)`, `repr(e)`.
카나리아는 응답에 실린 토큰(`ACCESS`·`REFRESH`·`ID_TOKEN`·본문)과 **요청에 실린 비밀**
(`SECRET`·입력 refresh/introspect 토큰·인가 코드·PKCE verifier — 요청 본문을 되돌리는 프록시가
오류 본문에 싣는다)이고, 원문 전체뿐 아니라 **앞 10 자**도 찾는다(Node 의 `SyntaxError` 가
긴 본문의 앞 10 자를 인용했다).

`test_facade_dump.py` 의 걷기와 다른 테스트인 이유: 걷기는 닿는 객체 중 **SDK 자신의 타입만**
찍는다. 여기서 비밀을 싣는 것은 사슬에 매달린 **남의 예외**(python-keycloak 의 `KeycloakError`·
`TypeError`)의 메시지라, 걷기는 구조적으로 못 본다.

⚠️ 흐름 검사가 요점이다 — 변형이 호출을 실제로 실패시키지 않으면 아래 누출 검사는 없는 오류를
찾으며 통과한다. 변형마다 **실패해야 하는 호출 집합**을 적고 정확히 그 집합이 실패했는지, 그리고
그 요청이 가짜 IdP 에 닿았는지 본다.
"""

from __future__ import annotations

import asyncio
import json
import threading
import traceback
from collections.abc import Awaitable, Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import unquote_plus, urlsplit

import pytest
from joserfc.jwk import KeySet, RSAKey

from keycloak_sdk import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakClient,
    KeycloakConfig,
    KeycloakTransportError,
)
from keycloak_sdk.aio import AsyncKeycloakClient

# --- 카나리아 — 앞 10 자가 서로 달라야 접두 누출을 어느 비밀의 것인지 가를 수 있다 ------------

ACCESS = "AT9f3kq2-access-canary"
REFRESH = "RT4m8zp1-refresh-canary"
ID_TOKEN = "IT6w2xv5-idtoken-canary"  # JWT 가 아니다
EXPIRES = "EX5k9m2p-expires-canary"
SHORT = "SB3n7q-short-body"  # 20 자 이하 — 짧은 본문은 통째로 인용된다
LONG = "LB8q1r4t-long-body-canary"  # 긴 본문의 **머리** — 뒤에 패딩이 붙는다
SECRET = "CS5h2j9k-client-secret"
REFRESH_IN = "RI2d6f8g-refresh-input"
TOKEN_IN = "TI7c3v5b-introspect-input"
CODE_IN = "CD1a5s9d-auth-code-input"
VERIFIER_IN = "PV4e8r2t-pkce-verifier-input-0123456789abcdef"

CANARIES: dict[str, str] = {
    "ACCESS": ACCESS,
    "REFRESH": REFRESH,
    "ID_TOKEN": ID_TOKEN,
    "EXPIRES": EXPIRES,
    "SHORT": SHORT,
    "LONG": LONG,
    "SECRET": SECRET,
    "REFRESH_IN": REFRESH_IN,
    "TOKEN_IN": TOKEN_IN,
    "CODE_IN": CODE_IN,
    "VERIFIER_IN": VERIFIER_IN,
}
_PREFIX = 10
assert len(SHORT) <= 20
assert len({v[:_PREFIX] for v in CANARIES.values()}) == len(CANARIES), "접두가 겹친다"

REDIRECT = "https://app.example/cb"
NONCE = "n-0123456789"

#: 알려진 누출 — `"facade|variant|call|path|canary"` → SDK 가 막을 수 없는 이유.
#: ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
KNOWN_LEAKS: dict[str, str] = {}


# --- 변형 ----------------------------------------------------------------------------------

_Response = tuple[int, str, bytes]


def _json(status: int, obj: object) -> _Response:
    return status, "application/json", json.dumps(obj).encode()


def _text(status: int, body: str, content_type: str = "text/plain") -> _Response:
    return status, content_type, body.encode()


_TOKENS = {"access_token": ACCESS, "refresh_token": REFRESH, "token_type": "Bearer"}

CC = "client_credentials_token"
EXCHANGE = "exchange_code"
EXCHANGE_NONCE = "exchange_code(nonce)"
REFRESH_CALL = "refresh"
INTROSPECT = "introspect"
LOGOUT = "logout"
ADMIN = "admin grant"
ALL_CALLS = frozenset({CC, EXCHANGE, EXCHANGE_NONCE, REFRESH_CALL, INTROSPECT, LOGOUT, ADMIN})
#: 200 이지만 쓸 수 없는 토큰 JSON — 토큰을 파싱하는 호출과 admin 그랜트가 실패한다. introspect 는
#: `active` 없는 객체를 비활성으로 읽고(정상), logout 은 204 가 아니라 실패한다.
_BAD_TOKEN_JSON = ALL_CALLS - {INTROSPECT}


@dataclass(frozen=True)
class _Variant:
    #: 요청 본문(디코드한 폼) → 응답. 토큰·introspect·logout 엔드포인트가 **같은 모양**을 낸다.
    respond: Callable[[str], _Response]
    #: 이 변형에서 **실패해야 하는** 호출 — 흐름 검사의 기준.
    fails: frozenset[str]


VARIANTS: dict[str, _Variant] = {
    # (a) id_token 이 JWT 가 아니다 — nonce 를 준 교환만 id_token 을 검증한다.
    "a id_token 이 JWT 가 아님": _Variant(
        lambda _: _json(200, {**_TOKENS, "id_token": ID_TOKEN, "expires_in": 300}),
        frozenset({EXCHANGE_NONCE, LOGOUT}),
    ),
    # (b) access_token 이 문자열이 아니고 refresh_token 이 카나리아다.
    "b access_token 이 문자열 아님": _Variant(
        lambda _: _json(
            200, {"access_token": 12345, "refresh_token": REFRESH, "id_token": ID_TOKEN}
        ),
        _BAD_TOKEN_JSON,
    ),
    # (c) expires_in·token_type 이 틀린 타입이고, 그 안에 토큰이 실려 있다.
    "c expires_in·token_type 타입 틀림": _Variant(
        lambda _: _json(
            200,
            {
                **_TOKENS,
                "id_token": ID_TOKEN,
                "token_type": {"echo": REFRESH},
                "expires_in": {"echo": ACCESS},
            },
        ),
        _BAD_TOKEN_JSON,
    ),
    # (c') expires_in 이 숫자가 아닌 문자열 — `float()` 의 ValueError 는 입력을 인용한다.
    "c' expires_in 이 숫자 아닌 문자열": _Variant(
        lambda _: _json(200, {**_TOKENS, "expires_in": EXPIRES}), _BAD_TOKEN_JSON
    ),
    # (c'') token_type 만 틀렸다 — 예전에는 **성공**했고 돌려받은 `TokenSet` 의 repr 이 찍었다.
    # python-keycloak 의 admin 그랜트는 token_type 을 읽지 않으므로 성공한다.
    "c'' token_type 에 토큰": _Variant(
        lambda _: _json(200, {**_TOKENS, "token_type": {"echo": REFRESH}, "expires_in": 300}),
        _BAD_TOKEN_JSON - {ADMIN},
    ),
    # (d) 200 인데 본문이 JSON 이 아니다 — 짧은 것(통째)과 긴 것(머리가 카나리아).
    "d 200 비JSON 짧은 본문": _Variant(lambda _: _text(200, SHORT), ALL_CALLS),
    "d 200 비JSON 긴 본문": _Variant(lambda _: _text(200, LONG + "-" + "z" * 300), ALL_CALLS),
    # (d') 200 JSON 이지만 객체가 아니다(배열).
    "d' 200 JSON 배열": _Variant(lambda _: _json(200, [ACCESS, REFRESH]), ALL_CALLS),
    # (e) 오류 본문의 error_description 이 토큰을 되돌린다.
    "e 400 error_description 에 토큰": _Variant(
        lambda _: _json(
            400,
            {"error": "invalid_grant", "error_description": f"refresh {REFRESH} not active"},
        ),
        ALL_CALLS,
    ),
    # (e') 401 — 요청 본문(client_secret·refresh_token·code·verifier)을 되돌리는 프록시.
    "e' 401 error_description 이 요청을 되돌림": _Variant(
        lambda body: _json(401, {"error": "invalid_client", "error_description": body}),
        ALL_CALLS,
    ),
    # (e'') python-keycloak 은 오류 본문의 `message` 키를 따로 뽑아 메시지로 쓴다.
    "e'' 400 message 키에 토큰": _Variant(
        lambda _: _json(400, {"error": "invalid_request", "message": ACCESS}), ALL_CALLS
    ),
    # (e''') 비JSON 오류 페이지(프록시 HTML)가 토큰을 되돌린다.
    "e''' 502 비JSON 오류 페이지": _Variant(
        lambda _: _text(502, f"<html>{LONG} upstream said {REFRESH}</html>", "text/html"),
        ALL_CALLS,
    ),
    # (e'''') 오류 본문이 JSON 배열 — python-keycloak 의 `json()["message"]` 가 TypeError 를 낸다.
    "e'''' 400 JSON 배열": _Variant(lambda _: _json(400, [ACCESS]), ALL_CALLS),
    # (e''''') OAuth 오류 **코드** 자리에 토큰 — 코드는 메시지에 싣는 유일한 본문 조각이다.
    "e''''' 400 error 코드 자리에 토큰": _Variant(
        lambda _: _json(400, {"error": ACCESS, "error_description": "x"}), ALL_CALLS
    ),
}


# --- 가짜 IdP ------------------------------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_VARIANT_PATHS = (f"{_OC}/token", f"{_OC}/token/introspect", f"{_OC}/logout")


@dataclass
class _Idp:
    jwks: bytes
    url: str = ""
    variant: str = ""
    hits: list[tuple[str, str]] = field(default_factory=list)  # (변형, 경로)
    bodies: list[str] = field(default_factory=list)


def _answer(idp: _Idp, path: str, body: str) -> _Response:
    if path == f"{_OC}/certs":
        return 200, "application/json", idp.jwks
    if path in _VARIANT_PATHS:
        idp.hits.append((idp.variant, path))
        idp.bodies.append(body)
        return VARIANTS[idp.variant].respond(body)
    if path == "/admin/realms/r/users/u1":
        return _json(200, {"id": "u1", "username": "svc"})
    return _json(404, {})


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            status, content_type, payload = _answer(idp, urlsplit(self.path).path, raw)
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve

    return Handler


@contextmanager
def _fake_idp() -> Iterator[_Idp]:
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig", "alg": "RS256"})
    idp = _Idp(jwks=json.dumps(KeySet([key]).as_dict(private=False)).encode())
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


# --- 호출 ----------------------------------------------------------------------------------


def _sync_admin_grant(kc: KeycloakClient) -> object:
    # admin 은 토큰을 캐시한다 — 앞 변형의 성공이 이 변형의 그랜트를 건너뛰게 두지 않는다.
    kc.admin.raw.connection.token = None
    return kc.admin.users.get("u1")


async def _aio_admin_grant(akc: AsyncKeycloakClient) -> object:
    akc.admin.raw.connection.token = None
    return await akc.admin.users.get("u1")


SYNC_CALLS: dict[str, Callable[[KeycloakClient], object]] = {
    CC: lambda kc: kc.auth.client_credentials_token(),
    EXCHANGE: lambda kc: kc.auth.exchange_code(CODE_IN, REDIRECT, VERIFIER_IN),
    EXCHANGE_NONCE: lambda kc: kc.auth.exchange_code(CODE_IN, REDIRECT, VERIFIER_IN, nonce=NONCE),
    REFRESH_CALL: lambda kc: kc.auth.refresh(REFRESH_IN),
    INTROSPECT: lambda kc: kc.auth.introspect(TOKEN_IN),
    LOGOUT: lambda kc: kc.auth.logout(REFRESH_IN),
    ADMIN: _sync_admin_grant,
}

AIO_CALLS: dict[str, Callable[[AsyncKeycloakClient], Awaitable[object]]] = {
    CC: lambda akc: akc.auth.client_credentials_token(),
    EXCHANGE: lambda akc: akc.auth.exchange_code(CODE_IN, REDIRECT, VERIFIER_IN),
    EXCHANGE_NONCE: lambda akc: akc.auth.exchange_code(CODE_IN, REDIRECT, VERIFIER_IN, nonce=NONCE),
    REFRESH_CALL: lambda akc: akc.auth.refresh(REFRESH_IN),
    INTROSPECT: lambda akc: akc.auth.introspect(TOKEN_IN),
    LOGOUT: lambda akc: akc.auth.logout(REFRESH_IN),
    ADMIN: _aio_admin_grant,
}


@dataclass
class _Outcome:
    facade: str
    variant: str
    call: str
    error: BaseException | None
    result: object  # 성공했으면 돌려받은 값 — 그 표현도 찍는 길이다
    reached: bool  # 이 변형의 요청이 가짜 IdP 의 변형 경로에 닿았는가


def _run_sync(idp: _Idp, kc: KeycloakClient) -> list[_Outcome]:
    outcomes = []
    for variant in VARIANTS:
        for call, fn in SYNC_CALLS.items():
            idp.variant, before = variant, len(idp.hits)
            error: BaseException | None = None
            result: object = None
            try:
                result = fn(kc)
            except Exception as exc:
                error = exc
            reached = len(idp.hits) > before
            outcomes.append(_Outcome("sync", variant, call, error, result, reached))
    return outcomes


async def _run_aio(idp: _Idp, akc: AsyncKeycloakClient) -> list[_Outcome]:
    outcomes = []
    for variant in VARIANTS:
        for call, fn in AIO_CALLS.items():
            idp.variant, before = variant, len(idp.hits)
            error: BaseException | None = None
            result: object = None
            try:
                result = await fn(akc)
            except Exception as exc:
                error = exc
            reached = len(idp.hits) > before
            outcomes.append(_Outcome("aio", variant, call, error, result, reached))
    return outcomes


async def _measure(idp: _Idp) -> list[_Outcome]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret=SECRET)
    with KeycloakClient.create(cfg) as kc:
        outcomes = _run_sync(idp, kc)
    async with AsyncKeycloakClient.create(cfg) as akc:
        outcomes += await _run_aio(idp, akc)
    return outcomes


# --- 판정 ----------------------------------------------------------------------------------


def _renders(outcome: _Outcome) -> dict[str, str]:
    """실패면 오류를, 성공이면 돌려받은 값을 찍는다."""
    if outcome.error is None:
        return {"repr": repr(outcome.result), "str": str(outcome.result)}
    return {
        # `logging.exception` 이 찍는 것 — `__cause__`·(억제 안 된) `__context__` 사슬을 따라간다.
        "traceback": "".join(traceback.format_exception(outcome.error)),
        "str": str(outcome.error),
        "repr": repr(outcome.error),
    }


def _leaks(outcome: _Outcome) -> list[tuple[str, str, str]]:
    """(찍는 길, 카나리아, full|prefix)."""
    found = []
    for how, out in _renders(outcome).items():
        for name, value in CANARIES.items():
            if value in out:
                found.append((how, name, "full"))
            elif value[:_PREFIX] in out:
                found.append((how, name, "prefix"))
    return found


def _reachable(error: BaseException) -> list[BaseException]:
    """`__cause__`·`__context__` 로 닿는 예외 전부 — **억제 여부와 무관하게**. 찍히지 않더라도
    소비자 코드가 속성으로 따라갈 수 있으면 공개 API 로 닿은 것이다."""
    seen: list[BaseException] = []
    todo = [error]
    while todo:
        current = todo.pop()
        if any(current is s for s in seen):
            continue
        seen.append(current)
        todo += [e for e in (current.__cause__, current.__context__) if e is not None]
    return seen


def _where(o: _Outcome) -> str:
    return f"{o.facade}|{o.variant}|{o.call}"


@pytest.fixture(scope="module")
def measured() -> tuple[_Idp, list[_Outcome]]:
    with _fake_idp() as idp:
        outcomes = asyncio.run(_measure(idp))
    return idp, outcomes


def test_each_hostile_variant_really_fails_the_calls(
    measured: tuple[_Idp, list[_Outcome]],
) -> None:
    """흐름 검사 — 변형마다 **정확히** 그 호출들이 실패했고, 요청이 그 변형으로 IdP 에 닿았다.
    이것이 무너지면 아래 두 테스트는 없는 오류를 찾으며 통과한다."""
    idp, outcomes = measured
    # 요청 비밀이 실제로 흘러 들어갔는가 — 안 흘렀으면 되돌림 변형은 없는 것을 찾는다.
    sent = "\n".join(unquote_plus(b) for b in idp.bodies)
    for name in ("SECRET", "REFRESH_IN", "TOKEN_IN", "CODE_IN", "VERIFIER_IN"):
        assert CANARIES[name] in sent, f"{name} 이 요청에 실리지 않았다"

    flow = [
        f"{_where(o)}: {'실패' if o.error is not None else '성공'}(기대 "
        f"{'실패' if o.call in VARIANTS[o.variant].fails else '성공'}), reached={o.reached}"
        for o in outcomes
        if (o.error is not None) != (o.call in VARIANTS[o.variant].fails) or not o.reached
    ]
    assert not flow, "변형이 호출을 기대대로 실패시키지 않았다:\n" + "\n".join(flow)
    assert (
        len(outcomes) == 2 * len(VARIANTS) * len(SYNC_CALLS) == 2 * len(VARIANTS) * len(AIO_CALLS)
    )


def test_failures_are_sdk_types_with_no_lower_exception_reachable(
    measured: tuple[_Idp, list[_Outcome]],
) -> None:
    """§4 — 실패는 SDK 타입이고, 사슬(억제된 `__context__` 까지)에 python-keycloak 원본이 없다.
    분류는 레인 규칙대로다: auth 는 `KeycloakAuthError`, admin 은 admin 계층 또는 전송 오류."""
    _, outcomes = measured
    failed = [o for o in outcomes if o.error is not None]
    assert failed, "실패가 없다 — 흐름이 공허하다"
    problems = []
    for o in failed:
        assert o.error is not None
        if o.call == ADMIN:
            if not isinstance(o.error, (KeycloakAdminError, KeycloakTransportError)):
                problems.append(f"{_where(o)}: admin 계층이 아니다 — {type(o.error)}")
        elif not isinstance(o.error, KeycloakAuthError):
            problems.append(f"{_where(o)}: KeycloakAuthError 가 아니다 — {type(o.error)}")
        status = VARIANTS[o.variant].respond("")[0]
        # ⚠️ 오류 본문이 JSON 배열이면 python-keycloak 은 상태를 실은 오류를 **만들기 전에**
        # `json()["message"]` 에서 `TypeError` 를 낸다 — 상태를 싣는 객체가 없다(예전 raw
        # `TypeError` 도 상태가 없었다). 요약의 던진 자리(`raise_error_from_response`)가 대신한다.
        keeps_status = o.variant != "e'''' 400 JSON 배열"
        if o.call != ADMIN and status >= 300 and keeps_status and str(status) not in str(o.error):
            problems.append(f"{_where(o)}: 메시지가 HTTP 상태를 잃었다 — {o.error}")
        problems += [
            f"{_where(o)}: 닿는 사슬에 {type(e).__module__}.{type(e).__qualname__}"
            for e in _reachable(o.error)
            if type(e).__module__.partition(".")[0] == "keycloak"
        ]
    assert not problems, "\n".join(problems)


def test_hostile_token_responses_do_not_print_secrets(
    measured: tuple[_Idp, list[_Outcome]],
) -> None:
    _, outcomes = measured
    seen_known: set[str] = set()
    leaks: list[str] = []
    for o in outcomes:
        for how, name, extent in _leaks(o):
            key = f"{_where(o)}|{how}|{name}"
            if key in KNOWN_LEAKS:
                seen_known.add(key)
            else:
                leaks.append(f"{key} ({extent}) [{type(o.error or o.result).__name__}]")
    assert not leaks, f"비밀이 찍힌다 ({len(leaks)}):\n" + "\n".join(leaks)
    stale = sorted(set(KNOWN_LEAKS) - seen_known)
    assert not stale, f"알려진 누출이 더 안 난다 — KNOWN_LEAKS 에서 지워라: {stale}"
