"""admin 요청의 URL 은 보낼 bearer 토큰을 싣지 않는다(등록부
`python-raw-upload-certificate-bearer-in-url`).

python-keycloak 7.1.1 의 `KeycloakOpenIDConnection.raw_post(path, data, **kwargs)` 는 남은
키워드 인자를 전부 쿼리로 보낸다(sync `params=kwargs` ·
aio `params=self._filter_query_params(kwargs)`). `upload_certificate`·`a_upload_certificate` 는
그 자리에 `headers=new_headers` — bearer 를 실은 헤더 사전 — 를 넘긴다(424 개 `raw_*` 호출
가운데 그 둘뿐이다). aio(httpx)는 사전의 글(`str(dict)`)을 URL 에 싣는다(수정 전 실측 —
`…/upload-certificate?headers=%7B%27Content-Type%27%3A+…%27Authorization%27%3A+%27Bearer+<토큰>…`)
— 서버·프록시의 접근 로그에 토큰이 남는다. sync(requests)는 사전을 키 이름으로만 쓴다
(`?headers=Content-Type&headers=Authorization`). 예전에는 `raw` 로 닿았다 — 이제 `raw` 의 업로드는
SDK 의 것이라 쿼리가 없고(`_internal/admin_upload.py`), python-keycloak 의 것은 소비자 하위 클래스의
`super()` 로 닿는다(아래 업로드 시험은 감시 클래스를 건너뛰어 그것을 부른다).

보내는 자리(REST 세션의 `send` — `_internal/admin_guard.py`)가, 나갈 bearer 의 토큰이 요청
URL 에 그대로든 퍼센트 디코딩한 꼴(`unquote_plus`)로든 나타나면 보내지 않는다 —
`KeycloakTransportError`「admin request refused: the request URL would carry the access
token」. 탈출구 `raw` 는 #1141 의 송신 자리 거부처럼 python-keycloak 이 감싼 채
(`KeycloakConnectionError` ← 그 오류) 받고, 파사드는 같은 타입·문구로 새로 받는다(사슬·
python-keycloak 프레임 없음).
"""

from __future__ import annotations

import contextlib
import json
import threading
from collections.abc import AsyncIterator, Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qsl, unquote_plus, urlsplit

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakConnectionError

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import KeycloakTransportError

from .test_admin_grant import LANES, _attempt, _chain, _inner_frames

pytestmark = pytest.mark.usefixtures("fast_tls")

IN_URL = "admin request refused: the request URL would carry the access token"
#: 그랜트가 돌려줄 토큰 — `plain` 은 URL 에 글자 그대로 실리고, `encoded` 는 쿼리에서 `/`·`+`·`=`
#: 가 퍼센트 인코딩돼 **디코딩한 꼴에만** 나타난다(`unquote_plus` 갈래).
TOKENS = {"plain": "GD5k2w-good-access-token", "encoded": "GD5k2w/good+access-token=="}
_TOKEN = "/realms/r/protocol/openid-connect/token"
_USER = "admin/realms/r/users/u1"
_UPLOAD = "/admin/realms/r/clients/c1/certificates/jwt.credential/upload-certificate"
#: 3xx 답의 `Location` — 따라가면 이 경로가 `seen` 에 적힌다.
ELSEWHERE = "/elsewhere"
#: 선언한 본문이 다 오기를 기다리는 상한(초) — `Content-Length` 만 싣고 본문을 보내지 않는 요청
#: 앞에서 처리기를 놓아 준다(그 요청은 적고 답 없이 끊는다). 제대로 된 요청은 곧바로 다 온다.
_BODY_WAIT = 2.0


@dataclass(frozen=True)
class _Seen:
    method: str
    target: str  # 경로와 쿼리 — 받은 그대로
    #: 받은 `Content-Type` — 대조(`==`)에는 들지 않는다. 헤더 복원 시험
    #: (`test_admin_upload_certificate_headers.py`)이 읽는다.
    content_type: str | None = field(default=None, compare=False)
    #: 아래 넷도 대조에 들지 않는다 — 업로드 시험(`test_admin_upload_certificate_in_flight.py`)이
    #: 읽는다. 받은 `Content-Type` 줄 전부 · `Authorization` · 선언한 `Content-Length` · 받은 본문.
    content_types: tuple[str, ...] = field(default=(), compare=False)
    authorization: str | None = field(default=None, compare=False)
    length: int = field(default=0, compare=False)
    body: bytes = field(default=b"", compare=False)


@dataclass
class _Idp:
    """그랜트는 `access_token` 을 돌려주고, admin 요청은 받은 그대로 적는다."""

    access_token: str
    url: str = ""
    seen: list[_Seen] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)
    #: 주면 `held_path` 의 다음 요청 하나를 붙잡는다 — `holding` 을 알리고 이것이 설정될 때까지
    #: 기다렸다가 응답 없이 끊는다(보낸 쪽에는 전송 실패다). 그 뒤의 요청은 답한다.
    hold: threading.Event | None = None
    held_path: str = _TOKEN
    holding: threading.Event = field(default_factory=threading.Event)
    #: 참이면 붙잡은 요청도 풀린 뒤 답한다(끊지 않는다).
    answer_held: bool = False
    #: 업로드 경로의 답 각본 — (상태, 본문)을 차례로 꺼낸다. 비면 200 `{"certificate": "PEM"}`.
    uploads: list[tuple[int, bytes]] = field(default_factory=list)

    def admin_requests(self) -> list[_Seen]:
        with self.lock:
            return [s for s in self.seen if s.target.startswith("/admin/")]

    def paths(self) -> list[str]:
        """받은 요청 전부의 경로 — 그랜트와 3xx 의 `Location` 도."""
        with self.lock:
            return [urlsplit(s.target).path for s in self.seen]


def _read_body(handler: BaseHTTPRequestHandler, length: int) -> bytes:
    """선언한 길이까지 받는다 — `_BODY_WAIT` 초 안에 오지 않은 나머지는 기다리지 않는다."""
    body = b""
    handler.connection.settimeout(_BODY_WAIT)
    try:
        while len(body) < length:
            chunk = handler.rfile.read1(length - len(body))
            if not chunk:
                break
            body += chunk
    except TimeoutError:
        pass
    finally:
        handler.connection.settimeout(None)
    return body


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = _read_body(self, length)
            path = urlsplit(self.path).path
            seen = _Seen(
                self.command,
                self.path,
                self.headers.get("Content-Type"),
                tuple(self.headers.get_all("Content-Type") or ()),
                self.headers.get("Authorization"),
                length,
                body,
            )
            with idp.lock:
                idp.seen.append(seen)
                hold = idp.hold if path == idp.held_path else None
                if hold is not None:
                    idp.hold = None
                reply = idp.uploads.pop(0) if path == _UPLOAD and idp.uploads else None
            if len(body) < length:  # 본문이 다 오지 않았다 — 답하지 않는다
                self.close_connection = True
                return
            if hold is not None:
                idp.holding.set()
                hold.wait(10)
                if not idp.answer_held:
                    self.close_connection = True
                    return
            status, obj = 404, {}
            if path == _TOKEN:
                status = 200
                obj = {"access_token": idp.access_token, "expires_in": 300, "token_type": "Bearer"}
            elif path == f"/{_USER}":
                status, obj = 200, {"id": "u1"}
            elif path == _UPLOAD:
                status, obj = 200, {"certificate": "PEM"}
            payload = json.dumps(obj).encode()
            if reply is not None:
                status, payload = reply
            self.send_response(status)
            if 300 <= status < 400:
                self.send_header("Location", ELSEWHERE)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve

    return Handler


@contextlib.contextmanager
def _fake_idp(access_token: str) -> Iterator[_Idp]:
    idp = _Idp(access_token)
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


@contextlib.asynccontextmanager
async def _client(lane: str, url: str) -> AsyncIterator[Any]:
    cfg = KeycloakConfig(
        server_url=url, realm="r", client_id="c", client_secret="s", read_timeout=10.0
    )
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            yield kc
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            yield akc


def _raw_refused(err: BaseException | None) -> list[str]:
    """탈출구의 모양 — 송신 자리의 거부를 python-keycloak 의 `raw_*` 가 감쌌다(#1141 과 같은 길)."""
    if err is None:
        return ["거부하지 않았다"]
    cause = err.__cause__
    if type(err) is not KeycloakConnectionError or type(cause) is not KeycloakTransportError:
        return [f"{type(err).__qualname__}({str(err)!r}) ← {cause!r}"]
    return [] if str(cause) == IN_URL else [f"원인 {str(cause)!r}"]


def _raw_get(lane: str, **query: str) -> Callable[[Any], Any]:
    if lane == "sync":
        return lambda kc: kc.admin.raw.connection.raw_get(_USER, **query)
    return lambda kc: kc.admin.raw.connection.a_raw_get(_USER, **query)


async def test_raw_a_upload_certificate_does_not_send_the_bearer_in_its_url() -> None:
    """python-keycloak 의 aio `a_upload_certificate` 는 헤더 사전을 쿼리로 넘긴다 — 보내기 전에
    거부된다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client("aio", idp.url) as kc:
            result, err = await _attempt(
                "aio", kc, lambda c: KeycloakAdmin.a_upload_certificate(c.admin.raw, "c1", "PEM")
            )

    assert idp.admin_requests() == [], "토큰을 URL 에 실은 요청이 나갔다"
    assert result is None
    assert _raw_refused(err) == []


@pytest.mark.parametrize("token", sorted(TOKENS))
@pytest.mark.parametrize("lane", LANES)
async def test_a_raw_request_whose_query_carries_the_token_is_not_sent(
    lane: str, token: str
) -> None:
    """쿼리가 지금 보낼 토큰을 품는다 — 글자 그대로든 퍼센트 인코딩돼서든."""
    value = TOKENS[token]
    with _fake_idp(value) as idp:
        async with _client(lane, idp.url) as kc:
            result, err = await _attempt(lane, kc, _raw_get(lane, q=value))

    assert idp.admin_requests() == [], "토큰을 URL 에 실은 요청이 나갔다"
    assert result is None
    assert _raw_refused(err) == []


@pytest.mark.parametrize("lane", LANES)
async def test_a_raw_request_with_an_unrelated_query_is_sent(lane: str) -> None:
    """대조 — 거부는 그 토큰에만 걸린다. 같은 경로·같은 쿼리 이름은 그대로 나간다."""
    with _fake_idp(TOKENS["encoded"]) as idp:
        async with _client(lane, idp.url) as kc:
            response, err = await _attempt(lane, kc, _raw_get(lane, q="unrelated"))

    assert err is None, repr(err)
    assert response.status_code == 200
    assert idp.admin_requests() == [_Seen("GET", f"/{_USER}?q=unrelated")]


async def test_sync_upload_certificate_is_sent_without_the_token_in_its_url() -> None:
    """python-keycloak 의 sync `upload_certificate` 는 헤더 사전을 키 이름으로만 쓴다 — URL 에
    토큰이 없으니 나간다(지나치게 거부하지 않는다)."""
    token = TOKENS["encoded"]
    with _fake_idp(token) as idp:
        async with _client("sync", idp.url) as kc:
            result, err = await _attempt(
                "sync", kc, lambda c: KeycloakAdmin.upload_certificate(c.admin.raw, "c1", "PEM")
            )

    assert (result, err) == ({"certificate": "PEM"}, None)
    [sent] = idp.admin_requests()
    target = urlsplit(sent.target)
    assert (sent.method, target.path) == ("POST", _UPLOAD)
    assert sorted(parse_qsl(target.query)) == [
        ("headers", "Authorization"),
        ("headers", "Content-Type"),
    ]
    assert token not in sent.target
    assert token not in unquote_plus(sent.target)


@pytest.mark.parametrize("lane", LANES)
async def test_a_facade_request_whose_url_carries_the_token_is_refused_cleanly(lane: str) -> None:
    """파사드 경계는 그 거부를 같은 타입·문구로 새로 만든다 — 「Can't connect to server」가 아니다.
    경로가 토큰을 품는 호출(사용자 id 로 토큰을 넘김)이다."""
    token = TOKENS["plain"]
    with _fake_idp(token) as idp:
        async with _client(lane, idp.url) as kc:
            result, err = await _attempt(lane, kc, lambda c: c.admin.users.get(token))

    assert idp.admin_requests() == [], "토큰을 URL 에 실은 요청이 나갔다"
    assert result is None
    assert type(err) is KeycloakTransportError, repr(err)
    assert str(err) == IN_URL
    assert _chain(err) == [], "python-keycloak 의 감싼 오류가 사슬로 닿는다"
    assert _inner_frames(err) == [], "traceback 이 python-keycloak 프레임을 지난다"
