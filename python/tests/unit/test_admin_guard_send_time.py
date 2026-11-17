"""admin·auth 하드닝은 **보내는 순간에** 성립한다 — 무장한 때가 아니라(등록부
`python-admin-guard-send-time`).

`_internal/admin_guard.py` 의 검사는 `admin.connection` 을 읽을 때(무장)와 python-keycloak 의 갱신
자리(`_refresh_if_required`) 바로 뒤에 섰다. 그 둘과 실제 송신 사이에, 소비자가 **비공개 상태를
쓰지 않고** 닿는 틈이 있었다(수정 전 실측 — 이 파일을 수정 전 코드에서 돌렸다):

* (S1) 401 재시도 — python-keycloak 은 401 을 받으면 `refresh_token()` 뒤 갱신 자리를 거치지 않고
  같은 요청을 다시 보낸다(`KeycloakOpenIDConnection.raw_get`·`a_raw_get` 등). 첫 요청이 나가 있는
  동안 다른 호출자가 공개 토큰 세터로 실은 bearer 가 검사 없이 나갔다.
* (S2) 철자 — 검사는 `Authorization` 키와 `Bearer ` 접두를 글자 그대로 찾았다. 공개
  `add_param_headers` 로 실은 `bearer …`·`authorization: …`·토큰 없는 `Bearer` 는 검사 없이 나갔다.
* (S3) 보내는 헤더 — 나가는 것은 세션 기본값과 요청 헤더를 합친 것인데 검사는 연결의 헤더만 봤다.
  세션 객체를 고치는 것 자체는 지키는 범위 밖이다(sync 는 비공개 `_s`) — 송신 자리의 검사가 그것을
  함께 닫을 뿐이고, 이 파일의 S3 시험은 그 이음매의 계약(합친 헤더)을 고정한다.
* (S4) 그랜트 객체의 연결 — `KeycloakOpenID.connection` 은 공개 세터다. 그것으로 끼운 연결은 다음
  `admin.connection` 읽기 전까지 훅이 없어, 그 사이의 그랜트(쥔 그랜트 객체로 직접 · 다른 호출자가
  바꾼 뒤의 401 재시도)가 상한 없이 읽고 sync 는 307 을 따라가 client_secret 을 넘겼다.
* (S5) auth 레인 — 주입한 `KeycloakOpenID` 의 연결을 공개 세터로 바꾸면 하드닝 없는 세션으로
  나갔다(sync 는 307 을 따라가 client_secret 을 넘기고 JWKS 도 거기서 받았다).

순서는 이벤트로 강제한다 — 잠들지 않는다. 가짜 IdP 가 첫 admin 요청을 붙잡고(도착을 알린 뒤 풀릴
때까지 답하지 않는다) 그동안 다른 호출자가 공개 API 를 부른다.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import threading
import traceback
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest
from keycloak import KeycloakAdmin, KeycloakOpenID
from keycloak.connection import ConnectionManager
from keycloak.exceptions import KeycloakConnectionError, KeycloakPostError

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.openid_watch import HARDENERS
from keycloak_sdk._internal.token_cap import ResponseRefused
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakConfigError, KeycloakTransportError
from keycloak_sdk.oidc import OidcEndpoints
from tests.unit.conftest import CLIENT_SECRET, Trap

pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")
SECRET = "CS3n8v-send-time-client-secret"
GOOD = "GD5k2w-good-access-token"
REFRESH = "RF7p4q-refresh-from-the-good-grant"
CAP = 1_048_576
_RULE = "after trimming SP, HTAB, CR and LF it must be a non-empty RFC 6750 b64token"
_SEND = f"admin request not sent: the access token is not a bearer token ({_RULE})"
#: 빈 토큰은 그 전에 쓸 수 없는 토큰이다(`tokens._usable_access_token` — 오늘의 메시지 그대로).
_EMPTY = "token response has no usable access_token"
_TOO_BIG = f"token response exceeds {CAP} bytes"
_ADMIN_CLIENTS: dict[str, Any] = {"sync": AdminClient, "aio": AsyncAdminClient}

# --- 첫 admin 요청을 붙잡는 가짜 IdP ------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_USER = "/admin/realms/r/users/u1"
_Resp = tuple[int, dict[str, object]]


@dataclass(frozen=True)
class _Sent:
    path: str
    grant: str
    authorization: tuple[str, ...]  # 그 요청이 실은 Authorization 줄 전부(받은 그대로)


class _Gate:
    """첫 admin 요청을 붙잡는다 — 도착을 알리고(`arrived`) 풀릴 때까지 답하지 않는다."""

    def __init__(self, arrived: Callable[[], None]) -> None:
        self.arrived = arrived
        self.released = threading.Event()

    def hold(self) -> None:
        self.arrived()
        # 순서는 이벤트가 정한다 — 이 상한은 시험이 깨졌을 때 처리기를 놓아 주는 교착 방지일 뿐이다.
        self.released.wait(30)


@dataclass
class _Idp:
    """grant_type 마다 각본(차례대로 꺼내고 마지막 것은 남는다)과 admin GET 의 상태 각본."""

    url: str = ""
    grants: dict[str, list[_Resp]] = field(default_factory=dict)
    admin: list[int] = field(default_factory=list)
    gate: _Gate | None = None
    seen: list[_Sent] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def record(self, path: str, body: str, authorization: tuple[str, ...]) -> tuple[str, bool]:
        """(grant_type, 붙잡을까) — 붙잡는 것은 첫 admin 요청 하나다."""
        with self.lock:
            grant = parse_qs(body).get("grant_type", [""])[0] if path == _TOKEN else ""
            self.seen.append(_Sent(path, grant, authorization))
            first = path == _USER and sum(s.path == _USER for s in self.seen) == 1
            return grant, first and self.gate is not None

    def respond(self, path: str, grant: str) -> _Resp:
        with self.lock:
            if path == _TOKEN:
                script = self.grants.get(grant) or [(400, {"error": "unsupported_grant_type"})]
                return script.pop(0) if len(script) > 1 else script[0]
            if path == _USER:
                status = self.admin.pop(0) if self.admin else 200
                return status, ({"id": "u1"} if status == 200 else {"error": "unauthorized"})
            return 404, {}

    def admin_requests(self) -> list[_Sent]:
        with self.lock:
            return [s for s in self.seen if s.path.startswith("/admin/")]


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            path = urlsplit(self.path).path
            sent = tuple(self.headers.get_all("Authorization") or ())
            grant, hold = idp.record(path, body, sent)
            if hold and idp.gate is not None:
                idp.gate.hold()
            status, obj = idp.respond(path, grant)
            payload = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
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
        if idp.gate is not None:
            idp.gate.released.set()  # 붙잡힌 처리기를 놓아 서버가 닫히게 한다
        server.shutdown()
        server.server_close()


def _grant(access_token: str) -> _Resp:
    return 200, {
        "access_token": access_token,
        "expires_in": 300,
        "refresh_token": REFRESH,
        "token_type": "Bearer",
    }


def _cfg(url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret=SECRET, read_timeout=10.0
    )


@contextlib.asynccontextmanager
async def _sdk(lane: str, url: str) -> AsyncIterator[Any]:
    if lane == "sync":
        with KeycloakClient.create(_cfg(url)) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(_cfg(url)) as akc:
            yield akc


async def _attempt(lane: str, act: Callable[[], Any]) -> tuple[Any, BaseException | None]:
    """(결과, 오류) — 호출을 여기서 잡는다."""
    try:
        result = act()
        return (await result if lane == "aio" else result), None
    except Exception as exc:
        return None, exc


async def _while_held(
    lane: str, idp: _Idp, act: Callable[[], Any], meanwhile: Callable[[], None]
) -> tuple[Any, BaseException | None]:
    """`act` 의 첫 admin 요청이 IdP 에 닿아 붙잡힌 동안 `meanwhile`(다른 호출자)을 부르고, 놓아 준
    뒤 `act` 의 (결과, 오류). sync 는 `act` 를 다른 스레드에서, aio 는 다른 태스크에서 돈다."""
    if lane == "sync":
        arrived = threading.Event()
        gate = idp.gate = _Gate(arrived.set)
        out: list[tuple[Any, BaseException | None]] = []

        def run() -> None:
            try:
                out.append((act(), None))
            except Exception as exc:
                out.append((None, exc))

        worker = threading.Thread(target=run)
        worker.start()
        try:
            assert arrived.wait(30), "첫 admin 요청이 IdP 에 닿지 않았다"
            meanwhile()
        finally:
            gate.released.set()
            worker.join(30)
        return out[0]
    loop = asyncio.get_running_loop()
    landed = asyncio.Event()
    gate = idp.gate = _Gate(lambda: loop.call_soon_threadsafe(landed.set))
    task = asyncio.ensure_future(_attempt("aio", act))
    try:
        await asyncio.wait_for(landed.wait(), 30)
        meanwhile()
    finally:
        gate.released.set()
    return await task


async def _close(lane: str, client: Any) -> None:
    if lane == "aio":
        await client.aclose()
    else:
        client.close()


async def _close_connection(lane: str, conn: Any) -> None:
    """갈아 끼워져 SDK 의 정리에서 빠진 옛 연결 — 시험이 직접 닫는다."""
    if lane == "aio":
        await conn.aclose()
    conn._s.close()


def _raw_get(lane: str, raw: Any) -> Callable[[], Any]:
    return (lambda: raw.get_user("u1")) if lane == "sync" else (lambda: raw.a_get_user("u1"))


def _inner_frames(err: BaseException) -> list[str]:
    """traceback 이 지나는 python-keycloak 프레임 — 경계가 새로 던졌으면 하나도 없다."""
    return [
        f"{frame.f_globals.get('__name__')}.{frame.f_code.co_name}"
        for frame, _line in traceback.walk_tb(err.__traceback__)
        if str(frame.f_globals.get("__name__", "")).partition(".")[0] == "keycloak"
    ]


def _refused(err: BaseException | None, message: str, *, route: str) -> list[str]:
    """`message` 의 거부인가 — 경로마다 오늘의 모양 그대로.

    * `facade` — 경계를 지난 `KeycloakAuthError`, 사슬·하위 프레임 없음(오늘의 bearer 거부와 같다).
    * `raw` — 탈출구는 python-keycloak 을 그대로 지난다(§4(b)). 송신 **전**에 거부되면
      `KeycloakAuthError` 그대로다.
    * `raw-sent` — 송신 **자리**(세션)에서 거부되면 python-keycloak 의 `raw_*` 가 그 거부를
      `KeycloakConnectionError` 의 원인으로 감싼다 — 그랜트 응답 상한(`ResponseRefused`)과 같은 길.
    """
    if err is None:
        return ["거부하지 않았다"]
    shown = f"{type(err).__module__}.{type(err).__qualname__}({str(err)!r})"
    if route == "raw-sent":
        cause = err.__cause__
        if type(err) is not KeycloakConnectionError or type(cause) is not KeycloakAuthError:
            return [f"{shown} ← {cause!r}"]
        return [] if str(cause) == message else [f"원인 {str(cause)!r}"]
    problems = [] if (type(err), str(err)) == (KeycloakAuthError, message) else [shown]
    if route == "facade":
        if err.__cause__ is not None or err.__context__ is not None:
            problems.append(f"사슬 {err.__cause__!r} / {err.__context__!r}")
        problems += [f"traceback 이 {f} 프레임을 지난다" for f in _inner_frames(err)]
    return problems


def _first_only() -> list[_Sent]:
    return [_Sent(_USER, "", (f"Bearer {GOOD}",))]


# --- (S1) 401 재시도 — 첫 요청이 나가 있는 동안 다른 호출자가 실은 bearer ----------------------

#: 다른 호출자가 공개 토큰 세터로 싣는 토큰 — 빈 것(등록부의 `'Bearer '`)과, h11 도 싣는 규칙 밖의
#: 것(가운데 `=`). aio 의 빈 것은 수정 전에도 나가지 않았다 — h11 이 그 헤더를 거부해
#: `KeycloakTransportError`(「Can't connect to server」)였다.
_LATER_TOKENS = {"empty": ("", _EMPTY), "mid-pad": ("a=bc", _SEND)}


@pytest.mark.parametrize("token", list(_LATER_TOKENS))
@pytest.mark.parametrize("route", ["facade", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_401_retry_does_not_resend_a_bearer_set_while_the_first_request_was_out(
    lane: str, route: str, token: str
) -> None:
    """python-keycloak 의 재시도는 갱신 자리를 거치지 않는다 — 그 사이 다른 호출자가 공개 세터로
    실은 토큰은 보내는 자리에서 거부된다. 토큰만 받은 admin 은 재시도에서 그랜트하지 않고 헤더를
    그대로 다시 보낸다(`refresh_token` → `get_token` → `token = None`)."""
    value, message = _LATER_TOKENS[token]
    with _fake_idp() as idp:
        idp.admin = [401]
        admin = KeycloakAdmin(
            server_url=idp.url, realm_name="r", token={"access_token": GOOD, "expires_in": 300}
        )
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        act = (lambda: client.users.get("u1")) if route == "facade" else _raw_get(lane, admin)

        def meanwhile() -> None:
            admin.connection.token = {"access_token": value, "expires_in": 300}  # 공개 세터

        result, err = await _while_held(lane, idp, act, meanwhile)
        await _close(lane, client)

    assert result is None
    assert _refused(err, message, route="facade" if route == "facade" else "raw-sent") == []
    assert idp.admin_requests() == _first_only(), "재시도가 검사 없이 나갔다"


# --- (S2) 철자 — 이름과 scheme 은 대소문자를 가리지 않는다 -----------------------------------

#: id → (공개 `add_param_headers` 로 싣는 이름, 값, 거부 메시지). bytes 값은 requests·httpx 가
#: 그대로 싣는다 — 검사도 latin-1 로 읽는다.
_SPELLINGS: dict[str, tuple[str, str | bytes, str]] = {
    "scheme in lower case": ("Authorization", "bearer a=bc", _SEND),
    "name in lower case": ("authorization", "Bearer a=bc", _SEND),
    "both in upper case": ("AUTHORIZATION", "BEARER a=bc", _SEND),
    "tab after the scheme": ("Authorization", "Bearer\ta=bc", _SEND),
    "scheme without a token": ("Authorization", "Bearer", _EMPTY),
    "bytes value": ("Authorization", b"Bearer a=bc", _SEND),
}


@pytest.mark.parametrize("spelling", list(_SPELLINGS))
@pytest.mark.parametrize("route", ["facade", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_is_recognised_whatever_its_spelling(
    lane: str, route: str, spelling: str
) -> None:
    """RFC 7235 §2.1 — scheme 은 대소문자를 가리지 않고 헤더 이름도 그렇다. 연결의 헤더에 실린
    bearer 는 철자와 무관하게 **보내기 전에** 거부된다(raw 도 오늘의 타입 그대로)."""
    name, value, message = _SPELLINGS[spelling]
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [_grant(GOOD)]
        async with _sdk(lane, idp.url) as kc:
            first = await _attempt(lane, lambda: kc.admin.users.get("u1"))
            assert first == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            raw = kc.admin.raw
            raw.connection.add_param_headers(name, value)  # 공개 메서드
            act = (lambda: kc.admin.users.get("u1")) if route == "facade" else _raw_get(lane, raw)
            result, err = await _attempt(lane, act)

    assert result is None
    assert _refused(err, message, route=route) == []
    assert idp.admin_requests() == _first_only(), "규칙 밖의 bearer 가 나갔다"


#: id → (이름, 값, 서버가 받을 Authorization) — 규칙에 맞으면 철자는 그대로 두고 토큰만 다듬는다.
_SENDABLE: dict[str, tuple[str, str, str]] = {
    "scheme in lower case": ("Authorization", f"bearer {GOOD}", f"bearer {GOOD}"),
    "trailing HTAB": ("Authorization", f"BEARER {GOOD}\t", f"BEARER {GOOD}"),
}


@pytest.mark.parametrize("spelling", list(_SENDABLE))
@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_the_rule_lets_out_is_sent_in_any_spelling(lane: str, spelling: str) -> None:
    """지나치게 거부하지 않는다는 경계 — 규칙에 맞는 토큰은 철자와 무관하게 나가고, 다듬을 것은
    다듬어 나간다(수정 전 aio 는 끝 HTAB 을 h11 이 거부해 전송 오류였다)."""
    name, value, received = _SENDABLE[spelling]
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [_grant(GOOD)]
        async with _sdk(lane, idp.url) as kc:
            first = await _attempt(lane, lambda: kc.admin.users.get("u1"))
            assert first == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            kc.admin.raw.connection.add_param_headers(name, value)
            result, err = await _attempt(lane, lambda: kc.admin.users.get("u1"))

    assert (result, err) == ({"id": "u1"}, None)
    assert idp.admin_requests() == [*_first_only(), _Sent(_USER, "", (received,))]


# --- (S3) 보내는 헤더 그대로 — 세션의 기본 헤더도 합쳐 본다 ------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_the_bearer_is_judged_on_the_headers_the_request_carries(lane: str) -> None:
    """나가는 것은 HTTP 클라이언트의 기본 헤더와 요청 헤더를 합친 것이다 — 검사도 그것을 본다.
    연결의 헤더에 bearer 가 없는(자격증명도 토큰도 없는) admin 이라야 기본값이 실린다.

    ⚠️ 이 시험은 이음매의 계약(합친 헤더)을 고정한다 — 세션 객체를 고치는 것 자체는 지키는 범위
    밖이다(`_internal/admin_guard.py` 머리 주석). 같은 자리가 함께 닫을 뿐이다."""
    with _fake_idp() as idp:
        admin = KeycloakAdmin(server_url=idp.url, realm_name="r")
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        session = admin.connection._s if lane == "sync" else admin.connection.async_s
        session.headers["Authorization"] = "Bearer a=bc"
        result, err = await _attempt(lane, lambda: client.users.get("u1"))
        await _close(lane, client)

    assert result is None
    assert _refused(err, _SEND, route="facade") == []
    assert idp.admin_requests() == [], "기본 헤더의 bearer 가 검사 없이 나갔다"


@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_reaching_the_send_only_now_is_trimmed_there(lane: str) -> None:
    """송신 자리도 규칙대로 다듬어 싣는다 — 연결의 헤더를 거치지 않은 bearer 라도(수정 전 aio 는
    끝 HTAB 을 h11 이 거부해 전송 오류였고, sync 는 그대로 보냈다)."""
    with _fake_idp() as idp:
        admin = KeycloakAdmin(server_url=idp.url, realm_name="r")
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        session = admin.connection._s if lane == "sync" else admin.connection.async_s
        session.headers["Authorization"] = f"Bearer {GOOD}\t"
        result, err = await _attempt(lane, lambda: client.users.get("u1"))
        await _close(lane, client)

    assert (result, err) == ({"id": "u1"}, None)
    assert idp.admin_requests() == _first_only()


@pytest.mark.parametrize("where", ["connection", "session"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_authorization_that_is_not_a_bearer_is_left_to_the_server(
    lane: str, where: str
) -> None:
    """검사는 **bearer** 자격증명만 본다 — 다른 scheme 은 그대로 나가고 판정은 서버가 한다(지나치게
    거부하지 않는다는 경계)."""
    with _fake_idp() as idp:
        admin = KeycloakAdmin(server_url=idp.url, realm_name="r")
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        if where == "connection":
            admin.connection.add_param_headers("Authorization", "Basic YTpi")
        else:
            session = admin.connection._s if lane == "sync" else admin.connection.async_s
            session.headers["Authorization"] = "Bearerish a=bc"
        result, err = await _attempt(lane, lambda: client.users.get("u1"))
        await _close(lane, client)

    sent = "Basic YTpi" if where == "connection" else "Bearerish a=bc"
    assert (result, err) == ({"id": "u1"}, None)
    assert idp.admin_requests() == [_Sent(_USER, "", (sent,))]


# --- (S4) 그랜트 객체의 연결 — 공개 세터로 끼운 연결 ------------------------------------------


def _grant_call(lane: str, openid: Any) -> Callable[[], Any]:
    if lane == "sync":
        return lambda: openid.token(grant_type="client_credentials")
    return lambda: openid.a_token(grant_type="client_credentials")


def _oversized(token_idp: Any) -> None:
    head = {"access_token": "J" * 40, "token_type": "Bearer", "expires_in": 300}
    token_idp.head, token_idp.size = json.dumps(head).encode(), CAP + 1


@pytest.mark.parametrize("lane", LANES)
async def test_a_grant_object_handed_a_new_connection_caps_the_grant_sent_through_it(
    lane: str, token_idp: Any
) -> None:
    """쥔 그랜트 객체(`raw.connection.keycloak_openid`)에 공개 세터로 끼운 연결 — 그것으로 나가는
    그랜트의 응답도 상한까지만 읽는다. 수정 전: 다음 `admin.connection` 읽기 전이라 훅이 없어
    1 MiB 를 넘는 응답을 받아들였다."""
    _oversized(token_idp)
    async with _sdk(lane, token_idp.url) as kc:
        nested = kc.admin.raw.connection.keycloak_openid
        old = nested.connection
        nested.connection = ConnectionManager(base_url=token_idp.url)  # 공개 세터
        result, err = await _attempt(lane, _grant_call(lane, nested))
        await _close_connection(lane, old)

    assert result is None
    signal = err.__cause__ if err is not None else None
    assert type(err) is KeycloakConnectionError and type(signal) is ResponseRefused, repr(err)
    assert str(signal) == _TOO_BIG
    assert token_idp.hits == [_TOKEN], "갈아 끼운 연결의 그랜트에 닿지 않았다 — 공허하다"


def _trap_cfg(trap: Trap) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=trap.idp_url,
        realm="t",
        client_id="app",
        client_secret=CLIENT_SECRET,
        read_timeout=5.0,
    )


def _trap_openid(trap: Trap) -> KeycloakOpenID:
    return KeycloakOpenID(
        server_url=trap.idp_url,
        realm_name="t",
        client_id="app",
        client_secret_key=CLIENT_SECRET,
        timeout=5,
    )


def test_a_grant_object_handed_a_new_connection_does_not_follow_a_redirect(trap: Trap) -> None:
    """대조군을 같은 시험에 둔다 — 하드닝 없는 그랜트 객체에 같은 연결을 끼우면 307 을 따라가
    client_secret 을 넘긴다. SDK 의 그랜트 객체는 끼우는 순간 하드닝한다."""
    stock = _trap_openid(trap)
    stock.connection = ConnectionManager(base_url=trap.idp_url, timeout=5)
    try:
        stock.token(grant_type="client_credentials")
    finally:
        stock.connection._s.close()
    assert len(trap.hits) == 1 and CLIENT_SECRET in trap.hits[0].body, "대조군 덫이 무장되지 않았다"
    trap.reset()

    client = AdminClient(_trap_cfg(trap))
    nested = client.raw.connection.keycloak_openid
    old = nested.connection
    nested.connection = ConnectionManager(base_url=trap.idp_url, timeout=5)  # 공개 세터
    try:
        with pytest.raises(KeycloakPostError) as excinfo:  # 탈출구 — python-keycloak 의 오류다
            nested.token(grant_type="client_credentials")
    finally:
        client.close()
        old._s.close()

    assert trap.hits == [], "끼운 연결이 리다이렉트를 따라가 client_secret 을 넘겼다"
    assert excinfo.value.response_code == 307


@pytest.mark.parametrize("lane", LANES)
async def test_a_grant_connection_replaced_while_a_request_is_out_is_hardened_before_the_retry(
    lane: str, token_idp: Any
) -> None:
    """등록부의 「401 재시도 중 그랜트 객체 교체」를 공개 세터로 — 첫 admin 요청이 나가 있는 동안
    다른 호출자가 그랜트 객체의 연결을 바꾸면, 401 재시도의 그랜트는 그 연결로 나간다. 수정 전:
    `admin.connection` 을 다시 읽지 않는 길이라 훅이 없어 상한 너머 응답을 받고 그 토큰으로 다시
    보냈다."""
    _oversized(token_idp)
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [_grant(GOOD)]
        idp.admin = [401]
        async with _sdk(lane, idp.url) as kc:
            raw = kc.admin.raw
            old = raw.connection.keycloak_openid.connection

            def meanwhile() -> None:
                fresh = ConnectionManager(base_url=token_idp.url)
                raw.connection.keycloak_openid.connection = fresh  # 공개 세터 — 다른 호출자

            result, err = await _while_held(lane, idp, lambda: kc.admin.users.get("u1"), meanwhile)
            await _close_connection(lane, old)

    assert result is None
    assert (type(err), str(err)) == (KeycloakTransportError, _TOO_BIG)
    assert idp.admin_requests() == _first_only(), "상한 너머 그랜트의 토큰으로 다시 보냈다"
    assert token_idp.hits == [_TOKEN], "재시도의 그랜트가 바꾼 연결에 닿지 않았다 — 공허하다"


# --- (S5) auth 레인 — 주입한 KeycloakOpenID 의 연결 -----------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_an_injected_openid_handed_a_new_connection_caps_the_auth_back_channel(
    lane: str, token_idp: Any
) -> None:
    _oversized(token_idp)
    cfg = _cfg(token_idp.url)
    openid = KeycloakOpenID(
        server_url=token_idp.url, realm_name="r", client_id="c", client_secret_key=SECRET
    )
    endpoints = OidcEndpoints.for_realm(cfg)
    auth: Any = (AuthClient if lane == "sync" else AsyncAuthClient)(cfg, endpoints, openid=openid)
    old = openid.connection
    openid.connection = ConnectionManager(base_url=token_idp.url)  # 공개 세터 — 주입한 객체
    result, err = await _attempt(lane, auth.client_credentials_token)
    await _close(lane, auth)
    await _close_connection(lane, old)

    assert result is None
    assert (type(err), str(err)) == (KeycloakTransportError, _TOO_BIG)
    assert token_idp.hits == [_TOKEN]


@pytest.mark.parametrize("operation", ["client_credentials_token", "jwks_load"])
def test_an_injected_openid_handed_a_new_connection_still_refuses_redirects(
    trap: Trap, operation: str
) -> None:
    """대조군은 위 그랜트 객체 시험과 같다(하드닝 없는 객체 + 같은 연결은 따라간다). JWKS 는 상류를
    우회한 직접 GET 이라 3xx 가 `KeycloakTransportError` 다(`test_redirects.py` 와 같다)."""
    stock = _trap_openid(trap)
    stock.connection = ConnectionManager(base_url=trap.idp_url, timeout=5)
    try:
        stock.token(grant_type="client_credentials")
    finally:
        stock.connection._s.close()
    assert len(trap.hits) == 1, "대조군 덫이 무장되지 않았다"
    trap.reset()

    cfg = _trap_cfg(trap)
    openid = _trap_openid(trap)
    auth = AuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)
    old = openid.connection
    openid.connection = ConnectionManager(base_url=trap.idp_url, timeout=5)  # 공개 세터
    grant = operation == "client_credentials_token"
    expected = KeycloakAuthError if grant else KeycloakTransportError
    try:
        with pytest.raises(expected) as excinfo:
            if grant:
                auth.client_credentials_token()
            else:
                auth.validate("not.a.real.token")
    finally:
        auth.close()
        old._s.close()

    assert trap.hits == [], f"{operation}: 끼운 연결이 리다이렉트를 따라갔다"
    assert "307" in str(excinfo.value)


# --- 감시를 걸 수 없는 그랜트 객체는 손대지 않고 거부한다 ---------------------------------------
#
# 공개 세터를 지켜볼 수 없으면 그 객체로는 끼운 연결을 무장할 수 없다 — 조용히 넘어가지 않는다
# (`admin_guard` 의 감시할 수 없는 admin 과 같은 규칙). admin 은 전부이거나 아무것도 안에서, auth 는
# 생성에서 거부한다.


class _GrantConnectionNotSettable(KeycloakOpenID):
    """`connection` 을 평범한 클래스 속성으로 가린다 — 세터가 없으니 끼우기를 볼 자리가 없다."""

    connection = None  # type: ignore[assignment]


class _FinalGrant(KeycloakOpenID):
    """하위 클래스를 막는다 — 감시 클래스를 만들 수 없다."""

    def __init_subclass__(cls, **kwargs: Any) -> None:
        raise TypeError("this grant object class is final")


class _GrantRefusesItsClass(KeycloakOpenID):
    def __setattr__(self, name: str, value: Any) -> None:
        if name == "__class__":
            raise TypeError("this grant object keeps its class")
        super().__setattr__(name, value)


class _GrantKeepsItsClass(KeycloakOpenID):
    """`__class__` 쓰기를 조용히 버린다 — 바꿨다고 믿으면 감시 없는 세터가 남는다."""

    def __setattr__(self, name: str, value: Any) -> None:
        if name != "__class__":
            super().__setattr__(name, value)


_NOT_SETTABLE = r"_GrantConnectionNotSettable\.connection is not a property with a setter"
#: id → (그랜트 객체의 클래스, admin 의 거부 메시지, auth 의 거부 메시지).
_UNWATCHABLE: dict[str, tuple[type[KeycloakOpenID], str, str]] = {
    "connection without a setter": (
        _GrantConnectionNotSettable,
        rf"admin token grant: {_NOT_SETTABLE}",
        rf"auth back-channel: {_NOT_SETTABLE}",
    ),
    "final class": (
        _FinalGrant,
        r"admin token grant: subclassing _FinalGrant failed \(TypeError\)",
        r"auth back-channel: subclassing _FinalGrant failed \(TypeError\)",
    ),
    "refuses its class": (
        _GrantRefusesItsClass,
        r"hook at connection\.keycloak_openid failed \(TypeError\)",
        r"replacing the class of _GrantRefusesItsClass failed \(TypeError\)",
    ),
    "drops its class": (
        _GrantKeepsItsClass,
        r"hook at connection\.keycloak_openid failed \(AttributeError\)",
        r"_GrantKeepsItsClass did not keep its replaced class",
    ),
}
_SDK_HOOKS = ("token", "refresh_token", "a_token", "a_refresh_token", HARDENERS)


def _grant_object(cls: type[KeycloakOpenID]) -> KeycloakOpenID:
    url = "http://127.0.0.1:9"
    return cls(server_url=url, realm_name="r", client_id="c", client_secret_key=SECRET)


@pytest.mark.parametrize("kind", list(_UNWATCHABLE))
@pytest.mark.parametrize("lane", LANES)
def test_an_admin_whose_grant_object_cannot_be_watched_is_refused_untouched(
    lane: str, kind: str
) -> None:
    cls, admin_refusal, _auth_refusal = _UNWATCHABLE[kind]
    admin = KeycloakAdmin(
        server_url="http://127.0.0.1:9",
        realm_name="r",
        client_id="c",
        client_secret_key=SECRET,
        grant_type="client_credentials",
    )
    nested = _grant_object(cls)
    admin.connection._keycloak_openid = nested  # 시험 수단 — 그런 그랜트 객체를 심는다

    with pytest.raises(KeycloakConfigError, match=admin_refusal):
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=admin)

    assert type(nested) is cls and type(admin) is KeycloakAdmin
    assert [name for name in _SDK_HOOKS if name in vars(nested)] == []
    assert "send" not in vars(nested.connection._s), "거부한 설치가 그랜트 세션에 훅을 남겼다"


def test_public_realm_and_client_setters_keep_the_armed_grant_objects() -> None:
    """python-keycloak 자신의 동작(지키는 범위) — realm·client 의 공개 세터는 그랜트 객체·그
    연결·세션을 다시 만들지 않는다(7.1.1: 그랜트 객체를 만드는 곳은
    `KeycloakOpenIDConnection.keycloak_openid` 의 첫 읽기 하나, 연결은 `KeycloakOpenID.__init__`,
    세션은 `ConnectionManager.__init__` 뿐이다). 다시 만들게 바뀌면 쥔 연결의 그랜트가 무장 안 된
    객체로 나갈 수 있다 — 이 시험이 먼저 운다."""
    client = AdminClient(_cfg("http://127.0.0.1:9"))
    raw = client.raw
    conn = raw.connection
    nested = conn.keycloak_openid
    grant = nested.connection
    before = (nested, grant, conn._s, conn.async_s, grant._s, grant.async_s)

    raw.change_current_realm("other")
    conn.realm_name, conn.user_realm_name, conn.server_url = "other", "users", "http://127.0.0.1:8"
    conn.client_id, conn.client_secret_key = "c2", "s2"
    nested.realm_name, nested.client_id, nested.client_secret_key = "other", "c2", "s2"

    after = (conn.keycloak_openid, nested.connection, conn._s, conn.async_s)
    after += (grant._s, grant.async_s)
    assert all(a is b for a, b in zip(after, before, strict=True)), "다시 만들었다"
    assert vars(nested)[HARDENERS] and type(nested) is not KeycloakOpenID, "그랜트 객체 감시가 없다"
    client.close()


@pytest.mark.parametrize("kind", list(_UNWATCHABLE))
def test_an_injected_openid_that_cannot_be_watched_is_refused(kind: str) -> None:
    cls, _admin_refusal, auth_refusal = _UNWATCHABLE[kind]
    cfg = _cfg("http://127.0.0.1:9")
    openid = _grant_object(cls)

    with pytest.raises(KeycloakConfigError, match=auth_refusal):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)

    assert type(openid) is cls
    assert HARDENERS not in vars(openid)
    openid.connection._s.close()
