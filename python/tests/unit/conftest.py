"""단위 테스트 공유 픽스처 — 백채널 리다이렉트 덫 서버(sync/async 공용)·JWKS 서버·토큰 응답 서버·
하위 오류 생성기, 그리고 새 클라이언트를 많이 만드는 테스트의 TLS 문맥 재사용(`fast_tls`)."""

from __future__ import annotations

import gzip
import importlib
import json
import threading
import zlib
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from unittest.mock import AsyncMock, MagicMock
from urllib.parse import parse_qs

import pytest

CLIENT_SECRET = "s3cret-must-not-leak"
REFRESH_TOKEN = "refresh-must-not-leak"
ACCESS_TOKEN = "access-must-not-leak"


@dataclass
class Hit:
    method: str
    path: str
    authorization: str | None
    body: str


@dataclass
class Trap:
    """3xx를 뱉는 idp 서버 + 리다이렉트 대상(evil) 서버."""

    idp_url: str
    evil_url: str
    hits: list[Hit] = field(default_factory=list)
    same_origin: bool = False

    def reset(self) -> None:
        self.hits.clear()


def _body(handler: BaseHTTPRequestHandler) -> str:
    length = int(handler.headers.get("Content-Length") or 0)
    return handler.rfile.read(length).decode("utf-8", "replace") if length else ""


def _make_handler(trap_box: dict[str, Trap], role: str) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:  # 테스트 출력 오염 방지
            pass

        def _serve(self) -> None:
            trap = trap_box["trap"]
            body = _body(self)
            recording = role == "evil" or self.path.startswith("/stolen")
            if recording:
                trap.hits.append(
                    Hit(
                        method=self.command,
                        path=self.path,
                        authorization=self.headers.get("Authorization"),
                        body=body,
                    )
                )
                payload, status = self._answer_as_attacker()
                self._send(status, payload)
                return
            target = (
                f"/stolen{self.path}" if trap.same_origin else f"{trap.evil_url}/stolen{self.path}"
            )
            # 307: requests가 메서드와 **본문**을 보존한다 — 자격증명이 그대로 따라간다.
            self.send_response(307)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _answer_as_attacker(self) -> tuple[bytes, int]:
            if "certs" in self.path:
                return json.dumps({"keys": [{"kid": "ATTACKER-KEY", "kty": "oct"}]}).encode(), 200
            if "introspect" in self.path:
                return json.dumps({"active": True, "username": "victim"}).encode(), 200
            if "logout" in self.path:
                return b"", 204  # 공격자가 204를 주면 SDK가 로그아웃 성공으로 읽는다
            if "/users" in self.path:
                return json.dumps([{"id": "planted", "username": "planted"}]).encode(), 200
            return json.dumps({"access_token": "ATTACKER-TOKEN", "expires_in": 300}).encode(), 200

        def _send(self, status: int, payload: bytes) -> None:
            self.send_response(status)
            if payload:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve
        do_PUT = _serve
        do_DELETE = _serve

    return Handler


@pytest.fixture
def fast_tls(monkeypatch: pytest.MonkeyPatch) -> None:
    """`httpx.AsyncClient` 하나마다 certifi 번들을 읽는다(0.45초) — 호출마다 새 클라이언트를
    만드는 테스트(적대 경로 행렬의 행·칸, admin 그랜트의 경로마다)는 그대로면 수천·수십 초다.
    가짜 IdP 는 평문 HTTP 라 TLS 문맥을 쓰지 않는다. 같은 인자의 문맥을 재사용할 뿐 검증 설정은
    그대로다."""
    transport = importlib.import_module("httpx._transports.default")
    original = getattr(transport, "create_ssl_context", None)
    if original is None:  # httpx 가 이음매를 옮겼다 — 느려질 뿐 결과는 같다
        return
    cache: dict[bool, object] = {}

    def cached(verify: object = True, cert: object = None, trust_env: bool = True) -> object:
        if verify is True and cert is None:
            if trust_env not in cache:
                cache[trust_env] = original(verify=verify, cert=cert, trust_env=trust_env)
            return cache[trust_env]
        return original(verify=verify, cert=cert, trust_env=trust_env)

    monkeypatch.setattr(transport, "create_ssl_context", cached)


@pytest.fixture
def jwks(monkeypatch: pytest.MonkeyPatch) -> Any:
    """JWKS 로딩 목(sync) — 옛 `openid.certs` 목을 **대체한다**.

    ⚠️ JWKS 는 더 이상 상류 `certs()` 로 나가지 않는다. 바이트 상한을 걸 이음매가 거기
    없어서(`raw_get` 이 `**kwargs` 를 `params=` 로 보낸다) 상한이 걸린 직접 GET 으로
    바뀌었다(`_internal/jwks_fetch.py`). 목 자리도 그 이음매로 옮긴다 — MagicMock 관용
    (`return_value`·`side_effect`·`call_count`)은 그대로 쓴다.
    """
    stub = MagicMock(return_value={"keys": []})
    monkeypatch.setattr("keycloak_sdk.auth.fetch_jwks", stub)
    return stub


@pytest.fixture
def ajwks(monkeypatch: pytest.MonkeyPatch) -> Any:
    """JWKS 로딩 목(aio) — 옛 `openid.a_certs` 목을 대체한다. sync 미러와 같은 이유다."""
    stub = AsyncMock(return_value={"keys": []})
    monkeypatch.setattr("keycloak_sdk.aio.auth.afetch_jwks", stub)
    return stub


@dataclass
class JwksServer:
    """JWKS 엔드포인트 하나만 서빙하는 실 HTTP 서버.

    ⚠️ **목으로는 바이트 상한을 잴 수 없다.** 기존 테스트는 `openid.certs`를 목하는데 그
    경계는 상한이 걸리는 자리(HTTP 전송)보다 **위**라, 목을 아무리 크게 만들어도 상한을
    통과하지 않는다. 그래서 실제로 바이트를 흘리는 서버가 필요하다.
    """

    url: str
    body: bytes = b'{"keys": []}'
    status: int = 200
    chunked: bool = False  # Content-Length 없이 보낸다 — 헤더만 믿는 상한을 걸러내는 대조군
    truncate: bool = False  # 약속한 길이보다 적게 보내고 끊는다 — 읽는 도중 실패 재현
    gzip: bool = False  # gzip 으로 보낸다 — 압축폭탄(작은 본문 → 거대 팽창) 재현
    fake_encoding: str | None = None  # 본문은 그대로 두고 Content-Encoding 만 붙인다
    hits: int = 0
    accept_encoding: str | None = None  # 마지막 요청이 실어 온 값 — 압축 거부를 관측한다


def _make_jwks_handler(box: dict[str, JwksServer]) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def do_GET(self) -> None:
            srv = box["server"]
            srv.hits += 1
            srv.accept_encoding = self.headers.get("Accept-Encoding")
            if srv.gzip:
                # 압축폭탄: 전송 바이트는 작고 팽창 후가 거대하다. 상한을 **팽창 뒤**에만
                # 재는 구현은 이미 메모리를 내준 뒤에야 거부한다.
                payload = gzip.compress(srv.body)
                self.send_response(srv.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(srv.status)
            self.send_header("Content-Type", "application/json")
            if srv.fake_encoding is not None:
                self.send_header("Content-Encoding", srv.fake_encoding)
            if srv.chunked:
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for i in range(0, len(srv.body), 4096):
                    chunk = srv.body[i : i + 4096]
                    self.wfile.write(f"{len(chunk):X}\r\n".encode())
                    self.wfile.write(chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            elif srv.truncate:
                # 길이는 크게 약속하고 조금만 보낸 뒤 끊는다 — 클라이언트는 읽는 도중 실패한다.
                self.send_header("Content-Length", str(len(srv.body) + 1024))
                self.end_headers()
                self.wfile.write(srv.body)
                self.close_connection = True
            else:
                self.send_header("Content-Length", str(len(srv.body)))
                self.end_headers()
                self.wfile.write(srv.body)

    return Handler


class _QuietServer(ThreadingHTTPServer):
    """상한에 걸린 클라이언트가 연결을 끊으면 서버가 트레이스백을 찍는다 — 그건 상한이
    **작동한** 증거이지 오류가 아니고, 그 잡음이 진짜 실패를 덮는다."""

    def handle_error(self, *_args: Any) -> None:
        pass


@pytest.fixture
def jwks_server() -> Any:
    box: dict[str, JwksServer] = {}
    server = _QuietServer(("127.0.0.1", 0), _make_jwks_handler(box))
    box["server"] = JwksServer(url=f"http://127.0.0.1:{server.server_address[1]}")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield box["server"]
    server.shutdown()
    server.server_close()


#: 덧댈 공백 — JSON 이 허용하는 뒤 공백이다. 한 번 만들어 잘라 쓴다(거대 본문을 메모리에
#: 만들지 않는다).
_PAD = memoryview(b" " * 65_536)


def _padded(head: bytes, total: int) -> Iterator[memoryview]:
    yield memoryview(head)
    left = total - len(head)
    while left > 0:
        n = min(len(_PAD), left)
        yield _PAD[:n]
        left -= n


def gzip_padded(head: bytes, total: int) -> bytes:
    """`head` + 공백 `total` 바이트를 gzip 으로 — 전송은 작고 푼 뒤가 거대하다(압축폭탄).
    조각마다 압축해 원문을 통째로 만들지 않는다."""
    comp = zlib.compressobj(9, zlib.DEFLATED, 31)
    out = [comp.compress(piece) for piece in _padded(head, total)]
    out.append(comp.flush())
    return b"".join(out)


class RawBeforeMaxLength:
    """urllib3 2.6 미만 `HTTPResponse` 의 원문 읽기 흉내(gzip) — **설치된 urllib3 와 무관하게**
    SDK 가 무엇을 청하는지, 그때 메모리가 얼마나 드는지를 잰다.

    ⚠️ `decode_content=True` 면 원문 `amt` 바이트를 읽어 **상한 없이 통째로** 풀고, `amt` 를 넘는
    분량은 버퍼에 쥔다 — 2.6 미만의 `GzipDecoder.decompress(data)` 에는 `max_length` 가 없다(실측
    2.5.0: 16 MiB 폭탄 한 번의 decompress 가 16,762,622 바이트). `decode_content=False` 면 원문
    그대로다(2.5.0 과 2.8.0 이 같다). `inflates=False` 는 urllib3 에 그 인코딩의 디코더가 없는
    경우다(`identity`, `brotli` 없는 `br`) — 그때는 `decode_content=True` 여도 원문 그대로다."""

    def __init__(self, wire: bytes, *, inflates: bool = True) -> None:
        self._wire = wire
        self._at = 0
        self._decoder = zlib.decompressobj(zlib.MAX_WBITS | 16) if inflates else None
        self._decoded = bytearray()
        self.asked: list[bool | None] = []  # 읽기마다 받은 `decode_content`
        self.closed = False

    def read(self, amt: int | None = None, decode_content: bool | None = None) -> bytes:
        self.asked.append(decode_content)
        if not decode_content or self._decoder is None:
            return self._raw(amt)
        while amt is None or len(self._decoded) < amt:
            data = self._raw(amt)
            if not data:
                break
            self._decoded += self._decoder.decompress(data)  # 상한 없음 — 2.6 미만처럼
        n = len(self._decoded) if amt is None else min(amt, len(self._decoded))
        out = bytes(self._decoded[:n])
        del self._decoded[:n]
        return out

    def stream(self, amt: int = 65_536, decode_content: bool | None = None) -> Iterator[bytes]:
        """requests `iter_content` 가 부르는 자리 — `read` 를 빈 조각까지 되풀이한다."""
        while data := self.read(amt, decode_content=decode_content):
            yield data

    def close(self) -> None:
        self.closed = True

    def _raw(self, amt: int | None) -> bytes:
        end = len(self._wire) if amt is None else self._at + amt
        data = self._wire[self._at : end]
        self._at += len(data)
        return data


@dataclass
class TokenIdp:
    """토큰·introspect 엔드포인트와 admin `GET /admin/realms` 를 내는 실 HTTP 서버(realm `r`).

    ⚠️ **목으로는 토큰 응답 상한을 잴 수 없다** — 상한은 HTTP 전송에서 걸린다(`JwksServer` 와 같은
    이유). ⚠️ **거대 본문은 유효한 JSON + 공백이다** — 쓰레기 바이트로 부풀리면 상한이 없어도 JSON
    파싱이 실패해 「거부됐다」가 거짓 초록이 된다. 본문은 `head` 뒤에 공백을 덧대 정확히 `size`
    바이트다(거대 본문도 64 KiB 버퍼 하나를 잘라 보낸다).
    """

    url: str
    head: bytes = b"{}"
    size: int | None = None  # 본문 전체 바이트. None 이면 head 그대로
    status: int = 200
    chunked: bool = False  # Content-Length 없이 보낸다 — 헤더만 믿는 상한을 걸러내는 대조군
    gzip_body: bytes | None = None  # 미리 압축한 본문(`Content-Encoding: gzip`) — 압축폭탄
    hits: list[str] = field(default_factory=list)
    bearer_len: int | None = None  # admin REST 요청이 실어 온 Authorization 값의 길이
    introspected_len: int | None = None  # introspect 요청 폼의 token 길이
    accept_encoding: str | None = None  # 마지막 토큰 엔드포인트 요청의 Accept-Encoding

    def serve_gzip(self, head: bytes, total: int) -> None:
        """`head` + 공백 `total` 바이트를 gzip 으로 보낸다(`gzip_padded`)."""
        self.gzip_body = gzip_padded(head, total)


def _make_token_handler(box: dict[str, TokenIdp]) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _small(self, status: int, payload: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:
            idp = box["idp"]
            idp.hits.append(self.path)
            if self.path.startswith("/admin/realms"):
                auth = self.headers.get("Authorization")
                idp.bearer_len = len(auth) if auth is not None else None
                self._small(200, b"[]")
            else:
                self._small(404, b'{"error":"not_found"}')

        def do_POST(self) -> None:
            idp = box["idp"]
            length = int(self.headers.get("Content-Length") or 0)
            form = self.rfile.read(length) if length else b""
            idp.hits.append(self.path)
            if not self.path.startswith("/realms/r/protocol/openid-connect/token"):
                self._small(404, b'{"error":"not_found"}')
                return
            idp.accept_encoding = self.headers.get("Accept-Encoding")
            if self.path.endswith("/introspect"):
                token = parse_qs(form.decode("ascii", "replace")).get("token", [""])[0]
                idp.introspected_len = len(token)
            self._body(idp)

        def _body(self, idp: TokenIdp) -> None:
            self.send_response(idp.status)
            self.send_header("Content-Type", "application/json")
            if idp.gzip_body is not None:
                self.send_header("Content-Encoding", "gzip")
                total = len(idp.gzip_body)
                pieces: Iterator[memoryview] = iter([memoryview(idp.gzip_body)])
            else:
                total = len(idp.head) if idp.size is None else idp.size
                pieces = _padded(idp.head, total)
            if idp.chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(total))
            self.end_headers()
            try:
                for piece in pieces:
                    if idp.chunked:
                        self.wfile.write(b"%x\r\n" % len(piece) + piece.tobytes() + b"\r\n")
                    else:
                        self.wfile.write(piece)
                if idp.chunked:
                    self.wfile.write(b"0\r\n\r\n")
            except OSError:
                # 상한에 걸린 클라이언트가 끊었다 — 상한이 작동한 증거이지 오류가 아니다.
                self.close_connection = True

    return Handler


@pytest.fixture
def token_idp() -> Any:
    box: dict[str, TokenIdp] = {}
    server = _QuietServer(("127.0.0.1", 0), _make_token_handler(box))
    box["idp"] = TokenIdp(url=f"http://127.0.0.1:{server.server_address[1]}")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield box["idp"]
    server.shutdown()
    server.server_close()


@pytest.fixture
def trap() -> Any:
    box: dict[str, Trap] = {}
    idp = ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(box, "idp"))
    evil = ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(box, "evil"))
    box["trap"] = Trap(
        idp_url=f"http://127.0.0.1:{idp.server_address[1]}",
        evil_url=f"http://127.0.0.1:{evil.server_address[1]}",
    )
    for server in (idp, evil):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    yield box["trap"]
    for server in (idp, evil):
        server.shutdown()
        server.server_close()


class _FakeResponse:
    """python-keycloak `raise_error_from_response` 가 읽는 만큼만 흉내 낸 응답."""

    def __init__(self, status_code: int, content: bytes) -> None:
        self.status_code = status_code
        self.content = content

    def json(self) -> Any:
        return json.loads(self.content)


@pytest.fixture(scope="session")
def lower_type_error() -> Any:
    """python-keycloak 이 **실제로** 던지는, 응답 본문을 인용한 `TypeError` 를 만든다.

    200 인데 JSON 객체가 아닌 본문이면 `KeycloakOpenID.token` 이 `value b'...'` 로 본문을 실은
    `TypeError` 를 던진다(7.1.1 실측). 네트워크 없이 — `raw_post` 만 바꿔 끼운다."""
    from keycloak import KeycloakOpenID

    openid = KeycloakOpenID(server_url="https://kc.invalid", realm_name="r", client_id="c")

    def make(body: bytes) -> TypeError:
        openid.connection.raw_post = lambda *_a, **_k: _FakeResponse(200, body)
        try:
            openid.token(grant_type="client_credentials")
        except TypeError as exc:
            assert body.decode() in str(exc), "python-keycloak 이 더는 본문을 인용하지 않는다"
            return exc
        raise AssertionError("python-keycloak 이 TypeError 를 던지지 않았다")

    return make


@pytest.fixture(scope="session")
def lower_post_error() -> Any:
    """python-keycloak 이 오류 응답에서 **실제로** 만드는 오류 — 메시지가 본문이다. 401 이면
    `KeycloakAuthenticationError`, 그 밖은 `KeycloakPostError` 다(`raise_error_from_response`)."""
    from keycloak.exceptions import KeycloakError, KeycloakPostError, raise_error_from_response

    def make(status: int, body: bytes) -> KeycloakError:
        try:
            raise_error_from_response(_FakeResponse(status, body), KeycloakPostError)
        except KeycloakError as exc:
            return exc
        raise AssertionError("python-keycloak 이 오류를 던지지 않았다")

    return make
