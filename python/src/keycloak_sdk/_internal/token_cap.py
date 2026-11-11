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
본문을 이 상한까지만 읽는다 — 읽은 만큼만 메모리를 잡는다. 세션의 어댑터(풀·재시도)는 이
모듈이 건드리지 않는다 — 재시도는 `retries.py` 가 끈다.

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
`refused_body`)가 `__cause__` 에서 이 신호를 알아보고 같은 메시지의 SDK 오류를 **새로** 만든다
— 상한을 넘은 본문(`incomplete`)은 다 읽지 않은 응답이라 `KeycloakTransportError`, 받은
머리만으로 쓸 수 없는 응답(두 번 압축 — 본문을 읽기 전에 거부)은 `KeycloakAuthError` 다. 신호는
python-keycloak 의 프레임(보낼 폼, 곧 `client_secret`)을 지나왔으므로 원인으로 달지 않는다.

**2xx 토큰·introspection 본문은 UTF-8 이어야 한다**(`_strict_utf8`) — 다 읽은 본문을
여기서 보는 자리가 이 모듈뿐이라 같이 둔다. 거부는 받은 머리만으로 쓸 수 없는 응답과 같은
신호(`KeycloakAuthError`)다.

⚠️ **admin REST 세션에는 걸지 않는다** — 사용자 목록은 정당하게 크다(그 세션의 오류
본문 상한과 쓰지 않는 본문은 `admin_body.py` 가 맡는다). admin 은 자체 그랜트의
세션(중첩 `KeycloakOpenID`)에만 걸고, 그 설치는 `admin_guard.py` 가 요청마다 다시 본다.

**언제까지, 얼마나 읽는가.** 요청을 보낸 때부터 그 요청의 타임아웃 안에 — sync 는 소켓의 원문
읽기마다 마감을 보고, aio 는 교환 전체를 마감으로 묶는다(`deadline.py`). sync 는 그 응답이 소켓에서
읽히는 바이트도 묶는다 — 이 상한 + 틀 몫(`wire.FRAMING_ALLOWANCE_BYTES` — 상태 줄·헤더·청크 틀·
트레일러)이다(`wire.py`). 본문 상한은 푼 본문만 세므로, 그것만으로는 4 KiB 트레일러 줄 4,096 개(16
MiB)를 끝까지 읽었다(등록부 `response-framing-unbounded` F3a).
"""

from __future__ import annotations

import zlib
from collections.abc import Awaitable, Callable, Coroutine
from typing import Any

import httpx
import requests

from ..exceptions import KeycloakConfigError
from .deadline import reader, request_seconds, seconds, within
from .wire import FRAMING_ALLOWANCE_BYTES, exchange

#: 토큰·introspection 응답 본문의 상한 — 푼 뒤 바이트. Keycloak 26.6 이 기본 설정으로 받는
#: 가장 긴 bearer(65,459 바이트, 실측 2026-10-03)의 16 배라 서버가 받는 토큰은 거부하지 않는다.
#: ⚠️ 아홉 언어가 함께 움직이는 값이고 교차 언어 가드가 이 리터럴을 읽는다 — 식(`1 << 20`)으로
#: 바꾸지 말 것.
TOKEN_RESPONSE_MAX_BYTES = 1_048_576
#: sync 응답 하나가 소켓에서 읽혀도 되는 바이트 — 본문 상한 + 틀 몫(`wire.py`).
_WIRE_BUDGET = TOKEN_RESPONSE_MAX_BYTES + FRAMING_ALLOWANCE_BYTES

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
#: 압축 스트림이 끝났는가(gzip·deflate) — 풀지 않는 원문에는 없다(None).
_Ended = Callable[[], bool]


class ResponseRefused(Exception):
    """세션이 응답 본문을 거부했다 — 경계가 같은 메시지의 SDK 오류로 바꾸는 신호. `incomplete` 면
    본문을 다 읽지 않았다(상한 초과 · 잘린 압축 → `KeycloakTransportError`), 아니면 끝까지 온
    응답을 쓸 수 없다(두 번 압축 — 본문을 읽기 전 · 풀 수 없는 압축 · 2xx 본문이 UTF-8 JSON 텍스트가
    아니거나 짝 없는 서로게이트 이스케이프를 품음 → `KeycloakAuthError`)."""

    def __init__(self, message: str, *, incomplete: bool = False) -> None:
        super().__init__(message)
        self.incomplete = incomplete


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
    return ResponseRefused(f"{kind} exceeds {TOKEN_RESPONSE_MAX_BYTES} bytes", incomplete=True)


#: 본문이 JSON 이라 UTF-8 이어야 하는 응답 — logout 은 상태만 본다.
_JSON_KINDS = ("token response", "introspection response")


def _strict_utf8(status: int, kind: str, body: bytes) -> None:
    """2xx 토큰·introspection 본문은 UTF-8 이어야 한다(RFC 8259 §8.1) — 아니면 받은 응답을
    쓸 수 없다는 거부다(`KeycloakAuthError` · 등록부 token-response-class-divergent D1).

    ⚠️ sync 는 requests 가 `application/json` 을 `errors="replace"` 로 풀어 잘못된 바이트를
    U+FFFD 로 바꾸고 **받아들였다** — IdP 가 내지 않은 토큰·바뀐 클레임이다(실측 2026-11-10:
    introspection 의 username 바이트 `s FF FE vc` 가 `'s\\ufffd\\ufffdvc'` 로 성공). aio 는
    httpx 가 엄격히 풀어 python-keycloak 의 `TypeError` 였다 — 두 미러가 여기서 같은 거부를
    낸다. 오류 응답(4xx·5xx)의 본문은 보지 않는다(판정은 상태가 한다). 선언된 charset 도 보지
    않는다 — RFC 8259 §11, application/json 에는 효과가 없다."""
    if not 200 <= status < 300 or kind not in _JSON_KINDS:
        return
    try:
        body.decode("utf-8")
    except UnicodeDecodeError:
        readable = False
    else:
        readable = True
    # ⚠️ 거부는 `except` **밖**이다 — 안에서 던지면 본문을 쥔 `UnicodeDecodeError` 가
    # `__context__` 로 매달린다.
    if not readable:
        raise ResponseRefused(f"{kind} is not valid UTF-8")
    # 0x00 — UTF-8 JSON 텍스트에는 없다(RFC 8259 §7). 모든 바이트가 UTF-8 인 BOM 없는 UTF-16
    # 본문을 aio 의 `json.loads(bytes)` 가 인코딩을 짐작해 받아들였다(실측 2026-11-11, 등록부
    # token-response-class-residue — 다른 여덟과 sync 는 거부한다).
    if b"\x00" in body:
        raise ResponseRefused(f"{kind} is not valid JSON")
    # 짝 없는 서로게이트 이스케이프는 어디에 있든 쓸 수 없다(판정 Q2) — 그 값은 UTF-8 로 보낼 수
    # 없어, 받아 둔 refresh token 을 다시 보내면 폼을 만들지 못해 `KeycloakTransportError` 였다.
    if holds_unpaired_surrogate(body):
        raise ResponseRefused(f"{kind} holds an unpaired surrogate escape")


def holds_unpaired_surrogate(json_text: bytes) -> bool:
    """JSON 텍스트가 짝 없는 UTF-16 서로게이트의 `\\u` 이스케이프를 품는가 — 문자열 값이든 멤버
    이름이든(RFC 8259 §8.2 의 문법은 싣지만 I-JSON §2.1 은 금한다). 엄격한 UTF-8 인 바이트를
    그대로 훑는다 — 이스케이프는 ASCII 이고 여러 바이트 글자의 바이트는 `"` 나 `\\` 와 겹치지
    않는다. 이스케이프된 역슬래시 뒤의 `u` 는 이스케이프가 아니고, 형식이 틀린 이스케이프는
    건너뛰고 계속 훑는다(파서의 몫 — 거기서 멈추면 뒤의 것을 못 본다). JVM 의
    `holdsUnpairedSurrogate` 동형."""
    in_string = False
    i = 0
    n = len(json_text)
    while i < n:
        b = json_text[i]
        if not in_string:
            in_string = b == 0x22
        elif b == 0x22:
            in_string = False
        elif b == 0x5C and i + 1 < n:
            if json_text[i + 1] != 0x75:  # 두 글자 이스케이프 — 이스케이프된 글자를 건너뛴다
                i += 2
                continue
            unit = _hex4(json_text, i + 2)
            if unit < 0:
                i += 2
                continue
            i += 5
            if 0xDC00 <= unit <= 0xDFFF:
                return True  # 앞에 높은 서로게이트가 없는 낮은 서로게이트
            if 0xD800 <= unit <= 0xDBFF:
                follows = i + 2 < n and json_text[i + 1] == 0x5C and json_text[i + 2] == 0x75
                low = _hex4(json_text, i + 3) if follows else -1
                if not 0xDC00 <= low <= 0xDFFF:
                    return True
                i += 6
        i += 1
    return False


def _hex4(json_text: bytes, at: int) -> int:
    """`at` 의 16진 넷(대소문자 무관)의 값, 아니면 -1."""
    digits = json_text[at : at + 4]
    if len(digits) != 4 or any(d not in b"0123456789abcdefABCDEF" for d in digits):
        return -1
    return int(digits, 16)


def _keep(body: bytearray, inflate: _Inflate, data: bytes, kind: str) -> None:
    """원문 조각 하나를 상한 안에서 풀어 쌓는다 — 넘으면 거부한다(sync·aio 공용). `limit` 은
    언제나 1 이상이다 — 본문이 cap 을 넘는 순간 거부하므로 cap+1-len 은 0 이 되지 않는다.

    풀지 못하면(`zlib.error` — 깨진 deflate · CRC) 끝까지 온 응답이 쓸 수 없는 것이다(등록부
    판정 Q1, 2026-11-11 — 전에는 python-keycloak 이 감싸 `KeycloakTransportError` 였다). 손상은
    재시도로 고쳐지지 않는다. 깨끗이 끊긴 스트림은 오류가 아니다(본문이 모자라 JSON 판정이
    거부한다)."""
    try:
        inflated = inflate(data, TOKEN_RESPONSE_MAX_BYTES + 1 - len(body))
    except zlib.error:
        corrupt = True
    else:
        corrupt = False
    # ⚠️ 거부는 `except` 밖이다 — `_strict_utf8` 과 같은 이유(원인 사슬에 본문 조각을 매달지 않는다).
    if corrupt:
        raise ResponseRefused(f"{kind} could not be decoded")
    body += inflated
    if len(body) > TOKEN_RESPONSE_MAX_BYTES:
        raise _too_large(kind)


def _read(response: requests.Response, kind: str, check: Callable[[], None]) -> bytes:
    """원문을 와 있는 만큼 cap+1 까지만 청해 읽고(`decode_content=False` — urllib3 에 풀기를 맡기지
    않는다) 여기서 상한 안에서 푼다. 읽기마다 앞뒤로 마감(`check`)을 본다."""
    inflate, ended = _decoder(response.headers.get("content-encoding", "").split(","), kind)
    read = reader(response, check)
    body = bytearray()
    fed = False
    while data := read(min(_CHUNK, TOKEN_RESPONSE_MAX_BYTES + 1 - len(body)), decode_content=False):
        fed = True
        _keep(body, inflate, data, kind)
    _whole(kind, ended, fed)
    return bytes(body)


def _whole(kind: str, ended: _Ended | None, fed: bool) -> None:
    """원문이 끝났는데 그 압축 스트림은 끝나지 않았다 — 잘린 gzip · deflate(꼬리 — CRC · 길이 —
    만 없는 것 포함)는 끊긴 연결과 가를 수 없어 다 오지 않은 응답이다(`KeycloakTransportError` ·
    등록부 token-response-class-residue 판정 Q1 — Go · JVM 의 해제기도 그렇게 낸다). 전에는 꼬리가
    없는 gzip 토큰 응답을 받아들였다(실측 2026-11-11). 원문이 아예 없으면 빈 본문이다(httpx ·
    net/http 와 같다)."""
    if ended is not None and fed and not ended():
        raise ResponseRefused(f"{kind} was cut short", incomplete=True)


def capped_send(send: _SyncSend) -> _SyncSend:
    """requests `Session.send` 를 감싼다 — 스트리밍이 아닌 요청의 본문을 원문으로 받아 상한까지만
    푼다(aio 와 같다)."""

    def capped(request: requests.PreparedRequest, **kwargs: Any) -> requests.Response:
        if kwargs.get("stream"):
            return send(request, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING
        kind = _kind(request.path_url)
        with exchange(seconds(kwargs.get("timeout")), _WIRE_BUDGET) as (check, _lift):
            response = send(request, **{**kwargs, "stream": True})
            try:
                body = _read(response, kind, check)
                _strict_utf8(response.status_code, kind, body)
            except BaseException:
                response.close()  # 남은 본문을 읽지 않고 연결째 버린다
                raise
        # requests 가 `content` 에서 하는 일 그대로다 — 다 읽은 본문을 응답에 둔다.
        response._content = body
        response._content_consumed = True
        if kind in _JSON_KINDS:
            # 선언된 charset 은 효과가 없다(RFC 8259 §11) — requests 의 `json()` 은 그것으로
            # 본문을 풀어(`charset=utf-16` 이면 UTF-8 본문이 글자 덩어리가 된다) python-keycloak
            # 이 bytes 를 돌려줬고 경계가 `TypeError` 로 거부했다(실측 2026-11-11 — aio 는
            # 받아들였다).
            response.encoding = "utf-8"
        return response

    return capped


def _inflater(codings: list[str], kind: str) -> _Inflate:
    """`_decoder` 의 푸는 함수 — JWKS 읽기(`jwks_fetch.py`)가 쓴다. 토큰 응답은 스트림의 끝까지
    묻는다(`_whole`)."""
    return _decoder(codings, kind)[0]


def _decoder(codings: list[str], kind: str) -> tuple[_Inflate, _Ended | None]:
    """`Content-Encoding` 대로 원문을 상한 안에서 푸는 함수와, 그 압축 스트림이 끝났는지 묻는
    함수(원문 그대로면 None). admin 오류 본문(`admin_body.py`)은 끝을 물어 꼬리를 읽지 않는다.
    `limit` 은 언제나 1 이상이다 —
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
        return (lambda data, limit: data[:limit]), None
    if len(known) > 1:
        raise ResponseRefused(f"{kind} is compressed more than once ({', '.join(known)})")
    if known[0] == "gzip":
        gzip = zlib.decompressobj(zlib.MAX_WBITS | 16)
        return (lambda data, limit: b"" if gzip.eof else gzip.decompress(data, limit)), (
            lambda: gzip.eof
        )
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

    # 날 deflate 로 갈아탄 뒤의 객체를 본다 — `deflate` 가 같은 이름을 다시 묶는다.
    return deflate, lambda: inflater.eof


async def _aread(response: httpx.Response, kind: str) -> bytes:
    codings = response.headers.get_list("content-encoding", split_commas=True)
    inflate, ended = _decoder(codings, kind)
    body = bytearray()
    fed = False
    async for data in response.aiter_raw():
        fed = True
        _keep(body, inflate, data, kind)
    _whole(kind, ended, fed)
    return bytes(body)


def acapped_send(send: _AsyncSend) -> Callable[..., Coroutine[Any, Any, httpx.Response]]:
    """httpx `AsyncClient.send` 를 감싼다 — sync 와 같다(원문을 받아 여기서 푼다)."""

    async def capped(
        request: httpx.Request, *, stream: bool = False, **kwargs: Any
    ) -> httpx.Response:
        if stream:
            return await send(request, stream=True, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING

        async def exchange() -> httpx.Response:
            response = await send(request, stream=True, **kwargs)
            kind = _kind(request.url.path)
            try:
                body = await _aread(response, kind)
                _strict_utf8(response.status_code, kind, body)
            except BaseException:
                await response.aclose()
                raise
            # httpx 가 `aread()` 에서 하는 일 그대로다(푼 본문을 두고 `Content-Encoding` 은 남긴다).
            response._content = body
            return response

        return await within(request_seconds(request), exchange(), request)

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
