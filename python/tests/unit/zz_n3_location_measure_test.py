"""measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).

What id does `admin.users.create` return — sync (python-keycloak over requests) and aio (over httpx) — when the 201's
Location carries a byte that is not visible ASCII? A raw TCP server answers the token grant with a token and the create
with 201 + `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd`
(Latin-1 obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE),
what requests and httpx hand back as the header (CLIENT), and what the SDK returns (ID).

Run: N3_OUT=<file> <venv python> -m pytest tests/unit/zz_n3_location_measure_test.py -p no:cacheprovider
"""

from __future__ import annotations

import importlib.metadata
import os
import socket
import sys
import threading
from typing import Any

import httpx
import keycloak_sdk
import requests

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient

USERS = "/admin/realms/it-realm/users"
CASES = [
    ("ascii-control", b"abc"),
    ("latin1-0xE9", b"ab\xe9cd"),
    ("utf8-0xC3A9", b"ab\xc3\xa9cd"),
]


class _RawServer:
    """One request per connection (head + Content-Length body); the Location value is written as raw bytes."""

    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.location = b""
        self.seen: list[str] = []
        self.lock = threading.Lock()
        threading.Thread(target=self._serve, daemon=True).start()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                buf += chunk
            head, _, body = buf.partition(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            method, path = lines[0].split(" ")[:2]
            length = 0
            for line in lines[1:]:
                name, _, value = line.partition(":")
                if name.strip().lower() == "content-length":
                    length = int(value.strip())
            while len(body) < length:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                body += chunk
            with self.lock:
                self.seen.append(f"{method} {path}")
                location = self.location
            if path.endswith("/protocol/openid-connect/token"):
                payload = b'{"access_token":"at-n3","token_type":"Bearer","expires_in":300}'
                answer = (
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    + str(len(payload)).encode()
                    + b"\r\nConnection: close\r\n\r\n"
                    + payload
                )
            elif method == "POST" and path.rstrip("/") == USERS:
                answer = b"HTTP/1.1 201 Created\r\nLocation: " + location + b"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            else:
                answer = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.sendall(answer)

    def close(self) -> None:
        self.sock.close()


def _hex(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


def _show(s: Any) -> str:
    if s is None:
        return "None"
    if not isinstance(s, str):
        return f"{type(s).__name__}({s!r})"
    escaped = "".join(c if 0x20 <= ord(c) < 0x7F else f"\\u{ord(c):04X}" for c in s)
    return f'"{escaped}" cps=[{",".join(f"U+{ord(c):04X}" for c in s)}]'


def _tail(s: str | None) -> str | None:
    return None if s is None else s.rsplit("/", 1)[-1]


def _wire_probe(port: int) -> bytes:
    with socket.create_connection(("127.0.0.1", port)) as c:
        c.sendall(f"POST {USERS} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
        raw = b""
        while chunk := c.recv(4096):
            raw += chunk
    for line in raw.split(b"\r\n"):
        if line.startswith(b"Location: "):
            return line[len(b"Location: ") :]
    return b""


def _err(e: BaseException) -> str:
    cause = f" cause={type(e.__cause__).__name__}: {e.__cause__}" if e.__cause__ is not None else ""
    return f"Err({type(e).__name__}: {e}{cause})".replace("|", "/").replace("\n", " ")


async def test_zz_n3_location_measure() -> None:
    out_path = os.environ["N3_OUT"]
    srv = _RawServer()
    versions = "|".join(
        f"{d}={importlib.metadata.version(d)}" for d in ("requests", "urllib3", "httpx", "h11", "python-keycloak")
    )
    out = [
        f"ENV|python={sys.version.split()[0]}|{versions}|keycloak_sdk_from={'worktree' if 'kc-n3' in keycloak_sdk.__file__ else keycloak_sdk.__file__}",
        "HEADER|sdk|lane|case|field|value",
    ]
    cfg = KeycloakConfig(server_url=srv.base, realm="it-realm", client_id="it-client", client_secret="dummy-secret")
    for name, id_ in CASES:
        prefix = f"{srv.base}{USERS}/".encode()
        with srv.lock:
            srv.location = prefix + id_
        got = _wire_probe(srv.port)
        out.append(
            f"WIRE|python|-|{name}|location=<base>/admin/realms/it-realm/users/+[{_hex(id_)}]"
            f"|raw_socket_read_equals_sent={got == prefix + id_}|id_bytes_on_wire={_hex(got[len(prefix):])}"
        )
        r = requests.post(f"{srv.base}{USERS}", data=b"{}", allow_redirects=False, timeout=5)
        out.append(
            f"CLIENT|python|requests(http.client)|{name}|status={r.status_code}"
            f"|headers['Location'].after_last_slash={_show(_tail(r.headers.get('Location')))}"
        )
        h = httpx.post(f"{srv.base}{USERS}", content=b"{}", follow_redirects=False, timeout=5)
        out.append(
            f"CLIENT|python|httpx|{name}|status={h.status_code}"
            f"|headers['location'].after_last_slash={_show(_tail(h.headers.get('location')))}"
            f"|headers.encoding={h.headers.encoding}"
        )
        for lane in ("sync", "aio"):
            with srv.lock:
                srv.seen.clear()
            try:
                if lane == "sync":
                    with KeycloakClient.create(cfg) as kc:
                        result = f"Ok({_show(kc.admin.users.create({'username': 'n3-user'}))})"
                else:
                    async with AsyncKeycloakClient.create(cfg) as akc:
                        result = f"Ok({_show(await akc.admin.users.create({'username': 'n3-user'}))})"
            except Exception as e:  # noqa: BLE001 — the measurement records whatever comes out
                result = _err(e)
            with srv.lock:
                seen = ",".join(srv.seen)
            out.append(f"ID|python|{lane} admin.users.create|{name}|{result}|requests={seen}")
    srv.close()
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    assert sum(1 for line in out if line.startswith("ID|")) == 6
