"""admin 이 보내는 bearer 의 문법 — 아홉 언어 공통 규칙(등록부 `bearer-token-grammar-divergent`,
2026-10-29 판정).

규칙(`_internal/bearer.py`): 토큰의 앞뒤에서 SP·HTAB·CR·LF **만** 떼고, 남은 것이 비어 있지 않은
RFC 6750 `b64token`(`[A-Za-z0-9\\-._~+/]+=*`, ASCII — `=` 는 끝의 채움으로만)이면 `Authorization:
Bearer <남은 것>` 으로 보낸다. 아니면 요청을 하나도 보내지 않고 `KeycloakAuthError` 다. sync·aio 가
같은 판정이다.

수정 전 실측(정본 표를 수정 전 코드에서 돌림 — origin/main 3ed85eb3 ·
python-keycloak 7.1.1 · requests 2.34.2 · httpx 0.28.1 · h11 0.16.0): 기준이
「그 레인의 전송이 헤더로 실을 수 있는가」라 두 레인이 갈렸다. 받는 자리·보내는
자리, 파사드·`raw` 가 모두 같았다.

* sync 는 lead-tab(앞뒤 그대로)·inner-sp·inner-tab·mid-pad·latin1(0xE9)·
  c1(0x85)·nbsp(0xA0)를, aio 는 inner-sp·inner-tab·mid-pad 를 보냈다 — 캐시됐다.
* 다듬지 않았다 — lf·crlf 는 두 레인, lead-tab 은 aio 가 거부했다(레인마다 다른
  메시지).

Python 은 규칙의 두 자리를 다 맡는다 — **받는 자리**(그랜트 래퍼가 세터 앞에서
판정하고 다듬은 값을 넘긴다 — python-keycloak 의 401 재시도는 보내는 자리를 거치지
않고 세터가 실은 값을 다시 보낸다)와 **보내는 자리**(그랜트를 거치지 않고 실린
bearer — 주입된 `KeycloakAdmin(token=…)`·토큰 세터. 소비자가 토큰을 넣을 수 있다).
그래서 lf·crlf·lead-tab 은 다듬어 보낸다.

기대는 시험이 따로 쓴 규칙(`_rule`)에서 온다 — SDK 의 정규식을 빌리지 않는다. 그 규칙은 스펙의 정본
표와 대조된다(`test_the_rule_oracle_agrees_with_the_canonical_table`). 서버는 받은 `Authorization`
바이트를 그대로 남기는 날 소켓이다 — http.server 의 헤더 파서는 값을 다듬을 수 있다.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import json
import secrets
import socket
import threading
import traceback
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest
from keycloak import KeycloakAdmin

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError

from .test_admin_grant import LANES, SECRET, _attempt, _chain, _client, _inner_frames

pytestmark = pytest.mark.usefixtures("fast_tls")

# --- 계약 ---------------------------------------------------------------------------------

_RULE = "after trimming SP, HTAB, CR and LF it must be a non-empty RFC 6750 b64token"
_GRANT = f"admin token grant returned an access token that is not a bearer token ({_RULE})"
_SEND = f"admin request not sent: the access token is not a bearer token ({_RULE})"
#: 빈 access_token 은 그 전에 쓸 수 없는 토큰이다(`tokens._usable_access_token` — auth 레인과 같다).
_EMPTY = "token response has no usable access_token"

#: 규칙을 시험이 따로 쓴다 — 떼는 글자 넷과 b64token 의 글자.
_TRIMMED = " \t\r\n"
_ALPHABET = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/")


def _rule(token: str) -> str | None:
    """정본 규칙 — 앞뒤의 SP·HTAB·CR·LF 만 떼고 남은 것이 b64token 이면 그것, 아니면 None."""
    start, end = 0, len(token)
    while start < end and token[start] in _TRIMMED:
        start += 1
    while end > start and token[end - 1] in _TRIMMED:
        end -= 1
    body = token[start:end].rstrip("=")
    if not body or any(ch not in _ALPHABET for ch in body):
        return None
    return token[start:end]


def _jws() -> str:
    """진짜 세 조각 JWS(HS256) — 시험마다 새 키로 서명한다(소스에 키를 두지 않는다)."""

    def b64(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

    head = b64(b'{"alg":"HS256","typ":"JWT"}')
    claims = b64(b'{"sub":"bearer-grammar","iat":1767225600}')
    mac = hmac.new(secrets.token_bytes(32), f"{head}.{claims}".encode("ascii"), hashlib.sha256)
    return f"{head}.{claims}.{b64(mac.digest())}"


_JWS = _jws()

#: 정본 표(스펙의 스무 행) + UTF-16 문자열 언어의 추가 행 — id → (입력, 보낼 값(None 이면 거부),
#: 거부 오류의 메시지가 싣지 말아야 할 글자). ⚠️ 글자는 이스케이프로 적는다 — 소스에 문자 그대로 두면
#: NBSP·U+3000 같은 것이 숨는다.
_TABLE: dict[str, tuple[str, str | None, str | None]] = {
    "plain": ("abc.DEF-ghi_jkl~mno+pqr/stu", "abc.DEF-ghi_jkl~mno+pqr/stu", None),
    "pad": ("abc==", "abc==", None),
    "jwt": (_JWS, _JWS, None),
    "lf": ("abc\n", "abc", None),
    "crlf": ("abc\r\n", "abc", None),
    "lead-tab": (" \tabc\t ", "abc", None),
    "inner-sp": ("a bc", None, "bc"),
    "inner-tab": ("a\tbc", None, "bc"),
    "inner-crlf": ("a\r\nX-Evil: 1", None, "X-Evil"),
    "mid-pad": ("a=bc", None, "=bc"),
    "empty": ("", None, None),
    "blank": (" \t\r\n", None, None),
    "latin1": ("abcé", None, "abc"),
    "above-ff": ("abcĀ", None, "abc"),
    "c1": ("abc\x85", None, "abc"),
    "nul": ("abc\x00", None, "abc"),
    "del": ("abc\x7f", None, "abc"),
    "nbsp": ("abc\xa0", None, "abc"),
    "ideographic": (chr(0x3000) + "abc", None, "abc"),
    "vt": ("abc\x0b", None, "abc"),
    "lone-surrogate": ("abc\ud800", None, "abc"),
}

#: 거부된 토큰이 오류 어디에도 없어야 한다 — 아래 사례 토큰이 모두 이 꼬리를 단다. 16진 글자가 아닌
#: 것을 섞었다 — 프레임 로컬을 찍으면 객체 repr 의 주소(16진)가 나온다.
CANARY = "Zq7canaryW3"
GOOD = f"good-{CANARY}-0"
REFRESH = "RF2m8x-refresh-from-a-good-grant"


def _token(ch: str, *, where: str = "middle") -> str:
    if where == "middle":
        return f"tok{ch}en-{CANARY}"
    if where == "lead":
        return f"{ch}token-{CANARY}"
    return f"token-{CANARY}{ch}"


#: 카나리아를 단 대표 열 — 기대는 `_rule` 이 정한다. ⚠️ 글자는 `chr(코드)` 로 적는다.
_CASES: dict[str, str] = {
    "NUL": _token(chr(0x00)),
    "SOH": _token(chr(0x01)),
    "LF": _token(chr(0x0A)),
    "CR": _token(chr(0x0D)),
    "US": _token(chr(0x1F)),
    "DEL": _token(chr(0x7F)),
    "U+00E9": _token(chr(0xE9)),
    "U+0100": _token(chr(0x100)),
    "U+4E2D": _token(chr(0x4E2D)),
    "lone U+D800": _token(chr(0xD800)),
    "trailing SP": _token(chr(0x20), where="trail"),
    "trailing HTAB": _token(chr(0x09), where="trail"),
    "trailing LF": _token(chr(0x0A), where="trail"),
    "HTAB": _token(chr(0x09)),
    "SP": _token(chr(0x20)),
    "leading SP": _token(chr(0x20), where="lead"),
}


def test_the_rule_oracle_agrees_with_the_canonical_table() -> None:
    """시험의 규칙이 스펙의 정본 표와 같은 답을 낸다 — 아래 스윕·사례의 기대가 그 규칙에서 온다."""
    assert {row: _rule(token) for row, (token, _, _) in _TABLE.items()} == {
        row: sent for row, (_, sent, _) in _TABLE.items()
    }


def test_the_sdk_predicate_agrees_with_the_rule() -> None:
    """SDK 의 판정(`bearer.sendable`)이 시험의 규칙과 같은 답을 낸다 — 정본 표·사례·스윕 전부.
    가져오기는 여기서 한다 — 수정 전 코드에서도 이 모듈의 다른 시험이 모이게."""
    from keycloak_sdk._internal.bearer import sendable

    tokens = [t for t, _, _ in _TABLE.values()] + list(_CASES.values()) + _SWEEP
    assert [sendable(t) for t in tokens] == [_rule(t) for t in tokens]


# --- 받은 바이트를 남기는 IdP ---------------------------------------------------------------

_OC = "/realms/r/protocol/openid-connect"
_TOKEN = f"{_OC}/token"
_USER = "/admin/realms/r/users/u1"
_Resp = tuple[int, dict[str, object]]


@dataclass(frozen=True)
class _Seen:
    path: str
    grant: str
    authorization: bytes | None  # 헤더 줄에서 이름·콜론·첫 공백을 뺀 바이트 그대로


@dataclass
class _Wire:
    """토큰 엔드포인트·admin GET 을 내는 날 소켓 서버. 헤더를 해석하지 않고 받은 `Authorization`
    바이트를 남긴다 — http.server 의 헤더 파서는 값을 다듬을 수 있다."""

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


def _quotes(err: BaseException, needle: str, *, frames: bool) -> list[str]:
    """오류가 `needle` 을 싣는 자리 — 메시지·repr·사슬, 그리고 `frames` 면 프레임 로컬까지 찍은
    traceback. ⚠️ 프레임 로컬은 카나리아로만 본다 — `abc` 같은 짧은 글자는 객체 repr 의 16진 주소에도
    나온다."""
    places = [
        f"{type(node).__qualname__} 의 str/repr"
        for node in [err, *_chain(err)]
        if needle in str(node) or needle in repr(node)
    ]
    if frames:
        rendered = "".join(
            traceback.TracebackException.from_exception(err, capture_locals=True).format()
        )
        if needle in rendered:
            places.append("프레임 로컬(capture_locals)")
    return places


def _refused(
    err: BaseException | None,
    message: str,
    *,
    boundary: bool,
    sent_from_raw: bool = False,
    marker: str | None = None,
) -> list[str]:
    """`message` 의 `KeycloakAuthError` 인가. `boundary` 면 파사드 경계를 지난 것 — 사슬·하위
    프레임·프레임 로컬도 비어 있어야 한다. 탈출구 `raw` 는 python-keycloak 프레임을 지나 그대로
    나오므로(§4(b)) 메시지까지만 본다 — 단 `sent_from_raw`(보내는 자리의 거부)면 사슬과 프레임
    로컬도 비어 있어야 한다: 거부는 헤더 값을 쥐지 않은 프레임에서 난다
    (`admin_guard._require_usable_bearer`). 받는 자리의 거부는 그랜트 래퍼 프레임이 응답을 쥔다.
    `marker` 를 주면 카나리아 대신 그 글자를 메시지·사슬에서만 찾는다(정본 표의 토큰)."""
    if err is None:
        return ["거부하지 않았다"]
    problems = []
    if type(err) is not KeycloakAuthError or str(err) != message:
        problems.append(f"{type(err).__module__}.{type(err).__qualname__}({str(err)!r})")
    if getattr(err, "error", None) is not None:
        problems.append(f"error={err.error!r}")  # type: ignore[attr-defined]
    quoted = _quotes(err, marker or CANARY, frames=marker is None)
    if boundary or sent_from_raw:
        problems += [f"사슬에 {type(e).__module__}.{type(e).__qualname__}" for e in _chain(err)]
        problems += [f"토큰이 {where} 에" for where in quoted]
    else:
        problems += [f"토큰이 {where} 에" for where in quoted if "프레임 로컬" not in where]
    if boundary:
        problems += [f"traceback 이 {f} 프레임을 지난다" for f in _inner_frames(err)]
    return problems


def _bearer(token: str) -> bytes:
    """보낸 헤더 값 — 규칙이 다듬은 값(ASCII)."""
    bearer = _rule(token)
    assert bearer is not None
    return f"Bearer {bearer}".encode("ascii")


def _cfg(url: str) -> KeycloakConfig:
    return KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret=SECRET)


_ADMIN_CLIENTS: dict[str, Any] = {"sync": AdminClient, "aio": AsyncAdminClient}


async def _close(lane: str, client: Any) -> None:
    if lane == "aio":
        await client.aclose()
    else:
        client.close()


def _raw_get(lane: str, raw: Any) -> Any:
    return (lambda _c: raw.get_user("u1")) if lane == "sync" else (lambda _c: raw.a_get_user("u1"))


def _client_raw_get(lane: str) -> Any:
    """SDK 가 만든 admin 의 탈출구 — 그 `raw` 로 python-keycloak 메서드를 부른다."""
    if lane == "sync":
        return lambda c: c.admin.raw.get_user("u1")
    return lambda c: c.admin.raw.a_get_user("u1")


# --- 정본 표 -------------------------------------------------------------------------------


@pytest.mark.parametrize("row", list(_TABLE))
@pytest.mark.parametrize("route", ["facade", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_the_canonical_table_through_the_sdk_grant(lane: str, route: str, row: str) -> None:
    """SDK 자신의 그랜트(받는 자리)가 받은 토큰 — 두 번 부른다. 보낼 행은 다듬은 값 그대로 두 번
    나가고 캐시된다(그랜트 1). 거부 행은 admin 요청 0 · 캐시하지 않는다(두 번째 호출이 다시
    그랜트한다)."""
    token, sent, marker = _TABLE[row]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token)]
        async with _client(lane, wire) as client:
            act = _client_raw_get(lane) if route == "raw" else (lambda c: c.admin.users.get("u1"))
            outcomes = [await _attempt(lane, client, act) for _ in range(2)]

    if sent is not None:
        assert outcomes == [({"id": "u1"}, None)] * 2
        assert wire.admin_requests() == [f"Bearer {sent}".encode("ascii")] * 2
        assert wire.grant_types() == ["client_credentials"], "보낸 토큰은 캐시돼야 한다"
        return
    message = _EMPTY if token == "" else _GRANT
    for result, err in outcomes:
        assert result is None
        assert _refused(err, message, boundary=route == "facade", marker=marker) == []
    assert wire.admin_requests() == [], "거부한 토큰으로 admin 요청이 나갔다"
    assert wire.grant_types() == ["client_credentials"] * 2, "거부한 토큰을 캐시했다"


@pytest.mark.parametrize("row", list(_TABLE))
@pytest.mark.parametrize("route", ["facade", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_the_canonical_table_through_an_injected_bearer(
    lane: str, route: str, row: str
) -> None:
    """그랜트를 거치지 않고 실린 bearer(보내는 자리 — 주입된 `KeycloakAdmin(token=…)`) — 두 번
    부른다. 보낼 행은 다듬은 값으로 두 번 나가고, 거부 행은 admin 요청 0."""
    token, sent, marker = _TABLE[row]
    with _wire() as wire:
        admin = KeycloakAdmin(
            server_url=wire.url, realm_name="r", token={"access_token": token, "expires_in": 300}
        )
        client = _ADMIN_CLIENTS[lane](_cfg(wire.url), admin=admin)
        act = (lambda c: c.users.get("u1")) if route == "facade" else _raw_get(lane, admin)
        outcomes = [await _attempt(lane, client, act) for _ in range(2)]
        await _close(lane, client)

    assert wire.grant_types() == []
    if sent is not None:
        assert outcomes == [({"id": "u1"}, None)] * 2
        assert wire.admin_requests() == [f"Bearer {sent}".encode("ascii")] * 2
        return
    message = _EMPTY if token == "" else _SEND
    for result, err in outcomes:
        assert result is None
        assert (
            _refused(err, message, boundary=route == "facade", sent_from_raw=True, marker=marker)
            == []
        )
    assert wire.admin_requests() == [], "주입된 admin 이 규칙에 맞지 않는 bearer 를 보냈다"


# --- 스윕 — 가운데 자리의 모든 바이트 값 ------------------------------------------------------

#: 가운데 자리의 모든 바이트 값과, U+00FF 위의 대표(U+2028 · U+FEFF · U+FFFD · 아스트랄 · 짝 없는
#: 서로게이트 둘) — 그리고 앞·끝의 SP·HTAB.
_ABOVE = (0x100, 0x2028, 0x4E2D, 0xFEFF, 0xFFFD, 0x1F600, 0xD800, 0xDFFF)
_SWEEP = (
    [_token(chr(c)) for c in range(0x100)]
    + [_token(chr(c)) for c in _ABOVE]
    + [_token(chr(c), where=w) for c in (0x20, 0x09) for w in ("lead", "trail")]
)


@pytest.mark.parametrize("lane", LANES)
async def test_the_sweep_is_judged_by_the_bearer_rule(lane: str) -> None:
    """토큰마다 — 규칙이 받아들이면 다듬은 값 그대로 admin 요청이 나가고, 아니면 받을 때
    거부한다(요청 0). 클라이언트 하나로 돈다(expires_in 1 이라 호출마다 다시 그랜트한다) —
    행마다 클라이언트를 만들면 연결이 수백이다."""
    problems: list[str] = []
    with _wire() as wire:
        async with _client(lane, wire) as client:
            for token in _SWEEP:
                wire.serve = token
                wire.forget()
                result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
                problems += [f"{token!r}: {w}" for w in _verdict(token, wire, result, err)]

    assert problems == []


def _verdict(token: str, wire: _Wire, result: Any, err: BaseException | None) -> list[str]:
    """한 토큰의 판정 — 규칙이 받아들이면 다듬은 값 그대로 보냈는가, 아니면 받을 때 거부했는가."""
    sent = wire.admin_requests()
    if len(wire.grant_types()) != 1:
        return [f"그랜트 {wire.grant_types()} — 호출마다 하나여야 한다(아니면 공허하다)"]
    if _rule(token) is not None:
        ok = err is None and result == {"id": "u1"} and sent == [_bearer(token)]
        return [] if ok else [f"보내지 않았다: {err!r} · 서버가 받은 {sent!r}"]
    wrong = _refused(err, _GRANT, boundary=True)
    if sent:
        wrong.append(f"거부했는데 admin 요청이 나갔다 {sent!r}")
    return wrong


def test_the_sweep_covers_every_byte_and_both_sides_of_each_ceiling() -> None:
    """스윕이 줄면 위 시험이 조용히 공허해진다 — 가운데 자리의 모든 바이트 값, 경계 양쪽(U+007F/
    U+0080 · U+00FF/U+0100), 서로게이트, 앞·끝의 SP·HTAB 이 남아 있는지."""
    sweep = set(_SWEEP)
    assert {_token(chr(c)) for c in range(0x100)} <= sweep
    assert {_token(chr(c)) for c in (0x100, 0xD800, 0xDFFF)} <= sweep
    assert {_token(chr(c), where=w) for c in (0x20, 0x09) for w in ("lead", "trail")} <= sweep


# --- 받는 자리 — SDK 자신의 그랜트 ------------------------------------------------------------


@pytest.mark.parametrize("case", list(_CASES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_grant_is_judged_by_the_bearer_rule(lane: str, case: str) -> None:
    token = _CASES[case]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token)]
        async with _client(lane, wire) as client:
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert wire.grant_types() == ["client_credentials"], "admin 그랜트에 닿지 않았다 — 공허하다"
    if _rule(token) is not None:  # 보낸다 — 다듬은 값 그대로
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [_bearer(token)]
        return
    assert result is None
    assert _refused(err, _GRANT, boundary=True) == []
    assert wire.admin_requests() == [], "규칙에 맞지 않는 토큰으로 admin 요청을 보냈다"


@pytest.mark.parametrize(
    ("lane", "case"),
    [
        ("sync", "NUL"),
        ("sync", "U+0100"),
        ("aio", "NUL"),
        ("aio", "U+0100"),
        ("aio", "SP"),
    ],
)
async def test_a_refused_token_is_not_cached(lane: str, case: str) -> None:
    """거부한 토큰은 세터에 닿지 않는다 — 다음 호출이 다시 그랜트하고 그 토큰으로 보낸다."""
    token = _CASES[case]
    assert _rule(token) is None
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token), _grant(GOOD)]
        async with _client(lane, wire) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            second, err2 = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert first is None
    assert _refused(err, _GRANT, boundary=True) == []
    assert (second, err2) == ({"id": "u1"}, None), "거부한 토큰이 캐시돼 다음 호출도 실패했다"
    assert wire.grant_types() == ["client_credentials", "client_credentials"]
    assert wire.admin_requests() == [_bearer(GOOD)]


#: 경로 → (첫 그랜트의 expires_in, admin GET 상태 각본, 판정할 호출 앞의 성공 호출 수, 기대 그랜트
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


@pytest.mark.parametrize("case", ["NUL", "U+0100", "trailing LF"])
@pytest.mark.parametrize("path", list(_LATER))
@pytest.mark.parametrize("lane", LANES)
async def test_a_later_grant_is_judged_the_same_way(lane: str, path: str, case: str) -> None:
    """나중 그랜트(만료 갱신 · 401 재시도 · 폴백)가 받은 토큰도 같은 판정이다. ⚠️ 401 재시도는 보내는
    자리를 거치지 않고 세터가 실은 값을 곧바로 다시 보낸다 — 다듬는 것도 받는 자리의 몫인 이유다
    (`trailing LF`)."""
    expires_in, statuses, ok_calls, grants = _LATER[path]
    token = _CASES[case]
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

    assert wire.grant_types() == grants, f"{path} 경로에 닿지 않았다 — 공허하다"
    before = [_bearer(GOOD)] * (ok_calls + len(statuses))
    if _rule(token) is not None:  # 다듬어 보낸다 — 401 재시도도 같은 값이다
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [*before, _bearer(token)]
        return
    assert result is None
    assert _refused(err, _GRANT, boundary=True) == []
    # 요청은 첫 그랜트의 토큰으로 나간 것뿐이다 — 401 재시도는 거부된 토큰으로 다시 보내지 않는다.
    assert wire.admin_requests() == before


# --- 보내는 자리 — 그랜트를 거치지 않고 실린 bearer --------------------------------------------

_SEND_CASES = ["NUL", "LF", "DEL", "U+00E9", "U+0100", "trailing SP", "HTAB"]


@pytest.mark.parametrize("case", _SEND_CASES)
@pytest.mark.parametrize("path", ["리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_injected_bearer_is_judged_by_the_bearer_rule(
    lane: str, path: str, case: str
) -> None:
    token = _CASES[case]
    with _wire() as wire:
        admin = KeycloakAdmin(
            server_url=wire.url, realm_name="r", token={"access_token": token, "expires_in": 300}
        )
        client = _ADMIN_CLIENTS[lane](_cfg(wire.url), admin=admin)
        act = (lambda c: c.users.get("u1")) if path == "리소스" else _raw_get(lane, admin)
        result, err = await _attempt(lane, client, act)
        await _close(lane, client)

    assert wire.grant_types() == []
    if _rule(token) is not None:  # 보낸다 — 다듬은 값으로 바꿔 싣는다
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [_bearer(token)]
        return
    assert result is None
    assert _refused(err, _SEND, boundary=path == "리소스", sent_from_raw=True) == []
    assert wire.admin_requests() == [], "주입된 admin 이 규칙에 맞지 않는 bearer 를 보냈다"


@pytest.mark.parametrize("case", ["NUL", "trailing LF"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_set_on_the_live_connection_is_judged_before_sending(
    lane: str, case: str
) -> None:
    """토큰 세터도 공개다 — 생성 뒤에 실린 bearer 도 보내기 직전에 본다(거부하거나 다듬어
    싣는다)."""
    token = _CASES[case]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(GOOD)]
        async with _client(lane, wire) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            client.admin.raw.connection.token = {"access_token": token, "expires_in": 300}
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    if _rule(token) is not None:
        assert (result, err) == ({"id": "u1"}, None)
        assert wire.admin_requests() == [_bearer(GOOD), _bearer(token)]
        return
    assert result is None
    assert _refused(err, _SEND, boundary=True) == []
    assert wire.admin_requests() == [_bearer(GOOD)]


async def test_both_lanes_send_the_bearer_one_rule_settled() -> None:
    """판정은 레인과 무관하다 — sync 그랜트가 받아 다듬은 토큰(끝 SP)을 같은 admin 의 `a_*` 메서드로
    보내도 같은 값이 나간다. 예전에는 sync 가 끝 SP 를 그대로 싣고 aio 는 그 헤더를 거부했다."""
    token = _CASES["trailing SP"]
    with _wire() as wire:
        wire.grants["client_credentials"] = [_grant(token)]
        async with _client("sync", wire) as client:
            first, err = await _attempt("sync", client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "sync 가 보내지 않았다"
            raw = client.admin.raw
            result, err = await _attempt("aio", client, lambda _c: raw.a_get_user("u1"))
            await raw.connection.aclose()  # sync 클라이언트의 close 는 async 세션을 못 닫는다

    assert (result, err) == ({"id": "u1"}, None)
    assert wire.admin_requests() == [_bearer(token)] * 2
    assert wire.grant_types() == ["client_credentials"]
