"""공개 메서드가 예외를 내보낼 때 **프레임 로컬**에 남은 비밀을 떼어 낸다.

⚠️ 메시지·원인 사슬을 정화해도(`lower.py`) 로컬은 남는다. `traceback.TracebackException(
capture_locals=True)` 와 Sentry Python(기본값)은 traceback 이 닿는 **모든 프레임의 로컬**을 `repr`
로 찍는다 — 거부된 교환의 `response`(raw refresh token)·인자 `code`·`code_verifier`, 검증기에
넘긴 id_token, 사슬 끝 joserfc 프레임의 JWT 조각이 거기 있었다(실측 2026-09-27, 여섯 호출 ·
sync·aio 전부). `str`·`repr`·`format_exception` 에는 없어서 기존 누출 테스트가 못 봤다.

그래서 데코레이터가 예외를 다시 던지기 전에:

1. **안쪽 프레임을 뗀다** — `with_traceback(None)`. 남는 프레임은 이 래퍼와 그 위 호출자뿐이다.
2. **사슬의 traceback 도 뗀다** — `__cause__`·`__context__` 를 따라가며. 예외 객체·타입·메시지·
   사슬 모양은 그대로이고, 잃는 것은 안쪽 프레임의 줄 번호뿐이다.
3. **래퍼 자신의 인자를 지운다** — `args`·`kwargs` 가 곧 소비자가 넘긴 토큰·코드·verifier 다.

⚠️ `BaseException` 전부에 건다. `asyncio.timeout` 은 취소(`CancelledError`)를 `TimeoutError` 의
원인으로 달아 올리므로, 취소 traceback 도 교환 프레임(살아 있는 토큰 응답)을 쥔 채 수집기에 닿는다.
"""

from __future__ import annotations

import functools
from collections.abc import Awaitable, Callable, Coroutine
from typing import Any, ParamSpec, TypeVar

P = ParamSpec("P")
R = TypeVar("R")


def _detached(exc: BaseException) -> BaseException:
    """`exc` 와 그 사슬에서 traceback(= 프레임과 그 로컬)을 뗀 `exc` 자신."""
    seen: set[int] = set()
    todo = [exc.__cause__, exc.__context__]
    while todo:
        node = todo.pop()
        if node is None or id(node) in seen:
            continue
        seen.add(id(node))
        node.__traceback__ = None
        todo += [node.__cause__, node.__context__]
    return exc.with_traceback(None)


def scrub_frames(fn: Callable[P, R]) -> Callable[P, R]:
    """sync 공개 메서드용 — 실패하면 안쪽 프레임·사슬 traceback·인자를 떼고 같은 예외를 던진다."""

    @functools.wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        try:
            return fn(*args, **kwargs)
        except BaseException as exc:
            del args, kwargs
            raise _detached(exc)  # noqa: B904 — 같은 객체다. `from` 이 사슬을 바꾸면 안 된다

    return wrapper


def ascrub_frames(fn: Callable[P, Awaitable[R]]) -> Callable[P, Coroutine[Any, Any, R]]:
    """aio 공개 메서드용 — `scrub_frames` 와 같다(코루틴 프레임도 traceback 으로 닿는다)."""

    @functools.wraps(fn)
    async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        try:
            return await fn(*args, **kwargs)
        except BaseException as exc:
            del args, kwargs
            raise _detached(exc)  # noqa: B904 — 같은 객체다

    return wrapper
