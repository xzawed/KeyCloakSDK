"""SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 요청 타임아웃 안에 다 읽힌다(등록부
response-read-deadline-divergent — python 칸, sync·aio).

읽기 타임아웃은 읽기 **하나**를 묶을 뿐이다. 공개 API(`KeycloakClient`·
`AsyncKeycloakClient`, 읽기 타임아웃 1 초)와 루프백의 날 소켓 서버로 레인 셋(auth 토큰 ·
JWKS · admin)을 sync·aio 각각 잰다:

1. 흘리기 — 머리와 본문 앞부분을 곧바로 쓰고 마지막 10 바이트를 0.7 초마다 하나씩 쓴다
   (읽기 타임아웃은 한 번도 차지 않는다) → 마감(1 초) + 읽기 타임아웃 하나(1 초) + 여유
   1 초 안에 `KeycloakTransportError` 다. 여유 1 초는 다른 빌드가 함께 도는 기계의 스레드
   깨움 지연을 덮고, 그래도 수정 전(7 초 넘어 성공)과 4 초 넘게 떨어진다.
2. 멈춤(대조) — 머리와 5 바이트 뒤 침묵 → 지금처럼 읽기 타임아웃(1 초 남짓)에 실패한다.
3. 건강(대조) — 상한 바로 아래 본문을 0.15 초 간격 네 조각으로(마감 안에 끝난다) →
   성공한다(거짓 마감 없음).

수정 전(실측 2026-10-29, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 ·
python-keycloak 7.1.1 · requests 2.34.2 · urllib3 2.7.0 · httpx 0.28.1): 흘리기 여섯 칸이
전부 7,046~7,100 ms 뒤 **성공**, 멈춤 1,007~1,027 ms `KeycloakTransportError`, 건강
471~511 ms 성공. 수정 뒤: 흘리기 sync 1,407~1,455 ms · aio 1,004~1,026 ms
`KeycloakTransportError`(sync 는 마감 뒤 첫 읽기에서, aio 는 마감 그 자리에서).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import socket
import threading
import time
from collections.abc import Callable, Iterator
from typing import Any

import httpx
import pytest
import requests
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.deadline import deadline, reader, request_seconds, seconds, within
from keycloak_sdk.aio.client import AsyncKeycloakClient
from keycloak_sdk.client import KeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError
from keycloak_sdk.tokens import TokenSet, ValidatedToken

pytestmark = pytest.mark.usefixtures("fast_tls")

SDKS = ("sync", "aio")
LANES = ("auth", "jwks", "admin")
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
REALM_PATH = "/realms/r/protocol/openid-connect"
PATHS = {
    "auth": f"{REALM_PATH}/token",
    "jwks": f"{REALM_PATH}/certs",
    "admin": "/admin/realms/r/users/x",
}

#: (그 앞에 쉴 초, 쓸 바이트) — 서버가 응답 하나를 쓰는 순서.
Piece = tuple[float, bytes]
_NOT_FOUND: list[Piece] = [
    (0.0, b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"),
]


class _Idp:
    """날 HTTP/1.1 서버 — 경로(쿼리 앞)마다 응답 하나(`routes`). 연결 하나에 요청 여럿."""

    def __init__(self) -> None:
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.url = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
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
        reader = conn.makefile("rb")
        try:
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
        except OSError:
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
def _idp() -> Iterator[_Idp]:
    idp = _Idp()
    try:
        yield idp
    finally:
        idp.close()


def _head(length: int) -> bytes:
    return (
        f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {length}\r\n\r\n"
    ).encode("ascii")


def _whole(body: bytes) -> list[Piece]:
    return [(0.0, _head(len(body)) + body)]


def _trickle(body: bytes) -> list[Piece]:
    """머리와 본문 앞부분은 곧바로, 마지막 `TAIL` 바이트는 `GAP` 초마다 하나씩."""
    cut = len(body) - TAIL
    return [(0.0, _head(len(body)) + body[:cut])] + [
        (GAP, body[i : i + 1]) for i in range(cut, len(body))
    ]


def _stall(body: bytes) -> list[Piece]:
    """머리와 5 바이트 뒤 침묵 — 서버가 닫힐 때까지."""
    return [(0.0, _head(len(body)) + body[:5]), (HOLD, b"")]


def _healthy(body: bytes) -> list[Piece]:
    """본문을 네 조각으로, 조각 사이 0.15 초 — 마감 안에 끝난다."""
    step = -(-len(body) // 4)
    parts = [body[i : i + step] for i in range(0, len(body), step)]
    return [(0.0, _head(len(body)) + parts[0])] + [(0.15, part) for part in parts[1:]]


def _padded(doc: dict[str, Any], size: int) -> bytes:
    """`doc` 의 JSON 뒤에 공백(JSON 이 허용하는 뒤 공백)을 붙여 정확히 `size` 바이트로."""
    raw = json.dumps(doc).encode("ascii")
    assert len(raw) <= size
    return raw + b" " * (size - len(raw))


def _bodies(healthy: bool) -> dict[str, bytes]:
    """레인마다 쓸 수 있는 본문 — 건강 대조는 상한 바로 아래(토큰·admin 은 토큰 응답
    상한, JWKS 는 JWKS 상한)."""
    return {
        "auth": _padded(
            {"access_token": ACCESS_TOKEN, "token_type": "Bearer", "expires_in": 300},
            CAP - 64 if healthy else 200,
        ),
        "jwks": _padded({"keys": [KEY.as_dict(private=False)]}, JWKS_CAP - 64 if healthy else 1000),
        "admin": _padded({"id": "x", "username": "alice"}, CAP - 64 if healthy else 100),
    }


def _serve(idp: _Idp, lane: str, shape: Callable[[bytes], list[Piece]], healthy: bool) -> None:
    """재는 레인의 경로만 `shape` 로, 나머지(admin 의 자체 그랜트 등)는 곧바로 답한다."""
    bodies = _bodies(healthy)
    for name, path in PATHS.items():
        idp.routes[path] = shape(bodies[name]) if name == lane else _whole(bodies[name])


def _config(url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret="s3cret", read_timeout=READ_TIMEOUT
    )


def _signed(url: str) -> str:
    claims = {"iss": f"{url}/realms/r", "aud": "c", "sub": "s", "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": "k1"}, claims, KEY)


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
                if lane == "auth":
                    result = kc.auth.client_credentials_token()
                elif lane == "jwks":
                    result = kc.auth.validate(token)
                else:
                    result = kc.admin.users.get("x")
            except Exception as exc:
                err = exc
            return result, err, time.monotonic() - start
    async with AsyncKeycloakClient.create(_config(url)) as akc:
        _ = akc.admin.raw
        start = time.monotonic()
        try:
            if lane == "auth":
                result = await akc.auth.client_credentials_token()
            elif lane == "jwks":
                result = await akc.auth.validate(token)
            else:
                result = await akc.admin.users.get("x")
        except Exception as exc:
            err = exc
        return result, err, time.monotonic() - start


def _name(err: BaseException | None) -> str:
    return type(err).__name__ if err else "ok"


def _report(sdk: str, lane: str, shape: str, err: BaseException | None, elapsed: float) -> None:
    print(f"[ReadDeadline] {sdk} {lane} {shape} -> {_name(err)} | {elapsed * 1000:.0f} ms")


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_trickled_response_fails_at_the_deadline(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _trickle, healthy=False)
        result, err, elapsed = await _call(sdk, lane, idp.url)
    _report(sdk, lane, "trickle", err, elapsed)
    assert result is None and isinstance(err, KeycloakTransportError), (
        f"{_name(err)} after {elapsed:.2f} s — 흘린 응답을 마감 뒤에도 끝까지 기다렸다"
    )
    assert elapsed < BOUND, f"마감 + 읽기 타임아웃 하나를 넘겼다 — {elapsed:.2f} s"
    assert ACCESS_TOKEN not in str(err) and "alice" not in str(err), str(err)


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_stalled_response_still_fails_at_the_read_timeout(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _stall, healthy=False)
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


def test_a_sync_deadline_refuses_reads_that_start_after_it() -> None:
    deadline(None)()  # 마감 없음
    deadline(60)()
    with pytest.raises(requests.ReadTimeout, match=r"not fully read within 0 s"):
        deadline(0)()


def test_a_sync_read_that_ends_after_the_deadline_is_refused() -> None:
    # 마감 전에 시작해 마감 뒤에 끝난 읽기(끝 — 빈 조각 — 이어도)의 결과는 쓰지 않는다. 청크
    # 트레일러를 흘리는 서버 앞에서 마지막 `read1` 하나가 그렇게 끝난다.
    class Late:
        def read1(self, amt: int, decode_content: bool) -> bytes:
            time.sleep(0.3)
            return b""

    response = requests.Response()
    response.raw = Late()
    with pytest.raises(requests.ReadTimeout):
        reader(response, deadline(0.1))(16, decode_content=False)
    assert reader(response, deadline(5))(16, decode_content=False) == b""


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


@pytest.mark.parametrize("lane", LANES)
@pytest.mark.parametrize("sdk", SDKS)
async def test_a_healthy_response_under_the_cap_is_not_cut(sdk: str, lane: str) -> None:
    with _idp() as idp:
        _serve(idp, lane, _healthy, healthy=True)
        result, err, elapsed = await _call(sdk, lane, idp.url)
    _report(sdk, lane, "healthy", err, elapsed)
    assert err is None, f"{err!r} after {elapsed:.2f} s"
    if lane == "auth":
        assert isinstance(result, TokenSet) and result.access_token == ACCESS_TOKEN
    elif lane == "jwks":
        assert isinstance(result, ValidatedToken) and result.subject == "s"
    else:
        assert result == {"id": "x", "username": "alice"}
