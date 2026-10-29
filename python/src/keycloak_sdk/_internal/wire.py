"""SDK 의 sync 세션이 소켓에서 읽는 응답 — 읽기마다 마감과 바이트 예산을 본다(requests).

⚠️ **본문 고리의 마감(`deadline.reader`)은 하위 호출 안을 못 본다.** 상태 줄·헤더 블록은
`send` 안에서, 청크 크기 줄·트레일러는 urllib3 `read1` 한 번 안에서 http.client 가
읽는다 — 그것을 흘리는 서버 앞에서는 그 호출이 끝난 뒤에야 실패했다(수정 전 실측
2026-10-29 · 읽기 타임아웃 1 초 · 마지막 10 바이트를 0.7 초마다: 7,066~7,129 ms —
`tests/unit/test_response_read_deadline.py`). 그리고 http.client 는 줄 하나를 65,536
에서 끊지만 트레일러 **줄 수**는 판에 따라 세지 않는다 — 4 KiB 줄 4,096 개(16 MiB)를 끝까지
읽었다(등록부 `response-framing-unbounded` F3a · 최근 CPython 보안 패치 판은 100 개에서 끊는다 —
판에 기대지 않고 아래 예산이 묶는다).

**어디에 거는가.** 응답의 읽기는 전부 http.client 응답의 버퍼(`sock.makefile("rb")`)
아래 원문 `readinto` 한 자리를 지난다 — 상태 줄·헤더·1xx·청크 크기 줄·트레일러·본문·
프록시 CONNECT 응답, TLS 면 레코드를 푼 평문이다. 세션의 HTTPAdapter 마다 그 자리에
이렇게 닿는다(전역 패치가 아니라 SDK 세션의 객체에만): 풀 관리자의
`connection_from_pool_key`(새 풀·있던 풀이 다 지난다 — 프록시면 `proxy_manager_for` 가
내준 관리자의 것) → 풀의 `_get_conn`(새 연결·쉬던 연결이 다 지난다) → 연결의
`response_class`(http.client 가 응답마다 부른다) → 응답 버퍼의 `raw.readinto`. 그
하나가 원문 읽기 하나(소켓 `recv_into` 하나)다 — 버퍼 채우기(`readline` 하나가 여러
읽기)가 아니다.

**무엇을 보는가.** 요청을 보내기 직전에 `exchange` 가 그 교환의 마감과 예산을 문맥
변수에 걸고, 그 안에서 만들어진 응답이 그것을 붙든다. 원문 읽기마다: 마감이 지났으면
읽지 않는다 · 읽기 하나를 남은 시간으로 묶는다(소켓 타임아웃을 `min(읽기 타임아웃,
남은 시간)` 으로 두고 끝나면 되돌린다) · 마감 뒤에 끝난 읽기의 바이트는 쓰지 않는다 ·
받은 바이트를 예산에 올린다(읽기 하나는 예산 + 1 바이트를 넘게 청하지 않는다). 그래서
최악은 마감이다(스레드 깨움만큼 늦을 뿐) — 스레드·타이머를 두지 않는다. TLS 레코드
하나를 한 바이트씩 흘려도 같다: CPython 의 `_ssl` 읽기는 소켓 타임아웃을 호출
**하나의 총량**으로 쓴다(레코드가 찰 때까지의 기다림 전부 — 실측, ruby·JVM 과 다르다).

**실패는 지금과 같은 꼴이다.** 마감은 소켓 타임아웃과 같은 `TimeoutError`(urllib3 가
`ReadTimeoutError` 로 — 요청 타임아웃과 같은 길), 예산은 http.client 의 틀
한도(`LineTooLong`)와 같은 부류의 `HTTPException`(urllib3 가 `ProtocolError` 로)이다.
공개 API 에서는 둘 다 지금의 읽기 타임아웃·틀 거부와 같은 `KeycloakTransportError`
이고 메시지에 응답 바이트를 싣지 않는다.

**예산** = 그 응답 종류의 본문 상한 + 틀 몫 `FRAMING_ALLOWANCE_BYTES`(상태 줄·헤더·
청크 틀·트레일러·1xx). 상한이 없는 응답(admin 성공 본문 — 목록은 정당하게 크다)은
상태를 본 뒤 예산을 푼다(`exchange` 의 `lift`) — 그 본문은 바이트로 묶지 않는 것이
정책이라, 틀만 따로 세어도 같은 바이트를 본문으로 보내면 그만이다(시간은 마감이,
할당은 http.client 의 줄 한도가 묶는다).

⚠️ HTTPAdapter 가 아닌 어댑터(소비자가 `mount` 한 전송)는 건너뛴다 — 그 소켓은 이
SDK 가 볼 수 없다(`retries.py` 와 같은 규칙). 그때도 본문 고리의 마감(`exchange` 의
`check`)은 남는다. HTTPAdapter 의 자리를 못 찾으면 거부한다(`KeycloakConfigError`).

⚠️ 클래스로 두지 않는다 — 공개 뿌리에서 닿지 않는 SDK 선언은
`tests/unit/test_facade_dump.py` 가 면제를 요구한다. 걸 자리마다 닫힌 함수다.
"""

from __future__ import annotations

import contextlib
import http.client
import time
from collections.abc import Callable, Iterator
from contextvars import ContextVar
from typing import Any

import requests
from requests.adapters import HTTPAdapter

from ..exceptions import KeycloakConfigError
from .deadline import _late

#: 응답 하나가 본문 상한 밖으로 실어도 되는 틀의 바이트 — 상태 줄·헤더·청크 크기 줄·
#: 트레일러·1xx. ruby 의 응답당 틀 예산(`MAX_FRAMING_BYTES`)·.NET 의 헤더+트레일러
#: 한도·Go 의 머리 블록 한도와 같은 값이다. Keycloak 26.6 의 머리 블록은 339 바이트
#: 이하(Go 실측)이고, KiB 단위 청크(nginx 4~8 KiB)는 1 MiB 본문에 2 KiB 남짓의 틀을
#: 싣는다.
FRAMING_ALLOWANCE_BYTES = 65_536

#: 이 모듈이 건 래퍼의 표지 — 같은 자리를 두 번 감싸지 않는다.
_MARK = "__kcsdk_wire__"

_Read = Callable[[Any], int | None]
_Wrap = Callable[[Callable[..., Any]], Callable[..., Any]]
#: 교환 하나의 계량 — (읽기 전: 남은 초 · 지났으면 `TimeoutError`, 이번 읽기가 청해도
#: 되는 바이트 · 예산이 없으면 None, 읽은 뒤: 받은 바이트를 올린다 · 마감·예산을 넘으면
#: 거부).
_Meter = tuple[Callable[[], float | None], Callable[[], int | None], Callable[[int], None]]
#: (걸 객체, 속성 이름, 감싸는 함수, 메시지에 쓸 자리). 클래스로 두지 않는다(위 머리말).
Hook = tuple[Any, str, _Wrap, str]

_EXCHANGE: ContextVar[_Meter | None] = ContextVar("kcsdk_wire_exchange", default=None)


def _over(budget: int) -> http.client.HTTPException:
    return http.client.HTTPException(f"HTTP response exceeds {budget} bytes on the wire")


@contextlib.contextmanager
def exchange(
    limit: float | None, budget: int | None
) -> Iterator[tuple[Callable[[], None], Callable[[], None]]]:
    """요청을 보내기 직전부터 본문을 다 읽을 때까지 — 이 블록에서 만들어진 응답의 원문
    읽기에 마감(`limit` 초, 부른 때부터)과 바이트 예산(`budget`)을 건다. `None` 이면 그것을
    두지 않는다.

    (본문 고리의 마감 검사, 예산을 푸는 함수)를 낸다. 검사는 같은 마감을 requests 의 읽기
    타임아웃으로 본다(`deadline.reader` 가 읽기 앞뒤로 부른다 — 버퍼에 와 있던 바이트도
    마감 뒤에는 쓰지 않고, 이 모듈이 닿지 못한 전송도 본문은 묶인다)."""
    at = None if limit is None else time.monotonic() + limit
    late = _late(limit) if limit is not None else ""
    used = 0
    cap = budget

    def left() -> float | None:
        if at is None:
            return None
        remaining = at - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(late)
        return remaining

    def room() -> int | None:
        return None if cap is None else cap - used + 1

    def charge(received: int) -> None:
        nonlocal used
        left()  # 마감 뒤에 끝난 읽기의 바이트는 쓰지 않는다
        used += received
        if cap is not None and used > cap:
            raise _over(cap)

    def check() -> None:
        if at is not None and time.monotonic() >= at:
            raise requests.ReadTimeout(late)

    def lift() -> None:
        nonlocal cap
        cap = None

    token = _EXCHANGE.set((left, room, charge))
    try:
        yield check, lift
    finally:
        _EXCHANGE.reset(token)


def _metered(read: _Read, sock: Any, meter: _Meter) -> _Read:
    """응답 버퍼 아래의 원문 읽기 하나 — 앞뒤로 계량을 보고, 읽기를 남은 시간과 남은
    예산으로 묶는다."""
    left, room, charge = meter

    def readinto(buffer: Any) -> int | None:
        remaining = left()
        most = room()
        if most is not None and most < len(buffer):
            buffer = memoryview(buffer)[:most]
        prior = sock.gettimeout()
        bounded = remaining is not None and (prior is None or remaining < prior)
        if bounded:
            sock.settimeout(remaining)
        try:
            got = read(buffer)
        finally:
            if bounded:
                sock.settimeout(prior)
        charge(got or 0)
        return got

    return readinto


def _unreachable(what: str) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot bound response reads: {what}. Refusing to read a response that could keep a "
        f"request waiting past its timeout. Pin python-keycloak to a supported version (>=7.1,<8) "
        f"and report this at https://github.com/xzawed/KeyCloakSDK/issues."
    )


def _respond(make: Callable[..., Any]) -> Callable[..., Any]:
    """연결의 `response_class` — `make` 가 만든 응답의 버퍼 아래 원문 읽기에 지금 교환의
    계량을 건다. 교환 밖에서 만들어진 응답(소비자가 같은 세션으로 스트리밍하는 것)은
    그대로다."""

    def response(sock: Any, *args: Any, **kwargs: Any) -> Any:
        made = make(sock, *args, **kwargs)
        meter = _EXCHANGE.get()
        if meter is not None:
            raw: Any = getattr(getattr(made, "fp", None), "raw", None)
            read = getattr(raw, "readinto", None)
            if not callable(read):
                raise _unreachable("the HTTP response has no raw socket reader under its buffer")
            raw.readinto = _metered(read, sock, meter)
        return made

    return response


def _checked_out(get_conn: Callable[..., Any]) -> Callable[..., Any]:
    """풀의 `_get_conn` — 내주는 연결(새 것·쉬던 것)의 `response_class` 를 `_respond` 로
    둔다."""

    def checkout(*args: Any, **kwargs: Any) -> Any:
        conn = get_conn(*args, **kwargs)
        make = getattr(conn, "response_class", None)
        if not getattr(make, _MARK, False):
            if not callable(make):
                raise _unreachable("the pooled HTTP connection has no response_class")
            hooked = _respond(make)
            setattr(hooked, _MARK, True)
            conn.response_class = hooked
        return conn

    return checkout


def _wrap(target: Any, name: str, wrap: _Wrap, where: str) -> None:
    """`target.name` 을 `wrap` 으로 감싼다 — 이미 감쌌으면 그대로, 없거나 부를 수 없으면
    거부한다."""
    current = getattr(target, name, None)
    if getattr(current, _MARK, False):
        return
    if not callable(current):
        raise _unreachable(f"this SDK expects requests' HTTPAdapter to expose {where}")
    hooked = wrap(current)
    setattr(hooked, _MARK, True)
    setattr(target, name, hooked)


def _pooled(pool_for: Callable[..., Any]) -> Callable[..., Any]:
    """풀 관리자의 `connection_from_pool_key` — 내주는 풀의 `_get_conn` 을 `_checked_out`
    으로."""

    def pool(*args: Any, **kwargs: Any) -> Any:
        found = pool_for(*args, **kwargs)
        _wrap(found, "_get_conn", _checked_out, "_get_conn on its connection pools")
        return found

    return pool


def _proxied(manager_for: Callable[..., Any]) -> Callable[..., Any]:
    """어댑터의 `proxy_manager_for` — 내주는 프록시 관리자의 `connection_from_pool_key` 를
    `_pooled` 로."""

    def manager(*args: Any, **kwargs: Any) -> Any:
        found = manager_for(*args, **kwargs)
        where = "connection_from_pool_key on its proxy managers"
        _wrap(found, "connection_from_pool_key", _pooled, where)
        return found

    return manager


def read_hooks(session: Any, where: str) -> list[Hook]:
    """`session` 의 HTTPAdapter 마다 걸 자리 — 풀 관리자의 `connection_from_pool_key`,
    어댑터의 `proxy_manager_for`, 이미 있는 프록시 관리자의 `connection_from_pool_key`.
    어댑터 표를 읽지 못하면 `KeycloakConfigError` 다(`where` 는 메시지에 쓸 세션 자리)."""
    try:
        adapters = list(session.adapters.items())
        proxies = [
            (prefix, adapter, list(getattr(adapter, "proxy_manager", {}).items()))
            for prefix, adapter in adapters
            if isinstance(adapter, HTTPAdapter)
        ]
    except Exception as exc:
        raise _unreachable(
            f"this SDK could not read the transport adapters at {where}.adapters"
        ) from exc
    hooks: list[Hook] = []
    for prefix, adapter, managers in proxies:
        at = f"{where}.adapters[{prefix!r}]"
        manager = getattr(adapter, "poolmanager", None)
        hooks.append((manager, "connection_from_pool_key", _pooled, f"{at}.poolmanager"))
        hooks.append((adapter, "proxy_manager_for", _proxied, at))
        hooks += [
            (found, "connection_from_pool_key", _pooled, f"{at}.proxy_manager[{proxy!r}]")
            for proxy, found in managers
        ]
    return hooks


def bound_reads(openid: Any) -> None:
    """auth 레인의 `KeycloakOpenID` — sync 세션(`connection._s`)의 응답 읽기에 마감과
    예산을 건다(생성 때 한 번 — `forbid_retries` 와 같은 자리). `connection._s` 의 존재는
    먼저 부르는 `harden_openid` 가 강제한다."""
    for target, name, wrap, where in read_hooks(openid.connection._s, "connection._s"):
        _wrap(target, name, wrap, f"{where}.{name}")
