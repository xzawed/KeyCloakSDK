"""admin 이 쓰지 않는 응답 본문은 읽지 않는다 · 오류 본문은 상한까지만 쥔다(등록부
admin-response-body-unbounded — python 칸).

파사드의 쓰기 호출(다섯 리소스의 create·update·delete)이 받는 2xx 본문은 읽지 않고, 오류
상태(3xx 이상)의 본문은 1,048,576 바이트(토큰 응답 상한)에서 끊는다 — 그 밖의 성공 본문(목록
등)과 `raw` 로 부른 python-keycloak 메서드의 본문은 그대로다. sync(requests)와 aio(httpx) 두
레인을 같은 칸으로 잰다. 공개 API(`AdminClient`·`AsyncAdminClient` 에 토큰을 쥔
`KeycloakAdmin` 을 주입 — 그랜트 없음)와 로컬 루프백의 날 소켓 서버만 쓴다.

수정 전(실측 2026-10-25, 이 파일을 수정 전 코드에 — Windows · Python 3.13.11 ·
python-keycloak 7.1.1 · requests 2.34.2 · urllib3 2.7.0 · httpx 0.28.1, 두 레인 같다): 쓰기
열다섯의 2xx + 64 MiB 를 서버가 끝까지 썼고 · create 201 뒤 멈춘 서버 앞에서 읽기 타임아웃
4 초 끝에 KeycloakTransportError(4,008~4,019 ms) · get 404/300 + 64 MiB 는 keycloak_error 에
67,108,864 자를 실었고(호출 하나 최대 135~201 MB) · gzip 65,278 B 가 64 MiB 로 풀렸다.
"""

from __future__ import annotations

import base64
import contextlib
import datetime
import gzip
import ipaddress
import os
import socket
import ssl
import threading
import time
import tracemalloc
import zlib
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from keycloak import KeycloakAdmin

from keycloak_sdk._internal.admin_body import abounded_send, bounded_send
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakNotFoundError

from .test_admin_grant import LANES, _attempt

pytestmark = pytest.mark.usefixtures("fast_tls")

CAP = 1_048_576
HUGE = 64 << 20
#: 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼를 넉넉히 넘는다.
WRITTEN_BOUND = 16 << 20
#: 64 MiB 오류 본문 호출 하나의 할당 한도(tracemalloc 의 최대치).
ALLOCATION_BOUND = 16 << 20
USER = b'{"id":"x","username":"alice"}'
NOT_FOUND = b'{"error":"User not found"}'
TYPED = "Content-Type: application/json\r\n"
LOCATION = "Location: http://127.0.0.1:1/admin/realms/r/users/abc\r\n"
_SLAB = b" " * (64 << 10)

Reply = Callable[[socket.socket, "_Wire"], bool]


class _Wire:
    """날 HTTP/1.1 서버(평문 또는 TLS) — 연결 하나에 요청 여럿. 받아들인 연결 수 · 마지막
    응답이 쓴 본문 바이트 · 그 응답의 쓰기가 끝났는지 · 마지막 요청의 머리를 남긴다."""

    def __init__(
        self, route: Callable[[str, str], Reply], tls: ssl.SSLContext | None = None
    ) -> None:
        self.route = route
        self.tls = tls
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.url = f"{'https' if tls else 'http'}://127.0.0.1:{self.sock.getsockname()[1]}"
        self.conns = 0
        self.written = 0
        self.done = threading.Event()
        self.last_headers: dict[str, str] = {}
        self._open: list[socket.socket] = []
        self._lock = threading.Lock()
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with self._lock:
                self.conns += 1
                self._open.append(conn)
            threading.Thread(target=self._exchanges, args=(conn,), daemon=True).start()

    def _exchanges(self, conn: socket.socket) -> None:
        try:
            if self.tls is not None:
                conn = self.tls.wrap_socket(conn, server_side=True)
                with self._lock:
                    self._open.append(conn)
            reader = conn.makefile("rb")
            while True:
                line = reader.readline()
                if not line:
                    return
                method, target, _ = line.decode("latin-1").split(" ", 2)
                headers: dict[str, str] = {}
                while (field := reader.readline()) not in (b"\r\n", b"\n", b""):
                    name, _, value = field.decode("latin-1").partition(":")
                    headers[name.strip().lower()] = value.strip()
                if length := int(headers.get("content-length", "0")):
                    reader.read(length)
                self.last_headers = headers
                reply = self.route(method, target)
                self.written = 0
                self.done.clear()
                keep = reply(conn, self)
                self.done.set()
                if not keep:
                    return
        except (OSError, ValueError, ssl.SSLError):
            return
        finally:
            with contextlib.suppress(OSError):
                conn.close()

    def await_reply(self) -> bool:
        """마지막 응답의 쓰기가 끝날 때까지(최대 30 초) — 끝나지 않으면 거짓."""
        return self.done.wait(30)

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.sock.close()
        with self._lock:
            for conn in self._open:
                with contextlib.suppress(OSError):
                    conn.close()


@contextlib.contextmanager
def _wire(route: Callable[[str, str], Reply], tls: ssl.SSLContext | None = None) -> Iterator[_Wire]:
    wire = _Wire(route, tls)
    try:
        yield wire
    finally:
        wire.close()


def _send(conn: socket.socket, wire: _Wire, data: bytes) -> bool:
    """data 를 쓰고 쓴 본문 바이트를 센다 — 클라이언트가 끊으면 거짓."""
    view = memoryview(data)
    try:
        while view:
            n = conn.send(view)
            wire.written += n
            view = view[n:]
    except OSError:
        return False
    return True


def _head(conn: socket.socket, status: str, headers: str, length: int) -> bool:
    try:
        conn.sendall(f"HTTP/1.1 {status}\r\n{headers}Content-Length: {length}\r\n\r\n".encode())
    except OSError:
        return False
    return True


def _framed(status: str, headers: str, head: bytes, total: int, tail: bytes = b"") -> Reply:
    """head 와 tail 사이를 공백으로 채워 total 바이트를 쓴다 — `{"errorMessage":"` 와 `"}`
    사이를 채우면 통째로는 유효하고 잘리면 깨지는 JSON 이다."""

    def reply(conn: socket.socket, wire: _Wire) -> bool:
        if not (_head(conn, status, headers, total) and _send(conn, wire, head)):
            return False
        left = total - len(head) - len(tail)
        while left > 0:
            chunk = _SLAB[: min(left, len(_SLAB))]
            if not _send(conn, wire, chunk):
                return False
            left -= len(chunk)
        return _send(conn, wire, tail)

    return reply


def _padded(status: str, headers: str, head: bytes, total: int) -> Reply:
    return _framed(status, headers, head, total)


def _exact(status: str, headers: str, body: bytes) -> Reply:
    return _framed(status, headers, body, len(body))


def _no_length(status: str) -> Reply:
    """길이 머리 없는 본문 없는 답(204·304)."""

    def reply(conn: socket.socket, _wire: _Wire) -> bool:
        try:
            conn.sendall(f"HTTP/1.1 {status}\r\n\r\n".encode())
        except OSError:
            return False
        return True

    return reply


def _stalled(status: str, headers: str, sent: int) -> Reply:
    """1 MiB 를 알리고 공백 sent 바이트만 쓴 뒤 20 초 동안 붙든다."""

    def reply(conn: socket.socket, wire: _Wire) -> bool:
        if not (_head(conn, status, headers, CAP) and _send(conn, wire, _SLAB[:sent])):
            return False
        time.sleep(20)
        return False

    return reply


def _tls(tmp_path: Path) -> tuple[ssl.SSLContext, str]:
    """127.0.0.1 의 시험 인증서(실행마다 새로)와 그것을 믿는 CA 파일 — 저장소에 키를 두지
    않는다."""
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(hours=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
        .sign(key, hashes.SHA256())
    )
    cert_file, key_file = tmp_path / "cert.pem", tmp_path / "key.pem"
    cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_file.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert_file, key_file)
    return ctx, str(cert_file)


def _client(lane: str, url: str, timeout: float = 20, verify: bool | str = True) -> Any:
    admin = KeycloakAdmin(
        server_url=url,
        realm_name="r",
        token={"access_token": "good", "expires_in": 300},
        timeout=timeout,  # type: ignore[arg-type]
        verify=verify,
    )
    cfg = KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret="s")
    return (AdminClient if lane == "sync" else AsyncAdminClient)(cfg, admin=admin)


async def _close(lane: str, client: Any) -> None:
    if lane == "aio":
        await client.aclose()
    else:
        client.close()


def _create(client: Any) -> Any:
    return client.users.create({"username": "u"})


def _name(err: BaseException | None) -> str:
    return type(err).__name__ if err else "ok"


# (1) 파사드의 쓰기 호출 열다섯은 2xx 본문을 읽지 않는다 — 결과를 돌려주고 서버는 64 MiB 를
# 다 쓰지 못한다.
_WRITES: dict[str, Callable[[Any], Any]] = {
    "users.create": lambda c: c.users.create({"username": "u"}),
    "users.update": lambda c: c.users.update("x", {"username": "u"}),
    "users.delete": lambda c: c.users.delete("x"),
    "clients.create": lambda c: c.clients.create({"clientId": "c"}),
    "clients.update": lambda c: c.clients.update("x", {"clientId": "c"}),
    "clients.delete": lambda c: c.clients.delete("x"),
    "groups.create": lambda c: c.groups.create({"name": "g"}),
    "groups.update": lambda c: c.groups.update("x", {"name": "g"}),
    "groups.delete": lambda c: c.groups.delete("x"),
    "roles.create": lambda c: c.roles.create({"name": "ro"}),
    "roles.update": lambda c: c.roles.update("ro", {"name": "ro"}),
    "roles.delete": lambda c: c.roles.delete("ro"),
    "realms.create": lambda c: c.realms.create({"realm": "re"}),
    "realms.update": lambda c: c.realms.update("re", {"realm": "re"}),
    "realms.delete": lambda c: c.realms.delete("re"),
}


@pytest.mark.parametrize("call", sorted(_WRITES))
@pytest.mark.parametrize("lane", LANES)
async def test_facade_writes_read_no_2xx_body(lane: str, call: str) -> None:
    # create 는 201 + 64 MiB 를 받고 id 를 돌려준다. update·delete 는 200 + 64 MiB 를 받는다 —
    # python-keycloak 은 그 둘에 204 만 기대하므로 200 은 지금처럼 오류(KeycloakAdminError
    # 200)이되, 본문은 읽지 않는다. realms.create 는 수정 전에 201 의 JSON 본문을 해석하다
    # TypeError(KeycloakTransportError)였다 — 본문을 읽지 않으면 성공이다.
    def route(method: str, _target: str) -> Reply:
        if method == "POST":
            return _padded("201 Created", LOCATION + TYPED, b"{}", HUGE)
        return _padded("200 OK", TYPED, b"{}", HUGE)

    with _wire(route) as wire:
        client = _client(lane, wire.url)
        _, err = await _attempt(lane, client, _WRITES[call])
        await _close(lane, client)
        finished = wire.await_reply()
        print(f"[AdminResponseBody] {lane} {call} → {_name(err)} · server wrote {wire.written} B")
    if call.endswith(".create"):
        assert err is None, f"결과를 돌려주지 않았다: {err!r}"
    else:
        assert isinstance(err, KeycloakAdminError) and err.status_code == 200, repr(err)
    assert finished and wire.written <= WRITTEN_BOUND, (
        f"읽지 않는 본문을 읽었다 — server wrote {wire.written} B"
    )


# (2) 오류 본문은 상한까지만 쥔다 — 404 는 KeycloakNotFoundError 이고 서버는 다 쓰지 못하며
# 할당이 묶인다. 잘려서 깨지는 JSON 도 상태를 지킨다. 상한은 3xx 부터다(python-keycloak 은
# 기대 밖 3xx 를 오류로 본다).
_ERROR_ROWS = {
    "404 · 상한 안에서 닫히는 JSON": ("404 Not Found", NOT_FOUND, b""),
    "404 · 상한 너머로 이어지는 JSON": ("404 Not Found", b'{"errorMessage":"', b'"}'),
    "300": ("300 Multiple Choices", NOT_FOUND, b""),
}


@pytest.mark.parametrize("row", sorted(_ERROR_ROWS))
@pytest.mark.parametrize("lane", LANES)
async def test_error_bodies_are_held_only_up_to_the_cap(lane: str, row: str) -> None:
    status, head, tail = _ERROR_ROWS[row]
    with _wire(lambda _m, _t: _framed(status, TYPED, head, HUGE, tail)) as wire:
        client = _client(lane, wire.url)
        tracemalloc.start()
        try:
            result, err = await _attempt(lane, client, lambda c: c.users.get("x"))
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        await _close(lane, client)
        finished = wire.await_reply()
        body = getattr(err, "keycloak_error", None) or ""
        print(
            f"[AdminResponseBody] {lane} get {row} + 64 MiB → {_name(err)}"
            f" · keycloak_error {len(body)} 자 · peak {peak} B · server wrote {wire.written} B"
        )
    assert result is None and isinstance(err, KeycloakAdminError), repr(err)
    assert err.status_code == int(status[:3])
    if status.startswith("404"):
        assert isinstance(err, KeycloakNotFoundError)
    assert len(body) <= CAP, f"오류 본문을 상한 너머까지 실었다 — {len(body)} 자"
    assert finished and wire.written <= WRITTEN_BOUND, (
        f"오류 본문의 나머지를 읽었다 — server wrote {wire.written} B"
    )
    assert peak <= ALLOCATION_BOUND, f"할당이 한도를 넘었다 — {peak} B"


# 대조 — 상한 안의 오류 본문은 통째로 실리고, 한 바이트 넘으면 상한까지 잘린다(경계). 쓰기
# 호출(update)의 오류도 본문을 싣는다.
@pytest.mark.parametrize("total", [CAP, CAP + 1])
@pytest.mark.parametrize("lane", LANES)
async def test_error_body_at_the_cap_is_carried_whole(lane: str, total: int) -> None:
    def reply(_m: str, _t: str) -> Reply:
        return _padded("404 Not Found", "Content-Type: text/plain\r\n", b"missing", total)

    with _wire(reply) as wire:
        client = _client(lane, wire.url)
        _, err = await _attempt(lane, client, lambda c: c.users.update("x", {"username": "u"}))
        await _attempt(lane, client, lambda c: c.users.update("x", {"username": "u"}))
        await _close(lane, client)
        conns = wire.conns
    body = getattr(err, "keycloak_error", None) or ""
    print(
        f"[AdminResponseBody] {lane} update 404 {total} B → keycloak_error {len(body)} 자"
        f" · 두 번째 호출까지 연결 {conns}"
    )
    assert isinstance(err, KeycloakNotFoundError), repr(err)
    assert len(body) == CAP and body.startswith("missing"), (
        f"{total} B 본문 → {len(body)} 자(기대 {CAP})"
    )
    # 끝까지 읽은 오류 본문(정확히 상한)의 연결은 다시 쓰인다. 상한 + 1 바이트 본문은 상한 + 1 을
    # 읽는 순간 끝에 닿으므로 레인마다 갈린다(sync 는 그때 연결을 돌려주고 aio 는 끝 신호 전에
    # 멈춰 버린다) — 상한을 넘는 본문에서 끊는지는 위 오류 행이 서버가 쓴 양으로 잰다.
    if total == CAP:
        assert conns == 1, f"끝까지 읽은 오류 본문의 연결을 다시 쓰지 않았다 — 연결 {conns}"


# (3) 결과 뒤 멈춘 서버를 기다리지 않는다 — create 201(1 MiB 를 알린 본문)의 머리만 받은 뒤
# 읽기 타임아웃 4 초의 절반 안에 id 를 돌려준다. 본문 64 KiB 가 와 있다 · 한 바이트도 없다,
# 평문과 TLS 1.3 각각, 갈래마다 세 번.
@pytest.mark.parametrize("sent", [65536, 0])
@pytest.mark.parametrize("tls", [False, True])
@pytest.mark.parametrize("lane", LANES)
async def test_a_server_stalled_after_the_result_is_not_waited_for(
    lane: str, tls: bool, sent: int, tmp_path: Path
) -> None:
    ctx, ca = _tls(tmp_path) if tls else (None, None)
    for attempt in range(1, 4):
        with _wire(lambda _m, _t: _stalled("201 Created", LOCATION, sent), ctx) as wire:
            client = _client(lane, wire.url, timeout=4, verify=ca or True)
            start = time.monotonic()
            result, err = await _attempt(lane, client, _create)
            elapsed = time.monotonic() - start
            await _close(lane, client)
        print(
            f"[AdminResponseBody] {lane} {'TLS 1.3' if tls else '평문'} · 본문 {sent} B 뒤 멈춤"
            f" #{attempt} → {result!r} {_name(err)} · {elapsed * 1000:.0f} ms"
        )
        assert (result, err) == ("abc", None), f"결과를 돌려주지 않았다: {result!r} {err!r}"
        assert elapsed < 2, f"멈춘 서버를 기다렸다 — {elapsed * 1000:.0f} ms"


# 대조 — raw 로 부른 python-keycloak 메서드는 2xx 본문을 그대로 받는다: PUT 의 200 본문
# (update_client_management_permissions)과 201 본문(create_client_authz_resource).
@pytest.mark.parametrize("lane", LANES)
async def test_raw_calls_keep_their_bodies(lane: str) -> None:
    def route(method: str, _target: str) -> Reply:
        if method == "PUT":
            return _exact("200 OK", TYPED, b'{"enabled":true,"resource":"res-1"}')
        return _exact("201 Created", TYPED, b'{"name":"made"}')

    with _wire(route) as wire:
        client = _client(lane, wire.url)
        raw = client.raw
        if lane == "sync":
            perm = raw.update_client_management_permissions({"enabled": True}, "cid")
            made = raw.create_client_authz_resource(client_id="cid", payload={"name": "made"})
        else:
            perm = await raw.a_update_client_management_permissions({"enabled": True}, "cid")
            made = await raw.a_create_client_authz_resource(
                client_id="cid", payload={"name": "made"}
            )
        await _close(lane, client)
    assert perm == {"enabled": True, "resource": "res-1"}, perm
    assert made == {"name": "made"}, made


# 대조 — 성공 본문에는 상한을 걸지 않는다(정당하게 크다): 상한을 넘는 사용자 목록도 통째로
# 결합된다.
@pytest.mark.parametrize("lane", LANES)
async def test_a_success_body_past_the_cap_is_read_whole(lane: str) -> None:
    users = CAP // len(USER) + 1000
    body = b"[" + b",".join([USER] * users) + b"]"
    with _wire(lambda _m, _t: _exact("200 OK", TYPED, body)) as wire:
        client = _client(lane, wire.url)
        got, err = await _attempt(lane, client, lambda c: c.users.search("u", 0, users))
        await _close(lane, client)
    assert err is None and len(got) == users and len(body) > CAP, f"{len(got or [])} 명 {err!r}"


# 대조 — 끊긴 연결은 다시 쓰이지 않는다: 본문을 읽지 않은 create 다음의 get 은 새 연결에서
# 성공한다(연결 2).
@pytest.mark.parametrize("lane", LANES)
async def test_a_cut_connection_is_not_reused(lane: str) -> None:
    def route(method: str, _target: str) -> Reply:
        if method == "POST":
            return _padded("201 Created", LOCATION, b"", 16 << 20)
        return _exact("200 OK", TYPED, USER)

    with _wire(route) as wire:
        client = _client(lane, wire.url)
        created, err = await _attempt(lane, client, _create)
        assert (created, err) == ("abc", None), f"create: {created!r} {err!r}"
        got, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
        conns = wire.conns
    assert err is None and got == {"id": "x", "username": "alice"}, f"get: {got!r} {err!r}"
    assert conns == 2, f"끊긴 연결을 다시 썼거나 연결이 더 열렸다 — 연결 {conns}"


# 대조 — 끝까지 읽은 응답의 연결은 지금처럼 다시 쓰인다(create 201 빈 본문 · get · search ·
# update 204 · delete 204 가 연결 하나에서). 빈 본문의 쓰기 응답을 닫으면 다시 쓸 연결을 버린다.
@pytest.mark.parametrize("lane", LANES)
async def test_responses_read_to_their_end_keep_their_connection(lane: str) -> None:
    def route(method: str, target: str) -> Reply:
        if method == "POST":
            return _exact("201 Created", LOCATION, b"")
        if method in ("PUT", "DELETE"):
            return _no_length("204 No Content")  # 서버는 204 에 흔히 길이를 달지 않는다
        # 목록은 경로로 가른다 — get_user 도 쿼리(userProfileMetadata)를 단다.
        if target.split("?", 1)[0].endswith("/users"):
            return _exact("200 OK", TYPED, b"[" + USER + b"]")
        return _exact("200 OK", TYPED, USER)

    with _wire(route) as wire:
        client = _client(lane, wire.url)
        for act in (
            _create,
            lambda c: c.users.get("x"),
            lambda c: c.users.search("u", 0, 10),
            lambda c: c.users.update("x", {"username": "u"}),
            lambda c: c.users.delete("x"),
        ):
            _, err = await _attempt(lane, client, act)
            assert err is None, repr(err)
        await _close(lane, client)
        conns = wire.conns
    assert conns == 1, f"끝까지 읽은 응답의 연결을 다시 쓰지 않았다 — 연결 {conns}"


# 대조 — 오류 본문을 읽다 연결이 끊기면(알린 길이 100 · 10 바이트 뒤 닫힘) 전처럼
# KeycloakTransportError 다(본문은 버린다).
@pytest.mark.parametrize("lane", LANES)
async def test_an_error_body_cut_by_the_server_fails_as_a_transport_error(lane: str) -> None:
    def reply(conn: socket.socket, wire: _Wire) -> bool:
        if _head(conn, "404 Not Found", TYPED, 100):
            _send(conn, wire, b'{"error":"')
        return False

    with _wire(lambda _m, _t: reply) as wire:
        client = _client(lane, wire.url)
        result, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
    assert result is None and type(err).__name__ == "KeycloakTransportError", repr(err)


# 대조 — 둘 이상 겹친 압축(Content-Encoding: gzip, deflate)은 상한 안에서 풀 수 없으므로 풀지
# 않고 원문을 상한까지 싣는다 — 토큰 응답과 달리 거부하지 않는다: 답의 상태가 결과다.
@pytest.mark.parametrize("lane", LANES)
async def test_an_error_body_compressed_twice_is_carried_as_it_came(lane: str) -> None:
    def reply(_m: str, _t: str) -> Reply:
        return _exact("404 Not Found", TYPED + "Content-Encoding: gzip, deflate\r\n", b"as-it-came")

    with _wire(reply) as wire:
        client = _client(lane, wire.url)
        _, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
    assert isinstance(err, KeycloakNotFoundError) and err.keycloak_error == "as-it-came", repr(err)


# 대조 — 깨진 gzip 오류 본문(머리 뒤 쓰레기 + 64 MiB)은 전처럼 KeycloakTransportError 이고, 풀다 난
# 오류 뒤에도 연결을 끊는다 — 서버는 64 MiB 를 다 쓰지 못한다.
@pytest.mark.parametrize("lane", LANES)
async def test_a_corrupt_gzip_error_body_fails_and_cuts_the_connection(lane: str) -> None:
    corrupt = gzip.compress(NOT_FOUND)[:10] + b"\xff" * 64

    def reply(_m: str, _t: str) -> Reply:
        return _framed("404 Not Found", TYPED + "Content-Encoding: gzip\r\n", corrupt, HUGE)

    with _wire(reply) as wire:
        client = _client(lane, wire.url)
        result, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
        finished = wire.await_reply()
    print(
        f"[AdminResponseBody] {lane} 깨진 gzip 404 → {_name(err)} · server wrote {wire.written} B"
    )
    assert result is None and type(err).__name__ == "KeycloakTransportError", repr(err)
    assert finished and wire.written <= WRITTEN_BOUND, f"연결을 끊지 않았다 — {wire.written} B"


# 압축된 오류 본문은 그 압축 스트림과 함께 끝난다 — gzip 멤버 뒤의 꼬리(64 MiB)는 읽지 않고, 멤버
# 뒤 멈춘 서버는 기다리지 않는다(다 받은 400 을 돌려준다). 수정 전과 이 PR 의 앞 커밋은 꼬리를
# 끝까지 읽었고(서버 2,097,190 B), 멈춘 서버 앞에서 4,010~4,022 ms 에 KeycloakTransportError 였다
# (Grok 레그 지목 · 실측).
_NOPE = b'{"message":"nope"}'
_MEMBER = gzip.compress(_NOPE)


def _raw_deflate(data: bytes) -> bytes:
    packer = zlib.compressobj(wbits=-zlib.MAX_WBITS)
    return packer.compress(data) + packer.flush()


#: 인코딩마다 끝나는 압축 스트림 하나 — 날 deflate 는 첫 조각이 zlib 머리로 실패해 갈아탄 뒤의
#: 객체로 끝을 본다.
_STREAMS = {
    "gzip": ("gzip", _MEMBER),
    "deflate": ("deflate", zlib.compress(_NOPE)),
    "날 deflate": ("deflate", _raw_deflate(_NOPE)),
}


def _member_then(encoding: str, stream: bytes, tail: int, stall: bool) -> Reply:
    def reply(conn: socket.socket, wire: _Wire) -> bool:
        head = "HTTP/1.1 400 Bad Request\r\n" + TYPED + f"Content-Encoding: {encoding}\r\n"
        head += "Transfer-Encoding: chunked\r\n\r\n"
        if not _send(conn, wire, head.encode() + f"{len(stream):x}\r\n".encode() + stream):
            return False
        left = tail
        while left > 0:
            n = min(left, len(_SLAB))
            if not _send(conn, wire, f"\r\n{n:x}\r\n".encode() + _SLAB[:n]):
                return False
            left -= n
        if stall:
            time.sleep(20)
            return False
        return _send(conn, wire, b"\r\n0\r\n\r\n")

    return reply


@pytest.mark.parametrize("stall", [False, True])
@pytest.mark.parametrize("kind", sorted(_STREAMS))
@pytest.mark.parametrize("lane", LANES)
async def test_a_compressed_error_body_ends_with_its_stream(
    lane: str, kind: str, stall: bool
) -> None:
    encoding, stream = _STREAMS[kind]
    with _wire(lambda _m, _t: _member_then(encoding, stream, 0 if stall else HUGE, stall)) as wire:
        client = _client(lane, wire.url, timeout=4)
        start = time.monotonic()
        _, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        elapsed = time.monotonic() - start
        await _close(lane, client)
        # 멈춘 서버는 20 초를 붙든다 — 그 쓰기의 끝은 기다리지 않는다(쓴 것은 스트림 하나뿐이다).
        finished = stall or wire.await_reply()
    tail = "멈춤" if stall else "64 MiB"
    print(
        f"[AdminResponseBody] {lane} {kind} 스트림 뒤 {tail} → {_name(err)}"
        f" {getattr(err, 'keycloak_error', None)!r} · {elapsed * 1000:.0f} ms · server wrote"
        f" {wire.written} B"
    )
    assert isinstance(err, KeycloakAdminError) and err.status_code == 400, repr(err)
    assert err.keycloak_error == '{"message":"nope"}', repr(err)
    assert elapsed < 2, f"멈춘 서버를 기다렸다 — {elapsed * 1000:.0f} ms"
    assert finished and wire.written <= WRITTEN_BOUND, f"꼬리를 읽었다 — {wire.written} B"


# 대조 — 잘린 압축 오류 본문(gzip 머리 10 B 뿐)은 전처럼 그 상태의 오류다(KeycloakAdminError 400,
# 빈 본문) — urllib3·httpx 의 끝내기(flush)도 잘림을 오류로 보지 않았다(main 실측).
@pytest.mark.parametrize("lane", LANES)
async def test_a_truncated_compressed_error_body_keeps_its_status(lane: str) -> None:
    def reply(_m: str, _t: str) -> Reply:
        return _exact("400 Bad Request", TYPED + "Content-Encoding: gzip\r\n", _MEMBER[:10])

    with _wire(reply) as wire:
        client = _client(lane, wire.url)
        _, err = await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
    assert isinstance(err, KeycloakAdminError) and err.status_code == 400, repr(err)
    assert not err.keycloak_error, repr(err)


# 연결을 끊는 것은 이 전송의 닫기다 — 응답이나 예외를 쥔 호출자 앞에서도. 파사드 경로에서는 응답이
# 곧바로 버려져 CPython 의 참조 계수가 소켓을 대신 닫는다(그래서 닫기를 빼도 위 시험은 못 본다 —
# 변이 실측). raw 로 응답을 쥐거나, 실패의 예외(트레이스백이 응답을 쥔 프레임을 붙든다)를 쥐면
# 이 전송의 닫기만 연결을 끊는다.
async def _raw_get(lane: str, client: Any) -> Any:
    path = "admin/realms/r/users/x"
    conn = client.raw.connection
    return conn.raw_get(path) if lane == "sync" else await conn.a_raw_get(path)


@pytest.mark.parametrize("lane", LANES)
async def test_an_error_response_held_by_a_raw_caller_is_cut(lane: str) -> None:
    with _wire(lambda _m, _t: _framed("404 Not Found", TYPED, NOT_FOUND, HUGE)) as wire:
        client = _client(lane, wire.url)
        held = await _raw_get(lane, client)
        finished = wire.await_reply()
        print(f"[AdminResponseBody] {lane} raw 가 쥔 404 → server wrote {wire.written} B")
        assert held.status_code == 404 and len(held.content) == CAP, (held, len(held.content))
        await _close(lane, client)
    assert finished and wire.written <= WRITTEN_BOUND, (
        f"쥔 응답의 연결을 끊지 않았다 — {wire.written} B"
    )


@pytest.mark.parametrize("lane", LANES)
async def test_a_failed_error_read_held_by_a_raw_caller_is_cut(lane: str) -> None:
    corrupt = gzip.compress(NOT_FOUND)[:10] + b"\xff" * 64

    def reply(_m: str, _t: str) -> Reply:
        return _framed("404 Not Found", TYPED + "Content-Encoding: gzip\r\n", corrupt, HUGE)

    with _wire(reply) as wire:
        client = _client(lane, wire.url)
        held: BaseException | None = None
        try:
            await _raw_get(lane, client)
        except Exception as exc:  # 예외를 쥐는 것이 시험이다
            held = exc
        finished = wire.await_reply()
        print(f"[AdminResponseBody] {lane} 예외를 쥔 깨진 gzip → server wrote {wire.written} B")
        assert held is not None
        await _close(lane, client)
    assert finished and wire.written <= WRITTEN_BOUND, (
        f"예외 뒤 연결을 끊지 않았다 — {wire.written} B"
    )


# 대조 — 요청은 상한 안에서 풀 수 있는 압축만 청한다(gzip, deflate) — 소비자가 세션에 다른 것을
# 걸어 두어도(여기서는 br) 그 요청은 그것으로 나간다. 아니면 서버가 br 로 답한 오류 본문을 풀지
# 못하고 압축된 바이트를 메시지로 싣는다.
@pytest.mark.parametrize("lane", LANES)
async def test_requests_ask_only_for_encodings_decoded_under_the_cap(lane: str) -> None:
    with _wire(lambda _m, _t: _exact("404 Not Found", TYPED, NOT_FOUND)) as wire:
        client = _client(lane, wire.url)
        session = client.raw.connection._s if lane == "sync" else client.raw.connection.async_s
        session.headers["Accept-Encoding"] = "br"
        await _attempt(lane, client, lambda c: c.users.get("x"))
        await _close(lane, client)
    assert wire.last_headers.get("accept-encoding") == "gzip, deflate", wire.last_headers


# 대조 — 호출자가 스트리밍으로 받는 요청(`stream=True`)은 손대지 않는다 — 본문을 읽는 것도,
# Accept-Encoding 도 호출자의 몫이다.
def test_a_streaming_request_passes_through_untouched() -> None:
    seen: dict[str, Any] = {}

    def send(request: Any, **kwargs: Any) -> str:
        seen.update(kwargs)
        return "as-sent"

    request = requests.Request("GET", "http://127.0.0.1:1/").prepare()
    assert bounded_send(send)(request, stream=True) == "as-sent"
    assert seen == {"stream": True} and "Accept-Encoding" not in request.headers


async def test_an_async_streaming_request_passes_through_untouched() -> None:
    seen: dict[str, Any] = {}

    async def send(request: Any, **kwargs: Any) -> str:
        seen.update(kwargs)
        return "as-sent"

    request = httpx.Request("GET", "http://127.0.0.1:1/")
    assert await abounded_send(send)(request, stream=True) == "as-sent"
    assert seen == {"stream": True} and "accept-encoding" not in request.headers


# (4) 압축된 오류 본문도 푼 뒤 상한까지만 쥔다 — 상류는 Accept-Encoding: gzip 을 청하고 푼
# 본문을 통째로 쥐었다. 이름의 대소문자는 가리지 않는다(urllib3·httpx 처럼).
@pytest.mark.parametrize("encoding", ["gzip", "GZIP"])
@pytest.mark.parametrize("lane", LANES)
async def test_compressed_error_bodies_are_held_only_up_to_the_cap(
    lane: str, encoding: str
) -> None:
    random_json = b'{"errorMessage":"' + base64.b64encode(os.urandom(3 << 19)) + b'"}'
    rows = {
        "작은 압축이 상한 너머로 풀린다": gzip.compress(NOT_FOUND + b" " * HUGE, compresslevel=6),
        "압축이 상한을 넘는다": gzip.compress(random_json, compresslevel=6),
    }
    assert len(rows["작은 압축이 상한 너머로 풀린다"]) < CAP < len(rows["압축이 상한을 넘는다"])
    for name, body in rows.items():

        def reply(_m: str, _t: str, b: bytes = body) -> Reply:
            return _exact("404 Not Found", TYPED + f"Content-Encoding: {encoding}\r\n", b)

        with _wire(reply) as wire:
            client = _client(lane, wire.url)
            tracemalloc.start()
            try:
                _, err = await _attempt(lane, client, lambda c: c.users.get("x"))
                peak = tracemalloc.get_traced_memory()[1]
            finally:
                tracemalloc.stop()
            await _close(lane, client)
        kept = getattr(err, "keycloak_error", None) or ""
        print(
            f"[AdminResponseBody] {lane} get 404 + {encoding} {len(body)} B({name})"
            f" → {_name(err)} · keycloak_error {len(kept)} 자 · peak {peak} B"
        )
        assert isinstance(err, KeycloakNotFoundError), f"{name}: {err!r}"
        assert len(kept) <= CAP, f"{name}: 오류 본문을 상한 너머까지 실었다 — {len(kept)} 자"
        assert peak <= ALLOCATION_BOUND, f"{name}: 할당이 한도를 넘었다 — {peak} B"
