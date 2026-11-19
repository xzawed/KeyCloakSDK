"""공개 메서드가 예외를 내보낼 때 **프레임 로컬**에 남은 비밀을 떼어 낸다.

⚠️ 메시지·원인 사슬을 정화해도(`lower.py`) 로컬은 남는다. `traceback.TracebackException(
capture_locals=True)` 와 Sentry Python(기본값)은 traceback 이 닿는 **모든 프레임의 로컬**을 `repr`
로 찍는다 — 거부된 교환의 `response`(raw refresh token)·인자 `code`·`code_verifier`, 검증기에
넘긴 id_token, 사슬 끝 joserfc 프레임의 JWT 조각이 거기 있었다(실측 2026-09-27, 여섯 호출 ·
sync·aio 전부). `str`·`repr`·`format_exception` 에는 없어서 기존 누출 테스트가 못 봤다.

그래서 데코레이터가 예외를 다시 던지기 전에:

1. **안쪽 프레임을 뗀다** — 그 예외의 `__traceback__` 을 비운다. 남는 프레임은 이 래퍼와 그 위
   호출자뿐이다.
2. **닿는 예외의 traceback 도 뗀다** — `__cause__`·`__context__` 와 그룹의 구성원을 따라가며
   (`reachable`). 예외 객체·타입·메시지·사슬 모양은 그대로이고, 잃는 것은 안쪽 프레임의 줄
   번호뿐이다.
3. **래퍼 자신의 인자를 지운다** — `args`·`kwargs` 가 곧 소비자가 넘긴 토큰·코드·verifier 다.

⚠️ `BaseException` 전부에 건다. `asyncio.timeout` 은 취소(`CancelledError`)를 `TimeoutError` 의
원인으로 달아 올리므로, 취소 traceback 도 교환 프레임(살아 있는 토큰 응답)을 쥔 채 수집기에 닿는다.

⚠️ **그룹의 구성원(`.exceptions`)도 따라간다**(등록부 `python-scrub-frames-skips-exception-groups`).
aio 의 JWKS 조회는 httpx → httpcore → anyio 로 연결하는데, 호스트가 주소 여럿으로 풀려 모두
실패하면 anyio 가 시도마다의 오류를 `ExceptionGroup` 으로 묶어 `OSError` 의 원인으로 단다. 사슬만
떼던 때는 aio `validate`·`validate_id_token` 의 오류에서 그 구성원마다 연결 프레임 여덟의
traceback 이 남았다(실측 2026-11-19 · Windows 3.10.21 · 3.13.11 — `localhost:<닫힌 포트>` 가
::1 · 127.0.0.1 로 풀린다). 그 로컬에 비밀은 없었고, 그룹은 httpcore 풀이 `from None` 으로 숨긴
`__context__` 너머라 `TracebackException` 은 찍지 않았다 — 계약이 「닿는 traceback 은 뗀다」라서
따라간다. 걸음은 하나다 — `admin_guard._clear_locals` 도 `reachable` 로 걷는다.
"""

from __future__ import annotations

import builtins
import functools
import sys
from collections.abc import Awaitable, Callable, Coroutine, Iterator
from typing import Any, ParamSpec, TypeVar

P = ParamSpec("P")
R = TypeVar("R")

#: 3.11 부터의 내장 `BaseExceptionGroup` — 3.10 에는 없다(`None`).
_BUILTIN_GROUP = getattr(builtins, "BaseExceptionGroup", None)


def _group_types() -> tuple[type[BaseException], ...]:
    """그룹으로 보는 타입 — 내장(3.11+)과, 백포트 `exceptiongroup` 이 import 돼 있으면 그
    `BaseExceptionGroup`(3.10 의 anyio 가 그것을 던진다 · 3.11+ 에서는 내장 그것이다).

    ⚠️ 3.10 규칙: 내장이 없다고 그룹이 없는 것이 아니다 — 예전 `admin_guard._GROUPS` 는 3.10 에서
    빈 튜플이라 백포트 그룹의 구성원을 지나쳤다(실측 3.10.21). 백포트를 스스로 import 하지는 않는다
    — 그 인스턴스는 모듈이 import 된 뒤에만 있다. `if` 문이 아니라 값으로 가른다 — 100 % 커버리지
    게이트가 3.10 ~ 3.14 모두에서 돌므로 판마다 한쪽만 지나는 분기를 남기지 않는다."""
    backport = getattr(sys.modules.get("exceptiongroup"), "BaseExceptionGroup", None)
    return tuple(kind for kind in (_BUILTIN_GROUP, backport) if isinstance(kind, type))


def reachable(exc: BaseException) -> Iterator[BaseException]:
    """`exc` 와 거기서 닿는 예외 — `__cause__`·`__context__`(숨긴 것도)와 그룹의 구성원을 따라
    예외마다 한 번. 순환이어도 끝난다. 이 모듈의 `_detached` 와 `admin_guard._clear_locals` 가
    함께 쓰는 하나뿐인 정의다."""
    groups = _group_types()
    seen: set[int] = set()
    todo: list[BaseException | None] = [exc]
    while todo:
        node = todo.pop()
        if node is None or id(node) in seen:
            continue
        seen.add(id(node))
        yield node
        # 타입 검사는 3.10 기준(`python_version`)이라 그룹의 `.exceptions` 를 모른다 — `getattr`.
        members = getattr(node, "exceptions", ()) if isinstance(node, groups) else ()
        todo += [node.__cause__, node.__context__, *members]


def _detached(exc: BaseException) -> BaseException:
    """`exc` 와 거기서 닿는 예외(`reachable`)에서 traceback(= 프레임과 그 로컬)을 뗀 `exc` 자신."""
    for node in reachable(exc):
        node.__traceback__ = None
    return exc


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
