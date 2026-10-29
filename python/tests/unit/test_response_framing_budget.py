"""응답 하나가 소켓에서 읽히는 바이트는 그 응답 종류의 본문 상한 + 틀 몫(65,536)까지다
(등록부 response-framing-unbounded — python sync 의 F3a 칸).

http.client 는 틀 줄 **하나**를 65,536 바이트에서 끊지만(`LineTooLong` — F1 헤더 한 줄 ·
F2 청크 확장 · F3b 트레일러 한 줄) 트레일러 **줄 수**는 세지 않는다. 4 KiB 트레일러 줄
4,096 개(16 MiB — F3a)를 보내는 서버 앞에서 sync 는 그것을 끝까지 읽고 받아들였다
(2026-10-09 실측 — 할당은 0.04 MB 로 평탄, 읽기만 끝이 없다). 공개 API(읽기 타임아웃 5 초
— 16 MiB 를 루프백으로 다 받는 시간보다 넉넉하다)와 날 소켓 서버로 레인마다 잰다. 읽은
바이트는 클라이언트의 원문 읽기(`socket.SocketIO.readinto`)를 세어 얻는다 — 서버는
`recv` 로 읽어 그 셈에 들지 않는다.

예산(본문 상한 + 65,536): 토큰·introspection·admin 자체 그랜트·admin 오류 본문
1,114,112 · JWKS 116,736. admin 의 **성공** 본문에는 상한이 없다 — 상태를 본 뒤 예산이
풀린다(대조군: 같은 16 MiB 트레일러를 끝까지 읽고 받아들인다 · 같은 바이트를 본문으로
보내도 받아야 하는 응답이라 틀만 따로 묶어도 바이트를 묶지 못한다). aio(httpx·h11)는
h11 이 이 틀을 거부한다(대조군 — 바꾸지 않았다).

수정 전(실측 2026-10-29, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 · requests
2.34.2 · urllib3 2.7.0 · httpx 0.28.1 · h11 0.16.0): sync 다섯 레인이 전부 16,777,357~
16,777,724 바이트를 끝까지 읽고 받아들였다(admin 오류는 404 `KeycloakNotFoundError` 그대로).
aio 는 131,211~131,578 바이트에서 거부. 수정 뒤: sync 는 예산 + 1 바이트(1,114,113 ·
JWKS 116,737 — admin 오류 레인은 앞선 그랜트 응답 144 바이트를 더해 1,114,257)를 읽은
자리에서 `KeycloakTransportError`.
"""

from __future__ import annotations

import contextlib
import http.client
import io
import json
import socket
import threading
import time
from collections.abc import Callable, Iterator
from typing import Any

import pytest
from httpcore._backends.anyio import AnyIOStream
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey
from keycloak.connection import ConnectionManager

from keycloak_sdk.aio.client import AsyncKeycloakClient
from keycloak_sdk.client import KeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakNotFoundError, KeycloakTransportError

pytestmark = pytest.mark.usefixtures("fast_tls")

READ_TIMEOUT = 5.0
FRAMING = 65_536
TOKEN_BUDGET = 1_048_576 + FRAMING
JWKS_BUDGET = 51_200 + FRAMING
#: F3a — 4 KiB 트레일러 줄 4,096 개(줄 하나는 http.client 의 줄 한도 65,536 안이다).
LINES, LINE = 4096, 4096


def _http_client_limits_trailer_count() -> bool:
    """이 CPython 의 http.client 가 트레일러 **줄 수**를 묶는가 — 판 번호가 아니라 동작으로 묻는다.

    최근 보안 패치 판(CI 실측 2026-10-29: 3.10.22 · 3.11.17 · 3.12.15 · 3.13.17 · 3.14.9)은 100 개를
    넘으면 `HTTPException("got more than 100 trailers")` 이고, 그 전 판(로컬 3.13.11 · WSL 3.12.3)은
    끝까지 읽는다. 그 판에서는 F3a 를 SDK 예산보다 먼저 http.client 가 끊는다."""
    raw = (
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n"
        + b"X-T: y\r\n" * 101
        + b"\r\n"
    )

    class _Wire:
        def makefile(self, *_args: Any, **_kwargs: Any) -> io.BytesIO:
            return io.BytesIO(raw)

    response = http.client.HTTPResponse(_Wire())  # type: ignore[arg-type]
    response.begin()
    try:
        response.read()
    except http.client.HTTPException:
        return True
    return False


HTTP_CLIENT_LIMITS_TRAILERS = _http_client_limits_trailer_count()
ACCESS_TOKEN = "AT-framing"
KEY = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
OC = "/realms/r/protocol/openid-connect"
TOKEN, INTROSPECT, CERTS = f"{OC}/token", f"{OC}/token/introspect", f"{OC}/certs"
USER = "/admin/realms/r/users/x"
GRANT = {"access_token": ACCESS_TOKEN, "token_type": "Bearer", "expires_in": 300}
BODIES = {
    TOKEN: json.dumps(GRANT).encode(),
    INTROSPECT: json.dumps({"active": True, "client_id": "c", "username": "u"}).encode(),
    CERTS: json.dumps({"keys": [KEY.as_dict(private=False)]}).encode(),
    USER: json.dumps({"id": "x", "username": "alice"}).encode(),
}
#: 레인 → (흘리는 경로, 그 응답의 상태 줄, 예산).
LANES: dict[str, tuple[str, bytes, int]] = {
    "auth": (TOKEN, b"200 OK", TOKEN_BUDGET),
    "introspect": (INTROSPECT, b"200 OK", TOKEN_BUDGET),
    "jwks": (CERTS, b"200 OK", JWKS_BUDGET),
    "grant": (TOKEN, b"200 OK", TOKEN_BUDGET),
    "admin error": (USER, b"404 Not Found", TOKEN_BUDGET),
}
#: 다른 응답(admin 오류 레인의 자체 그랜트)이 함께 읽히는 몫.
OTHERS = 1024
_SLAB = 64 << 10


def _trailers() -> bytes:
    """F3a 의 트레일러 — 4,096 바이트 줄 4,096 개와 끝의 빈 줄."""
    lines = []
    for i in range(LINES):
        name = b"X-Pad-%04d: " % i
        lines.append(name + b"a" * (LINE - len(name) - 2) + b"\r\n")
    return b"".join(lines) + b"\r\n"


TRAILERS = _trailers()


class _Idp:
    """날 HTTP/1.1 서버 — 요청은 `recv` 로 읽는다(클라이언트의 원문 읽기 셈에 들지 않게). `framed`
    경로는 (상태, 본문)을 청크로 보내고 그 뒤에 `TRAILERS` 를 64 KiB 씩 쓴다 — 클라이언트가 끊으면
    거기서 멈추고, 쓴 바이트를 `written` 에 남긴다."""

    def __init__(self, framed: str, status: bytes) -> None:
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.url = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.framed, self.status = framed, status
        self.written = 0
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
        buf = b""
        try:
            while True:
                while b"\r\n\r\n" not in buf:
                    if not (got := conn.recv(65536)):
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
                    buf += conn.recv(65536)
                buf = buf[length:]
                body = BODIES.get(path, b"")
                if path != self.framed:
                    status = b"200 OK" if path in BODIES else b"404 Not Found"
                    conn.sendall(b"HTTP/1.1 %s\r\nContent-Type: application/json\r\n" % status)
                    conn.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
                    continue
                conn.sendall(
                    b"HTTP/1.1 %s\r\nContent-Type: application/json\r\n"
                    b"Transfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n"
                    % (self.status, len(body), body)
                )
                for i in range(0, len(TRAILERS), _SLAB):
                    conn.sendall(TRAILERS[i : i + _SLAB])
                    self.written += len(TRAILERS[i : i + _SLAB])
        except OSError:
            return  # 클라이언트가 예산에서 끊었다 — 예산이 작동한 증거다
        finally:
            with contextlib.suppress(OSError):
                conn.close()

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.sock.close()
        for conn in self._conns:
            with contextlib.suppress(OSError):
                conn.close()


@contextlib.contextmanager
def _idp(framed: str, status: bytes) -> Iterator[_Idp]:
    idp = _Idp(framed, status)
    try:
        yield idp
    finally:
        idp.close()


@pytest.fixture
def read_bytes(monkeypatch: pytest.MonkeyPatch) -> list[int]:
    """클라이언트가 소켓에서 읽은 바이트 — 원문 읽기(`SocketIO.readinto`) 하나하나의 합."""
    seen = [0]
    plain = socket.SocketIO.readinto

    def counted(self: socket.SocketIO, buffer: Any) -> int | None:
        got = plain(self, buffer)
        seen[0] += got or 0
        return got

    monkeypatch.setattr(socket.SocketIO, "readinto", counted)
    return seen


@pytest.fixture
def aio_read_bytes(monkeypatch: pytest.MonkeyPatch) -> list[int]:
    """aio(httpcore 의 anyio 스트림)가 읽은 바이트."""
    seen = [0]
    plain = AnyIOStream.read

    async def counted(self: AnyIOStream, max_bytes: int, timeout: float | None = None) -> bytes:
        got = await plain(self, max_bytes, timeout)
        seen[0] += len(got)
        return got

    monkeypatch.setattr(AnyIOStream, "read", counted)
    return seen


def _config(url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret="s3cret", read_timeout=READ_TIMEOUT
    )


def _signed(url: str) -> str:
    claims = {"iss": f"{url}/realms/r", "aud": "c", "sub": "s", "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": "k1"}, claims, KEY)


_SYNC: dict[str, Callable[[KeycloakClient, str], Any]] = {
    "auth": lambda kc, _t: kc.auth.client_credentials_token(),
    "introspect": lambda kc, _t: kc.auth.introspect("some-token"),
    "jwks": lambda kc, token: kc.auth.validate(token),
    "grant": lambda kc, _t: kc.admin.users.get("x"),
    "admin error": lambda kc, _t: kc.admin.users.get("x"),
    "admin": lambda kc, _t: kc.admin.users.get("x"),
}


def _call_sync(lane: str, url: str) -> tuple[Any, BaseException | None, float]:
    token = _signed(url)
    with KeycloakClient.create(_config(url)) as kc:
        _ = kc.admin.raw
        start = time.monotonic()
        try:
            return _SYNC[lane](kc, token), None, time.monotonic() - start
        except Exception as exc:
            return None, exc, time.monotonic() - start


async def _call_aio(lane: str, url: str) -> tuple[Any, BaseException | None, float]:
    token = _signed(url)
    async with AsyncKeycloakClient.create(_config(url)) as akc:
        _ = akc.admin.raw
        start = time.monotonic()
        try:
            if lane == "auth":
                result: Any = await akc.auth.client_credentials_token()
            elif lane == "introspect":
                result = await akc.auth.introspect("some-token")
            elif lane == "jwks":
                result = await akc.auth.validate(token)
            else:
                result = await akc.admin.users.get("x")
            return result, None, time.monotonic() - start
        except Exception as exc:
            return None, exc, time.monotonic() - start


def _report(sdk: str, lane: str, err: BaseException | None, read: int, elapsed: float) -> None:
    name = type(err).__name__ if err else "ok"
    print(f"[WireBudget] {sdk} {lane} F3a -> {name} | read {read} B | {elapsed * 1000:.0f} ms")


def _why(err: BaseException | None) -> str:
    """실패의 원인 사슬 전부(`__cause__`·`__context__`) — python-keycloak 은 `get` 에서 난 예외를
    무엇이든 「Can't connect to server」로 감싸므로, 대조군이 실패하면 그 아래를 봐야 한다."""
    chain: list[str] = []
    seen: set[int] = set()
    while err is not None and id(err) not in seen:
        seen.add(id(err))
        chain.append(f"{type(err).__module__}.{type(err).__qualname__}: {err}")
        err = err.__cause__ or err.__context__
    return " <- ".join(chain)


@pytest.mark.parametrize("lane", list(LANES))
def test_trailer_lines_past_the_wire_budget_fail_the_request(
    lane: str, read_bytes: list[int]
) -> None:
    path, status, budget = LANES[lane]
    with _idp(path, status) as idp:
        result, err, elapsed = _call_sync(lane, idp.url)
    _report("sync", lane, err, read_bytes[0], elapsed)
    assert result is None and isinstance(err, KeycloakTransportError), (
        f"{type(err).__name__ if err else 'ok'} after reading {read_bytes[0]} B — "
        "트레일러를 예산 너머까지 읽었다"
    )
    assert read_bytes[0] <= budget + 1 + OTHERS, (
        f"예산 {budget} 을 넘겨 {read_bytes[0]} B 를 읽었다"
    )
    assert str(len(TRAILERS)) not in str(err) and "aaaa" not in str(err), str(err)


def test_control_an_admin_success_body_has_no_wire_budget(
    read_bytes: list[int], monkeypatch: pytest.MonkeyPatch
) -> None:
    """admin 의 성공 본문은 바이트로 묶지 않는다(목록은 정당하게 크다) — 같은 F3a 를 SDK 예산이
    끊지 않는다. 트레일러 수를 묶지 않는 CPython 에서는 끝까지 읽고 받아들이고, 묶는 판에서는
    http.client 가 100 개째에서 끊는다(`HTTP_CLIENT_LIMITS_TRAILERS`) — 어느 쪽이든 끊은 것이 SDK
    예산이 아니다. 큰 목록을 끝까지 받는 대조는
    `test_response_read_deadline.py::test_a_large_admin_list_is_read_whole` 이다."""
    # SDK 경계(`lower.py`)는 하위 예외의 사슬을 일부러 떼므로, python-keycloak 이 감싸기 직전의
    # 원래 예외를 여기서 잡는다 — 누가 끊었는지는 그것이 말한다.
    lower: list[BaseException] = []
    plain = ConnectionManager.raw_get

    def spied(self: ConnectionManager, *args: Any, **kwargs: Any) -> Any:
        try:
            return plain(self, *args, **kwargs)
        except Exception as exc:
            lower.append(exc)
            raise

    monkeypatch.setattr(ConnectionManager, "raw_get", spied)
    with _idp(USER, b"200 OK") as idp:
        result, err, elapsed = _call_sync("admin", idp.url)
    _report("sync", "admin success", err, read_bytes[0], elapsed)
    why = f"{_why(err)} | lower: {_why(lower[0]) if lower else '-'}"
    if HTTP_CLIENT_LIMITS_TRAILERS:
        assert isinstance(err, KeycloakTransportError), why
        assert "got more than 100 trailers" in why, why  # 끊은 것은 http.client 다
        assert "on the wire" not in why, why  # SDK 예산의 문구가 아니다
        assert read_bytes[0] < TOKEN_BUDGET, read_bytes[0]
        return
    assert err is None, why
    assert result == {"id": "x", "username": "alice"}
    assert read_bytes[0] > len(TRAILERS), read_bytes[0]


@pytest.mark.parametrize("lane", list(LANES))
async def test_control_aio_rejects_the_same_trailers(lane: str, aio_read_bytes: list[int]) -> None:
    """aio(httpx·h11)는 이 틀을 h11 이 거부한다 — 교환은 `asyncio.wait_for` 안이다(바꾸지
    않았다)."""
    path, status, _budget = LANES[lane]
    with _idp(path, status) as idp:
        result, err, elapsed = await _call_aio(lane, idp.url)
    _report("aio", lane, err, aio_read_bytes[0], elapsed)
    assert result is None and isinstance(err, KeycloakTransportError), repr(err)
    assert aio_read_bytes[0] < TOKEN_BUDGET, aio_read_bytes[0]


def test_control_a_plain_admin_404_is_still_classified() -> None:
    """트레일러 없는 404 — 오류 분류(`KeycloakNotFoundError`)는 그대로다(예산이 오류 응답 자체를
    막는 것이 아니다). 이 서버는 모르는 경로에 404 + 빈 본문으로 답한다."""
    with (
        _idp("/nowhere", b"200 OK") as idp,
        KeycloakClient.create(_config(idp.url)) as kc,
        pytest.raises(KeycloakNotFoundError),
    ):
        kc.admin.users.get("nobody")
