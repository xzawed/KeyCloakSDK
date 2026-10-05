"""토큰·introspection 응답 본문에 바이트 상한을 건다 — auth 백채널과 admin 자체 그랜트,
sync·aio 모두.

⚠️ **상류는 본문을 통째로 읽는다.** python-keycloak 의 `raw_post` 는 `stream` 없이 보내므로
requests 가 `r.content` 로 본문 전체를 읽고, aio 는 httpx `send` 가 `aread()` 한다 — 상한도
`Content-Length` 검사도 없다. JSON 공백으로 32 MiB 를 덧댄 **쓸 수 있는** 토큰 응답을 열 레인
(cc·refresh·code·introspect·admin 그랜트, 각각 sync·aio) 전부가 받아들였고 프로세스 피크가
+70 MB 늘었다(실측 2026-10-05). 상류에는 상한을 넘길 인자가 없다 — `raw_*` 가 `**kwargs` 를
`params=` 로 보낸다(`jwks_fetch.py` 와 같은 이유).

**어디에 거는가.** 세션 인스턴스의 `send` 를 감싼다 — requests `Session.send`, httpx
`AsyncClient.send`. 그 세션의 요청이 전부 지나는 한 자리이고, 호출자가 본문을 스트리밍으로
받으려는지(`stream`)를 안다. `stream=True` 로 온 요청은 그대로 보낸다 — 같은 세션의 JWKS 직접
GET(`jwks_fetch.py`)이 그렇고, 그쪽은 51,200 상한을 스스로 건다. 나머지는 스트리밍으로 받아
본문을 이 상한까지만 읽는다 — 읽은 만큼만 메모리를 잡는다. python-keycloak 이 세션에 단
재시도·풀 어댑터는 건드리지 않는다.

⚠️ **세는 것은 푼 뒤의 바이트이고, 푸는 것은 두 미러 모두 이 모듈이다(`_inflater`).** 하위
디코더에 맡기면 상한이 그 버전에 달린다 — httpx 디코더에는 상한이 없고(`jwks_fetch.py` 실측:
20 MB 폭탄에 피크 84 MB), urllib3 는 2.6.0 부터만 `read(amt, decode_content=True)` 를 `amt`
까지만 푼다. requests 는 urllib3 1.26 부터 받고 이 SDK 는 urllib3 하한을 두지 않는데, 2.5.0 에서는
16 MiB gzip 폭탄이 한 번의 `decompress` 에 16,762,622 바이트로 풀려 sync 여섯 레인의 피크가
47.6 MB 였다(2.8.0 은 1.2 MB, 실측 2026-10-05). 그래서 둘 다 원문(sync `read(amt,
decode_content=False)`·aio `aiter_raw`)을 받아 여기서 풀고, 그렇게 풀 수 있는 인코딩만 요구한다.

**한 번에 얼마나 넘을 수 있나.** 쌓는 본문은 두 미러 모두 cap+1 을 넘지 않는다 — 풀기를
`max_length` 로 묶는다(`_keep`). 원문 조각의 크기는 sync 는 우리가 정하고(받은 것 + 이번에 청하는
것이 cap+1 을 넘지 않는다), aio 는 전송이 정한다(httpcore 의 한 번 읽기는 64 KiB — 조각은 받은
뒤에야 보이므로 그 나머지가 상한 너머에 잠깐 있을 수 있다).

⚠️ **여기서 던지는 것은 신호다.** python-keycloak 의 `raw_*` 는 세션 안에서 난 예외를 전부
`KeycloakConnectionError("Can't connect to server")` 로 감싼다. 경계(`lower.py` 의
`refused_body`)가 `__cause__` 에서 이 신호를 알아보고 같은 메시지의 `KeycloakAuthError` 를
**새로** 만든다 — 신호는 python-keycloak 의 프레임(보낼 폼, 곧 `client_secret`)을 지나왔으므로
원인으로 달지 않는다.

⚠️ **admin REST 세션에는 걸지 않는다** — 사용자 목록은 정당하게 크다. admin 은 자체 그랜트의
세션(중첩 `KeycloakOpenID`)에만 걸고, 그 설치는 `admin_guard.py` 가 요청마다 다시 본다.
"""

from __future__ import annotations

import zlib
from collections.abc import Awaitable, Callable, Coroutine
from typing import Any

import httpx
import requests

from ..exceptions import KeycloakConfigError

#: 토큰·introspection 응답 본문의 상한 — 푼 뒤 바이트. Keycloak 26.6 이 기본 설정으로 받는
#: 가장 긴 bearer(65,459 바이트, 실측 2026-10-03)의 16 배라 서버가 받는 토큰은 거부하지 않는다.
#: ⚠️ 아홉 언어가 함께 움직이는 값이고 교차 언어 가드가 이 리터럴을 읽는다 — 식(`1 << 20`)으로
#: 바꾸지 말 것.
TOKEN_RESPONSE_MAX_BYTES = 1_048_576

#: sync 한 번 읽기의 상한. ~2 KiB 응답에 상한 크기 버퍼를 잡지 않게 작게 둔다.
_CHUNK = 16_384
#: 두 미러가 요구하는 인코딩 — 상한 안에서 풀 수 있는 것만. httpx 도 requests 도 `brotli`·
#: `zstandard` 가 깔려 있으면 `br`·`zstd` 를 요구하는데, 여기서는 그것을 `max_length` 로 묶어 풀 수
#: 없다.
_ACCEPT_ENCODING = "gzip, deflate"
_INFLATABLE = ("gzip", "deflate")
#: 이 모듈이 감싼 `send` 의 표지 — 같은 세션을 두 번 감싸지 않는다.
_MARK = "__kcsdk_capped__"

_SyncSend = Callable[..., requests.Response]
_AsyncSend = Callable[..., Awaitable[httpx.Response]]
_Inflate = Callable[[bytes, int], bytes]


class ResponseRefused(Exception):
    """세션이 응답 본문을 거부했다 — 경계가 같은 메시지의 `KeycloakAuthError` 로 바꾸는 신호."""


def _kind(path: str) -> str:
    """메시지에 쓸 응답 이름 — 같은 세션이 토큰·introspection·logout 을 함께 나른다."""
    path = path.split("?", 1)[0].rstrip("/")
    if path.endswith("/token/introspect"):
        return "introspection response"
    if path.endswith("/token"):
        return "token response"
    if path.endswith("/logout"):
        return "logout response"
    return "identity provider response"


def _too_large(kind: str) -> ResponseRefused:
    return ResponseRefused(f"{kind} exceeds {TOKEN_RESPONSE_MAX_BYTES} bytes")


def _keep(body: bytearray, inflate: _Inflate, data: bytes, kind: str) -> None:
    """원문 조각 하나를 상한 안에서 풀어 쌓는다 — 넘으면 거부한다(sync·aio 공용). `limit` 은
    언제나 1 이상이다 — 본문이 cap 을 넘는 순간 거부하므로 cap+1-len 은 0 이 되지 않는다."""
    body += inflate(data, TOKEN_RESPONSE_MAX_BYTES + 1 - len(body))
    if len(body) > TOKEN_RESPONSE_MAX_BYTES:
        raise _too_large(kind)


def _read(response: requests.Response, kind: str) -> bytes:
    """원문을 cap+1 까지만 청해 읽고(`decode_content=False` — urllib3 에 풀기를 맡기지 않는다)
    여기서 상한 안에서 푼다."""
    inflate = _inflater(response.headers.get("content-encoding", "").split(","), kind)
    body = bytearray()
    while data := response.raw.read(
        min(_CHUNK, TOKEN_RESPONSE_MAX_BYTES + 1 - len(body)), decode_content=False
    ):
        _keep(body, inflate, data, kind)
    return bytes(body)


def capped_send(send: _SyncSend) -> _SyncSend:
    """requests `Session.send` 를 감싼다 — 스트리밍이 아닌 요청의 본문을 원문으로 받아 상한까지만
    푼다(aio 와 같다)."""

    def capped(request: requests.PreparedRequest, **kwargs: Any) -> requests.Response:
        if kwargs.get("stream"):
            return send(request, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING
        response = send(request, **{**kwargs, "stream": True})
        try:
            body = _read(response, _kind(request.path_url))
        except BaseException:
            response.close()  # 남은 본문을 읽지 않고 연결째 버린다
            raise
        # requests 가 `content` 에서 하는 일 그대로다 — 다 읽은 본문을 응답에 둔다.
        response._content = body
        response._content_consumed = True
        return response

    return capped


def _inflater(codings: list[str], kind: str) -> _Inflate:
    """`Content-Encoding` 대로 원문을 상한 안에서 푸는 함수. `limit` 은 언제나 1 이상이다 —
    `decompress(data, 0)` 은 「상한 없음」이라 0 을 넘기면 안 된다(호출자가 cap 을 넘기 전에
    멈춘다).

    httpx 와 같게 모르는 이름(`identity`·`br`·`zstd`…)은 풀지 않고 원문 그대로 센다. 압축이
    둘 이상 겹친 응답은 묶어서 풀 수 없으므로 거부한다.

    ⚠️ 스트림이 끝난 뒤의 입력은 풀지도 쥐지도 않는다 — zlib 의 `decompressobj` 는 끝난 뒤 받은
    입력을 **전부** `unused_data` 에 이어 붙이고, 상한은 푼 바이트에만 걸린다(aio 레인 실측: 작은
    gzip 뒤에 16 MiB 를 덧대면 피크 34 MB). 그 꼬리는 읽어서 버린다 — 두 번째 gzip 멤버도 풀지
    않는다(httpx 와 같고, 멤버를 이어 푸는 urllib3 와는 다르다)."""
    known = [c.strip().lower() for c in codings if c.strip().lower() in _INFLATABLE]
    if not known:
        return lambda data, limit: data[:limit]
    if len(known) > 1:
        raise ResponseRefused(f"{kind} is compressed more than once ({', '.join(known)})")
    if known[0] == "gzip":
        gzip = zlib.decompressobj(zlib.MAX_WBITS | 16)
        return lambda data, limit: b"" if gzip.eof else gzip.decompress(data, limit)
    # deflate 는 zlib 래퍼가 표준이지만 날 deflate 를 보내는 서버가 있다 — httpx 처럼 첫 조각이
    # 실패하면 날 deflate 로 다시 푼다.
    inflater = zlib.decompressobj()
    first = True

    def deflate(data: bytes, limit: int) -> bytes:
        nonlocal inflater, first
        if inflater.eof:
            return b""
        was_first, first = first, False
        try:
            return inflater.decompress(data, limit)
        except zlib.error:
            if not was_first:
                raise
            inflater = zlib.decompressobj(-zlib.MAX_WBITS)
            return inflater.decompress(data, limit)

    return deflate


async def _aread(response: httpx.Response, kind: str) -> bytes:
    inflate = _inflater(response.headers.get_list("content-encoding", split_commas=True), kind)
    body = bytearray()
    async for data in response.aiter_raw():
        _keep(body, inflate, data, kind)
    return bytes(body)


def acapped_send(send: _AsyncSend) -> Callable[..., Coroutine[Any, Any, httpx.Response]]:
    """httpx `AsyncClient.send` 를 감싼다 — sync 와 같다(원문을 받아 여기서 푼다)."""

    async def capped(
        request: httpx.Request, *, stream: bool = False, **kwargs: Any
    ) -> httpx.Response:
        if stream:
            return await send(request, stream=True, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING
        response = await send(request, stream=True, **kwargs)
        try:
            body = await _aread(response, _kind(request.url.path))
        except BaseException:
            await response.aclose()
            raise
        # httpx 가 `aread()` 에서 하는 일 그대로다(푼 본문을 두고 `Content-Encoding` 은 남긴다).
        response._content = body
        return response

    return capped


def unsupported(where: str) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot bound the size of token responses: this SDK expects python-keycloak to expose "
        f"{where}, but it is missing or not callable. Refusing to build a client that would read "
        f"an unbounded token response into memory. Pin python-keycloak to a supported version "
        f"(>=7.1,<8) and report this at https://github.com/xzawed/KeyCloakSDK/issues."
    )


def _wrap_send(conn: Any, attr: str, wrap: Callable[[Any], Callable[..., Any]]) -> None:
    session: Any = getattr(conn, attr, None)
    send = getattr(session, "send", None)
    if not callable(send):
        raise unsupported(f"connection.{attr}.send")
    if getattr(send, _MARK, False):
        return
    capped = wrap(send)
    setattr(capped, _MARK, True)
    session.send = capped


def cap_openid(openid: Any) -> None:
    """auth 레인의 `KeycloakOpenID` — 두 세션의 `send` 를 감싼다(생성 때 한 번,
    `harden_openid` 처럼).

    sync 는 `connection._s`(requests), aio 는 `connection.async_s`(httpx)로 나가지만 두 미러가
    두 세션을 다 가진다 — 쓰지 않는 쪽도 감싼다(`harden_openid` 와 같은 심층방어)."""
    conn = openid.connection
    _wrap_send(conn, "_s", capped_send)
    _wrap_send(conn, "async_s", acapped_send)
