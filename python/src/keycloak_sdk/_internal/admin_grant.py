"""admin 레인 **자체** 토큰 그랜트의 응답 검사 — python-keycloak 이 보지 않는 `access_token`.

⚠️ python-keycloak 의 토큰 세터(`KeycloakOpenIDConnection.token`)는
`"Bearer " + value["access_token"]` 이 전부다 — 타입도 빈 값도 보지 않는다. 그래서 sync admin 은
빈 `access_token` 을 받으면 `Authorization: Bearer ` 로 admin REST 요청을 보냈고, aio 는 h11 이
그 헤더 값을 거부해 **우연히** 막혔지만 `KeycloakTransportError("Can't connect to server")` 로
잘못 보고됐다. 없음·null·비문자열은 세터의 `KeyError`·`TypeError` 가 전송 오류로 옮겨졌다 — auth
레인은 같은 응답을 `KeycloakAuthError` 로 거부한다(등록부
`python-admin-grant-accepts-empty-access-token`, `tests/unit/test_admin_grant.py`).

**왜 이 자리인가.** 연결이 토큰을 받는 곳은 중첩 `KeycloakOpenID` 의 네 메서드뿐이다 —
`get_token`·`refresh_token`·`a_get_token`·`a_refresh_token` 이 `token`·`refresh_token`·
`a_token`·`a_refresh_token` 의 결과를 그대로 세터에 넘긴다(첫 그랜트·만료 갱신·401 재시도·
`Refresh token expired` 폴백이 전부 이 넷을 지난다). 인스턴스에서 넷을 감싸 세터 **앞에서** auth
레인과 같은 판정(`tokens._usable_access_token`)으로 거부하므로 헤더가 서지 않고 요청도 나가지
않는다. 세터는 클래스의 프로퍼티라 인스턴스마다 바꿀 수 없다.

⚠️ 거부는 python-keycloak 프레임 **안에서** 난다 — 그 traceback 은 거부된 응답·이전 refresh
token 을 쥔 프레임을 지나고, 폴백이면 python-keycloak 의 `except` 안이라 `__context__` 가 그
400(응답 본문)이다. 그래서 경계(`admin/_translate.py` 의 `call`·`acall`)가 같은 타입·메시지로
**새로** 만들어 `except` 밖에서 던진다.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Coroutine
from typing import Any

from ..exceptions import KeycloakConfigError
from ..tokens import _usable_access_token

#: 중첩 `KeycloakOpenID` 의 그랜트 메서드 — 연결이 토큰을 받는 자리 전부다.
_SYNC_GRANTS = ("token", "refresh_token")
_ASYNC_GRANTS = ("a_token", "a_refresh_token")

_Grant = Callable[..., dict[str, Any]]
_AsyncGrant = Callable[..., Awaitable[dict[str, Any]]]


def _checked(grant: _Grant) -> _Grant:
    def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        response = grant(*args, **kwargs)
        _usable_access_token(response)
        return response

    return checked


def _achecked(grant: _AsyncGrant) -> Callable[..., Coroutine[Any, Any, dict[str, Any]]]:
    async def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        response = await grant(*args, **kwargs)
        _usable_access_token(response)
        return response

    return checked


def _grant(openid: Any, name: str) -> Any:
    grant = getattr(openid, name, None)
    if not callable(grant):
        raise KeycloakConfigError(
            f"cannot check the admin token grant: this SDK expects python-keycloak to expose "
            f"connection.keycloak_openid.{name}, but it is missing or not callable. Refusing to "
            f"build an admin client that could send an unusable access token to the admin API. "
            f"Pin python-keycloak to a supported version (>=7.1,<8) and report this at "
            f"https://github.com/xzawed/KeyCloakSDK/issues."
        )
    return grant


def guard_admin_grant(admin: Any) -> None:
    """`KeycloakAdmin` 의 토큰 그랜트가 쓸 수 없는 `access_token` 을 연결에 넘기지 못하게 한다.

    `harden_admin` **뒤에** 부른다 — 그것이 `connection.keycloak_openid`(지연 프로퍼티)를 이미
    실체화하고 없으면 생성을 거부했다. 넷을 다 감싼 뒤에야 바꾼다(하나라도 없으면 아무것도
    안 바꾼다).
    """
    openid = admin.connection.keycloak_openid
    sync = {name: _checked(_grant(openid, name)) for name in _SYNC_GRANTS}
    aio = {name: _achecked(_grant(openid, name)) for name in _ASYNC_GRANTS}
    for name, wrapped in {**sync, **aio}.items():
        setattr(openid, name, wrapped)
