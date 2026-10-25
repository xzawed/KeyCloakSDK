"""admin REST 응답 본문의 끝을 정한다 — 오류 본문은 상한까지, 파사드 쓰기의 2xx 는
읽지 않는다(sync·aio).

⚠️ **상류는 본문을 통째로 읽는다.** python-keycloak 의 `raw_*` 는 `stream` 없이 보내므로
requests 가 `r.content` 로, aio 는 httpx `send` 가 `aread()` 로 본문 전체를 읽은 뒤에야
결과를 본다. 수정 전 실측(2026-10-25, `tests/unit/test_admin_response_body.py` 를 수정 전
코드에 — sync·aio 같다): 파사드 쓰기 열다섯의 2xx + 64 MiB 를 서버가 끝까지 썼고, 201 뒤
멈춘 서버 앞에서 create 가 읽기 타임아웃 끝에 `KeycloakTransportError`(4,008~4,019 ms)
였고, 404 + 64 MiB 는 `keycloak_error` 에 67,108,864 자를 실었다(호출 하나 최대
135~201 MB).

**어디에 거는가.** admin REST 세션 둘(`connection._s` · `connection.async_s`)의 `send` —
`token_cap.py` 가 그랜트 세션에 거는 자리와 같은 자리, 같은 방식(스트리밍으로 받아 상태를
본 뒤 읽을 만큼만 읽는다)이다. 설치와 재설치는 `admin_guard.py` 가 요청마다 맡는다.

- 상태 3xx 이상: 원문을 상한 + 1 까지 받아 **여기서** 푼다(`token_cap._inflater` — 하위
  디코더의 상한에 기대지 않는다). 상한을 넘으면 상한에서 자르고 연결을 버린다.
  python-keycloak 은 상태로 오류를 고르므로(`raise_error_from_response`) 잘린 본문이
  분류를 바꾸지 않는다 — JSON 해석이 실패하면 메시지가 본문 바이트일 뿐이다.
- 파사드 쓰기가 표시한(`no_body`) 요청의 2xx: 읽지 않고 닫는다. 본문이 이미 끝난 응답
  (길이 0 · 204 · 304)은 읽어서 연결을 풀에 돌려준다 — 닫으면 다시 쓸 연결을 버린다
  (urllib3·httpcore 는 끝을 읽어야 연결을 돌려준다).
- 그 밖(성공 본문 · `raw` 로 부른 메서드의 2xx): 지금처럼 다 읽는다 — 성공 본문에는
  상한이 없다(목록은 정당하게 크다).

요청의 `Accept-Encoding` 은 `token_cap` 처럼 `gzip, deflate` 로 둔다 — 여기서 상한 안에
풀 수 있는 것만 청한다. ⚠️ `stream=True` 로 온 요청(호출자가 스스로 읽는다)은 손대지
않는다.
"""

from __future__ import annotations

import contextlib
from collections.abc import Awaitable, Callable, Coroutine, Iterator
from contextvars import ContextVar
from typing import Any

import httpx
import requests

from .token_cap import (
    _ACCEPT_ENCODING,
    _CHUNK,
    TOKEN_RESPONSE_MAX_BYTES,
    ResponseRefused,
    _inflater,
)

#: 오류 본문의 상한 — 토큰 응답 상한을 빌린다(python-keycloak 은 오류 본문을 메시지로만 쓴다).
ADMIN_ERROR_BODY_MAX_BYTES = TOKEN_RESPONSE_MAX_BYTES

#: 파사드의 쓰기 호출이 성공 본문을 읽지 않음을 표시한다 — `no_body` 만 건다. ⚠️ 응답
#: 모양(201 · PUT 의 답)으로 가르지 않는다: `raw` 로 부르는 python-keycloak 메서드가 그
#: 본문을 결합한다(`create_client_authz_resource` 는 201 본문,
#: `update_client_management_permissions` 는 PUT 의 200 본문).
_NO_BODY: ContextVar[bool] = ContextVar("kcsdk_admin_no_body", default=False)

_SyncSend = Callable[..., requests.Response]
_AsyncSend = Callable[..., Awaitable[httpx.Response]]
_Inflate = Callable[[bytes, int], bytes]


@contextlib.contextmanager
def no_body() -> Iterator[None]:
    """이 블록 안의 admin 요청은 성공 본문을 읽지 않는다 — 파사드의 쓰기 호출(create 는
    `Location` 을, update·delete 는 상태만 쓴다)."""
    token = _NO_BODY.set(True)
    try:
        yield
    finally:
        _NO_BODY.reset(token)


def _ended(status: int, length: str | None) -> bool:
    """본문이 이미 끝났는가 — 읽어도 기다리지 않고 연결을 풀에 돌려준다."""
    return status in (204, 304) or length == "0"


def _error_inflater(codings: list[str]) -> _Inflate:
    """오류 본문을 상한 안에서 푸는 함수. 묶어서 풀 수 없는 압축(둘 이상 겹침)은 풀지 않고
    원문을 센다 — 토큰 응답과 달리 거부하지 않는다(답의 상태가 결과다)."""
    try:
        return _inflater(codings, "admin error response")
    except ResponseRefused:
        return lambda data, limit: data[:limit]


def _cut(body: bytearray, inflate: _Inflate, data: bytes) -> bool:
    """원문 조각 하나를 상한 + 1 까지 풀어 쌓는다 — 상한을 넘었으면 참(호출자가 자르고 멈춘다)."""
    body += inflate(data, ADMIN_ERROR_BODY_MAX_BYTES + 1 - len(body))
    return len(body) > ADMIN_ERROR_BODY_MAX_BYTES


def _read_error(response: requests.Response) -> tuple[bytes, bool]:
    """오류 본문을 원문으로 상한 + 1 까지 읽어 푼다 — (본문, 상한을 넘었나)."""
    inflate = _error_inflater(response.headers.get("content-encoding", "").split(","))
    body = bytearray()
    while data := response.raw.read(
        min(_CHUNK, ADMIN_ERROR_BODY_MAX_BYTES + 1 - len(body)), decode_content=False
    ):
        if _cut(body, inflate, data):
            return bytes(body[:ADMIN_ERROR_BODY_MAX_BYTES]), True
    return bytes(body), False


def bounded_send(send: _SyncSend) -> _SyncSend:
    """requests `Session.send` 를 감싼다 — 스트리밍으로 받아 상태를 보고 읽을 만큼만 읽는다."""

    def bounded(request: requests.PreparedRequest, **kwargs: Any) -> requests.Response:
        if kwargs.get("stream"):
            return send(request, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING
        response = send(request, **{**kwargs, "stream": True})
        try:
            if response.status_code >= 300:
                body, over = _read_error(response)
                if over:
                    response.close()  # 나머지를 읽지 않고 연결째 버린다
            elif _NO_BODY.get() and not _ended(
                response.status_code, response.headers.get("content-length")
            ):
                response.close()  # 쓰지 않는 본문 — 읽지 않고 연결째 버린다
                body = b""
            else:
                return _loaded(response)
        except BaseException:
            response.close()
            raise
        # requests 가 `content` 에서 하는 일 그대로다 — 읽은 본문을 응답에 둔다.
        response._content = body
        response._content_consumed = True
        return response

    return bounded


def _loaded(response: requests.Response) -> requests.Response:
    """끝까지 읽는다(하위 디코더 그대로) — `stream` 없이 보냈을 때와 같다."""
    response.content  # noqa: B018 — 읽기 자체가 목적이다
    return response


async def _aread_error(response: httpx.Response) -> tuple[bytes, bool]:
    inflate = _error_inflater(response.headers.get_list("content-encoding", split_commas=True))
    body = bytearray()
    async for data in response.aiter_raw():
        if _cut(body, inflate, data):
            return bytes(body[:ADMIN_ERROR_BODY_MAX_BYTES]), True
    return bytes(body), False


def abounded_send(send: _AsyncSend) -> Callable[..., Coroutine[Any, Any, httpx.Response]]:
    """httpx `AsyncClient.send` 를 감싼다 — sync 와 같다."""

    async def bounded(
        request: httpx.Request, *, stream: bool = False, **kwargs: Any
    ) -> httpx.Response:
        if stream:
            return await send(request, stream=True, **kwargs)
        request.headers["Accept-Encoding"] = _ACCEPT_ENCODING
        response = await send(request, stream=True, **kwargs)
        try:
            if response.status_code >= 300:
                body, _ = await _aread_error(response)
            elif _NO_BODY.get() and not _ended(
                response.status_code, response.headers.get("content-length")
            ):
                body = b""  # 쓰지 않는 본문 — 아래 닫기가 읽지 않고 연결째 버린다
            else:
                await response.aread()
                return response
        except BaseException:
            await response.aclose()
            raise
        # 끝까지 읽었으면 연결을 풀에 돌려주고, 아니면(상한을 넘음 · 읽지 않음) 연결째 버린다.
        await response.aclose()
        response._content = body
        return response

    return bounded
