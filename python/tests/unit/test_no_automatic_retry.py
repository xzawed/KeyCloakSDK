"""SDK 가 보낸 요청은 그 뒤에 연결이 깨져도 IdP 에 **한 번만** 닿는다(등록부
`python-sync-post-retried`).

python-keycloak 7.1.1 의 `ConnectionManager.__init__` 은 requests 세션에
`HTTPAdapter(max_retries=1)` 을 걸고 urllib3 재시도 허용 목록에 **POST 를 더한다**("adds POST to
retry whitelist"). urllib3 는 요청을 보낸 뒤 난 연결 오류(끊김·RST·HTTP 가 아닌 상태 줄·너무 긴
헤더 줄·읽기 타임아웃)를 「읽기 오류」로 보고, 허용된 메서드면 **같은 요청을 다시 보낸다** — 서버가
첫 요청을 처리했는지는 모른다. 503·429·413 + `Retry-After` 면 그 초만큼 잠든 뒤 다시 보낸다. 수정
전 실측(이 파일의 가짜 IdP, 2026-10-09): sync 는 아래 모든 요청이 여섯 고장 모두에서 **두 번**
닿았고(urllib3 의 「Retrying (…)」 로그 1 회와 일치), aio(httpx)는 한 번이었다.

⚠️ 가짜 IdP 는 요청을 **끝까지 읽은 뒤** 깨뜨린다 — 그래서 센 수가 곧 「서버가 처리했을 수
있는」 요청 수다. 덜 읽고 닫으면 Windows 가 RST 를 보내 「닿기 전」 실패와 섞인다
(`test_token_response_leaks.py` 실측).

⚠️ 대조군 셋 — 수정 전후 모두 통과해야 한다: (1) 건강한 IdP 는 요청마다 한 번이다(늘 2 를 세는
계측기가 아니다), (2) aio 는 한 번이다(httpcore 의 재시도는 연결 수립만 다시 한다),
(3) python-keycloak 을 SDK 없이 쓰면 같은 고장에서 두 번 보낸다(이 가짜 IdP 의 고장이 재시도를
실제로 일으킨다 — 수정 뒤 SDK 레인이 「한 번」인 것이 고장이 안 난 탓이 아니다).
"""

from __future__ import annotations

import contextlib
import datetime
import ipaddress
import json
import socket
import ssl
import struct
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from keycloak import KeycloakAdmin, KeycloakOpenID, KeycloakOpenIDConnection
from keycloak.connection import ConnectionManager
from keycloak.exceptions import KeycloakError
from requests.adapters import BaseAdapter, HTTPAdapter
from urllib3.util.retry import Retry

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.exceptions import KeycloakConfigError, KeycloakSdkError, KeycloakTransportError
from keycloak_sdk.oidc import OidcEndpoints

#: 경우마다 새 클라이언트(httpx.AsyncClient 셋까지)를 만든다 — TLS 문맥만 재사용한다(conftest).
pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")
_OC = "/realms/r/protocol/openid-connect"
_USERS = "/admin/realms/r/users"
_SECRET = "s3cret"
#: http.client 의 줄 상한(65,536)과 httpcore 의 사건 상한(102,400)을 둘 다 넘는다 — 두 레인 다
#: 실패한다. ⚠️ h11 은 그 상한을 **덜 받은** 사건에만 건다 — 110,000 바이트는 64 KiB 읽기 두 번에
#: 끝나 aio 가 응답으로 받아들였다(실측). 덜 받은 채로 상한을 넘게 넉넉히 둔다.
_LONG_HEADER = 262_144

#: 요청을 다 읽은 뒤 보낼 것. 「reset」(RST)과 「read timeout」(답하지 않음)은 `_break` 가 다룬다.
_BROKEN: dict[str, bytes] = {
    "close": b"",
    "garbage status line": b"XYZ not-http\r\n\r\n",
    "oversized header line": b"HTTP/1.1 200 OK\r\nX-Long: " + b"a" * _LONG_HEADER + b"\r\n\r\n",
    # `Retry-After: 0` — 수정 전에도 잠들지 않고 곧바로 다시 보낸다(잠드는 길이는 커밋 메시지의
    # 실측).
    "503 Retry-After": (
        b"HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\n"
        b"Connection: close\r\n\r\n"
    ),
}
BREAKS = (*_BROKEN, "reset", "read timeout")

#: 종류 → 깨뜨릴 요청(메서드, 경로).
TARGETS: dict[str, tuple[str, str]] = {
    "client_credentials grant": ("POST", f"{_OC}/token"),
    "refresh grant": ("POST", f"{_OC}/token"),
    "code exchange": ("POST", f"{_OC}/token"),
    "introspection": ("POST", f"{_OC}/token/introspect"),
    "logout": ("POST", f"{_OC}/logout"),
    "admin token grant": ("POST", f"{_OC}/token"),
    "admin create": ("POST", _USERS),
    "admin update": ("PUT", f"{_USERS}/u1"),
    "admin delete": ("DELETE", f"{_USERS}/u1"),
    "admin action (raw POST user_logout)": ("POST", f"{_USERS}/u1/logout"),
    "admin action (raw PUT send_verify_email)": ("PUT", f"{_USERS}/u1/send-verify-email"),
    "JWKS": ("GET", f"{_OC}/certs"),
    "admin get": ("GET", f"{_USERS}/u1"),
}
UNSAFE = [kind for kind, (method, _) in TARGETS.items() if method != "GET"]
GETS = [kind for kind, (method, _) in TARGETS.items() if method == "GET"]

_SYNC: dict[str, Callable[[KeycloakClient], object]] = {
    "client_credentials grant": lambda c: c.auth.client_credentials_token(),
    "refresh grant": lambda c: c.auth.refresh("refresh-in"),
    "code exchange": lambda c: c.auth.exchange_code("code-in", "http://127.0.0.1/cb", "v" * 43),
    "introspection": lambda c: c.auth.introspect("token-in"),
    "logout": lambda c: c.auth.logout("refresh-in"),
    "admin token grant": lambda c: c.admin.users.get("u1"),
    "admin create": lambda c: c.admin.users.create({"username": "new"}),
    "admin update": lambda c: c.admin.users.update("u1", {"firstName": "n"}),
    "admin delete": lambda c: c.admin.users.delete("u1"),
    "admin action (raw POST user_logout)": lambda c: c.admin.raw.user_logout("u1"),
    "admin action (raw PUT send_verify_email)": lambda c: c.admin.raw.send_verify_email("u1"),
    "JWKS": lambda c: c.auth.validate("x.y.z"),
    "admin get": lambda c: c.admin.users.get("u1"),
}
_AIO: dict[str, Callable[[AsyncKeycloakClient], Any]] = {
    "client_credentials grant": lambda c: c.auth.client_credentials_token(),
    "refresh grant": lambda c: c.auth.refresh("refresh-in"),
    "code exchange": lambda c: c.auth.exchange_code("code-in", "http://127.0.0.1/cb", "v" * 43),
    "introspection": lambda c: c.auth.introspect("token-in"),
    "logout": lambda c: c.auth.logout("refresh-in"),
    "admin token grant": lambda c: c.admin.users.get("u1"),
    "admin create": lambda c: c.admin.users.create({"username": "new"}),
    "admin update": lambda c: c.admin.users.update("u1", {"firstName": "n"}),
    "admin delete": lambda c: c.admin.users.delete("u1"),
    "admin action (raw POST user_logout)": lambda c: c.admin.raw.a_user_logout("u1"),
    "admin action (raw PUT send_verify_email)": lambda c: c.admin.raw.a_send_verify_email("u1"),
    "JWKS": lambda c: c.auth.validate("x.y.z"),
    "admin get": lambda c: c.admin.users.get("u1"),
}


# --- 요청을 다 읽은 뒤 깨뜨리는 가짜 IdP(raw socket) ---------------------------------------------


@dataclass
class _Idp:
    url: str = ""
    target: tuple[str, str] = ("", "")
    brk: str = "healthy"
    seen: list[tuple[str, str]] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def received(self) -> int:
        """`target` 이 서버에 닿은 수 — 요청을 끝까지 읽은 것만 센다."""
        with self.lock:
            return self.seen.count(self.target)


def _read_request(conn: socket.socket, buf: bytes) -> tuple[str, str, bytes] | None:
    """(메서드, 경로, 남은 바이트) — 머리와 `Content-Length` 만큼의 본문을 **끝까지** 읽는다."""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            return None
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    request_line, *headers = head.split(b"\r\n")
    method, target, _ = request_line.decode("latin-1").split(" ", 2)
    length = 0
    for line in headers:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value)
    while len(rest) < length:
        chunk = conn.recv(65536)
        if not chunk:
            return None
        rest += chunk
    return method, target.split("?", 1)[0], rest[length:]


def _response(status: int, body: bytes = b"", extra: str = "") -> bytes:
    head = f"HTTP/1.1 {status} X\r\nContent-Length: {len(body)}\r\n{extra}"
    if body:
        head += "Content-Type: application/json\r\n"
    return (head + "\r\n").encode() + body


def _healthy(url: str, method: str, path: str) -> bytes:
    if method == "POST" and path == f"{_OC}/token":
        grant = {"access_token": "a" * 40, "token_type": "Bearer", "expires_in": 300}
        return _response(200, json.dumps({**grant, "refresh_token": "r" * 40}).encode())
    if path == f"{_OC}/token/introspect":
        return _response(200, b'{"active": true, "client_id": "c", "username": "u"}')
    if path == f"{_OC}/certs":
        return _response(200, b'{"keys": []}')
    if method == "POST" and path == _USERS:
        return _response(201, extra=f"Location: {url}{_USERS}/new-id\r\n")
    if method == "GET" and path == f"{_USERS}/u1":
        return _response(200, b'{"id": "u1", "username": "u"}')
    if path in (f"{_OC}/logout", f"{_USERS}/u1", f"{_USERS}/u1/logout"):
        return _response(204)
    if path == f"{_USERS}/u1/send-verify-email":
        return _response(204)
    return _response(404, b'{"error": "not_found"}')


def _break(conn: socket.socket, brk: str) -> None:
    if brk == "reset":
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        return  # 호출자가 닫으면 RST 다
    if brk == "corrupt TLS record":
        # TLS 를 거치지 않고 같은 소켓에 깨진 application_data 레코드를 쓴다 — 클라이언트는 응답을
        # 읽다 `SSLError`(bad record mac)를 본다.
        raw = socket.socket(fileno=conn.fileno())
        try:
            raw.sendall(b"\x17\x03\x03\x00\x40" + b"\xaa" * 64)
        finally:
            raw.detach()
    elif brk != "read timeout":
        conn.sendall(_BROKEN[brk])
        conn.shutdown(socket.SHUT_WR)
    while conn.recv(65536):  # 클라이언트가 닫을 때까지(읽기 타임아웃이면 포기할 때까지)
        pass


@contextlib.contextmanager
def _breaking_idp(tls: ssl.SSLContext | None = None) -> Iterator[_Idp]:
    idp = _Idp()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(64)
    idp.url = f"{'https' if tls else 'http'}://127.0.0.1:{sock.getsockname()[1]}"

    def serve(conn: socket.socket) -> None:
        with conn:
            try:
                conn.settimeout(10)
                if tls is not None:
                    conn = tls.wrap_socket(conn, server_side=True)
                buf = b""
                while (got := _read_request(conn, buf)) is not None:
                    method, path, buf = got
                    with idp.lock:
                        idp.seen.append((method, path))
                    if (method, path) == idp.target and idp.brk != "healthy":
                        _break(conn, idp.brk)
                        return
                    conn.sendall(_healthy(idp.url, method, path))
            except OSError:
                pass  # 클라이언트가 먼저 끊었다(너무 긴 헤더를 보내는 도중 등)

    def accept() -> None:
        while True:
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=serve, args=(conn,), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    try:
        yield idp
    finally:
        sock.close()


def _config(url: str) -> KeycloakConfig:
    # auth 레인의 타임아웃은 정수 초라 1 초가 바닥이다(`max(1, round(...))`) — admin 은 0.3 초다.
    return KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret=_SECRET, read_timeout=0.3
    )


async def _attempt(lane: str, kind: str, idp: _Idp) -> BaseException | None:
    """공개 API 로 한 번 부른다 — 실패하면 그 예외, 성공하면 None."""
    if lane == "sync":
        with KeycloakClient.create(_config(idp.url)) as kc:
            try:
                _SYNC[kind](kc)
            except Exception as exc:
                return exc
        return None
    async with AsyncKeycloakClient.create(_config(idp.url)) as akc:
        try:
            await _AIO[kind](akc)
        except Exception as exc:
            return exc
    return None


def _failed_as_designed(err: BaseException | None) -> bool:
    """고장이 호출을 실제로 실패시켰고, 그 실패가 SDK 의 타입(파사드)이나 python-keycloak 의 타입
    (§4(b) 탈출구 `raw`)인가 — 아니면 아래 「한 번」은 고장이 안 난 탓일 수 있다."""
    return isinstance(err, (KeycloakSdkError, KeycloakError))


# --- 본 판정 ---------------------------------------------------------------------------------


@pytest.mark.parametrize("brk", BREAKS)
@pytest.mark.parametrize("kind", UNSAFE)
@pytest.mark.parametrize("lane", LANES)
async def test_a_request_the_idp_may_have_processed_is_sent_once(
    lane: str, kind: str, brk: str
) -> None:
    """토큰 그랜트·introspection·logout·admin 생성/수정/삭제/액션 — 서버가 읽은 뒤 연결이 깨지면
    처리됐는지 알 수 없다. 다시 보내면 처리된 생성은 409 로, 쓰인 인가 코드는 invalid_grant 로
    돌아오고 refresh token 은 두 번 제시된다. 그래서 다시 보내지 않는다."""
    with _breaking_idp() as idp:
        idp.target, idp.brk = TARGETS[kind], brk
        err = await _attempt(lane, kind, idp)

    assert _failed_as_designed(err), f"고장이 호출을 실패시키지 않았다 — 공허하다: {err!r}"
    assert idp.received() == 1, f"{lane}: {kind} 가 IdP 에 {idp.received()} 번 닿았다({brk})"


@pytest.mark.parametrize("brk", BREAKS)
@pytest.mark.parametrize("kind", GETS)
@pytest.mark.parametrize("lane", LANES)
async def test_a_get_is_not_retried_either(lane: str, kind: str, brk: str) -> None:
    """GET 재시도도 남기지 않는다(판정). 다시 보내도 상태는 안 바뀌지만 공짜가 아니다 — 503 +
    `Retry-After` 면 그 초만큼(설치된 urllib3 2.7.0 의 상한 21,600 초) 잠든 뒤 보내고, JWKS 면
    `_jwks_lock` 을 쥔 채 잠들어 그동안 모든 검증이 기다린다. 강제 재조회 창 하나가 IdP 요청 둘이
    된다(`.claude/rules/security.md` 의 「창마다 한 번」). 재시도는 소비자의 몫이다."""
    with _breaking_idp() as idp:
        idp.target, idp.brk = TARGETS[kind], brk
        err = await _attempt(lane, kind, idp)

    assert _failed_as_designed(err), f"고장이 호출을 실패시키지 않았다 — 공허하다: {err!r}"
    assert idp.received() == 1, f"{lane}: {kind} 가 IdP 에 {idp.received()} 번 닿았다({brk})"


# --- TLS 위에서는 허용 목록이 아니라 `total` 이 막는다 -------------------------------------------


@pytest.fixture(scope="module")
def tls_cert(tmp_path_factory: pytest.TempPathFactory) -> tuple[str, str]:
    """127.0.0.1 의 자체 서명 인증서(파이썬 3.13 의 `VERIFY_X509_STRICT` 를 통과하는 꼴)."""
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    ski = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
    now = datetime.datetime.now(datetime.timezone.utc)
    usage = dict.fromkeys(
        (
            "content_commitment",
            "key_encipherment",
            "data_encipherment",
            "key_agreement",
            "crl_sign",
            "encipher_only",
            "decipher_only",
        ),
        False,
    )
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(digital_signature=True, key_cert_sign=True, **usage), critical=True
        )
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(ski, critical=False)
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(ski), critical=False
        )
        .sign(key, hashes.SHA256())
    )
    tmp: Path = tmp_path_factory.mktemp("tls")
    cert_path, key_path = tmp / "cert.pem", tmp / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return str(cert_path), str(key_path)


def _server_tls(tls_cert: tuple[str, str]) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(*tls_cert)
    return context


@pytest.mark.parametrize("kind", UNSAFE)
async def test_over_tls_a_broken_record_after_the_request_is_not_retried_either(
    kind: str, tls_cert: tuple[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """⚠️ 허용 목록에서 POST 를 빼는 것으로는 모자란다. 응답을 읽다 난 TLS 레코드 오류(`SSLError`)를
    urllib3 는 「연결」도 「읽기」도 아닌 「그 밖」 오류로 보고 **메서드와 무관하게** 다시 보낸다 —
    아래 대조군. 막는 것은 `total=0` 이다. sync 만 잰다(httpx 는 다시 보내지 않는다)."""
    monkeypatch.setenv("REQUESTS_CA_BUNDLE", tls_cert[0])  # SDK 는 verify=True — 이 CA 를 믿게
    with _breaking_idp(_server_tls(tls_cert)) as idp:
        idp.target, idp.brk = TARGETS[kind], "corrupt TLS record"
        err = await _attempt("sync", kind, idp)

    assert _failed_as_designed(err), f"고장이 호출을 실패시키지 않았다 — 공허하다: {err!r}"
    assert idp.received() == 1, f"{kind} 가 IdP 에 {idp.received()} 번 닿았다(TLS)"


@pytest.mark.parametrize(
    "policy",
    [Retry(1), Retry(total=1, allowed_methods=frozenset({"GET"}))],
    ids=["urllib3 default allowlist", "GET only"],
)
def test_control_over_tls_a_post_off_the_allowlist_is_still_sent_twice(
    policy: Retry, tls_cert: tuple[str, str]
) -> None:
    """그래서 `NO_RETRY` 는 허용 목록이 아니라 `Retry(0, read=False)` 다 — 이 대조군이 1 을 세면
    TLS 고장이 재시도를 부르지 않는 환경이라 위 판정이 공허하다."""
    with _breaking_idp(_server_tls(tls_cert)) as idp:
        idp.target, idp.brk = ("POST", f"{_OC}/token"), "corrupt TLS record"
        openid = KeycloakOpenID(
            server_url=idp.url, realm_name="r", client_id="c", verify=tls_cert[0], timeout=1
        )
        for adapter in openid.connection._s.adapters.values():
            adapter.max_retries = policy
        with pytest.raises(KeycloakError):
            openid.token(grant_type="client_credentials")
        openid.connection._s.close()

    assert idp.received() == 2


# --- 대조군 ----------------------------------------------------------------------------------


@pytest.mark.parametrize("kind", list(TARGETS))
@pytest.mark.parametrize("lane", LANES)
async def test_control_a_healthy_idp_sees_each_request_once(lane: str, kind: str) -> None:
    with _breaking_idp() as idp:
        idp.target = TARGETS[kind]
        err = await _attempt(lane, kind, idp)

    # JWKS 만 실패한다 — `x.y.z` 는 JWT 가 아니다(전송은 성공했다).
    assert err is None or (kind == "JWKS" and not isinstance(err, KeycloakTransportError)), err
    assert idp.received() == 1


@pytest.mark.parametrize("brk", ["close", "503 Retry-After"])
@pytest.mark.parametrize("kind", ["token grant", "admin create"])
def test_control_python_keycloak_alone_sends_the_post_twice(kind: str, brk: str) -> None:
    """이 가짜 IdP 의 고장이 재시도를 실제로 일으킨다 — SDK 없이 쓰는 python-keycloak 이 증인이다.
    이 대조군이 1 을 세면 본 판정의 「한 번」은 고장이 재시도를 부르지 않은 탓일 수 있다."""
    with _breaking_idp() as idp:
        if kind == "token grant":
            idp.target, idp.brk = ("POST", f"{_OC}/token"), brk
            openid = KeycloakOpenID(server_url=idp.url, realm_name="r", client_id="c", timeout=1)
            with pytest.raises(KeycloakError):
                openid.token(grant_type="client_credentials")
            openid.connection._s.close()
        else:
            idp.target, idp.brk = ("POST", _USERS), brk
            stock = KeycloakAdmin(connection=_stock_connection(idp.url))
            with pytest.raises(KeycloakError):
                stock.create_user({"username": "new"})
            _close_connection(stock.connection)

    assert idp.received() == 2


# --- 갈아 끼운 연결·어댑터 — admin 레인은 요청마다 다시 본다(`_internal/admin_guard.py`) ----


def _stock_connection(url: str) -> KeycloakOpenIDConnection:
    """SDK 를 거치지 않고 만든 python-keycloak 연결 — 어댑터가 POST 를 다시 보낸다."""
    return KeycloakOpenIDConnection(
        server_url=url,
        realm_name="r",
        client_id="c",
        client_secret_key=_SECRET,
        grant_type="client_credentials",
        timeout=1,
    )


def _close_connection(conn: Any) -> None:
    """SDK 의 정리에서 빠진 연결 — 테스트가 직접 닫는다."""
    conn.keycloak_openid.connection._s.close()
    conn._s.close()


def _retries_post(session: Any) -> bool:
    """이 세션의 `http://` 어댑터가 POST 를 다시 보내는 정책인가(urllib3 `Retry`)."""
    policy = session.get_adapter("http://127.0.0.1/").max_retries
    return bool(policy.total) and "POST" in (policy.allowed_methods or {"POST"})


@pytest.mark.parametrize("swap", ["public setter", "private field"])
def test_a_replaced_admin_connection_sends_the_create_once(swap: str) -> None:
    with _breaking_idp() as idp, KeycloakClient.create(_config(idp.url)) as kc:
        raw = kc.admin.raw
        old, new = raw.connection, _stock_connection(idp.url)
        assert _retries_post(new._s), "갈아 끼울 연결이 재시도하지 않는다 — 공허하다"
        if swap == "public setter":
            raw.connection = new
        else:
            raw._connection = new
        idp.target, idp.brk = ("POST", _USERS), "close"
        with pytest.raises(KeycloakTransportError):
            kc.admin.users.create({"username": "new"})
        _close_connection(old)

    assert idp.received() == 1


def test_a_replaced_grant_connection_sends_the_grant_once() -> None:
    """중첩 그랜트 객체의 연결도 공개 세터다(`KeycloakOpenID.connection`)."""
    with _breaking_idp() as idp, KeycloakClient.create(_config(idp.url)) as kc:
        nested = kc.admin.raw.connection.keycloak_openid
        old, new = nested.connection, ConnectionManager(base_url=idp.url, timeout=1)
        assert _retries_post(new._s), "갈아 끼울 연결이 재시도하지 않는다 — 공허하다"
        nested.connection = new
        idp.target, idp.brk = ("POST", f"{_OC}/token"), "close"
        with pytest.raises(KeycloakTransportError):
            kc.admin.users.get("u1")
        old._s.close()

    assert idp.received() == 1


@pytest.mark.parametrize("session", ["REST", "grant"])
def test_an_adapter_mounted_later_is_not_allowed_to_retry(session: str) -> None:
    """소비자가 `raw` 로 나중에 건 어댑터도 다음 요청 전에 재시도를 잃는다 — SDK 세션의 재시도
    정책은 SDK 가 정한다(리다이렉트 하드닝과 같다)."""
    with _breaking_idp() as idp, KeycloakClient.create(_config(idp.url)) as kc:
        conn = kc.admin.raw.connection
        target = conn._s if session == "REST" else conn.keycloak_openid.connection._s
        target.mount("http://", HTTPAdapter(max_retries=Retry(total=3, allowed_methods=None)))
        assert _retries_post(target), "건 어댑터가 재시도하지 않는다 — 공허하다"
        kind = "admin create" if session == "REST" else "admin token grant"
        idp.target, idp.brk = TARGETS[kind], "close"
        with pytest.raises(KeycloakTransportError):
            _SYNC[kind](kc)

    assert idp.received() == 1


def test_an_injected_openid_and_admin_do_not_retry_either() -> None:
    """주입 경로(테스트 이음매)도 생성 경로와 같은 하드닝이다 — 느슨하면 테스트가 증명하는 것이
    실제와 달라진다."""
    with _breaking_idp() as idp:
        cfg = _config(idp.url)
        openid = KeycloakOpenID(server_url=idp.url, realm_name="r", client_id="c", timeout=1)
        auth = AuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)
        admin = AdminClient(cfg, admin=KeycloakAdmin(connection=_stock_connection(idp.url)))
        idp.target, idp.brk = ("POST", f"{_OC}/token"), "close"
        with pytest.raises(KeycloakTransportError):
            auth.client_credentials_token()
        assert idp.received() == 1
        idp.target = ("POST", _USERS)
        with pytest.raises(KeycloakTransportError):
            admin.users.create({"username": "new"})
        assert idp.received() == 1
        auth.close()
        admin.close()


# --- 걸 수 없을 때 ---------------------------------------------------------------------------


def _no_adapter_table() -> SimpleNamespace:
    """requests 세션처럼 보내고 리다이렉트 훅도 있지만 어댑터 표가 없다 — python-keycloak 이 세션을
    바꾼 모양이다(리다이렉트·응답 상한 하드닝은 이것을 받아들인다)."""
    return SimpleNamespace(
        resolve_redirects=lambda *_a, **_k: iter(()),
        send=lambda *_a, **_k: None,
        close=lambda: None,
    )


def test_an_auth_session_without_an_adapter_table_is_refused_at_construction() -> None:
    cfg = _config("http://127.0.0.1:9")
    endpoints = OidcEndpoints.for_realm(cfg)
    openid = KeycloakOpenID(server_url=cfg.server_url, realm_name="r", client_id="c")
    openid.connection._s = _no_adapter_table()

    with pytest.raises(KeycloakConfigError, match=r"connection\._s\.adapters"):
        AuthClient(cfg, endpoints, openid=openid)


@pytest.mark.parametrize("session", ["REST", "grant"])
def test_an_admin_session_without_an_adapter_table_is_refused_and_nothing_changes(
    session: str,
) -> None:
    conn = _stock_connection("http://127.0.0.1:9")
    nested = conn.keycloak_openid.connection
    real = nested._s if session == "REST" else conn._s
    if session == "REST":
        conn._s = _no_adapter_table()
    else:
        nested._s = _no_adapter_table()
    cfg, admin = _config("http://127.0.0.1:9"), KeycloakAdmin(connection=conn)

    with pytest.raises(KeycloakConfigError, match=r"_s\.adapters"):
        AdminClient(cfg, admin=admin)

    # 전부이거나 아무것도 — 남은 진짜 세션에는 리다이렉트 훅도 새 재시도 정책도 걸리지 않았다.
    assert "resolve_redirects" not in vars(real)
    assert _retries_post(real)
    real.close()


def test_control_an_adapter_without_a_retry_policy_is_left_alone() -> None:
    """requests 의 `HTTPAdapter` 가 아닌, 소비자가 직접 건 전송(`max_retries` 가 없다)은 건드리지
    않는다 — 그 재시도는 이 SDK 가 볼 수 없고, 막으면 목 어댑터로 시험하는 소비자가 깨진다."""

    class Mock(BaseAdapter):
        def send(self, *_a: Any, **_k: Any) -> Any:
            raise AssertionError("not used")

        def close(self) -> None:
            pass

    cfg = _config("http://127.0.0.1:9")
    openid = KeycloakOpenID(server_url=cfg.server_url, realm_name="r", client_id="c")
    mock = Mock()
    openid.connection._s.mount("mock://", mock)
    auth = AuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)
    admin_conn = _stock_connection("http://127.0.0.1:9")
    admin_conn._s.mount("mock://", mock)
    admin = AdminClient(cfg, admin=KeycloakAdmin(connection=admin_conn))

    assert "max_retries" not in vars(mock)
    auth.close()
    admin.close()
