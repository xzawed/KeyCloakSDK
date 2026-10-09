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

⚠️ **헤더가 실을 수 없는 토큰도 여기서 거부한다**(`bearer.py` — RFC 9110 이 빼는 제어 문자와 그
레인의 전송이 못 싣는 문자) — auth 레인은 그것을 거부하지 않는다(`TokenSet` 으로 소비자에게 가고,
그 판정은 언어 횡단 `bearer-token-grammar-divergent` 다). 레인은 래퍼의 것이다 — sync 그랜트 둘은
sync 요청이, `a_*` 둘은 aio 요청이 부른다.

⚠️ 감싸기를 **거는** 것은 이 모듈이 아니라 `admin_guard.py` 다 — 생성 때 한 번이 아니라 admin 요청이
나가기 전마다 살아 있는 중첩 객체에 걸려 있는지 다시 본다(`raw.connection` 은 공개 세터로 갈아
끼워진다). 그랜트를 거치지 않고 실린 bearer(주입·토큰 세터)도 거기서 잡는다.

⚠️ 거부는 python-keycloak 프레임 **안에서** 난다 — 그 traceback 은 거부된 응답·이전 refresh
token 을 쥔 프레임을 지나고, 폴백이면 python-keycloak 의 `except` 안이라 `__context__` 가 그
400(응답 본문)이다. 그래서 경계(`admin/_translate.py` 의 `call`·`acall`)가 같은 타입·메시지로
**새로** 만들어 `except` 밖에서 던진다.

⚠️ **그랜트 자체가 실패하면**(토큰 엔드포인트의 4xx·5xx) 그 python-keycloak 오류를 표시만 하고 **같은
객체를** 다시 던진다 — python-keycloak 의 `refresh_token` 폴백이 그 오류의 `response_code`·
`response_body`(`Refresh token expired` 등)를 읽고 client_credentials 로 넘어가므로 바꾸거나 감싸면
안 된다. 경계는 표시된 실패의 응답 본문을 SDK 예외에 싣지 않는다(`is_grant_failure`) — 토큰
엔드포인트는 그랜트가 폼에 실어 보낸 `client_secret`(갱신이면 admin 의 refresh token 도)을 오류
본문에 되울릴 수 있고, 예전에는 그것이 `KeycloakAdminError.keycloak_error` 에 그대로 남았다(등록부
`secret-echo-form-encoded-rescan`, `tests/unit/test_admin_grant_echo.py`). admin REST 응답의 오류는
이 래퍼를 지나지 않는다 — 같은 401 `KeycloakAuthenticationError` 라도 리소스의 것이면 표시가 없다.
"""

from __future__ import annotations

import weakref
from collections.abc import Awaitable, Callable, Coroutine
from typing import Any

from keycloak.exceptions import KeycloakError

from ..exceptions import KeycloakAuthError
from ..tokens import _usable_access_token
from .bearer import GRANTED, Lane, unsendable

#: 중첩 `KeycloakOpenID` 의 그랜트 메서드 — 연결이 토큰을 받는 자리 전부다.
_SYNC_GRANTS = ("token", "refresh_token")
_ASYNC_GRANTS = ("a_token", "a_refresh_token")

#: 그랜트 래퍼를 빠져나간 python-keycloak 실패 — 정체로 대조하고, 붙잡아 두지 않는다.
_FAILED_GRANTS: weakref.WeakSet[KeycloakError] = weakref.WeakSet()

_Grant = Callable[..., dict[str, Any]]
_AsyncGrant = Callable[..., Awaitable[dict[str, Any]]]


def is_grant_failure(exc: BaseException) -> bool:
    """`exc` 가 admin 자체 토큰 그랜트(위 네 메서드)에서 빠져나온 실패인가."""
    return exc in _FAILED_GRANTS


def _require_carried(response: dict[str, Any], lane: Lane) -> None:
    """그랜트 응답의 access_token 이 쓸 수 있고 `lane` 의 헤더가 실을 수 있는가 — 아니면
    `KeycloakAuthError`. 세터 앞이라 거부한 토큰은 캐시되지 않는다(`bearer.py`)."""
    reason = unsendable(_usable_access_token(response), lane)
    if reason is not None:
        raise KeycloakAuthError(GRANTED.format(reason))


def _checked(grant: _Grant) -> _Grant:
    def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        try:
            response = grant(*args, **kwargs)
        except KeycloakError as exc:
            _FAILED_GRANTS.add(exc)
            raise
        _require_carried(response, "sync")
        return response

    return checked


def _achecked(grant: _AsyncGrant) -> Callable[..., Coroutine[Any, Any, dict[str, Any]]]:
    async def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        try:
            response = await grant(*args, **kwargs)
        except KeycloakError as exc:
            _FAILED_GRANTS.add(exc)
            raise
        _require_carried(response, "aio")
        return response

    return checked
