"""SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 요청 타임아웃 안에 다 읽힌다(등록부
response-read-deadline-divergent — python 칸, sync·aio).

읽기 타임아웃은 읽기 **하나**를 묶을 뿐이다. 공개 API(`KeycloakClient`·
`AsyncKeycloakClient`, 읽기 타임아웃 1 초)와 루프백의 날 소켓 서버로 레인을 잰다 — auth
토큰 · introspection · logout · JWKS · admin 의 자체 그랜트 · admin REST. 흘리는 것은
언제나 꼬리 10 바이트를 0.7 초마다 하나씩이다(읽기 타임아웃은 한 번도 차지 않는다):

1. 본문 — 머리와 본문 앞부분을 곧바로, 본문의 마지막 10 바이트를.
2. 틀 — 헤더 블록 · 청크 크기 줄 · 트레일러의 마지막 10 바이트를. http.client 호출
   하나(`send` 안의 머리 읽기 · urllib3 `read1` 안의 청크 틀) 안이라 본문 고리의 검사는
   그 호출이 끝난 뒤에야 본다.
3. TLS — 헤더 블록의 꼬리를 바이트마다 레코드 하나로(읽기 하나가 레코드 하나) · 머리를
   실은 레코드 **하나**의 마지막 10 바이트를(읽기 하나가 레코드가 찰 때까지 기다린다).

→ 마감(1 초) + 읽기 타임아웃 하나(1 초) + 여유 1 초 안에 `KeycloakTransportError` 다. 여유
1 초는 다른 빌드가 함께 도는 기계의 스레드 깨움 지연을 덮고, 그래도 수정 전(7 초 넘어서야
실패)과 4 초 넘게 떨어진다. 대조군: 멈춤(머리와 5 바이트 뒤 침묵 → 지금처럼 읽기
타임아웃 1 초 남짓에 실패) · 건강(상한 바로 아래 본문을 0.15 초 간격 네 조각으로 —
길이로도, KiB 청크 + 트레일러로도 → 성공) · 큰 admin 목록(2 MiB 청크 본문을 조각으로 →
성공 — admin 성공 본문에는 상한이 없다).

수정 전(실측 2026-10-29, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 ·
python-keycloak 7.1.1 · requests 2.34.2 · urllib3 2.7.0 · httpx 0.28.1): 본문 흘리기 sync
1,413~1,432 ms(PR #889 의 본문 고리) · aio 1,008~1,024 ms. 틀 흘리기 sync 열여섯 칸(레인
여섯과 자리 셋, logout 은 머리만)은 7,066~7,129 ms 뒤에야 실패했다 — 호출이 끝난 뒤 본문
고리가 마감을 봤다. aio 는 1,011~1,023 ms. TLS 레코드마다 한 바이트 7,105~7,129 ms · 레코드
하나 안의 흘리기는 수정 전에도 1,017~1,025 ms 에 실패(CPython 의 `_ssl` 읽기는 소켓
타임아웃을 호출 하나의 총량으로 쓴다 — ruby·JVM 과 다르다). 수정 뒤(`_internal/wire.py`
— 원문 읽기마다 앞뒤로 보고 읽기 하나를 남은 시간으로 묶는다): 흘리기는 전부 마감 그
자리(1,001~1,030 ms)에서 `KeycloakTransportError`.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import socket
import ssl
import threading
import time
from collections.abc import Callable, Iterator
from typing import Any

import httpx
import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.deadline import request_seconds, seconds, within
from keycloak_sdk.aio.client import AsyncKeycloakClient
from keycloak_sdk.client import KeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet, ValidatedToken
from tests.unit.conftest import server_tls

pytestmark = pytest.mark.usefixtures("fast_tls")

SDKS = ("sync", "aio")
READ_TIMEOUT = 1.0
#: 흘리는 간격 — 읽기 타임아웃의 0.7 배라 읽기 하나는 끝까지 차지 않는다.
GAP = 0.7 * READ_TIMEOUT
#: 흘리는 꼬리 바이트 수 — 수정 전에는 꼬리 바이트마다 간격 하나(7 초 남짓)가 걸렸다.
TAIL = 10
#: 마감 + 읽기 타임아웃 하나 + 여유 — 마감 직전에 시작한 읽기 하나는 읽기 타임아웃까지 갈 수 있다.
BOUND = READ_TIMEOUT + READ_TIMEOUT + 1.0
#: 멈춘 서버가 붙드는 시간 — 시험이 끝나면 서버를 닫아 풀어 준다.
HOLD = 30.0
CAP = 1_048_576  # 토큰 응답 상한(아홉 언어 같은 값)
JWKS_CAP = 51_200
ACCESS_TOKEN = "AT-deadline"
KEY = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
OC = "/realms/r/protocol/openid-connect"
TOKEN, INTROSPECT, LOGOUT, CERTS = (
    f"{OC}/token",
    f"{OC}/token/introspect",
    f"{OC}/logout",
    f"{OC}/certs",
)
USER = "/admin/realms/r/users/x"
#: 레인 → 흘리는 경로. `grant` 는 admin 호출의 자체 그랜트(중첩 세션), `admin` 은 그 REST 응답이다.
LANES = {
    "auth": TOKEN,
    "introspect": INTROSPECT,
    "logout": LOGOUT,
    "jwks": CERTS,
    "grant": TOKEN,
    "admin": USER,
}
#: #889 의 세 레인 — 본문·멈춤·건강은 이 셋을 잰다.
CORE = ("auth", "jwks", "admin")
OK, NO_CONTENT = b"200 OK", b"204 No Content"
CHUNKED = b"Transfer-Encoding: chunked\r\n"

#: (그 앞에 쉴 초, 쓸 바이트) — 서버가 응답 하나를 쓰는 순서.
Piece = tuple[float, bytes]
_NOT_FOUND: list[Piece] = [
    (0.0, b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"),
]


class _Idp:
    """날 HTTP/1.1 서버(평문 또는 TLS) — 경로(쿼리 앞)마다 응답 하나(`routes`). 연결 하나에 요청
    여럿. TLS 면 `conn.sendall` 하나가 레코드 하나다(16 KiB 이하)."""

    def __init__(self, tls: ssl.SSLContext | None = None) -> None:
        self.sock = socket.create_server(("127.0.0.1", 0))
        scheme = "https" if tls is not None else "http"
        self.url = f"{scheme}://127.0.0.1:{self.sock.getsockname()[1]}"
        self.tls = tls
        self.routes: dict[str, list[Piece]] = {}
        self.stop = threading.Event()
        self._conns: list[socket.socket] = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self._conns.append(conn)
            threading.Thread(target=self._exchanges, args=(conn,), daemon=True).start()

    def _exchanges(self, conn: socket.socket) -> None:
        try:
            if self.tls is not None:
                conn = self.tls.wrap_socket(conn, server_side=True)
                self._conns.append(conn)
            reader = conn.makefile("rb")
            while line := reader.readline():
                path = line.split(b" ")[1].split(b"?")[0].decode("ascii")
                length = 0
                while (field := reader.readline()) not in (b"\r\n", b"\n", b""):
                    name, _, value = field.partition(b":")
                    if name.strip().lower() == b"content-length":
                        length = int(value)
                reader.read(length)
                for pause, data in self.routes.get(path, _NOT_FOUND):
                    if self.stop.wait(pause):
                        return
                    conn.sendall(data)
        except (OSError, ValueError):
            return
        finally:
            with contextlib.suppress(OSError):
                conn.close()

    def close(self) -> None:
        self.stop.set()
        with contextlib.suppress(OSError):
            self.sock.close()
        for conn in self._conns:
            with contextlib.suppress(OSError):
                conn.close()


@contextlib.contextmanager
def _idp(tls: ssl.SSLContext | None = None) -> Iterator[_Idp]:
    idp = _Idp(tls)
    try:
        yield idp
    finally:
        idp.close()


def _head(status: bytes, framing: bytes, extra: bytes = b"") -> bytes:
    return (
        b"HTTP/1.1 "
        + status
        + b"\r\nContent-Type: application/json\r\n"
        + framing
        + extra
        + b"\r\n"
    )


def _sized(length: int) -> bytes:
    return b"Content-Length: %d\r\n" % length


def _chunk(data: bytes) -> bytes:
    return b"%x\r\n" % len(data) + data + b"\r\n"


def _drip(data: bytes) -> list[Piece]:
    """`data` 를 `GAP` 초마다 한 바이트씩."""
    return [(GAP, data[i : i + 1]) for i in range(len(data))]


#: 응답의 모양 — (상태 줄, 본문) → 서버가 쓰는 순서.
Shape = Callable[[bytes, bytes], list[Piece]]


def _whole(status: bytes, body: bytes) -> list[Piece]:
    return [(0.0, _head(status, _sized(len(body))) + body)]


def _body_trickle(status: bytes, body: bytes) -> list[Piece]:
    """머리와 본문 앞부분은 곧바로, 본문의 마지막 `TAIL` 바이트는 `GAP` 초마다 하나씩."""
    cut = len(body) - TAIL
    return [(0.0, _head(status, _sized(len(body))) + body[:cut]), *_drip(body[cut:])]


def _header_trickle(status: bytes, body: bytes) -> list[Piece]:
    """헤더 블록의 마지막 `TAIL` 바이트(빈 줄까지)를 흘린다 — `send` 안의 머리 읽기다."""
    head = _head(status, _sized(len(body)), b"X-Trickle: 0123456789\r\n")
    return [(0.0, head[:-TAIL]), *_drip(head[-TAIL:]), (0.0, body)]


def _chunk_line_trickle(status: bytes, body: bytes) -> list[Piece]:
    """둘째 청크의 크기 줄(`0000000a\\r\\n` — 10 바이트)을 흘린다 — urllib3 `read1` 안이다."""
    first, last = body[:-TAIL], body[-TAIL:]
    line = b"%08x\r\n" % len(last)
    head = _head(status, CHUNKED) + _chunk(first)
    return [(0.0, head), *_drip(line), (0.0, last + b"\r\n0\r\n\r\n")]


def _trailer_trickle(status: bytes, body: bytes) -> list[Piece]:
    """마지막 청크 뒤 트레일러의 마지막 `TAIL` 바이트(빈 줄까지)를 흘린다 — urllib3 `read1`
    안이다."""
    trailer = b"X-Checksum: 0123456789\r\n\r\n"
    head = _head(status, CHUNKED) + _chunk(body) + b"0\r\n" + trailer[:-TAIL]
    return [(0.0, head), *_drip(trailer[-TAIL:])]


def _stall(status: bytes, body: bytes) -> list[Piece]:
    """머리와 5 바이트 뒤 침묵 — 서버가 닫힐 때까지."""
    return [(0.0, _head(status, _sized(len(body))) + body[:5]), (HOLD, b"")]


def _healthy(status: bytes, body: bytes) -> list[Piece]:
    """본문을 네 조각으로, 조각 사이 0.15 초 — 마감 안에 끝난다."""
    step = -(-len(body) // 4)
    parts = [body[i : i + step] for i in range(0, len(body), step)]
    return [(0.0, _head(status, _sized(len(body))) + parts[0])] + [(0.15, p) for p in parts[1:]]


def _healthy_chunked(status: bytes, body: bytes) -> list[Piece]:
    """4 KiB 청크 + 트레일러를 네 조각으로, 조각 사이 0.15 초 — 현실의 청크 틀은 틀 몫 안이다."""
    wire = b"".join(_chunk(body[i : i + 4096]) for i in range(0, len(body), 4096))
    wire = _head(status, CHUNKED) + wire + b"0\r\nX-Checksum: 0123456789\r\n\r\n"
    step = -(-len(wire) // 4)
    return [(0.0 if i == 0 else 0.15, wire[i : i + step]) for i in range(0, len(wire), step)]


FRAMES: dict[str, Shape] = {
    "header": _header_trickle,
    "chunk size line": _chunk_line_trickle,
    "trailer": _trailer_trickle,
}


def _padded(doc: Any, size: int) -> bytes:
    """`doc` 의 JSON 뒤에 공백(JSON 이 허용하는 뒤 공백)을 붙여 정확히 `size` 바이트로."""
    raw = json.dumps(doc).encode("ascii")
    assert len(raw) <= size
    return raw + b" " * (size - len(raw))


def _bodies(healthy: bool) -> dict[str, tuple[bytes, bytes]]:
    """경로마다 (상태, 쓸 수 있는 본문) — 건강 대조는 상한 바로 아래(토큰·admin 은 토큰 응답
    상한, JWKS 는 JWKS 상한). logout 은 204(본문 없음)다."""
    grant = {"access_token": ACCESS_TOKEN, "token_type": "Bearer", "expires_in": 300}
    active = {"active": True, "client_id": "c", "username": "u"}
    return {
        TOKEN: (OK, _padded(grant, CAP - 64 if healthy else 200)),
        INTROSPECT: (OK, _padded(active, CAP - 64 if healthy else 200)),
        LOGOUT: (NO_CONTENT, b""),
        CERTS: (
            OK,
            _padded({"keys": [KEY.as_dict(private=False)]}, JWKS_CAP - 64 if healthy else 1000),
        ),
        USER: (OK, _padded({"id": "x", "username": "alice"}, CAP - 64 if healthy else 100)),
    }


def _serve(idp: _Idp, lane: str, shape: Shape, healthy: bool = False) -> None:
    """재는 레인의 경로만 `shape` 로, 나머지(admin 의 자체 그랜트 등)는 곧바로 답한다."""
    for path, (status, body) in _bodies(healthy).items():
        idp.routes[path] = shape(status, body) if path == LANES[lane] else _whole(status, body)


def _config(url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret="s3cret", read_timeout=READ_TIMEOUT
    )


def _signed(url: str) -> str:
    claims = {"iss": f"{url}/realms/r", "aud": "c", "sub": "s", "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": "k1"}, claims, KEY)


def _sync(kc: KeycloakClient, lane: str, token: str) -> Any:
    if lane == "auth":
        return kc.auth.client_credentials_token()
    if lane == "introspect":
        return kc.auth.introspect("some-token")
    if lane == "logout":
        return kc.auth.logout("some-refresh-token") or "logged out"
    if lane == "jwks":
        return kc.auth.validate(token)
    return kc.admin.users.get("x")  # grant · admin


async def _aio(akc: AsyncKeycloakClient, lane: str, token: str) -> Any:
    if lane == "auth":
        return await akc.auth.client_credentials_token()
    if lane == "introspect":
        return await akc.auth.introspect("some-token")
    if lane == "logout":
        return await akc.auth.logout("some-refresh-token") or "logged out"
    if lane == "jwks":
        return await akc.auth.validate(token)
    return await akc.admin.users.get("x")


async def _call(sdk: str, lane: str, url: str) -> tuple[Any, BaseException | None, float]:
    """(결과, 오류, 걸린 초) — 공개 API 로 레인 하나를 부른다. admin 생성(네트워크
    없음)은 재지 않는다."""
    token = _signed(url)
    result: Any = None
    err: BaseException | None = None
    if sdk == "sync":
        with KeycloakClient.create(_config(url)) as kc:
            _ = kc.admin.raw
            start = time.monotonic()
            try:
                result = _sync(kc, lane, token)
            except Exception as exc:
                err = exc
            return result, err, time.monotonic() - start
    async with AsyncKeycloakClient.create(_config(url)) as akc:
        _ = akc.admin.raw
        start = time.monotonic()
        try:
            result = await _aio(akc, lane, token)
        except Exception as exc:
            err = exc
        return result, err, time.monotonic() - start


def _name(err: BaseException | None) -> str:
    return type(err).__name__ if err else "ok"


def _report(sdk: str, lane: str, shape: str, err: BaseException | None, elapsed: float) -> None:
    print(f"[ReadDeadline] {sdk} {lane} {shape} -> {_name(err)} | {elapsed * 1000:.0f} ms")


def _assert_late(err: BaseException | None, result: Any, elapsed: float) -> None:
    assert result is None and isinstance(err, KeycloakTransportError), (
        f"{_name(err)} after {elapsed:.2f} s — 흘린 응답을 마감 뒤에도 끝까지 기다렸다"
    )
    assert elapsed < BOUND, f"마감 + 읽기 타임아웃 하나를 넘겼다 — {elapsed:.2f} s"
    assert ACCESS_TOKEN not in str(err) and "alice" not in str(err), str(err)


def _assert_served(lane: str, result: Any) -> None:
    if lane == "auth":
        assert isinstance(result, TokenSet) and result.access_token == ACCESS_TOKEN
    elif lane == "introspect":
        assert isinstance(result, IntrospectionResult) and result.active
    elif lane == "jwks":
        assert isinstance(result, ValidatedToken) and result.subject == "s"
    else:
        assert result == {"id": "x", "username": "alice"}


@pytest.mark.parametrize("lane", CORE)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_trickled_response_fails_at_the_deadline(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _body_trickle)
        result, err, elapsed = await _call(sdk, lane, idp.url)
    _report(sdk, lane, "body", err, elapsed)
    _assert_late(err, result, elapsed)


#: (레인, 흘리는 자리) — logout 은 204 라 본문 틀이 없다(머리만).
_FRAMED = [
    (lane, frame) for lane in LANES for frame in FRAMES if lane != "logout" or frame == "header"
]


@pytest.mark.parametrize(("lane", "frame"), _FRAMED)
async def test_a_trickled_frame_fails_at_the_deadline(lane: str, frame: str) -> None:
    """머리·청크 크기 줄·트레일러는 http.client 호출 하나 안에서 읽힌다 — 마감은 그 안의 원문
    읽기마다 서야 한다(수정 전: 그 호출이 끝난 7 초 뒤에야 본문 고리의 검사가 실패시켰다)."""
    with _idp() as idp:
        _serve(idp, lane, FRAMES[frame])
        result, err, elapsed = await _call("sync", lane, idp.url)
    _report("sync", lane, frame, err, elapsed)
    _assert_late(err, result, elapsed)


@pytest.mark.parametrize("lane", CORE)
async def test_control_aio_already_bounds_a_trickled_header_block(lane: str) -> None:
    """aio 는 교환 전체를 `asyncio.wait_for` 로 묶는다(`deadline.within`) — 바꾸지 않았다."""
    with _idp() as idp:
        _serve(idp, lane, _header_trickle)
        result, err, elapsed = await _call("aio", lane, idp.url)
    _report("aio", lane, "header", err, elapsed)
    _assert_late(err, result, elapsed)


@pytest.mark.parametrize("lane", CORE)
async def test_over_tls_a_header_block_trickled_one_record_per_byte_fails_at_the_deadline(
    lane: str, tls_cert: tuple[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """레코드마다 한 바이트 — 읽기 하나가 레코드 하나라 TLS 아래에서도 읽기마다 봐야 선다."""
    monkeypatch.setenv("REQUESTS_CA_BUNDLE", tls_cert[0])  # SDK 는 verify=True — 이 CA 를 믿게
    with _idp(server_tls(tls_cert)) as idp:
        _serve(idp, lane, _header_trickle)
        result, err, elapsed = await _call("sync", lane, idp.url)
    _report("sync", lane, "TLS record per byte", err, elapsed)
    _assert_late(err, result, elapsed)


class _RecordIdp:
    """TLS 레코드를 손으로 싸는 서버(`ssl.MemoryBIO`) — 흘리는 경로의 응답 머리를 레코드 **하나**로
    싸서 그 마지막 `TAIL` 바이트를 `GAP` 초마다 하나씩 보낸다. 클라이언트는 레코드가 다 와야 그
    평문을 읽는다 — 읽기 하나가 레코드 하나를 기다린다."""

    def __init__(self, tls: ssl.SSLContext, routes: dict[str, tuple[bytes, bytes]], shaped: str):
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.url = f"https://127.0.0.1:{self.sock.getsockname()[1]}"
        self.tls, self.routes, self.shaped = tls, routes, shaped
        self.stop = threading.Event()
        self._conns: list[socket.socket] = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self._conns.append(conn)
            threading.Thread(target=self._exchanges, args=(conn,), daemon=True).start()

    def _exchanges(self, conn: socket.socket) -> None:
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = self.tls.wrap_bio(incoming, outgoing, server_side=True)

        def flush() -> None:
            if data := outgoing.read():
                conn.sendall(data)

        def fill() -> None:
            data = conn.recv(65536)
            if not data:
                raise EOFError
            incoming.write(data)

        def recv() -> bytes:
            while True:
                try:
                    return tls.read(65536)
                except ssl.SSLWantReadError:
                    flush()
                    fill()

        try:
            while True:
                try:
                    tls.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    flush()
                    fill()
            flush()
            buf = b""
            while True:
                while b"\r\n\r\n" not in buf:
                    if not (got := recv()):
                        return
                    buf += got
                head, _, buf = buf.partition(b"\r\n\r\n")
                lines = head.split(b"\r\n")
                path = lines[0].split(b" ")[1].split(b"?")[0].decode("ascii")
                length = 0
                for line in lines[1:]:
                    name, _, value = line.partition(b":")
                    if name.strip().lower() == b"content-length":
                        length = int(value)
                while len(buf) < length:
                    buf += recv()
                buf = buf[length:]
                status, body = self.routes.get(path, (b"404 Not Found", b""))
                if path != self.shaped:
                    tls.write(_head(status, _sized(len(body))) + body)
                    flush()
                    continue
                tls.write(_head(status, _sized(len(body)), b"X-Trickle: 0123456789\r\n"))
                record = (
                    outgoing.read()
                )  # 머리를 실은 레코드(그 앞에 TLS 1.3 세션 티켓이 있을 수 있다)
                conn.sendall(record[:-TAIL])
                for i in range(len(record) - TAIL, len(record)):
                    if self.stop.wait(GAP):
                        return
                    conn.sendall(record[i : i + 1])
                tls.write(body)
                flush()
        except (OSError, EOFError, ssl.SSLError, ValueError):
            return
        finally:
            with contextlib.suppress(OSError):
                conn.close()

    def close(self) -> None:
        self.stop.set()
        with contextlib.suppress(OSError):
            self.sock.close()
        for conn in self._conns:
            with contextlib.suppress(OSError):
                conn.close()


@pytest.mark.parametrize("lane", CORE)
async def test_over_tls_a_record_trickled_byte_by_byte_fails_at_the_deadline(
    lane: str, tls_cert: tuple[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """레코드 하나의 바이트를 흘린다 — 읽기 하나 안의 기다림이다. ruby 는 그 기다림이 버퍼 채우기
    하나 안에서 이어져(읽기 시도마다 새 타임아웃) 22.9 초 뒤 성공했다. CPython 의 `_ssl` 읽기는
    소켓 타임아웃을 호출 하나의 총량으로 쓰므로 여기서는 수정 전에도 읽기 타임아웃에 실패했다 —
    이 시험은 그 경계와 SDK 의 묶기(읽기 하나를 남은 시간으로)가 함께 마감을 넘기지 않음을 잰다."""
    monkeypatch.setenv("REQUESTS_CA_BUNDLE", tls_cert[0])
    routes = _bodies(healthy=False)
    idp = _RecordIdp(server_tls(tls_cert), routes, LANES[lane])
    try:
        result, err, elapsed = await _call("sync", lane, idp.url)
    finally:
        idp.close()
    _report("sync", lane, "TLS inside one record", err, elapsed)
    _assert_late(err, result, elapsed)


@pytest.mark.parametrize("lane", CORE)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_stalled_response_still_fails_at_the_read_timeout(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _stall)
        result, err, elapsed = await _call(sdk, lane, idp.url)
    _report(sdk, lane, "stall", err, elapsed)
    assert result is None and isinstance(err, KeycloakTransportError), repr(err)
    assert 0.8 * READ_TIMEOUT <= elapsed < READ_TIMEOUT + 1.0, f"{elapsed:.2f} s"


@pytest.mark.parametrize(
    ("timeout", "expected"),
    [(5, 5.0), (2.5, 2.5), ((3, 7.5), 7.5), (None, None), ((1, 2, 3), None), ("5", None)],
)
def test_the_deadline_length_is_the_timeout_the_lane_reads_with(
    timeout: object, expected: float | None
) -> None:
    # python-keycloak 은 수 하나를 넘긴다 — requests 의 (연결, 읽기) 쌍이면 읽기 쪽이 마감이다.
    assert seconds(timeout) == expected


def test_the_aio_deadline_length_is_the_read_timeout_on_the_request() -> None:
    timed = httpx.Request("GET", "http://idp.test/", extensions={"timeout": {"read": 4}})
    assert request_seconds(timed) == 4.0
    assert request_seconds(httpx.Request("GET", "http://idp.test/")) is None


async def test_an_aio_deadline_ends_the_exchange_with_a_read_timeout() -> None:
    async def slow() -> str:
        await asyncio.sleep(5)
        return "late"  # 마감이 먼저다

    async def quick() -> str:
        return "on time"

    assert await within(None, quick()) == "on time"
    assert await within(5, quick()) == "on time"
    start = time.monotonic()
    with pytest.raises(httpx.ReadTimeout, match=r"not fully read within 0.2 s"):
        await within(0.2, slow())
    assert time.monotonic() - start < 2


@pytest.mark.parametrize("lane", CORE)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_healthy_response_under_the_cap_is_not_cut(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _healthy, healthy=True)
        result, err, elapsed = await _call(sdk, lane, idp.url)
    _report(sdk, lane, "healthy", err, elapsed)
    assert err is None, f"{err!r} after {elapsed:.2f} s"
    _assert_served(lane, result)


@pytest.mark.parametrize("lane", ["auth", "introspect", "jwks", "grant", "admin"])
async def test_a_healthy_chunked_response_under_the_cap_is_not_cut(lane: str) -> None:
    """상한 바로 아래 본문을 4 KiB 청크 + 트레일러로, 네 조각에 — 틀이 예산의 틀 몫 안이다."""
    with _idp() as idp:
        _serve(idp, lane, _healthy_chunked, healthy=True)
        result, err, elapsed = await _call("sync", lane, idp.url)
    _report("sync", lane, "healthy chunked", err, elapsed)
    assert err is None, f"{err!r} after {elapsed:.2f} s"
    _assert_served(lane, result)


async def test_a_large_admin_list_is_read_whole() -> None:
    """admin 의 성공 본문에는 상한이 없다 — 2 MiB 넘는 목록(토큰 응답 예산의 두 배 남짓)을
    8 KiB 청크로, 네 조각에 받아도 그대로 읽는다(예산은 상태를 본 뒤 풀린다)."""
    users = [{"id": f"u{i}", "username": f"user-{i:07d}", "pad": "p" * 64} for i in range(20_000)]
    body = json.dumps(users).encode("ascii")
    assert len(body) > 2 * CAP
    wire = b"".join(_chunk(body[i : i + 8192]) for i in range(0, len(body), 8192))
    wire = _head(OK, CHUNKED) + wire + b"0\r\n\r\n"
    step = -(-len(wire) // 4)
    pieces = [(0.0 if i == 0 else 0.15, wire[i : i + step]) for i in range(0, len(wire), step)]
    with _idp() as idp:
        _serve(idp, "admin", _whole)
        idp.routes["/admin/realms/r/users"] = pieces
        with KeycloakClient.create(_config(idp.url)) as kc:
            start = time.monotonic()
            got = kc.admin.users.search()  # 쪽 하나(`first`·`max`) — 서버는 쿼리 앞의 경로로 답한다
            elapsed = time.monotonic() - start
    took = f"{elapsed * 1000:.0f} ms"
    print(f"[ReadDeadline] sync admin list {len(body)} B -> {len(got)} users | {took}")
    assert got == users
