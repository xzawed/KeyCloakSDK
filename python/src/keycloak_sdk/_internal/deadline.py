"""SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 그 타임아웃 안에 다 읽는다 — sync·aio.

⚠️ **읽기 타임아웃은 읽기 하나를 묶을 뿐이다.** 바이트를 그보다 조금 짧은 간격으로
흘리는 서버 앞에서 응답 하나가 흘린 바이트마다 간격 하나씩 걸렸다(수정 전 실측
2026-10-29 · 읽기 타임아웃 1 초 · 마지막 10 바이트를 0.7 초마다: 토큰·JWKS·admin 이
sync·aio 모두 7,046~7,100 ms 뒤 **성공** — `tests/unit/test_response_read_deadline.py`).
마감에 아직 오는 응답은 그 레인의 읽기 타임아웃과 같은 오류로 실패한다(공개 API 에서는
`KeycloakTransportError` — 메시지에 본문을 싣지 않는다).

- **sync** — 벽시계 마감(`deadline`, monotonic). SDK 의 읽기 고리(`token_cap`·
  `admin_body`·`jwks_fetch`)가 읽기마다 **앞뒤로** 본다(`reader`) — 마감 뒤에
  읽기를 시작하지 않고, 마감 뒤에 끝난 읽기의 바이트를 쓰지 않는다. 읽기는 와 있는
  만큼이다(urllib3 `read1`, 한 번의 시스템 호출) — `read(amt)` 는 `amt` 를 다 채울 때까지
  기다렸다. 그래서 읽기 하나는 지금처럼 읽기 타임아웃 하나로 묶이고, 최악은 마감 + 읽기
  타임아웃 하나다. 스레드·타이머를 두지 않는다.
  ⚠️ 하위 호출 **안**은 못 본다 — 머리(`send` 안)·청크 틀(크기 줄·트레일러)·urllib3 가
  푸는 성공 본문의 「풀린 것이 없으면 더 읽는」 고리는 호출 하나 안이라, 그것을 흘리는
  서버 앞에서는 그 호출이 끝난 뒤에야 실패한다(실측: 10 바이트 · 0.7 초 간격에 7 초).
- **aio** — 교환 전체(연결·보내기·머리·본문)를 `asyncio.wait_for` 로 묶는다(`within`) —
  정확한 마감이다. `asyncio.timeout` 은 3.11 부터라 하한(3.10)에 맞췄다.
"""

from __future__ import annotations

import asyncio
import time
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


def _unbounded() -> None:
    """마감이 없다."""


def deadline(limit: float | None) -> Callable[[], None]:
    """부른 때(요청을 보내기 직전)부터 `limit` 초의 마감 검사 — 넘었으면 requests 의 읽기
    타임아웃이다. `None` 이면 마감이 없다. ⚠️ 클래스로 두지 않는다 — 요청마다 만들고 버리는
    값이라 공개 뿌리에서 닿지 않는다(`tests/unit/test_facade_dump.py` 가 면제를 요구한다)."""
    if limit is None:
        return _unbounded
    length: float = limit
    at = time.monotonic() + length

    def check() -> None:
        if time.monotonic() >= at:
            raise requests.ReadTimeout(_late(length))

    return check


def reader(response: requests.Response, check: Callable[[], None]) -> Callable[..., bytes]:
    """`response` 의 원문 읽기 하나 — 와 있는 만큼(urllib3 `read1`)이고 앞뒤로 `check` 를
    본다. `read1` 이 없는 옛 urllib3 는 `read` 다 — 그 판에서는 읽기 하나가 청한 만큼을 채울
    때까지 기다린다."""
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
