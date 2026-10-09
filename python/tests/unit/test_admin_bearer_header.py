"""admin 이 보낼 bearer 를 HTTP 헤더가 실을 수 없으면 요청 없이 SDK 오류로 거부한다(등록부
`wave4-hardening-python` (2)(3)).

수정 전 실측(origin/main 80547df · python-keycloak 7.1.1 · requests 2.34.2 · urllib3 2.7.0 ·
httpx 0.28.1 · h11 0.16.0 · 공개 API · 받은 바이트를 남기는 날 소켓 IdP):

* (2) 실을 수 없는 토큰은 요청 없이 `KeycloakTransportError("Can't connect to server")` 였다 —
  sync 는 CR·LF·U+00FF 위(짝 없는 서로게이트 포함), aio 는 거기에 NUL·VT·FF·U+0080 부터 U+00FF·끝
  SP/HTAB. python-keycloak 의 `raw_*` 가 세션 안의 예외를 전부 `KeycloakConnectionError` 로 감싼다.
* (3) 전송이 거르지 않는 제어 문자는 그대로 나갔다 — sync 는 NUL·SOH·BS·VT·FF·US·DEL, aio 는
  SOH·BS·US·DEL(서버가 받은 `Bearer tok\\x00en…` 등). 토큰이 그랜트에서 왔든 주입됐든 같았다.

**기대 집합을 손으로 적지 않는다.** RFC 9110 §5.5 가 필드 값에서 빼는 것(HTAB 밖의 C0 제어 문자와
DEL)은 이 시험이 RFC 에서 따로 쓰고(`_rfc9110_excludes`), 나머지는 **전송에 묻는다** —
python-keycloak 의 `ConnectionManager` 로 같은 헤더를 실제로 보내 본다(`_Oracle`). 전송이 바이트
그대로 싣는 것(HTAB·SP, sync 의 U+0080 부터 U+00FF·끝 SP/HTAB)은 거부하지 않는다 — 판정은
서버다(언어 횡단 판정 `bearer-token-grammar-divergent`).

토큰은 두 자리로 들어온다 — SDK 자신의 그랜트(첫 그랜트·만료 갱신·401 재시도·`Refresh token expired`
폴백)와, 그랜트를 거치지 않고 실린 bearer(주입된 admin·토큰 세터·한 레인이 받은 토큰을 다른 레인으로
보내는 `raw`). 앞의 것은 **받을 때** 거부해 캐시되지 않는지, 뒤의 것은 보내기 전에 거부하는지 잰다.
"""

from __future__ import annotations

import contextlib
import json
import socket
import threading
import traceback
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest
from keycloak import KeycloakAdmin
from keycloak.connection import ConnectionManager
from keycloak.exceptions import KeycloakConnectionError

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError

from .test_admin_grant import LANES, SECRET, _attempt, _chain, _client, _inner_frames

pytestmark = pytest.mark.usefixtures("fast_tls")

# --- 계약 ---------------------------------------------------------------------------------

_GRANT = "admin token grant returned an access token an HTTP header cannot carry ({})"
_SEND = "admin request not sent: an HTTP header cannot carry the access token ({})"
_CONTROL = "it holds CR, LF, NUL, DEL or another control character other than HTAB"
_ABOVE_LATIN1 = (
    "it holds a character above U+00FF, which the sync admin client cannot encode in a header"
)
_NON_ASCII = (
    "it holds a non-ASCII character, which the async admin client cannot encode in a header"
)
_TRAILING = (
    "it ends with a space or tab, which the async admin client cannot send at the end of a header"
)
#: 레인마다 전송이 못 싣는 것의 이유 — RFC 제외(`_CONTROL`)는 두 레인 공통이라 따로 본다.
_TRANSPORT_REASONS = {"sync": {_ABOVE_LATIN1}, "aio": {_NON_ASCII, _TRAILING}}

#: 거부된 토큰이 오류 어디에도 없어야 한다 — 모든 시험 토큰이 이 꼬리를 단다.
CANARY = "Zq7canaryW3"
GOOD = f"good-{CANARY}-0"
REFRESH = "RF2m8x-refresh-from-a-good-grant"


def _token(ch: str, *, where: str = "middle") -> str:
    if where == "middle":
        return f"tok{ch}en-{CANARY}"
    if where == "lead":
        return f"{ch}token-{CANARY}"
    return f"token-{CANARY}{ch}"


def _rfc9110_excludes(token: str) -> bool:
    """RFC 9110 §5.5 — field-value 는 VCHAR·obs-text·SP·HTAB 이다. 빠지는 것은 HTAB 밖의 C0 와
    DEL 이다."""
    return any((ord(ch) < 0x20 and ch != "\t") or ord(ch) == 0x7F for ch in token)


#: 대표 열 — 이름 → (토큰, sync 의 기대 이유, aio 의 기대 이유). 이유가 None 이면 그 레인은 보낸다.
#: ⚠️ 글자는 `chr(코드)` 로 적는다 — 소스에 문자 그대로 두면 U+2028·U+FEFF 같은 것이 숨는다.
_CASES: dict[str, tuple[str, str | None, str | None]] = {
    "NUL": (_token(chr(0x00)), _CONTROL, _CONTROL),
    "SOH": (_token(chr(0x01)), _CONTROL, _CONTROL),
    "LF": (_token(chr(0x0A)), _CONTROL, _CONTROL),
    "CR": (_token(chr(0x0D)), _CONTROL, _CONTROL),
    "US": (_token(chr(0x1F)), _CONTROL, _CONTROL),
    "DEL": (_token(chr(0x7F)), _CONTROL, _CONTROL),
    "U+00E9": (_token(chr(0xE9)), None, _NON_ASCII),
    "U+0100": (_token(chr(0x100)), _ABOVE_LATIN1, _NON_ASCII),
    "U+4E2D": (_token(chr(0x4E2D)), _ABOVE_LATIN1, _NON_ASCII),
    "lone U+D800": (_token(chr(0xD800)), _ABOVE_LATIN1, _NON_ASCII),
    "trailing SP": (_token(chr(0x20), where="trail"), None, _TRAILING),
    "trailing HTAB": (_token(chr(0x09), where="trail"), None, _TRAILING),
    "HTAB": (_token(chr(0x09)), None, None),
    "SP": (_token(chr(0x20)), None, None),
    "leading SP": (_token(chr(0x20), where="lead"), None, None),
}


def _reason(case: str, lane: str) -> str | None:
    _, sync, aio = _CASES[case]
    return sync if lane == "sync" else aio


# --- 받은 바이트를 남기는 IdP ---------------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_USER = "/admin/realms/r/users/u1"
_PROBE = "/probe"
_Resp = tuple[int, dict[str, object]]


@dataclass(frozen=True)
class _Seen:
    path: str
    grant: str
    authorization: bytes | None  # 헤더 줄에서 이름·콜론·첫 공백을 뺀 바이트 그대로


@dataclass
class _Wire:
    """토큰 엔드포인트·admin GET·오라클 GET 을 내는 날 소켓 서버. 헤더를 해석하지 않고 받은
    `Authorization` 바이트를 남긴다 — http.server 의 헤더 파서는 값을 다듬을 수 있다."""

    url: str = ""
    grants: dict[str, list[_Resp]] = field(default_factory=dict)
    serve: str | None = None  # 정하면 어느 그랜트든 이 토큰(expires_in 1 — 다음 호출이 다시 그랜트)
    admin: list[int] = field(default_factory=list)  # admin GET 의 상태 각본
    seen: list[_Seen] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def answer(self, target: bytes, body: bytes, authorization: bytes | None) -> tuple[int, bytes]:
        path = urlsplit(target.decode("ascii")).path
        with self.lock:
            if path == _TOKEN:
                grant = parse_qs(body.decode("ascii", "replace")).get("grant_type", [""])[0]
                self.seen.append(_Seen(path, grant, None))
                if self.serve is not None:
                    status, obj = _grant(self.serve, expires_in=1)
                else:
                    script = self.grants.get(grant) or [(400, {"error": "unsupported_grant_type"})]
                    status, obj = script.pop(0) if len(script) > 1 else script[0]
                return status, json.dumps(obj).encode()  # ensure_ascii — 서로게이트는 \ud800 으로
            self.seen.append(_Seen(path, "", authorization))
            if path == _USER:
                status = self.admin.pop(0) if self.admin else 200
                return status, b'{"id": "u1"}' if status == 200 else b'{"error": "unauthorized"}'
            return 200, b"{}"

    def admin_requests(self) -> list[bytes | None]:
        with self.lock:
            return [s.authorization for s in self.seen if s.path == _USER]

    def probes(self) -> list[bytes | None]:
        with self.lock:
            return [s.authorization for s in self.seen if s.path == _PROBE]

    def grant_types(self) -> list[str]:
        with self.lock:
            return [s.grant for s in self.seen if s.path == _TOKEN]

    def forget(self) -> None:
        with self.lock:
            self.seen.clear()


def _grant(access_token: str, *, expires_in: int = 300) -> _Resp:
    return 200, {
        "access_token": access_token,
        "expires_in": expires_in,
        "refresh_token": REFRESH,
        "token_type": "Bearer",
    }


def _read_until(conn: socket.socket, buf: bytes, done: Any) -> bytes | None:
    while not done(buf):
        chunk = conn.recv(65536)
        if not chunk:
            return None
        buf += chunk
    return buf


def _serve_connection(wire: _Wire, conn: socket.socket) -> None:
    """keep-alive — 클라이언트가 닫을 때까지 요청을 차례로 받는다."""
    buf = b""
    with conn:
        while True:
            got = _read_until(conn, buf, lambda b: b"\r\n\r\n" in b)
            if got is None:
                return
            head, _, buf = got.partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            target = lines[0].split(b" ")[1]
            fields = [line.partition(b":") for line in lines[1:]]
            size = next((int(v) for n, _, v in fields if n.lower() == b"content-length"), 0)
            got = _read_until(conn, buf, lambda b, n=size: len(b) >= n)
            if got is None:
                return
            body, buf = got[:size], got[size:]
            values = [v for n, _, v in fields if n.lower() == b"authorization"]
            auth = values[0].removeprefix(b" ") if values else None  # 콜론 뒤 공백 하나만 뗀다
            status, payload = wire.answer(target, body, auth)
            conn.sendall(
                b"HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n"
                % (status, len(payload))
                + payload
            )


@contextlib.contextmanager
def _wire() -> Iterator[_Wire]:
    wire = _Wire()
    listener = socket.create_server(("127.0.0.1", 0))
    wire.url = f"http://127.0.0.1:{listener.getsockname()[1]}"

    def accept() -> None:
        with contextlib.suppress(OSError):  # 닫힌 리스너 — 끝
            while True:
                conn, _ = listener.accept()
                threading.Thread(target=_serve_connection, args=(wire, conn), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    try:
        yield wire
    finally:
        listener.close()


# --- 판정 도우미 ---------------------------------------------------------------------------


def _quotes(err: BaseException) -> list[str]:
    """오류가 토큰을 싣는 자리 — 메시지·repr·사슬, 그리고 프레임 로컬까지 찍은 traceback."""
    places = [
        f"{type(node).__qualname__} 의 str/repr"
        for node in [err, *_chain(err)]
        if CANARY in str(node) or CANARY in repr(node)
    ]
    rendered = "".join(
        traceback.TracebackException.from_exception(err, capture_locals=True).format()
    )
    if CANARY in rendered:
        places.append("프레임 로컬(capture_locals)")
    return places


def _refused(
    err: BaseException | None, message: str, *, boundary: bool, sent_from_raw: bool = False
) -> list[str]:
    """`message` 의 `KeycloakAuthError` 인가. `boundary` 면 파사드 경계를 지난 것 — 사슬·하위
    프레임·프레임 로컬도 비어 있어야 한다. 탈출구 `raw` 는 python-keycloak 프레임을 지나 그대로
    나오므로(§4(b)) 메시지까지만 본다 — 단 `sent_from_raw`(보내는 자리의 거부)면 사슬과 프레임
    로컬도 비어 있어야 한다: 거부는 헤더 값을 쥐지 않은 프레임에서 난다
    (`admin_guard._require_usable_bearer`). 받는 자리의 거부는 그랜트 래퍼 프레임이 응답을 쥔다."""
    if err is None:
        return ["거부하지 않았다"]
    problems = []
    if type(err) is not KeycloakAuthError or str(err) != message:
        problems.append(f"{type(err).__module__}.{type(err).__qualname__}({str(err)!r})")
    if getattr(err, "error", None) is not None:
        problems.append(f"error={err.error!r}")  # type: ignore[attr-defined]
    quoted = _quotes(err)
    if boundary or sent_from_raw:
        problems += [f"사슬에 {type(e).__module__}.{type(e).__qualname__}" for e in _chain(err)]
        problems += [f"토큰이 {where} 에" for where in quoted]
    else:
        problems += [f"토큰이 {where} 에" for where in quoted if "프레임 로컬" not in where]
    if boundary:
        problems += [f"traceback 이 {f} 프레임을 지난다" for f in _inner_frames(err)]
    return problems


def _wire_bytes(token: str) -> bytes:
    """보내진 헤더 값 — sync 는 latin-1, aio 는 ASCII 로 그대로 인코딩한다(아래 오라클이 잰다)."""
    return ("Bearer " + token).encode("latin-1")


def _cfg(url: str) -> KeycloakConfig:
    return KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret=SECRET)


# --- 오라클 — 전송에 묻는다 -----------------------------------------------------------------


class _Oracle:
    """python-keycloak 의 `ConnectionManager`(admin 이 쓰는 그 전송)로 `Bearer <토큰>` 을 보낸다.

    답은 셋 중 하나다 — 실었다(서버가 받은 바이트), 보내기 전에 거부했다(`None`), 그 밖(시험 실패).
    """

    def __init__(self, lane: str, wire: _Wire) -> None:
        self.lane = lane
        self.wire = wire
        self.cm = ConnectionManager(base_url=wire.url, timeout=5)

    async def ask(self, token: str) -> bytes | None:
        self.wire.forget()
        self.cm.add_param_headers("Authorization", "Bearer " + token)
        try:
            if self.lane == "sync":
                self.cm.raw_get(_PROBE)
            else:
                await self.cm.a_raw_get(_PROBE)
        except KeycloakConnectionError:
            assert self.wire.probes() == [], f"{token!r}: 실패했는데 서버가 받았다 — 오라클 고장"
            return None
        (got,) = self.wire.probes()
        assert got is not None, f"{token!r}: Authorization 없이 갔다"
        assert got.decode("latin-1") == "Bearer " + token, f"{token!r}: 전송이 바꿔 실었다 {got!r}"
        return got

    async def close(self) -> None:
        await self.cm.aclose()
        self.cm._s.close()


#: 오라클이 두 답을 다 낼 수 있는지 — 알려진 답(수정 전 실측 · 위 머리말).
_KNOWN = {
    "sync": {0x0D: False, 0x0A: False, 0x100: False, 0x00: True, 0x61: True, 0xE9: True},
    "aio": {0x00: False, 0x0D: False, 0xE9: False, 0x01: True, 0x61: True, 0x09: True},
}

#: 가운데 자리의 모든 바이트 값과, U+00FF 위의 대표(U+2028 · U+FEFF · U+FFFD · 아스트랄 · 짝 없는
#: 서로게이트 둘) — 그리고 앞·끝의 SP·HTAB.
_ABOVE = (0x100, 0x2028, 0x4E2D, 0xFEFF, 0xFFFD, 0x1F600, 0xD800, 0xDFFF)
_SWEEP = (
    [_token(chr(c)) for c in range(0x100)]
    + [_token(chr(c)) for c in _ABOVE]
    + [_token(chr(c), where=w) for c in (0x20, 0x09) for w in ("lead", "trail")]
)


@pytest.mark.parametrize("lane", LANES)
async def test_the_sdk_refuses_exactly_what_rfc_9110_or_the_transport_refuses(lane: str) -> None:
    """토큰마다 — RFC 9110 이 빼거나 전송이 못 실으면 받을 때 거부(요청 0), 아니면 전송이 싣는 그
    바이트 그대로 admin 요청이 나간다. 클라이언트 하나로 돈다(expires_in 1 이라 호출마다 다시
    그랜트한다) — 행마다 클라이언트를 만들면 연결이 수백이다."""
    with _wire() as wire:
        oracle = _Oracle(lane, wire)
        try:
            for code, carries in _KNOWN[lane].items():
                got = await oracle.ask(_token(chr(code)))
                assert (got is not None) == carries, f"오라클의 알려진 답이 틀렸다: U+{code:04X}"
            carried = {token: await oracle.ask(token) for token in _SWEEP}
        finally:
            await oracle.close()

        problems: list[str] = []
        async with _client(lane, wire) as client:
            for token in _SWEEP:
                wire.serve = token
                wire.forget()
                result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
                wrong = _verdict(lane, token, carried[token], wire, result, err)
                problems += [f"{token!r}: {w}" for w in wrong]

    assert problems == []


def _verdict(
    lane: str,
    token: str,
    carried: bytes | None,
    wire: _Wire,
    result: Any,
    err: BaseException | None,
) -> list[str]:
    """한 토큰의 판정 — 전송이 싣고 RFC 도 빼지 않으면 그 바이트 그대로 보냈는가, 아니면 받을 때
    거부했는가(메시지는 RFC 제외면 `_CONTROL`, 전송 거부면 그 레인의 전송 이유)."""
    sent = wire.admin_requests()
    if len(wire.grant_types()) != 1:
        return [f"그랜트 {wire.grant_types()} — 호출마다 하나여야 한다(아니면 공허하다)"]
    if not _rfc9110_excludes(token) and carried is not None:
        ok = err is None and result == {"id": "u1"} and sent == [carried]
        return [] if ok else [f"보내지 않았다: {err!r} · 서버가 받은 {sent!r}"]
    if _rfc9110_excludes(token):
        expected = {_GRANT.format(_CONTROL)}
    else:
        expected = {_GRANT.format(r) for r in _TRANSPORT_REASONS[lane]}
    message = str(err) if str(err) in expected else f"{sorted(expected)}"
    wrong = _refused(err, message, boundary=True)
    if sent:
        wrong.append(f"거부했는데 admin 요청이 나갔다 {sent!r}")
    return wrong


# --- 받는 자리 — SDK 자신의 그랜트 ------------------------------------------------------------


@pytest.mark.parametrize("case", list(_CASES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_grant_that_returns_a_token_the_header_cannot_carry_sends_nothing(
    lane: str, case: str
) -> None:
    token, reason = _CASES[case][0], _reason(case, lane)
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token)]
        async with _client(lane, wire) as client:
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert wire.grant_types() == ["client_credentials"], "admin 그랜트에 닿지 않았다 — 공허하다"
    if reason is None:  # 대조 — 전송이 싣는 것은 거부하지 않는다
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [_wire_bytes(token)]
        return
    assert result is None
    assert _refused(err, _GRANT.format(reason), boundary=True) == []
    assert wire.admin_requests() == [], "헤더가 못 싣는 토큰으로 admin 요청을 보냈다"


@pytest.mark.parametrize(
    ("lane", "case"),
    [
        ("sync", "NUL"),
        ("sync", "U+0100"),
        ("aio", "NUL"),
        ("aio", "U+0100"),
        ("aio", "trailing SP"),
    ],
)
async def test_a_refused_token_is_not_cached(lane: str, case: str) -> None:
    """거부한 토큰은 세터에 닿지 않는다 — 다음 호출이 다시 그랜트하고 그 토큰으로 보낸다."""
    token, reason = _CASES[case][0], _reason(case, lane)
    assert reason is not None
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token), _grant(GOOD)]
        async with _client(lane, wire) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            second, err2 = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert first is None
    assert _refused(err, _GRANT.format(reason), boundary=True) == []
    assert (second, err2) == ({"id": "u1"}, None), "거부한 토큰이 캐시돼 다음 호출도 실패했다"
    assert wire.grant_types() == ["client_credentials", "client_credentials"]
    assert wire.admin_requests() == [_wire_bytes(GOOD)]


#: 경로 → (첫 그랜트의 expires_in, admin GET 상태 각본, 실패할 호출 앞의 성공 호출 수, 기대 그랜트
#: 순서) — `test_admin_grant.py` 의 `_LATER` 와 같은 넷 중 첫 그랜트를 뺀 셋.
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


@pytest.mark.parametrize("case", ["NUL", "U+0100"])
@pytest.mark.parametrize("path", list(_LATER))
@pytest.mark.parametrize("lane", LANES)
async def test_a_later_grant_is_refused_the_same_way(lane: str, path: str, case: str) -> None:
    expires_in, statuses, ok_calls, grants = _LATER[path]
    token, reason = _CASES[case][0], _reason(case, lane)
    assert reason is not None
    with _wire() as wire:
        good = _grant(GOOD, expires_in=expires_in)
        if path == "Refresh token expired 폴백":
            expired = {"error": "invalid_grant", "error_description": "Refresh token expired"}
            wire.grants["client_credentials"] = [good, _grant(token)]
            wire.grants["refresh_token"] = [(400, expired)]
        else:
            wire.grants["client_credentials"] = [good]
            wire.grants["refresh_token"] = [_grant(token)]
        wire.admin = list(statuses)
        async with _client(lane, wire) as client:
            for _ in range(ok_calls):
                result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
                assert (result, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert result is None
    assert _refused(err, _GRANT.format(reason), boundary=True) == []
    assert wire.grant_types() == grants, f"{path} 경로에 닿지 않았다 — 공허하다"
    # 요청은 첫 그랜트의 토큰으로 나간 것뿐이다 — 401 재시도는 거부된 토큰으로 다시 보내지 않는다.
    assert wire.admin_requests() == [_wire_bytes(GOOD)] * (ok_calls + len(statuses))


# --- 보내는 자리 — 그랜트를 거치지 않고 실린 bearer --------------------------------------------

_ADMIN_CLIENTS: dict[str, Any] = {"sync": AdminClient, "aio": AsyncAdminClient}
_SEND_CASES = ["NUL", "LF", "DEL", "U+00E9", "U+0100", "trailing SP", "HTAB"]


async def _close(lane: str, client: Any) -> None:
    if lane == "aio":
        await client.aclose()
    else:
        client.close()


def _raw_get(lane: str, raw: Any) -> Any:
    return (lambda _c: raw.get_user("u1")) if lane == "sync" else (lambda _c: raw.a_get_user("u1"))


@pytest.mark.parametrize("case", _SEND_CASES)
@pytest.mark.parametrize("path", ["리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_injected_admin_holding_a_token_the_header_cannot_carry_sends_nothing(
    lane: str, path: str, case: str
) -> None:
    token, reason = _CASES[case][0], _reason(case, lane)
    with _wire() as wire:
        admin = KeycloakAdmin(
            server_url=wire.url, realm_name="r", token={"access_token": token, "expires_in": 300}
        )
        client = _ADMIN_CLIENTS[lane](_cfg(wire.url), admin=admin)
        act = (lambda c: c.users.get("u1")) if path == "리소스" else _raw_get(lane, admin)
        result, err = await _attempt(lane, client, act)
        await _close(lane, client)

    assert wire.grant_types() == []
    if reason is None:
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [_wire_bytes(token)]
        return
    assert result is None
    assert _refused(err, _SEND.format(reason), boundary=path == "리소스", sent_from_raw=True) == []
    assert wire.admin_requests() == [], "주입된 admin 이 헤더가 못 싣는 bearer 를 보냈다"


@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_set_on_the_live_connection_is_checked_before_sending(lane: str) -> None:
    """토큰 세터도 공개다 — 생성 뒤에 실린 bearer 도 보내기 직전에 본다."""
    token = _CASES["NUL"][0]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(GOOD)]
        async with _client(lane, wire) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            client.admin.raw.connection.token = {"access_token": token, "expires_in": 300}
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert result is None
    assert _refused(err, _SEND.format(_CONTROL), boundary=True) == []
    assert wire.admin_requests() == [_wire_bytes(GOOD)]


async def test_a_token_the_sync_lane_carries_is_refused_when_raw_sends_it_on_the_aio_lane() -> None:
    """레인은 그 요청의 것이다 — sync 그랜트가 받아 보낸 U+00E9 토큰을 같은 admin 의 `a_*` 메서드로
    보내면 aio 전송은 그것을 인코딩하지 못한다. 그랜트는 sync 라 받는 자리는 통과시켰다."""
    token = _CASES["U+00E9"][0]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token)]
        async with _client("sync", wire) as client:
            first, err = await _attempt("sync", client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "sync 가 U+00E9 를 보내지 않았다"
            raw = client.admin.raw
            result, err = await _attempt("aio", client, lambda _c: raw.a_get_user("u1"))
            await raw.connection.aclose()  # sync 클라이언트의 close 는 async 세션을 못 닫는다

    assert result is None
    assert _refused(err, _SEND.format(_NON_ASCII), boundary=False, sent_from_raw=True) == []
    assert wire.admin_requests() == [_wire_bytes(token)]
    assert wire.grant_types() == ["client_credentials"]


def test_the_sweep_covers_every_byte_and_both_sides_of_each_ceiling() -> None:
    """스윕이 줄면 위 시험이 조용히 공허해진다 — 가운데 자리의 모든 바이트 값, 경계 양쪽(U+007F/
    U+0080 · U+00FF/U+0100), 서로게이트, 앞·끝의 SP·HTAB 이 남아 있는지."""
    sweep = set(_SWEEP)
    assert {_token(chr(c)) for c in range(0x100)} <= sweep
    assert {_token(chr(c)) for c in (0x100, 0xD800, 0xDFFF)} <= sweep
    assert {_token(chr(c), where=w) for c in (0x20, 0x09) for w in ("lead", "trail")} <= sweep
