"""admin 레인 **자체** 토큰 그랜트의 `access_token` 이 쓸 수 없으면 admin REST 요청은 나가지 않고,
auth 레인과 **같은** SDK 예외로 실패한다(등록부 `python-admin-grant-accepts-empty-access-token`).

python-keycloak 의 토큰 세터는 `"Bearer " + value["access_token"]` 이 전부다 — 타입도 빈 값도 안
본다. 예전에는 sync 가 빈 문자열로 `Authorization: Bearer ` 를 실은 요청을 보냈고, aio 는 h11 이 그
헤더 값을 거부해 **우연히** 막혔지만 `KeycloakTransportError("Can't connect to server")` 였다.
없음·null·비문자열은 세터의 `KeyError`·`TypeError` 가 전송 오류로 옮겨졌다. auth 레인은 같은 응답을
`KeycloakAuthError` 로 거부한다.

기대 타입·메시지는 손으로 적지 않는다 — **같은 IdP·같은 응답**에서 auth 레인이 낸 것과 대조한다.
변형은 `test_tokens.py` 의 access_token 표(보안 기본값 가드 축 1c 의 앵커)를 그대로 읽는다.

토큰은 python-keycloak 의 네 갈래로 들어온다 — 첫 그랜트, 만료 갱신, 401 재시도, 그리고
`Refresh token expired` 폴백. 마지막은 python-keycloak 의 `except` **안에서** client_credentials 를
다시 부르므로, 거기서 난 거부의 `__context__` 는 그 400(응답 본문)이다. 넷 다 잰다. 거부는
python-keycloak 프레임 안에서 나므로 그 traceback 은 그랜트 응답·이전 refresh token 을 쥔 프레임을
지난다 — 경계가 그것을 버리는지도 `capture_locals` 로 잰다(`test_traceback_locals.py` 와 같은 렌더).
"""

from __future__ import annotations

import contextlib
import json
import threading
import traceback
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from unittest.mock import MagicMock
from urllib.parse import parse_qs, urlsplit

import pytest
from keycloak import KeycloakAdmin

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakConfigError
from keycloak_sdk.tokens import TokenSet

from . import test_tokens as tokens_tests

#: 경로마다 새 클라이언트(httpx.AsyncClient 셋)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

# --- 카나리아 ------------------------------------------------------------------------------

SECRET = "CS7q2w-admin-grant-client-secret"
ACCESS_OLD = "AO2v6b-access-from-the-last-good-grant"
REFRESH_OLD = "RO9p3x-refresh-from-the-last-good-grant"  # python-keycloak 의 갱신 프레임이 쥔다
REFRESH_NEW = "RN4k8m-refresh-in-the-refused-response"  # 거부된 응답 자체에 실린다
REFRESH_ERR = "RE5t1y-refresh-echoed-in-the-400-body"  # 폴백을 부른 400 의 본문
CANARIES = {
    "SECRET": SECRET,
    "ACCESS_OLD": ACCESS_OLD,
    "REFRESH_OLD": REFRESH_OLD,
    "REFRESH_NEW": REFRESH_NEW,
    "REFRESH_ERR": REFRESH_ERR,
}

_MISSING = object()


def _param_values(test: Callable[..., object]) -> list[object]:
    """`@pytest.mark.parametrize` 의 값 — 사본을 두지 않고 그 테스트의 표를 읽는다."""
    marks = [m for m in getattr(test, "pytestmark", []) if m.name == "parametrize"]
    assert marks, f"{test.__name__}: parametrize 표를 못 읽었다"
    return list(marks[0].args[1])


#: auth 레인이 거부하는 access_token 모양 전부 — `test_non_string_access_token_is_rejected` 의 표와
#: `test_missing_access_token_is_an_sdk_error` 의 「없음」.
_NON_STRING = _param_values(tokens_tests.test_non_string_access_token_is_rejected)
SHAPES: dict[str, object] = {**{json.dumps(v): v for v in _NON_STRING}, "missing": _MISSING}
assert len(SHAPES) == 6, f"access_token 표가 바뀌었다 — {sorted(SHAPES)}"

LANES = ("sync", "aio")


def _grant_body(access_token: object, *, expires_in: int, refresh_token: str) -> dict[str, object]:
    body: dict[str, object] = {
        "token_type": "Bearer",
        "expires_in": expires_in,
        "refresh_token": refresh_token,
    }
    if access_token is not _MISSING:
        body["access_token"] = access_token
    return body


def _auth_lane_verdict(body: dict[str, object]) -> tuple[type[BaseException], str]:
    """auth 레인의 파서가 같은 본문에 내는 판정 — `client_credentials_token`·`refresh` 가 이것을
    탄다."""
    try:
        TokenSet.from_response(body, issued_at=0.0)
    except Exception as exc:
        return type(exc), str(exc)
    raise AssertionError("auth 레인이 이 본문을 받아들였다 — 변형이 거부가 아니다")


# --- 각본대로 답하는 가짜 IdP ---------------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_USER = "/admin/realms/r/users/u1"
_Resp = tuple[int, dict[str, object]]


@dataclass(frozen=True)
class _Seen:
    method: str
    path: str
    grant: str
    authorization: str | None


@dataclass
class _Idp:
    """grant_type 마다 각본(차례대로 꺼내고 마지막 것은 남는다)과 admin GET 의 상태 각본."""

    url: str = ""
    grants: dict[str, list[_Resp]] = field(default_factory=dict)
    admin: list[int] = field(default_factory=list)
    seen: list[_Seen] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def answer(self, method: str, path: str, body: str, authorization: str | None) -> _Resp:
        with self.lock:
            grant = parse_qs(body).get("grant_type", [""])[0] if path == _TOKEN else ""
            self.seen.append(_Seen(method, path, grant, authorization))
            if path == _TOKEN:
                script = self.grants.get(grant) or [(400, {"error": "unsupported_grant_type"})]
                return script.pop(0) if len(script) > 1 else script[0]
            if path == _USER:
                status = self.admin.pop(0) if self.admin else 200
                return status, ({"id": "u1"} if status == 200 else {"error": "unauthorized"})
            return 404, {}

    def admin_requests(self) -> list[_Seen]:
        with self.lock:
            return [s for s in self.seen if s.path.startswith("/admin/")]

    def grant_types(self) -> list[str]:
        with self.lock:
            return [s.grant for s in self.seen if s.path == _TOKEN]

    def forget(self) -> None:
        with self.lock:
            self.seen.clear()


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            path = urlsplit(self.path).path
            status, obj = idp.answer(self.command, path, body, self.headers.get("Authorization"))
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
        server.shutdown()
        server.server_close()


@contextlib.asynccontextmanager
async def _client(lane: str, idp: _Idp) -> AsyncIterator[Any]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret=SECRET)
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            yield akc


async def _attempt(lane: str, client: Any, act: Callable[[Any], Any]) -> tuple[Any, Any]:
    """(결과, 오류) — 호출을 여기서 잡아 traceback 이 이 프레임에서 시작한다(하네스 로컬 제외)."""
    try:
        result = act(client)
        return (await result if lane == "aio" else result), None
    except Exception as exc:
        return None, exc


def _admin_get(client: Any) -> Any:
    return client.admin.users.get("u1")


# --- 판정 도우미 ---------------------------------------------------------------------------


def _chain(err: BaseException) -> list[BaseException]:
    """`__cause__`·`__context__` 로 닿는 예외 — 억제 여부와 무관하게(소비자가 속성으로 따라간다)."""
    seen: list[BaseException] = []
    todo = [err.__cause__, err.__context__]
    while todo:
        node = todo.pop()
        if node is None or any(node is s for s in seen):
            continue
        seen.append(node)
        todo += [node.__cause__, node.__context__]
    return seen


def _inner_frames(err: BaseException) -> list[str]:
    """traceback 이 지나는 python-keycloak 프레임 — 경계가 새로 던졌으면 하나도 없다."""
    out = []
    for frame, _line in traceback.walk_tb(err.__traceback__):
        module = str(frame.f_globals.get("__name__", ""))
        if module.partition(".")[0] == "keycloak":
            out.append(f"{module}.{frame.f_code.co_name}")
    return out


def _secrets_in_locals(err: BaseException) -> list[str]:
    """오류 수집기(Sentry Python 기본값)가 모으는 것 — 사슬까지, 프레임마다 로컬을 찍는다."""
    rendered = "".join(
        traceback.TracebackException.from_exception(err, capture_locals=True).format()
    )
    return [name for name, value in CANARIES.items() if value in rendered]


def _refused_like_the_auth_lane(
    err: BaseException | None, expected: tuple[type[BaseException], str]
) -> list[str]:
    problems = []
    if err is None:
        return ["거부하지 않았다"]
    if (type(err), str(err)) != expected:
        problems.append(
            f"auth 레인과 다르다: {type(err).__qualname__}({str(err)!r}) — "
            f"기대 {expected[0].__qualname__}({expected[1]!r})"
        )
    problems += [f"사슬에 {type(e).__module__}.{type(e).__qualname__}" for e in _chain(err)]
    problems += [f"traceback 이 {f} 프레임을 지난다" for f in _inner_frames(err)]
    problems += [f"프레임 로컬에 {name}" for name in _secrets_in_locals(err)]
    return problems


# --- 첫 그랜트 -----------------------------------------------------------------------------


@pytest.mark.parametrize("shape", list(SHAPES))
@pytest.mark.parametrize("lane", LANES)
async def test_unusable_access_token_in_the_first_grant_sends_no_admin_request(
    lane: str, shape: str
) -> None:
    body = _grant_body(SHAPES[shape], expires_in=300, refresh_token=REFRESH_NEW)
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, body)]
        async with _client(lane, idp) as client:
            # 대조 — 같은 IdP·같은 응답에서 auth 레인이 내는 것.
            _, auth_err = await _attempt(lane, client, lambda c: c.auth.client_credentials_token())
            idp.forget()
            result, err = await _attempt(lane, client, _admin_get)

    assert auth_err is not None, "auth 레인이 이 응답을 받아들였다 — 대조가 공허하다"
    assert (type(auth_err), str(auth_err)) == _auth_lane_verdict(body)
    assert result is None
    assert _refused_like_the_auth_lane(err, (type(auth_err), str(auth_err))) == []
    assert idp.grant_types() == ["client_credentials"], "admin 그랜트에 닿지 않았다 — 공허하다"
    assert idp.admin_requests() == [], "쓸 수 없는 토큰으로 admin 요청을 보냈다"


@pytest.mark.parametrize("lane", LANES)
async def test_a_usable_access_token_still_reaches_the_admin_api(lane: str) -> None:
    body = _grant_body(ACCESS_OLD, expires_in=300, refresh_token=REFRESH_OLD)
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, body)]
        async with _client(lane, idp) as client:
            result, err = await _attempt(lane, client, _admin_get)

    assert err is None
    assert result == {"id": "u1"}
    assert idp.admin_requests() == [_Seen("GET", _USER, "", f"Bearer {ACCESS_OLD}")]


# --- 나중 그랜트 — 만료 갱신 · 401 재시도 · `Refresh token expired` 폴백 ----------------------

#: 경로 → (첫 그랜트의 expires_in, admin GET 상태 각본, 실패할 호출 앞의 성공 호출 수,
#: 기대 그랜트 순서). expires_in 1 은 python-keycloak 이 `int(0.9 * 1)` = 0 초로 읽어 다음 호출이
#: 곧바로 갱신한다.
_LATER: dict[str, tuple[int, list[int], int, list[str]]] = {
    "만료 갱신": (1, [], 1, ["client_credentials", "refresh_token"]),
    "401 재시도": (300, [401], 0, ["client_credentials", "refresh_token"]),
    "Refresh token expired 폴백": (
        1,
        [],
        1,
        ["client_credentials", "refresh_token", "client_credentials"],
    ),
}


@pytest.mark.parametrize("bad", ["", None], ids=['""', "null"])
@pytest.mark.parametrize("path", list(_LATER))
@pytest.mark.parametrize("lane", LANES)
async def test_unusable_access_token_in_a_later_grant_is_refused_the_same_way(
    lane: str, path: str, bad: object
) -> None:
    expires_in, statuses, ok_calls, grants = _LATER[path]
    good = _grant_body(ACCESS_OLD, expires_in=expires_in, refresh_token=REFRESH_OLD)
    refused = _grant_body(bad, expires_in=300, refresh_token=REFRESH_NEW)
    with _fake_idp() as idp:
        if path == "Refresh token expired 폴백":
            expired = {
                "error": "invalid_grant",
                "error_description": f"Refresh token expired {REFRESH_ERR}",
            }
            idp.grants["client_credentials"] = [(200, good), (200, refused)]
            idp.grants["refresh_token"] = [(400, expired)]
        else:
            idp.grants["client_credentials"] = [(200, good)]
            idp.grants["refresh_token"] = [(200, refused)]
        idp.admin = list(statuses)
        async with _client(lane, idp) as client:
            for _ in range(ok_calls):
                result, err = await _attempt(lane, client, _admin_get)
                assert (result, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            result, err = await _attempt(lane, client, _admin_get)

    assert result is None
    assert _refused_like_the_auth_lane(err, _auth_lane_verdict(refused)) == []
    assert idp.grant_types() == grants, f"{path} 경로에 닿지 않았다 — 공허하다"
    # 요청은 첫 그랜트의 토큰으로 나간 것뿐이다 — 401 재시도는 다시 보내지 않는다.
    sent = [s.authorization for s in idp.admin_requests()]
    assert sent == [f"Bearer {ACCESS_OLD}"] * (ok_calls + len(statuses))


# --- 설치 — 주입된 admin 도 같고, 이음매가 없으면 만들지 않는다 ----------------------------------

_CONFIG = KeycloakConfig(
    server_url="https://kc.example.com", realm="r", client_id="c", client_secret=SECRET
)
_ADMIN_CLIENTS = {"sync": AdminClient, "aio": AsyncAdminClient}


@pytest.mark.parametrize("lane", LANES)
async def test_an_injected_admin_gets_the_grant_check_too(lane: str) -> None:
    """주입 경로가 생성 경로보다 느슨하면 주입으로 증명하는 테스트가 실제와 달라진다."""
    admin = MagicMock(spec=KeycloakAdmin)
    openid = admin.connection.keycloak_openid
    openid.token.return_value = {"access_token": ""}
    _ADMIN_CLIENTS[lane](_CONFIG, admin=admin)

    with pytest.raises(KeycloakAuthError):
        admin.connection.keycloak_openid.token()


@pytest.mark.parametrize("name", ["token", "refresh_token", "a_token", "a_refresh_token"])
@pytest.mark.parametrize("lane", LANES)
def test_construction_is_refused_when_a_grant_method_is_missing(lane: str, name: str) -> None:
    """python-keycloak 이 그랜트 자리를 옮기면 검사 없이 조용히 만들지 않는다(리다이렉트 하드닝과
    같다)."""
    admin = MagicMock(spec=KeycloakAdmin)
    delattr(admin.connection.keycloak_openid, name)

    # 이름만으로는 넷이 서로를 포함한다(`token` ⊂ `a_token`) — 빠진 바로 그 자리를 말해야 한다.
    with pytest.raises(KeycloakConfigError, match=rf"keycloak_openid\.{name}\b"):
        _ADMIN_CLIENTS[lane](_CONFIG, admin=admin)
