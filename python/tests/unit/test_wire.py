"""`_internal/wire.py` — 응답 버퍼 아래 원문 읽기마다의 마감·바이트 예산과, 그것을 SDK
세션의 연결마다 거는 자리(풀 관리자 → 풀 → 연결 → 응답).

공개 API 로 재는 레인 시험은 `test_response_read_deadline.py`(흘리기)와
`test_response_framing_budget.py`(F3a)다. 여기는 그 장치 자체 — 계량의 경계(마감 0 ·
예산 + 1 · 예산 풀기), 읽기를 남은 시간으로 묶고 되돌리기, 거는 자리마다 한 번만 걸기와
못 걸 때의 거부, 그리고 레인 시험이 밟지 않는 길 둘(HTTP 프록시 · CONNECT 터널)과 urllib3
자신의 청크 파서(`read_chunked` — 크기 줄을 길이 제한 없이 읽는다).
"""

from __future__ import annotations

import contextlib
import http.client
import socket
import threading
import time
from collections.abc import Iterator
from types import SimpleNamespace
from typing import Any

import pytest
import requests
import urllib3
from keycloak import KeycloakOpenID
from requests.adapters import BaseAdapter

from keycloak_sdk._internal import wire
from keycloak_sdk._internal.deadline import reader
from keycloak_sdk._internal.wire import FRAMING_ALLOWANCE_BYTES, exchange
from keycloak_sdk.exceptions import KeycloakConfigError

GAP = 0.7


# --- 계량 -----------------------------------------------------------------------------------


def _meter() -> Any:
    meter = wire._EXCHANGE.get()
    assert meter is not None, "교환 밖이다"
    return meter


def test_an_exchange_without_a_deadline_or_budget_meters_nothing() -> None:
    assert wire._EXCHANGE.get() is None
    with exchange(None, None) as (check, lift):
        left, room, charge = _meter()
        assert left() is None and room() is None
        charge(10**9)
        check()
        lift()
    assert wire._EXCHANGE.get() is None, "교환이 끝나면 문맥에서 내려온다"


def test_a_spent_deadline_refuses_the_read_and_the_body_loop_alike() -> None:
    with exchange(0, None) as (check, _lift):
        left, _room, charge = _meter()
        with pytest.raises(TimeoutError, match=r"not fully read within 0 s"):
            left()
        with pytest.raises(TimeoutError):
            charge(0)  # 마감 뒤에 끝난 읽기 — 빈 조각이어도 쓰지 않는다
        with pytest.raises(requests.ReadTimeout, match=r"not fully read within 0 s"):
            check()


def test_the_budget_takes_exactly_its_bytes_and_one_more_fails() -> None:
    with exchange(60, 10) as (check, lift):
        left, room, charge = _meter()
        assert 59 < (left() or 0) <= 60
        assert room() == 11  # 읽기 하나는 예산 + 1 까지만 청한다 — 넘은 것을 알 만큼
        charge(10)
        assert room() == 1
        with pytest.raises(http.client.HTTPException, match=r"exceeds 10 bytes on the wire"):
            charge(1)
        lift()  # 상한 없는 성공 본문 — 예산을 푼다
        assert room() is None
        charge(10**9)
        check()


def test_a_body_read_that_ends_after_the_deadline_is_refused() -> None:
    # 본문 고리(`deadline.reader`)도 같은 마감을 앞뒤로 본다 — 마감 전에 시작해 마감 뒤에 끝난
    # 읽기(끝 — 빈 조각 — 이어도)의 결과는 쓰지 않는다. 버퍼에 와 있던 바이트도, 원문 읽기 훅이
    # 닿지 않는 전송(HTTPAdapter 가 아닌 어댑터)의 본문도 이 검사가 묶는다.
    class Late:
        def read1(self, amt: int, decode_content: bool) -> bytes:
            time.sleep(0.3)
            return b""

    response = requests.Response()
    response.raw = Late()
    with exchange(0.1, None) as (check, _lift), pytest.raises(requests.ReadTimeout):
        reader(response, check)(16, decode_content=False)
    with exchange(5, None) as (check, _lift):
        assert reader(response, check)(16, decode_content=False) == b""


def test_exchanges_nest_and_unwind() -> None:
    with exchange(60, 100):
        outer = _meter()
        with exchange(60, 5):
            assert _meter() is not outer
        assert _meter() is outer


# --- 원문 읽기 하나 ---------------------------------------------------------------------------


class _Sock:
    """`gettimeout`·`settimeout` 을 적어 두는 소켓 흉내."""

    def __init__(self, timeout: float | None) -> None:
        self.timeout = timeout
        self.set: list[float | None] = []

    def gettimeout(self) -> float | None:
        return self.timeout

    def settimeout(self, value: float | None) -> None:
        self.set.append(value)
        self.timeout = value


def _metered(sock: _Sock, read: Any) -> Any:
    """지금 교환의 계량으로 감싼 원문 읽기 하나."""
    return wire._metered(read, sock, _meter())


def test_a_read_far_from_the_deadline_keeps_the_socket_timeout() -> None:
    sock, seen = _Sock(1.0), []

    def read(buffer: Any) -> int:
        seen.append(len(buffer))
        return 3

    with exchange(60, None):
        assert _metered(sock, read)(bytearray(8)) == 3
    assert sock.set == [] and seen == [8]


def test_a_read_near_the_deadline_is_bounded_by_what_is_left_and_restored() -> None:
    sock, during = _Sock(30.0), []

    def read(buffer: Any) -> int:
        during.append(sock.timeout)
        return 1

    with exchange(0.5, None):
        _metered(sock, read)(bytearray(8))
    assert during[0] is not None and 0 < during[0] <= 0.5, during
    assert sock.timeout == 30.0 and len(sock.set) == 2


def test_a_blocking_socket_is_bounded_by_the_deadline_too() -> None:
    sock = _Sock(None)
    with exchange(5, None):
        _metered(sock, lambda _b: 0)(bytearray(8))
    assert sock.set[0] is not None and sock.set[1] is None


def test_a_failed_read_still_restores_the_socket_timeout() -> None:
    sock = _Sock(30.0)

    def read(_buffer: Any) -> int:
        raise TimeoutError("timed out")

    with exchange(0.5, None), pytest.raises(TimeoutError):
        _metered(sock, read)(bytearray(8))
    assert sock.timeout == 30.0


def test_a_read_never_asks_for_more_than_the_budget_has_room_for() -> None:
    sock, seen = _Sock(1.0), []

    def read(buffer: Any) -> int:
        seen.append(len(buffer))
        buffer[: len(buffer)] = b"x" * len(buffer)
        return len(buffer)

    with exchange(60, 5):
        readinto = _metered(sock, read)
        assert readinto(bytearray(4)) == 4
        with pytest.raises(http.client.HTTPException):
            readinto(bytearray(8192))
    assert seen == [4, 2], "둘째 읽기는 남은 예산 + 1 바이트만 청한다"


def test_a_budgeted_read_asks_for_8_kib_however_large_the_buffer() -> None:
    # 3.14 의 응답 버퍼는 원문 읽기 하나로 131,072 바이트를 청한다(`io.DEFAULT_BUFFER_SIZE` —
    # 3.13 까지 8,192). 서버가 앞서 있으면 그만큼이 와서 http.client 가 쓰기 전에 예산에 오르고,
    # 그 몫이 틀 몫(65,536)보다 크다. 예산이 걸린 동안은 8 KiB 만 청한다 — 풀리면(`lift`) 그대로다.
    sock, seen = _Sock(1.0), []

    def read(buffer: Any) -> int:
        seen.append(len(buffer))
        return len(buffer)  # 서버가 한참 앞서 있다 — 청한 만큼 다 온다

    with exchange(60, 1_048_576 + FRAMING_ALLOWANCE_BYTES) as (_check, lift):
        readinto = _metered(sock, read)
        assert readinto(bytearray(131_072)) == 8_192
        lift()
        assert readinto(bytearray(131_072)) == 131_072
    with exchange(60, None):
        assert _metered(sock, read)(bytearray(131_072)) == 131_072
    assert seen == [8_192, 131_072, 131_072]


def test_a_non_blocking_read_that_got_nothing_charges_nothing() -> None:
    with exchange(60, 0):
        assert _metered(_Sock(1.0), lambda _b: None)(bytearray(8)) is None


# --- 거는 자리 ---------------------------------------------------------------------------------


def _response_with_raw() -> Any:
    raw = SimpleNamespace(readinto=lambda b: 0)
    return SimpleNamespace(fp=SimpleNamespace(raw=raw))


def test_a_response_made_outside_an_exchange_is_left_as_it_is() -> None:
    made = _response_with_raw()
    plain = made.fp.raw.readinto
    assert wire._respond(lambda *_a, **_k: made)(_Sock(1.0)) is made
    assert made.fp.raw.readinto is plain


def test_a_response_made_inside_an_exchange_reads_through_its_meter() -> None:
    made = _response_with_raw()
    plain = made.fp.raw.readinto
    with exchange(60, 100):
        wire._respond(lambda *_a, **_k: made)(_Sock(1.0), method="GET")
    assert made.fp.raw.readinto is not plain


def test_a_response_without_a_raw_reader_is_refused() -> None:
    with exchange(60, 100), pytest.raises(KeycloakConfigError, match=r"no raw socket reader"):
        wire._respond(lambda *_a, **_k: SimpleNamespace(fp=object()))(_Sock(1.0))


def test_a_checked_out_connection_reads_through_the_hook_once() -> None:
    conn = SimpleNamespace(response_class=http.client.HTTPResponse)
    checkout = wire._checked_out(lambda: conn)
    assert checkout() is conn
    hooked = conn.response_class
    assert getattr(hooked, wire._MARK) is True
    assert checkout() is conn and conn.response_class is hooked, "다시 내줄 때 겹쳐 감싸지 않는다"


def test_a_connection_without_a_response_class_is_refused() -> None:
    with pytest.raises(KeycloakConfigError, match=r"no response_class"):
        wire._checked_out(lambda: SimpleNamespace())()


def test_a_place_is_wrapped_once_and_a_missing_one_is_refused() -> None:
    pool = SimpleNamespace(
        _get_conn=lambda: SimpleNamespace(response_class=http.client.HTTPResponse)
    )
    wire._wrap(pool, "_get_conn", wire._checked_out, "here")
    first = pool._get_conn
    wire._wrap(pool, "_get_conn", wire._checked_out, "here")
    assert pool._get_conn is first
    with pytest.raises(KeycloakConfigError, match=r"to expose here"):
        wire._wrap(SimpleNamespace(), "_get_conn", wire._checked_out, "here")


def test_a_pool_manager_hands_out_pools_whose_connections_are_hooked() -> None:
    pool = SimpleNamespace(
        _get_conn=lambda: SimpleNamespace(response_class=http.client.HTTPResponse)
    )
    manager = SimpleNamespace(connection_from_pool_key=lambda *_a, **_k: pool)
    proxied = wire._proxied(lambda *_a, **_k: manager)
    assert proxied("http://proxy:3128") is manager
    assert manager.connection_from_pool_key("key") is pool
    assert getattr(pool._get_conn().response_class, wire._MARK) is True


def test_read_hooks_cover_every_http_adapter_and_skip_other_transports() -> None:
    class Mock(BaseAdapter):
        def send(self, *_a: Any, **_k: Any) -> Any:
            raise AssertionError("not used")

        def close(self) -> None:
            pass

    session = requests.Session()
    session.mount("mock://", Mock())
    proxy = session.adapters["https://"].proxy_manager_for("http://127.0.0.1:9")
    hooks = wire.read_hooks(session, "s")
    places = sorted(where for _t, _n, _w, where in hooks)
    assert places == sorted(
        [
            "s.adapters['https://'].poolmanager",
            "s.adapters['https://']",
            "s.adapters['https://'].proxy_manager['http://127.0.0.1:9']",
            "s.adapters['http://'].poolmanager",
            "s.adapters['http://']",
        ]
    ), places
    assert any(target is proxy for target, *_ in hooks), "이미 있는 프록시 관리자도 건다"
    session.close()


def test_read_hooks_refuse_a_session_without_an_adapter_table() -> None:
    with pytest.raises(KeycloakConfigError, match=r"transport adapters at s\.adapters"):
        wire.read_hooks(SimpleNamespace(), "s")


def test_bound_reads_installs_once_on_an_openid() -> None:
    openid = KeycloakOpenID(server_url="http://127.0.0.1:9", realm_name="r", client_id="c")
    session = openid.connection._s
    wire.bound_reads(openid)
    hooked = {
        prefix: vars(a.poolmanager)["connection_from_pool_key"]
        for prefix, a in session.adapters.items()
    }
    wire.bound_reads(openid)
    again = {
        prefix: vars(a.poolmanager)["connection_from_pool_key"]
        for prefix, a in session.adapters.items()
    }
    assert hooked == again and all(getattr(h, wire._MARK) for h in hooked.values())
    session.close()


def test_bound_reads_refuses_an_http_adapter_without_a_pool_manager() -> None:
    openid = KeycloakOpenID(server_url="http://127.0.0.1:9", realm_name="r", client_id="c")
    adapter = openid.connection._s.adapters["https://"]
    manager, adapter.poolmanager = adapter.poolmanager, None
    with pytest.raises(KeycloakConfigError, match=r"poolmanager\.connection_from_pool_key"):
        wire.bound_reads(openid)
    adapter.poolmanager = manager  # 닫을 수 있게 되돌린다(`HTTPAdapter.close` 가 그것을 비운다)
    openid.connection._s.close()


def test_the_framing_allowance_is_the_sister_lanes_value() -> None:
    # ruby `MAX_FRAMING_BYTES` · .NET 헤더+트레일러 한도 · Go 머리 블록 한도와 같다(모듈 머리말).
    assert FRAMING_ALLOWANCE_BYTES == 65_536


# --- 레인 시험이 밟지 않는 길 — 실제 requests 세션 -----------------------------------------------


class _Raw:
    """날 소켓 서버 — 요청 머리(요청 줄 포함)를 `recv` 로 다 읽고 `answer(요청 줄)` 이 돌려준 조각을
    쓴다((쉴 초, 바이트) — 시험이 끝나면 닫아 풀어 준다)."""

    def __init__(self, answer: Any) -> None:
        self.answer = answer
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self.lines: list[bytes] = []
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
            threading.Thread(target=self._one, args=(conn,), daemon=True).start()

    def _one(self, conn: socket.socket) -> None:
        buf = b""
        try:
            while b"\r\n\r\n" not in buf:
                if not (got := conn.recv(65536)):
                    return
                buf += got
            line = buf.split(b"\r\n", 1)[0]
            self.lines.append(line)
            for pause, data in self.answer(line):
                if self.stop.wait(pause):
                    return
                conn.sendall(data)
            self.stop.wait(30)
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
def _raw(answer: Any) -> Iterator[_Raw]:
    server = _Raw(answer)
    try:
        yield server
    finally:
        server.close()


def _hooked_session() -> requests.Session:
    session = requests.Session()
    session.trust_env = False  # 환경의 프록시를 쓰지 않는다 — 프록시는 시험이 준다
    wire.bound_reads(SimpleNamespace(connection=SimpleNamespace(_s=session)))
    return session


def _drip(data: bytes) -> list[tuple[float, bytes]]:
    return [(GAP, data[i : i + 1]) for i in range(len(data))]


_TRICKLED_HEAD = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Trickle: 0123456789\r\n\r\n"


def test_a_response_through_an_http_proxy_is_metered() -> None:
    """프록시 관리자(`proxy_manager_for`)가 내준 풀도 같다 — 머리 블록을 흘리는 프록시 앞에서."""

    def answer(_line: bytes) -> list[tuple[float, bytes]]:
        return [(0.0, _TRICKLED_HEAD[:-10]), *_drip(_TRICKLED_HEAD[-10:]), (0.0, b"{}")]

    with _raw(answer) as proxy:
        session = _hooked_session()
        start = time.monotonic()
        with exchange(1.0, 1000), pytest.raises(requests.ReadTimeout):
            session.get(
                "http://idp.invalid/x", timeout=1.0, stream=True, proxies={"http": proxy.url}
            )
        elapsed = time.monotonic() - start
        session.close()
    print(f"[Wire] http proxy trickled head -> ReadTimeout | {elapsed * 1000:.0f} ms")
    assert proxy.lines and proxy.lines[0].startswith(b"GET http://idp.invalid/x ")
    assert elapsed < 2.0, f"{elapsed:.2f} s"


def test_a_trickled_connect_response_is_metered_too() -> None:
    """CONNECT 터널의 응답도 연결의 `response_class` 로 읽힌다(http.client `_tunnel`) — 프록시가 그
    머리를 흘려도 마감에 끊는다. ruby 는 이 응답을 따로 묶어야 했다(`ConnectFraming`)."""
    tunnel = b"HTTP/1.1 200 Connection established\r\nX-Trickle: 0123456789\r\n\r\n"

    def answer(_line: bytes) -> list[tuple[float, bytes]]:
        return [(0.0, tunnel[:-10]), *_drip(tunnel[-10:])]

    with _raw(answer) as proxy:
        session = _hooked_session()
        start = time.monotonic()
        with exchange(1.0, 1000), pytest.raises(requests.RequestException):
            session.get(
                "https://idp.invalid/x", timeout=1.0, stream=True, proxies={"https": proxy.url}
            )
        elapsed = time.monotonic() - start
        session.close()
    print(f"[Wire] CONNECT trickled -> failed | {elapsed * 1000:.0f} ms")
    assert proxy.lines and proxy.lines[0].startswith(b"CONNECT idp.invalid:443 ")
    assert elapsed < 2.0, f"{elapsed:.2f} s"


#: 16 MiB 청크 확장 — http.client 는 줄 하나를 65,536 에서 끊지만(`LineTooLong`), urllib3
#: 자신의 청크 파서(`read_chunked` — `stream()`·`iter_content` 의 길)는 크기 줄을
#: `readline()` 으로 길이 제한 없이 읽는다(urllib3 2.7.0 `_update_chunk_length`).
_EXTENSION = 16 << 20

#: urllib3 2.8.0 부터는 그 크기 줄을 urllib3 가 스스로 65,536 에서 끊는다(CVE-2026-97689 의 수정 —
#: `response.py` `_MAX_CHUNK_LINE_LENGTH`). 대조군은 판에 따라 다른 것을 본다(아래 시험).
_URLLIB3_BOUNDS_CHUNK_LINE = tuple(int(p) for p in urllib3.__version__.split(".")[:2]) >= (2, 8)


def _extended() -> list[tuple[float, bytes]]:
    head = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;x="
    slab = b"e" * (1 << 20)
    return [(0.0, head)] + [(0.0, slab)] * (_EXTENSION >> 20) + [(0.0, b"\r\n{}\r\n0\r\n\r\n")]


def test_the_sdk_read_path_rejects_a_huge_chunk_extension_at_the_line_limit() -> None:
    """SDK 의 읽기(`reader` — urllib3 `read1`)는 http.client 의 청크 해석을 지난다 — 줄 한도에서
    끊는다(urllib3 판과 무관하다). 예산은 그보다 크다."""
    with _raw(lambda _l: _extended()) as server:
        session = _hooked_session()
        with exchange(5.0, 1_048_576 + FRAMING_ALLOWANCE_BYTES) as (check, _lift):
            response = session.get(server.url, timeout=5.0, stream=True)
            with pytest.raises(Exception, match=r"got more than 65536 bytes"):
                read = reader(response, check)
                while read(16_384, decode_content=False):
                    pass
        session.close()


@pytest.mark.parametrize("hooked", [True, False])
def test_urllib3s_own_chunk_parser_is_bounded_by_the_wire_budget(
    hooked: bool, monkeypatch: pytest.MonkeyPatch
) -> None:
    """urllib3 의 `read_chunked` 는 크기 줄을 길이 제한 없이 버퍼에 담는다 — 예산이 걸린
    교환에서는 예산 + 1 바이트를 읽은 자리에서 끊는다(파서가 무엇이든 원문 읽기는 이 모듈을
    지난다). 대조군(예산 없는 세션): urllib3 2.8.0 아래에서는 16 MiB 줄을 끝까지 읽고, 그
    위에서는 urllib3 가 스스로 끊는다(`_URLLIB3_BOUNDS_CHUNK_LINE`). 읽은 바이트는 계량
    아래(`SocketIO.readinto`)에서 센다 — 서버는 `recv` 로 읽어 그 셈에 들지 않는다."""
    budget = 1_048_576 + FRAMING_ALLOWANCE_BYTES
    seen = [0]
    plain = socket.SocketIO.readinto

    def counted(self: socket.SocketIO, buffer: Any) -> int | None:
        got = plain(self, buffer)
        seen[0] += got or 0
        return got

    monkeypatch.setattr(socket.SocketIO, "readinto", counted)
    with _raw(lambda _l: _extended()) as server:
        session = _hooked_session() if hooked else requests.Session()
        with exchange(5.0, budget):
            response = session.get(server.url, timeout=5.0, stream=True)
            try:
                body = b"".join(response.raw.stream(65_536, decode_content=False))
                error = None
            except Exception as exc:
                body, error = b"", exc
        session.close()
    outcome = type(error).__name__ if error else "ok"
    print(f"[Wire] urllib3 read_chunked 16 MiB extension hooked={hooked} -> {outcome}")
    print(f"[Wire] urllib3 read_chunked hooked={hooked} read {seen[0]} B")
    if hooked:
        assert error is not None and seen[0] <= budget + 1, seen[0]
    elif _URLLIB3_BOUNDS_CHUNK_LINE:
        # 2.8.0 이상: 예산 없는 세션에서도 urllib3 가 끊는다 — 끊은 것이 예산이 아니라
        # urllib3 다(예산보다 적게 읽고 urllib3 의 ProtocolError). 판정은 위의 hooked 칸이다.
        cut_by_urllib3 = isinstance(error, urllib3.exceptions.ProtocolError)
        assert cut_by_urllib3 and seen[0] < budget, (error, seen[0])
    else:
        assert error is None and body == b"{}" and seen[0] > _EXTENSION
