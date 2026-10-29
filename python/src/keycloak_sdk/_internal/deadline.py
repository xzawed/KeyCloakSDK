"""SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 그 타임아웃 안에 다 읽는다 — sync·aio.

⚠️ **읽기 타임아웃은 읽기 하나를 묶을 뿐이다.** 바이트를 그보다 조금 짧은 간격으로
흘리는 서버 앞에서 응답 하나가 흘린 바이트마다 간격 하나씩 걸렸다(수정 전 실측
2026-10-29 · 읽기 타임아웃 1 초 · 마지막 10 바이트를 0.7 초마다: 토큰·JWKS·admin 이
sync·aio 모두 7,046~7,100 ms 뒤 **성공** — `tests/unit/test_response_read_deadline.py`).
마감에 아직 오는 응답은 그 레인의 읽기 타임아웃과 같은 오류로 실패한다(공개 API 에서는
`KeycloakTransportError` — 메시지에 본문을 싣지 않는다).

- **sync** — 벽시계 마감(monotonic)을 요청을 보내기 직전에 건다(`wire.exchange`). 마감은 두
  자리에서 본다: (1) 소켓 — 응답 버퍼 아래의 원문 읽기마다 앞뒤로 보고 읽기 하나를 남은 시간으로
  묶는다(`wire.py` — 머리·청크 틀·트레일러·TLS 레코드처럼 하위 호출 하나 안의 읽기까지). 최악은
  마감이다. (2) 본문 고리 — SDK 의 읽기 고리(`token_cap`·`admin_body`·`jwks_fetch`)가 읽기마다
  **앞뒤로** 같은 마감을 본다(`reader`) — 버퍼에 와 있던 바이트도 마감 뒤에는 쓰지 않고, (1) 이
  닿지 못한 전송(HTTPAdapter 가 아닌 어댑터)도 본문은 묶인다. 읽기는 와 있는 만큼이다(urllib3
  `read1`) — admin 오류 본문은 그래야 압축 스트림의 끝을 기다리지 않고 본다. 스레드·타이머를 두지
  않는다.
- **aio** — 교환 전체(연결·보내기·머리·본문)를 `asyncio.wait_for` 로 묶는다(`within`) —
  정확한 마감이다. `asyncio.timeout` 은 3.11 부터라 하한(3.10)에 맞췄다.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Coroutine
from typing import Any, TypeVar

import httpx
import requests

T = TypeVar("T")


def seconds(timeout: object) -> float | None:
    """`timeout` 인자의 마감 길이(초) — 수면 그것, requests 의 (연결, 읽기) 쌍이면 읽기
    쪽이다. 그 밖(없음 포함)이면 마감을 두지 않는다. python-keycloak 은 수 하나를 넘긴다."""
    if isinstance(timeout, tuple) and len(timeout) == 2:
        timeout = timeout[1]
    return float(timeout) if isinstance(timeout, (int, float)) else None


def request_seconds(request: httpx.Request) -> float | None:
    """httpx 요청에 실린 읽기 타임아웃(초) — 호출의 `timeout` 이 요청에 실린다."""
    timeout = request.extensions.get("timeout")
    return seconds(timeout.get("read")) if isinstance(timeout, dict) else None


def _late(limit: float) -> str:
    return (
        f"Read timed out: the response was not fully read within {limit:g} s of sending the request"
    )


def reader(response: requests.Response, check: Callable[[], None]) -> Callable[..., bytes]:
    """`response` 의 본문 읽기 하나 — 와 있는 만큼(urllib3 `read1`)이고 앞뒤로 `check`(교환의
    마감 — `wire.exchange`)를 본다. `read1` 이 없는 옛 urllib3 는 `read` 다 — 그 판에서는 읽기
    하나가 청한 만큼을 채울 때까지 기다린다(그 안의 소켓 읽기는 `wire.py` 가 마감으로 묶는다)."""
    raw = response.raw
    read1: Callable[..., bytes] | None = getattr(raw, "read1", None)
    read = read1 or raw.read

    def checked(amt: int, *, decode_content: bool) -> bytes:
        check()
        data = read(amt, decode_content=decode_content)
        check()
        return data

    return checked


async def within(
    limit: float | None, exchange: Coroutine[Any, Any, T], request: httpx.Request | None = None
) -> T:
    """`exchange`(연결부터 본문 끝까지)를 `limit` 초 안에 끝낸다 — 넘으면 httpx 의 읽기
    타임아웃이다. `None` 이면 마감 없이 기다린다."""
    if limit is None:
        return await exchange
    try:
        return await asyncio.wait_for(exchange, limit)
    except asyncio.TimeoutError:
        raise httpx.ReadTimeout(_late(limit), request=request) from None
