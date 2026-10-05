"""admin 레인의 하드닝을 **요청이 나가는 순간에** 성립시킨다 — 생성 때 한 번이 아니라.

⚠️ **python-keycloak 은 하드닝이 걸린 객체를 갈아 끼우는 공개 세터를 둔다** —
`KeycloakAdmin.connection` 과 `KeycloakOpenID.connection`. 예전에는 리다이렉트 하드닝
(`redirects.py`)과 그랜트 검사(`admin_grant.py`)를 생성 때 **그 객체들에** 한 번 걸었으므로
`raw.connection = ...` 한 줄이면 둘 다 사라졌다 — sync 는 빈 `access_token` 을
`Authorization: Bearer ` 로 보냈고, aio 는 h11 이 그 헤더를 거부해 `KeycloakTransportError` 였다.
이미 빈 bearer 를 쥔 채 주입된 admin 은 그랜트 없이 곧바로 보냈고, 설치 중 `setattr` 이 실패하면
raw `AttributeError` 와 반쯤 감긴 객체가 남았다(등록부 `python-admin-grant-guard-install-time`,
`tests/unit/test_admin_guard_live.py`).

**어떻게.**

1. 진짜 `KeycloakAdmin`(과 그 하위 클래스)은 인스턴스의 클래스를 하위 클래스로 바꾼다 —
   정체성과 `isinstance` 는 그대로다. 그 클래스의 `connection` 게터는 python-keycloak 의 admin
   메서드가 요청 직전에 읽는 자리다(모두 `self.connection.raw_*` 로 보내고 `_connection` 을
   직접 읽는 메서드는 없다, 7.1.1 실측). 읽을 때마다 **지금 살아 있는** 연결 그래프에 훅이 다
   걸렸는지 보고 빠진 것을 다시 건다 — 공개 세터·비공개 필드·중첩 세터 어느 쪽으로 바뀌었어도
   다음 요청 전에 잡힌다.
2. 그래프의 훅 열 자리(전부 인스턴스 속성): 두 세션의 `resolve_redirects`(`redirects.py`),
   중첩 `KeycloakOpenID` 의 그랜트 넷(`admin_grant.py`), 그랜트 세션 둘(`_s`·`async_s`)의 `send` —
   그랜트 응답 본문의 크기 상한(`token_cap.py`, admin REST 세션에는 걸지 않는다), 그리고 연결의
   `_refresh_if_required`·`a__refresh_if_required` — 그 **뒤**에서 보낼 헤더의 bearer 를 본다.
   마지막이 주입·토큰 세터로 **그랜트를 거치지 않고** 실린 bearer 를 잡는다. `raw_*` 는 그 갱신
   직후 보내고, 401 재시도는 방금 그랜트(검사됨)가 실은 토큰으로만 보낸다.
3. 설치는 전부이거나 아무것도 아니다 — 먼저 다 계획(검증)하고, 걸다가 하나라도 실패하면 건
   것을 되돌린 뒤 `KeycloakConfigError` 로 거부한다. 그래프를 읽다 난 실패는 무엇을 던졌든
   그 거부이고, 훅은 되돌림과 같은 통로(인스턴스 `__dict__`)로 쓰며, 설치 도중의 재진입은
   거부한다(`_install`·`_apply`).

**왜 저장된 토큰이 아니라 헤더인가.** 보내는 것이 헤더다. 둘은 갈린다 — 자격증명 없이 토큰만
받은 admin 이 만료되면 python-keycloak 은 토큰을 `None` 으로 비우고 헤더(`Bearer `)는 남긴다.

**기각한 것.** (a) SDK 진입점(`raw` 게터·`call`/`acall`)에서만 재설치 — `raw` 를 쥔 소비자가
연결을 바꾸고 곧바로 메서드를 부르면 그 사이에 SDK 코드가 한 줄도 돌지 않는다. (b) 연결에 한 번
거는 요청 시점 검사 — 연결째 갈아 끼워진다. (c) `connection` **세터**만 가로채기 — 비공개
`_connection` 쓰기와 중첩 `KeycloakOpenID.connection` 교체를 못 본다. 게터가 치르는 값은 읽기마다
훅 열 자리를 확인하는 것이다.

⚠️ 목(`MagicMock(spec=KeycloakAdmin)`)은 클래스를 바꾸면 `isinstance` 가 깨진다(실측) — 그래서
진짜 `KeycloakAdmin` 만 읽기마다 다시 보고, 그 밖의 객체는 생성 때 한 번 건다.
"""

from __future__ import annotations

import inspect
import threading
import weakref
from collections.abc import Callable, Coroutine
from types import FunctionType
from typing import Any, cast

from keycloak import KeycloakAdmin

from ..exceptions import KeycloakConfigError
from ..tokens import _usable_access_token
from .admin_grant import _ASYNC_GRANTS, _SYNC_GRANTS, _achecked, _checked
from .redirects import _refuse_redirects, _require, _unsupported
from .token_cap import acapped_send, capped_send

#: 훅을 거는 일은 한 번에 하나 — 되돌림이 다른 스레드가 막 건 훅을 지우지 않게 한다.
_LOCK = threading.RLock()
#: 이 스레드가 지금 그래프를 읽거나 훅을 거는 중인가(`_install`). RLock 은 **같은 스레드**의
#: 재진입을 막지 않는다 — 그 사이 소비자 코드(`__getattribute__`·디스크립터·지연 프로퍼티)가
#: `admin.connection` 을 다시 읽으면 안쪽 설치가 끝까지 걸고, 바깥 설치가 실패해 되돌리면 자기가
#: 먼저 건 자리만 지워 거부된 연결에 SDK 훅이 반쯤 남았다(실측: 여덟 중 일곱). 재진입한 설치는
#: 그래서 거부한다 — 그 거부가 바깥 설치를 실패시키고, 바깥이 전부 되돌린다.
_LOCAL = threading.local()
#: 이 모듈이 건 래퍼. 「이미 걸려 있나」를 이것과 아래 주인으로 가른다.
_OURS: weakref.WeakSet[Callable[..., Any]] = weakref.WeakSet()
#: 래퍼가 걸린 객체. 얕은 복사본(`copy.copy(conn)`)은 원본의 래퍼를 인스턴스 속성째 물려받는데 그
#: 래퍼는 **원본의** 헤더를 본다 — 주인을 대조하지 않으면 복사본의 빈 bearer 가 검사 없이 나갔다
#: (실측). 래퍼 함수의 속성으로 둔다: 전역 표에 두면 객체를 붙잡아 놓아 주지 않는다.
_OWNER = "__kcsdk_owner__"
#: 래퍼를 걸기 **전** 그 자리의 인스턴스 상태(`_ABSENT` 면 클래스의 것이었다). 복사본이 물려받은
#: 래퍼는 다시 감싸지 않고 이것으로 **벗긴다** — 그 래퍼는 원본에 묶인 메서드로 원본의 갱신·그랜트를
#: 부르고 원본의 헤더를 본다. 감싸기만 하면 복사본의 만료 갱신이 원본에서 돌았고, bearer 를 싣지
#: 않는 복사본의 요청이 원본의 빈 bearer 로 거부됐다(실측). 복사본이 SDK 없이 가졌을 것이 이것이다.
_PRIOR = "__kcsdk_prior__"
#: 감시 클래스가 감싼 원래 `connection` 프로퍼티 — 정리 경로가 무장 없이 읽는 자리다.
_BASE = "__kcsdk_connection__"
_WATCHED: dict[type[KeycloakAdmin], type[KeycloakAdmin]] = {}
_ABSENT = object()
_BEARER = "Bearer "
_SUPPORT = (
    "Pin python-keycloak to a supported version (>=7.1,<8) and report this at "
    "https://github.com/xzawed/KeyCloakSDK/issues."
)
#: 훅을 걸 수 없을 때 거부 메시지가 말하는 위험.
_UNUSABLE = "send an unusable access token to the admin API"
_UNBOUNDED = "read an unbounded token grant response into memory"

#: (걸 객체, 속성 이름, 걸 값, 메시지에 쓸 자리). 클래스로 두지 않는다 — 공개 뿌리에서 닿지
#: 않는 SDK 선언은 `test_facade_dump.py` 가 면제를 요구한다.
_Hook = tuple[Any, str, Any, str]


def _require_usable_bearer(conn: Any) -> None:
    """보낼 헤더의 bearer 가 auth 레인이 받는 access_token 인가 — 아니면 그 오류를 던진다."""
    value = (conn.headers or {}).get("Authorization")
    if isinstance(value, str) and value.startswith(_BEARER):
        _usable_access_token({"access_token": value[len(_BEARER) :]})


def _bearer_checked(conn: Any, refresh: Callable[..., Any]) -> Callable[..., Any]:
    def checked(*args: Any, **kwargs: Any) -> Any:
        result = refresh(*args, **kwargs)
        _require_usable_bearer(conn)
        return result

    return checked


def _abearer_checked(
    conn: Any, refresh: Callable[..., Any]
) -> Callable[..., Coroutine[Any, Any, Any]]:
    async def checked(*args: Any, **kwargs: Any) -> Any:
        result = await refresh(*args, **kwargs)
        _require_usable_bearer(conn)
        return result

    return checked


def _missing(what: str, where: str, risk: str = _UNUSABLE) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot check the {what}: this SDK expects python-keycloak to expose {where}, but it is "
        f"missing or not callable. Refusing to build an admin client that could {risk}. {_SUPPORT}"
    )


def _own(target: Any, name: str) -> Any:
    """인스턴스 자신의 속성(클래스에서 온 것이 아닌) — 우리가 건 훅은 여기에만 산다."""
    return getattr(target, "__dict__", {}).get(name)


def _is_ours(hook: object) -> bool:
    """이 모듈이 만든 래퍼인가. 래퍼는 언제나 함수라 그것부터 본다 — 소비자가 먼저 건 훅이 해시되지
    않는 객체여도(`eq=True` 데이터클래스) 소속 대조가 raw `TypeError` 로 설치를 깨지 않는다
    (실측)."""
    return isinstance(hook, FunctionType) and hook in _OURS


def _hooked(target: Any, name: str) -> bool:
    """`target.name` 이 이 모듈이 **바로 이 객체에** 건 래퍼인가(복사본이 물려받은 것은 아니다)."""
    hook = _own(target, name)
    return _is_ours(hook) and getattr(hook, _OWNER, None) is target


def _base(target: Any, name: str) -> tuple[Any, object]:
    """(감쌀 것, 감싸기 전 인스턴스 상태). 복사본이 물려받은 래퍼면 벗겨 **복사본 자신의** 것을 낸다
    — 원본이 인스턴스에 두었던 것(소비자의 훅)이면 그것, 아니면 클래스의 것을 이 객체에 묶은 것."""
    state = getattr(target, "__dict__", {}).get(name, _ABSENT)
    if not _is_ours(state):
        return getattr(target, name, None), state
    prior = vars(state)[_PRIOR]  # 우리 래퍼가 아니다 — 걸 때 벗겨 둔 상태다
    if prior is not _ABSENT:
        return prior, prior
    attr = inspect.getattr_static(type(target), name, None)
    get = getattr(type(attr), "__get__", None)
    return (attr if get is None else get(attr, target, type(target))), _ABSENT


def _plan_redirects(hooks: list[_Hook], session: Any, what: str, where: str) -> None:
    if _own(session, "resolve_redirects") is _refuse_redirects:
        return
    if not callable(getattr(session, "resolve_redirects", None)):
        raise _unsupported(what, "_s.resolve_redirects")
    hooks.append((session, "resolve_redirects", _refuse_redirects, f"{where}.resolve_redirects"))


def _plan_wrap(
    hooks: list[_Hook],
    target: Any,
    name: str,
    what: str,
    where: str,
    wrap: Callable[[Callable[..., Any]], Callable[..., Any]],
    risk: str = _UNUSABLE,
) -> None:
    if _hooked(target, name):
        return
    current, prior = _base(target, name)
    if not callable(current):
        raise _missing(what, where, risk)
    wrapped = wrap(current)
    vars(wrapped)[_OWNER] = target
    vars(wrapped)[_PRIOR] = prior
    _OURS.add(wrapped)
    hooks.append((target, name, wrapped, where))


def _plan(conn: Any) -> list[_Hook]:
    """`conn` 그래프에서 빠진 훅. 하나라도 걸 수 없으면 아무것도 바꾸기 전에 거부한다."""
    hooks: list[_Hook] = []
    rest, grant = "admin REST call", "admin token grant"
    _plan_redirects(hooks, _require(conn, "_s", what=rest), rest, "connection._s")
    nested = _require(conn, "keycloak_openid", what=grant)
    nested_conn = _require(nested, "connection", what=grant)
    nested_session = _require(nested_conn, "_s", what=grant)
    _plan_redirects(hooks, nested_session, grant, "connection.keycloak_openid.connection._s")
    # 그랜트 응답 본문의 크기 상한(`token_cap.py`) — 그랜트 세션 둘에만 건다. REST 세션
    # (`connection._s`)의 응답(사용자 목록 등)은 정당하게 크다.
    size, at = "token grant response size", "connection.keycloak_openid.connection"
    _plan_wrap(hooks, nested_session, "send", size, f"{at}._s.send", capped_send, _UNBOUNDED)
    async_session = getattr(nested_conn, "async_s", None)
    _plan_wrap(hooks, async_session, "send", size, f"{at}.async_s.send", acapped_send, _UNBOUNDED)
    for name in _SYNC_GRANTS:
        _plan_wrap(hooks, nested, name, grant, f"connection.keycloak_openid.{name}", _checked)
    for name in _ASYNC_GRANTS:
        _plan_wrap(hooks, nested, name, grant, f"connection.keycloak_openid.{name}", _achecked)
    bearer = "admin bearer"
    _plan_wrap(
        hooks,
        conn,
        "_refresh_if_required",
        bearer,
        "connection._refresh_if_required",
        lambda refresh: _bearer_checked(conn, refresh),
    )
    _plan_wrap(
        hooks,
        conn,
        "a__refresh_if_required",
        bearer,
        "connection.a__refresh_if_required",
        lambda refresh: _abearer_checked(conn, refresh),
    )
    return hooks


def _undo(done: list[tuple[Any, str, object]]) -> None:
    for target, name, previous in reversed(done):
        state = vars(target)
        if previous is _ABSENT:
            state.pop(name, None)
        else:
            state[name] = previous


def _refused(what: str, exc: BaseException) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot guard the admin client: {what} failed ({type(exc).__name__}), so nothing was "
        f"changed. Refusing to use an admin client that could follow redirects or send an "
        f"unusable access token to the admin API. {_SUPPORT}"
    )


def _apply(hooks: list[_Hook]) -> list[tuple[Any, str, object]]:
    done: list[tuple[Any, str, object]] = []
    for target, name, value, where in hooks:
        try:
            state = cast("dict[str, Any]", vars(target))  # 인스턴스의 것 — 클래스는 걸지 않는다
            done.append((target, name, state.get(name, _ABSENT)))
            # 되돌림(`_undo`)과 같은 통로로 쓴다. `setattr` 은 소비자의 `__setattr__`·슬롯으로 새어
            # 되돌림이 못 보는 곳에 훅을 두었다 — 곁 사전·슬롯에 산 소비자의 훅이 거부 뒤
            # `_refuse_redirects` 로 바뀌어 있었다(실측). 쓴 값이 보이지 않으면(슬롯·데이터
            # 디스크립터·`__getattribute__` 가 가린다) 건 것이 아니다.
            state[name] = value
            if getattr(target, name) is not value:
                raise AttributeError(f"{name} did not keep the hook")
        except Exception as exc:
            _undo(done)
            raise _refused(f"installing the hook at {where}", exc) from exc
    return done


def _reentered() -> KeycloakConfigError:
    return KeycloakConfigError(
        "cannot guard the admin client: its connection was read again while the guard was being "
        "installed on it (code that runs while this SDK reads or hooks the connection graph "
        "called back into the admin client), so nothing was changed. Refusing to leave an admin "
        "client half-guarded."
    )


def _install(conn: Any) -> list[tuple[Any, str, object]]:
    """`conn` 그래프에 빠진 훅을 건다(전부이거나 아무것도) — `_LOCK` 을 쥔 채 부른다.

    그래프를 읽다 난 실패는 무엇이든 `KeycloakConfigError` 다 — 프로퍼티·지연 생성·디스크립터는
    `AttributeError` 만 던지지 않는다(실측: raw `TypeError`·`ValueError` 가 생성과 `raw` 로 샜고
    리소스로는 `KeycloakTransportError` 였다). 재진입은 `_LOCAL` 이 거부한다."""
    if getattr(_LOCAL, "installing", False):
        raise _reentered()
    _LOCAL.installing = True
    try:
        try:
            hooks = _plan(conn)
        except KeycloakConfigError:
            raise
        except Exception as exc:
            raise _refused("reading the connection graph", exc) from exc
        return _apply(hooks)
    finally:
        _LOCAL.installing = False


def _read_connection(read: Callable[[], Any]) -> Any:
    """`admin.connection` — 생성 때든 요청 직전이든 읽지 못하면 같은 `KeycloakConfigError` 다.

    지워진 연결 필드(`AttributeError`)는 걸 자리가 없다는 거부, 그 밖의 실패(하위 클래스의
    프로퍼티가 던진 `TypeError` 등)는 읽기가 실패했다는 거부다. 이미 감시 중인 admin 이면 읽기가
    곧 무장이라 그 거부는 그대로 지난다."""
    try:
        return read()
    except KeycloakConfigError:
        raise
    except AttributeError as exc:
        raise _unsupported("admin REST call", "connection") from exc
    except Exception as exc:
        raise _refused("reading the admin's connection", exc) from exc


def arm_connection(conn: Any) -> None:
    """`conn` 그래프에 빠진 훅을 건다(전부이거나 아무것도). 다 걸려 있으면 아무것도 안 한다."""
    with _LOCK:
        _install(conn)


def _watched_type(cls: type[KeycloakAdmin]) -> type[KeycloakAdmin]:
    """`cls` 의 하위 클래스 — `connection` 을 읽을 때마다 살아 있는 연결을 무장한다."""
    if _BASE in vars(cls):
        return cls
    cached = _WATCHED.get(cls)
    if cached is not None:
        return cached
    prop = inspect.getattr_static(cls, "connection", None)
    if not isinstance(prop, property):
        raise KeycloakConfigError(
            f"cannot guard the admin client: {cls.__qualname__}.connection is not a property, so "
            f"this SDK cannot check the connection each admin request goes out on. {_SUPPORT}"
        )

    def connection(self: KeycloakAdmin) -> Any:
        conn = _read_connection(lambda: prop.__get__(self, type(self)))  # 생성 때와 같은 거부
        arm_connection(conn)
        return conn

    # 이름·모듈은 감싼 클래스 그대로다 — `raw` 는 여전히 python-keycloak 의 객체로 보이고
    # 읽힌다(§4(b) 의 탈출구, 오류 수집기·걷기 도구의 분류도 그대로). 피클은 원래도 안 됐다
    # (python-keycloak 의 `lambda`·`RLock`, 실측). 달라지는 것은 `type(raw) is KeycloakAdmin`
    # 하나다 — `isinstance` 는 참이다.
    namespace = {
        "__slots__": (),
        "__module__": cls.__module__,
        "__qualname__": cls.__qualname__,
        "connection": property(connection, prop.fset, prop.fdel, prop.__doc__),
        _BASE: prop,
    }
    try:
        watched = cast("type[KeycloakAdmin]", type(cls.__name__, (cls,), namespace))
    except Exception as exc:  # `__init_subclass__`·메타클래스가 하위 클래스를 막는다(런타임 final)
        raise _refused(f"subclassing {cls.__qualname__} to watch its connection", exc) from exc
    return _WATCHED.setdefault(cls, watched)


def arm_admin(admin: KeycloakAdmin) -> None:
    """생성 때 부른다 — 지금 연결 그래프에 훅을 다 걸고(전부이거나 아무것도), 진짜
    `KeycloakAdmin` 이면 이후 `connection` 을 읽을 때마다 다시 보게 클래스를 바꾼다.
    실패는 `KeycloakConfigError` 다."""
    cls = type(admin)
    with _LOCK:
        watched = _watched_type(cls) if issubclass(cls, KeycloakAdmin) else cls
        done = _install(_read_connection(lambda: admin.connection))
        # 이미 감시 중이거나 진짜 KeycloakAdmin 이 아니다. 목에 `__class__` 를 쓰면 클래스가
        # 아니라 spec 이 바뀌어 `isinstance` 가 깨진다.
        if watched is cls:
            return
        try:
            admin.__class__ = watched
        except Exception as exc:
            _undo(done)
            raise _refused(f"replacing the class of {cls.__qualname__}", exc) from exc


def unarmed_connection(admin: KeycloakAdmin | None) -> Any:
    """`admin.connection` 을 **무장하지 않고** 읽는다 — 요청을 보내지 않는 정리 전용.

    정리가 보안 검사에 막혀 세션을 못 닫으면 안 된다. 없으면 `None`(예전 `getattr` 과 같다)."""
    prop = getattr(type(admin), _BASE, None)
    if prop is None:
        return getattr(admin, "connection", None)
    try:
        return prop.__get__(admin, type(admin))
    except AttributeError:
        return None
