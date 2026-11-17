"""`KeycloakOpenID.connection` 은 python-keycloak 의 **공개 세터**다 — 그것으로 끼우는 연결도
끼우기 **전에** 지금 연결과 같은 하드닝을 받게 한다(등록부 `python-admin-guard-send-time`).

하드닝(리다이렉트 거부·응답 상한·재시도 끔·읽기 마감)은 연결의 세션에 걸린다. 연결을 갈아 끼우면
새 세션에는 아무것도 없다. auth 레인은 생성 때 한 번 걸었으므로 주입한 `KeycloakOpenID` 의 연결을
바꾸면 sync 그랜트가 307 을 따라가 client_secret 을 넘기고 JWKS 도 리다이렉트 대상에서 받았다.
admin 의 그랜트 객체(`raw.connection.keycloak_openid`)는 다음 `admin.connection` 읽기 전까지 훅이
없었다 — 쥔 그랜트 객체로 직접 부르거나, 다른 호출자가 401 재시도 도중 바꾸면 그 틈으로 나갔다(수정
전 실측 `tests/unit/test_admin_guard_send_time.py`).

**어떻게.** 진짜 `KeycloakOpenID`(와 하위 클래스)는 인스턴스의 클래스를 하위 클래스로 바꾼다 —
정체성·`isinstance`·이름은 그대로다. 그 클래스의 `connection` 세터는 인스턴스에 등록된 하드닝
(`HARDENERS` — 연결 하나를 받는 함수들)을 새 연결에 다 건 **뒤에** 끼운다. 하나라도 던지면 끼우지
않는다 — 옛 연결이 남는다. 게터는 그대로라 정리(`close`·`aclose`)는 무장하지 않는다.

**세터만 보는 이유.** 비공개 상태를 쓰지 않고 그랜트 객체의 연결이 바뀌는 자리는 이 세터 하나다 —
python-keycloak 7.1.1 이 그 연결을 만드는 곳은 `KeycloakOpenID.__init__` 뿐이고 다시 만들지 않는다.
비공개 필드(`_connection`) 쓰기는 지키는 범위 밖이다(`admin_guard.py` 머리 주석).

⚠️ 목(`MagicMock(spec=KeycloakOpenID)`)은 클래스를 바꾸지 않는다 — `isinstance` 가 깨진다
(`admin_guard.py` 와 같은 규칙). 생성 때 건 하드닝만 남는다.
"""

from __future__ import annotations

import inspect
from collections.abc import Callable
from typing import Any

from keycloak import KeycloakOpenID

from ..exceptions import KeycloakConfigError

#: 인스턴스에 등록된 하드닝 — 새 연결에 걸 함수들의 튜플. 바꿀 때마다 새 튜플을 쓴다(얕은 복사본과
#: 리스트를 나눠 쓰다 한쪽의 등록이 다른 쪽에 새지 않게).
HARDENERS = "__kcsdk_hardeners__"
#: 감시 클래스가 감싼 원래 `connection` 프로퍼티 — 「이미 감시 클래스인가」의 표지다.
_BASE = "__kcsdk_openid_connection__"
_WATCHED: dict[type[KeycloakOpenID], type[KeycloakOpenID]] = {}
_SUPPORT = (
    "Pin python-keycloak to a supported version (>=7.1,<8) and report this at "
    "https://github.com/xzawed/KeyCloakSDK/issues."
)

#: 끼울 연결 하나를 받아 하드닝을 건다 — 걸 수 없으면 `KeycloakConfigError`.
Harden = Callable[[Any], None]


def _refused(what: str, why: str) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot guard the {what}: {why}, so this SDK cannot harden a connection set on it "
        f"through its public setter. {_SUPPORT}"
    )


def watched_type(cls: type[KeycloakOpenID], what: str) -> type[KeycloakOpenID]:
    """`cls` 의 하위 클래스 — `connection` 세터가 등록된 하드닝을 새 연결에 건 뒤에 끼운다. 이미
    감시 클래스면 그대로다. 만들 수 없으면 `KeycloakConfigError`(`what` 은 메시지에 쓸 대상)."""
    if _BASE in vars(cls):
        return cls
    cached = _WATCHED.get(cls)
    if cached is not None:
        return cached
    prop = inspect.getattr_static(cls, "connection", None)
    if not isinstance(prop, property) or prop.fset is None:
        raise _refused(what, f"{cls.__qualname__}.connection is not a property with a setter")
    fset = prop.fset

    def connection(self: KeycloakOpenID, value: Any) -> None:
        for harden in vars(self).get(HARDENERS, ()):
            harden(value)  # 던지면 끼우지 않는다 — 옛 연결이 남는다
        fset(self, value)

    # 이름·모듈은 감싼 클래스 그대로다(`admin_guard._watched_type` 과 같다).
    namespace = {
        "__slots__": (),
        "__module__": cls.__module__,
        "__qualname__": cls.__qualname__,
        "connection": property(prop.fget, connection, prop.fdel, prop.__doc__),
        _BASE: prop,
    }
    try:
        watched = type(cls.__name__, (cls,), namespace)
    except Exception as exc:  # `__init_subclass__`·메타클래스가 하위 클래스를 막는다
        why = f"subclassing {cls.__qualname__} failed ({type(exc).__name__})"
        raise _refused(what, why) from exc
    return _WATCHED.setdefault(cls, watched)


def watch(openid: Any, harden: Harden, what: str) -> None:
    """`openid.connection = 새 연결` 이 `harden(새 연결)` 을 지나야 끼워지게 한다 — 진짜
    `KeycloakOpenID` 만(목·흉내 객체는 그대로 둔다). 클래스를 바꾸지 못하면
    `KeycloakConfigError` 이고 등록하지 않는다. auth 레인이 생성 때 하드닝마다 부른다 — admin 은
    이 모듈의 조각으로 자기 설치의 전부이거나 아무것도 안에서 건다(`admin_guard._plan_watch`)."""
    cls = type(openid)
    if not issubclass(cls, KeycloakOpenID):
        return
    watched = watched_type(cls, what)
    if cls is not watched:
        try:
            openid.__class__ = watched
            kept = type(openid) is watched  # 소비자의 `__setattr__` 가 조용히 버릴 수 있다
        except Exception as exc:
            why = f"replacing the class of {cls.__qualname__} failed ({type(exc).__name__})"
            raise _refused(what, why) from exc
        if not kept:
            raise _refused(what, f"{cls.__qualname__} did not keep its replaced class")
    hardeners = vars(openid).get(HARDENERS, ())
    if harden not in hardeners:
        vars(openid)[HARDENERS] = (*hardeners, harden)
