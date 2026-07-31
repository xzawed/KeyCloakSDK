"""단위 테스트 공유 픽스처 — 백채널 리다이렉트 덫 서버(sync/async 공용)."""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

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
