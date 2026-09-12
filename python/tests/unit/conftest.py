"""단위 테스트 공유 픽스처 — 백채널 리다이렉트 덫 서버(sync/async 공용)."""

from __future__ import annotations

import gzip
import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from unittest.mock import AsyncMock, MagicMock

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
