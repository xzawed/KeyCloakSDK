"""admin 레인 **자체** 토큰 그랜트가 실패하면 SDK 예외는 토큰 엔드포인트의 응답 본문을 **어디에도**
싣지 않는다(등록부 `secret-echo-form-encoded-rescan`).

그랜트는 보낸 값을 폼 본문에 싣는다 — `client_secret`(client_credentials·refresh 둘 다)과, 갱신이면
admin 의 refresh token. IdP 가 그것을 오류 본문에 되울리면 예전 경계(`admin/_translate.py` 의
`translate`)는 그 본문을 `KeycloakAdminError.keycloak_error` 에 그대로 옮겼다 — 메시지·repr·
traceback 은 깨끗했지만 공개 속성(`vars(e)`)이 되울린 값을 쥐었다(실측: 다섯 인코딩, sync·aio
전부). auth 레인은 같은 응답에 `HTTP 401 (invalid_client)` 만 낸다.

찾는 자리: `str` · `repr` · `traceback.format_exception` · `capture_locals` 렌더(오류 수집기) ·
`vars(e)` · `args` · `__cause__`/`__context__` 사슬(억제 여부와 무관하게, 노드마다 str·repr·vars).
찾는 모양: 원문과 IdP 가 되울릴 법한 인코딩(선 위 그대로 · WHATWG 폼 · 퍼센트 · base64(`id:값`) ·
userinfo) — 각각 통째와 앞 10 자 — 그리고 응답 본문 자체의 표지(`BODY`).

대조군(수정 전후 모두 통과해야 한다): admin **리소스** 오류(404·409·403, 그리고 그랜트는 성공했는데
리소스가 다시 401 인 것)는 `keycloak_error` 에 본문을 예전 그대로 싣는다 — 그 표면은 따로 등록된
판단이다(`error-message-surface-unspecified`). 그랜트 실패의 타입·메시지·`status_code` 도 예전
그대로다(소비자의 `except` 절이 바뀌지 않는다).
"""

from __future__ import annotations

import base64
import contextlib
import json
import threading
import traceback
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, parse_qsl, quote, quote_plus, urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
)

from .test_admin_grant import _attempt, _chain

#: 경로마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

# --- 카나리아 ------------------------------------------------------------------------------

#: 인코딩마다 모양이 갈린다(공백 · `/` · `+` · `=` · `~` · 비 ASCII) — 프로브(`harness.mjs b`)와
#: 같은 값.
SECRET = "sec ret/+=~0005é"
CLIENT_ID = "c"
ACCESS = "AE3w7q-access-from-the-good-grant"
REFRESH = "RF8k2v-admin-refresh-token-sent-on-refresh"  # 갱신 그랜트가 폼에 실어 보낸다
BODY = "BM6t9x-token-endpoint-error-body"  # 되울린 응답 본문의 표지 — 본문째 실렸는지 가른다
RESOURCE = "RS4n1c-admin-resource-error-body"  # 리소스 오류 본문의 표지 — 대조군
_PREFIX = 10

LANES = ("sync", "aio")


def _echoes(value: str) -> dict[str, str]:
    """IdP 가 `value` 를 되울릴 법한 모양 — 프로브의 다섯. 선 위 그대로는 요청에서 읽는다
    (`_field`)."""
    return {
        "raw": value,
        "form": quote_plus(value, safe="*").replace("~", "%7E"),  # WHATWG x-www-form-urlencoded
        "pct": quote(value, safe=""),  # encodeURIComponent + !'()*
        "b64": base64.b64encode(f"{CLIENT_ID}:{value}".encode()).decode(),
        "userinfo": f"{CLIENT_ID}:{value}",
    }


def _field(form: str, name: str) -> str | None:
    """폼 본문에서 `name` 의 값 — 디코드하지 않은, 선 위 그대로의 모양."""
    for pair in form.split("&"):
        key, _, value = pair.partition("=")
        if key == name:
            return value
    return None


def _wire(form: str, name: str) -> str:
    value = _field(form, name)
    assert value is not None, f"요청 폼에 {name} 이 없다 — 되울릴 값이 없어 공허하다"
    return value


def _decoded(form: str, name: str) -> str:
    return parse_qs(form)[name][0]


# --- 받은 폼으로 답을 만드는 가짜 IdP ---------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_USER = "/admin/realms/r/users/u1"

#: (상태, Content-Type, 본문).
_Resp = tuple[int, str, bytes]
#: 토큰 엔드포인트의 각본 한 칸 — 받은 폼(선 위 그대로)으로 답을 만든다.
_Script = Callable[[str], _Resp]


def _json(status: int, obj: object) -> _Resp:
    return status, "application/json", json.dumps(obj).encode()


def _good_grant(expires_in: int) -> _Script:
    body = {
        "access_token": ACCESS,
        "token_type": "Bearer",
        "expires_in": expires_in,
        "refresh_token": REFRESH,
    }
    return lambda _form: _json(200, body)


@dataclass(frozen=True)
class _Seen:
    path: str
    grant: str
    form: str


@dataclass
class _Idp:
    """grant_type 마다 각본(차례대로 꺼내고 마지막 것은 남는다)과 admin GET 의 응답 각본."""

    url: str = ""
    grants: dict[str, list[_Script]] = field(default_factory=dict)
    admin: list[_Resp] = field(default_factory=list)
    seen: list[_Seen] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def answer(self, path: str, form: str) -> _Resp:
        with self.lock:
            grant = parse_qs(form).get("grant_type", [""])[0] if path == _TOKEN else ""
            self.seen.append(_Seen(path, grant, form))
            if path == _TOKEN:
                script = self.grants.get(grant)
                if not script:
                    return _json(400, {"error": "unsupported_grant_type"})
                step = script.pop(0) if len(script) > 1 else script[0]
                return step(form)
            if path == _USER:
                return self.admin.pop(0) if self.admin else _json(200, {"id": "u1"})
            return _json(404, {})

    def grant_types(self) -> list[str]:
        with self.lock:
            return [s.grant for s in self.seen if s.path == _TOKEN]

    def admin_requests(self) -> int:
        with self.lock:
            return sum(1 for s in self.seen if s.path.startswith("/admin/"))

    def sent(self, name: str) -> tuple[list[str], list[str]]:
        """토큰 요청 폼들이 `name` 으로 실어 보낸 값 — (디코드한 것, 선 위 그대로)."""
        with self.lock:
            forms = [s.form for s in self.seen if s.path == _TOKEN and _field(s.form, name)]
        return [_decoded(f, name) for f in forms], [_wire(f, name) for f in forms]


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            form = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            status, content_type, payload = idp.answer(urlsplit(self.path).path, form)
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve

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
async def _client(lane: str, idp: _Idp) -> AsyncIterator[Any]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id=CLIENT_ID, client_secret=SECRET)
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            yield akc


def _admin_get(client: Any) -> Any:
    return client.admin.users.get("u1")


# --- 판정 도우미 ---------------------------------------------------------------------------


def _surface(err: BaseException) -> dict[str, str]:
    """소비자가 이 예외에서 닿는 것 — 찍는 길 넷과 공개 속성, 그리고 사슬의 노드마다 같은 것."""
    out = {
        "str": str(err),
        "repr": repr(err),
        "traceback": "".join(traceback.format_exception(err)),
        "locals": "".join(
            traceback.TracebackException.from_exception(err, capture_locals=True).format()
        ),
        "vars": repr(vars(err)),
        "args": repr(err.args),
    }
    for i, node in enumerate(_chain(err)):
        kind = f"{type(node).__module__}.{type(node).__qualname__}"
        out[f"사슬[{i}] {kind}"] = f"{node!s} | {node!r} | {vars(node)!r}"
    return out


def _shapes(decoded: list[str], wire: list[str]) -> set[str]:
    """보낸 값의 되울릴 법한 모양 전부와 각각의 앞 10 자."""
    shapes = {s for value in decoded for s in _echoes(value).values()} | set(wire)
    return {s for shape in shapes for s in (shape, shape[:_PREFIX])}


def _leaks(err: BaseException, idp: _Idp, fields: tuple[str, ...]) -> list[str]:
    """`err` 의 표면에서 찾은 보낸 값(토큰 요청 폼 필드 `fields` 의 모든 모양)과 응답 본문의 표지
    — `자리: 필드 모양`. 찾을 값이 없으면 공허하므로 거부한다(필드 이름을 잘못 적은 판이 그랬다)."""
    shapes = {name: _shapes(*idp.sent(name)) for name in fields}
    assert all(shapes.values()), f"보낸 값이 없다 — 찾을 것이 없어 공허하다: {shapes}"
    found = []
    for where, text in _surface(err).items():
        for name, candidates in shapes.items():
            found += [f"{where}: {name} {s!r}" for s in sorted(candidates) if s in text]
        if BODY in text:
            found.append(f"{where}: 응답 본문 표지")
    return found


def _idp_that_saw(form: str) -> _Idp:
    idp = _Idp()
    idp.seen.append(_Seen(_TOKEN, "client_credentials", form))
    return idp


_SENT_FORM = f"grant_type=client_credentials&client_id=c&client_secret={quote_plus(SECRET)}"
#: 계측기 자체의 양성 — 모양마다 통째와 앞 10 자. `wire` 는 python 의 폼 인코딩이다(`~` 를 그대로
#: 둔다 — WHATWG 폼은 `%7E`).
_KNOWN_SHAPES = {
    **_echoes(SECRET),
    "wire": quote_plus(SECRET),
    **{f"{k}[:10]": v[:_PREFIX] for k, v in _echoes(SECRET).items()},
}


@pytest.mark.parametrize("echo", list(_KNOWN_SHAPES.values()), ids=list(_KNOWN_SHAPES))
def test_the_leak_finder_sees_every_shape_of_a_sent_value(echo: str) -> None:
    """계측기 자체 — 알려진 양성(모양마다, `keycloak_error` 안에서)은 잡고 알려진 음성(본문 없는
    같은 오류)은 놓아준다. 이것이 무너지면 아래 단언들은 무엇을 넣어도 빈 목록이다."""
    idp = _idp_that_saw(_SENT_FORM)
    assert _leaks(KeycloakAdminError(401, f"Bad credentials: {echo}"), idp, ("client_secret",))
    assert _leaks(KeycloakAdminError(401, None), idp, ("client_secret",)) == []
    with pytest.raises(AssertionError, match="공허"):
        _leaks(KeycloakAdminError(401, None), idp, ("refresh_token",))


# --- 첫 그랜트(client_credentials)의 거부 ---------------------------------------------------


def _described(encoding: str) -> _Script:
    """`error_description` 에 받은 시크릿을 `encoding` 모양으로 되울린다(`wire` = 받은 그대로)."""

    def respond(form: str) -> _Resp:
        if encoding == "wire":
            echo = _wire(form, "client_secret")
        else:
            echo = _echoes(_decoded(form, "client_secret"))[encoding]
        description = f"{BODY} Bad credentials: {echo}"
        return _json(401, {"error": "invalid_client", "error_description": description})

    return respond


def _in_error_code(form: str) -> _Resp:
    """OAuth `error` **코드** 자리에 — 선 위 모양은 RFC 6749 `error` 문법(NQSCHAR)에 맞는다."""
    return _json(401, {"error": _wire(form, "client_secret"), "error_description": BODY})


def _in_message_key(form: str) -> _Resp:
    """python-keycloak 이 따로 뽑아 오류 메시지로 쓰는 `message` 키에."""
    message = f"{BODY} {_decoded(form, 'client_secret')}"
    return _json(401, {"error": "invalid_client", "message": message})


def _not_json(form: str) -> _Resp:
    page = f"<html>{BODY} Bad credentials: {_decoded(form, 'client_secret')}</html>"
    return 401, "text/html", page.encode()


_FIRST: dict[str, _Script] = {
    **{
        f"error_description·{e}": _described(e)
        for e in ("raw", "form", "pct", "b64", "userinfo", "wire")
    },
    "error 코드 자리·wire": _in_error_code,
    "message 키·raw": _in_message_key,
    "비JSON 본문·raw": _not_json,
}


@pytest.mark.parametrize("shape", list(_FIRST))
@pytest.mark.parametrize("lane", LANES)
async def test_a_refused_first_grant_carries_no_echo_of_the_secret(lane: str, shape: str) -> None:
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [_FIRST[shape]]
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, _admin_get)

    # 흐름 — 그랜트가 시크릿을 실어 나갔고(되울릴 값이 있었다), admin 요청은 나가지 않았다.
    assert idp.sent("client_secret")[0] == [SECRET], "시크릿이 요청에 실리지 않았다 — 공허하다"
    assert idp.grant_types() == ["client_credentials"]
    assert idp.admin_requests() == 0
    assert result is None
    # 타입·메시지·상태는 예전 그대로다.
    assert type(err) is KeycloakAdminError
    assert str(err) == "Keycloak admin error (HTTP 401)"
    assert err.status_code == 401
    # 응답 본문은 어디에도 없다 — 보낸 값의 어떤 모양도, 본문 표지도.
    assert _leaks(err, idp, ("client_secret",)) == []
    assert err.keycloak_error is None


#: 첫 그랜트의 거부 상태 → 예전 그대로의 SDK 타입(`translate` 의 상태 매핑).
_STATUS_TYPES: dict[int, type[KeycloakAdminError]] = {
    400: KeycloakAdminError,
    403: KeycloakForbiddenError,
    404: KeycloakNotFoundError,
    409: KeycloakConflictError,
    500: KeycloakAdminError,
}


@pytest.mark.parametrize("status", list(_STATUS_TYPES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_refused_first_grant_keeps_its_type_whatever_the_status(
    lane: str, status: int
) -> None:
    def refuse(form: str) -> _Resp:
        echo = f"{_decoded(form, 'client_secret')} {_wire(form, 'client_secret')}"
        return _json(status, {"error": "invalid_request", "error_description": f"{BODY} {echo}"})

    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [refuse]
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, _admin_get)

    assert idp.sent("client_secret")[0] == [SECRET], "시크릿이 요청에 실리지 않았다 — 공허하다"
    assert idp.admin_requests() == 0
    assert result is None
    assert type(err) is _STATUS_TYPES[status]
    assert str(err) == f"Keycloak admin error (HTTP {status})"
    assert err.status_code == status
    assert _leaks(err, idp, ("client_secret",)) == []
    assert err.keycloak_error is None


# --- 나중 그랜트 — 만료 갱신 · 401 재시도 · `Refresh token expired` 폴백 ----------------------


def _echo_everything(status: int, error: str, lead: str = "") -> _Script:
    """받은 폼을 통째로 — 선 위 그대로와 디코드한 값 둘 다 — 되울린다(refresh token·시크릿 전부)."""

    def respond(form: str) -> _Resp:
        decoded = " ".join(f"{k}={v}" for k, v in parse_qsl(form))
        return _json(
            status, {"error": error, "error_description": f"{lead}{BODY} {form} {decoded}"}
        )

    return respond


#: 경로 → (첫 그랜트의 expires_in, admin GET 각본, 실패할 호출 앞의 성공 호출 수, 기대 그랜트
#: 순서, 실패의 HTTP 상태). expires_in 1 은 python-keycloak 이 `int(0.9 * 1)` = 0 초로 읽어 다음
#: 호출이 곧바로 갱신한다. 폴백은 python-keycloak 의 `except` 안에서 client_credentials 를 다시
#: 부르므로 마지막 실패는 그 401 이고, 그 `__context__` 가 refresh token 을 되울린 400 이다.
_LATER: dict[str, tuple[int, list[_Resp], int, list[str], int]] = {
    "만료 갱신": (1, [], 1, ["client_credentials", "refresh_token"], 400),
    "401 재시도": (
        300,
        [_json(401, {"error": "unauthorized"})],
        0,
        ["client_credentials", "refresh_token"],
        400,
    ),
    "Refresh token expired 폴백": (
        1,
        [],
        1,
        ["client_credentials", "refresh_token", "client_credentials"],
        401,
    ),
}


@pytest.mark.parametrize("path", list(_LATER))
@pytest.mark.parametrize("lane", LANES)
async def test_a_refused_later_grant_carries_no_echo_of_the_refresh_token(
    lane: str, path: str
) -> None:
    expires_in, statuses, ok_calls, grants, status = _LATER[path]
    with _fake_idp() as idp:
        if path == "Refresh token expired 폴백":
            refused = _echo_everything(400, "invalid_grant", "Refresh token expired ")
            idp.grants["client_credentials"] = [
                _good_grant(expires_in),
                _echo_everything(401, "invalid_client"),
            ]
        else:
            refused = _echo_everything(400, "invalid_grant")
            idp.grants["client_credentials"] = [_good_grant(expires_in)]
        idp.grants["refresh_token"] = [refused]
        idp.admin = list(statuses)
        async with _client(lane, idp) as client:
            for _ in range(ok_calls):
                result, err = await _attempt(lane, client, _admin_get)
                assert (result, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            result, err = await _attempt(lane, client, _admin_get)

    assert idp.grant_types() == grants, f"{path} 경로에 닿지 않았다 — 공허하다"
    assert idp.sent("refresh_token")[0] == [REFRESH], "refresh token 이 실리지 않았다 — 공허하다"
    assert result is None
    assert type(err) is KeycloakAdminError
    assert str(err) == f"Keycloak admin error (HTTP {status})"
    assert err.status_code == status
    assert _leaks(err, idp, ("client_secret", "refresh_token")) == []
    assert err.keycloak_error is None


# --- 대조군 — admin 리소스 오류는 본문을 예전 그대로 싣는다 ------------------------------------

#: 경우 → (admin GET 각본, 기대 타입, 상태, 기대 그랜트 순서). 401 은 python-keycloak 이
#: 갱신(성공)한 뒤 다시 보내고 그것도 401 이다 — 같은 `KeycloakAuthenticationError` 지만 그랜트
#: 실패가 아니다.
_RESOURCE: dict[str, tuple[list[_Resp], type[KeycloakAdminError], int, list[str]]] = {
    "404": (
        [_json(404, {"error": "User not found", "x": RESOURCE})],
        KeycloakNotFoundError,
        404,
        ["client_credentials"],
    ),
    "409": (
        [_json(409, {"errorMessage": RESOURCE})],
        KeycloakConflictError,
        409,
        ["client_credentials"],
    ),
    "403": (
        [_json(403, {"error": "forbidden", "x": RESOURCE})],
        KeycloakForbiddenError,
        403,
        ["client_credentials"],
    ),
    "401 (갱신은 성공)": (
        [
            _json(401, {"error": "first", "x": RESOURCE}),
            _json(401, {"error": "again", "x": RESOURCE}),
        ],
        KeycloakAdminError,
        401,
        ["client_credentials", "refresh_token"],
    ),
}


@pytest.mark.parametrize("case", list(_RESOURCE))
@pytest.mark.parametrize("lane", LANES)
async def test_a_failed_resource_call_keeps_its_body_in_keycloak_error(
    lane: str, case: str
) -> None:
    statuses, expected, status, grants = _RESOURCE[case]
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [_good_grant(300)]
        idp.grants["refresh_token"] = [_good_grant(300)]
        idp.admin = list(statuses)
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, _admin_get)

    assert idp.grant_types() == grants
    assert idp.admin_requests() == len(statuses)
    assert result is None
    assert type(err) is expected
    assert str(err) == f"Keycloak admin error (HTTP {status})"
    assert err.status_code == status
    # 예전 그대로 — 마지막 리소스 응답의 본문이 문자열로.
    assert err.keycloak_error == statuses[-1][2].decode()
