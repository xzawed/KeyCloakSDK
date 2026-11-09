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

⚠️ **bearer 규칙(`bearer.py`)에 맞지 않는 토큰도 여기서 거부하고, 맞으면 다듬은 값을 세터에
넘긴다** — python-keycloak 의 401 재시도는 보내는 자리를 거치지 않고 세터가 실은 값을 곧바로 다시
보낸다. auth 레인은 그것을 거부하지 않는다(`TokenSet` 으로 소비자에게 간다 — 규칙의 범위 밖이다).
sync 그랜트 둘과 `a_*` 둘이 같은 판정이다.

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
안 된다. 경계는 표시된 실패를 auth 레인과 같은 판정으로 낸다(`lower.grant_failure`
— `KeycloakAuthError`, 등록부 token-response-class-divergent D4). 응답 본문은 싣지
않는다 — 토큰 엔드포인트는 그랜트가 폼에 실어 보낸 `client_secret`(갱신이면 admin 의
refresh token 도)을 오류 본문에 되울릴 수 있고, 예전에는 그것이
`KeycloakAdminError.keycloak_error` 에 그대로 남았다(등록부
`secret-echo-form-encoded-rescan`, `tests/unit/test_admin_grant_echo.py`). admin REST
응답의 오류는 이 래퍼를 지나지 않는다 — 같은 401 `KeycloakAuthenticationError` 라도
리소스의 것이면 표시가 없다.

⚠️ **python-keycloak 이 끝까지 온 그랜트 응답을 못 쓴 실패**(JSON 객체가 아닌 2xx 에
본문을 인용한 `TypeError`)는 표시할 수 없다 — `WeakSet` 이 내장 예외를 담지 못한다.
그래서 여기서 곧바로 같은 판정의 `KeycloakAuthError` 로 바꿔 던진다(경계가
`refused_grant` 로 새로 만든다). 세터가 쓰는 `expires_in`
(`int(0.9 * value["expires_in"])`)도 세터 앞에서 본다 — 없거나 못 쓰면 세터의
`KeyError`·`TypeError` 가 전송 오류로 옮겨졌다.
"""

from __future__ import annotations

import math
import weakref
from collections.abc import Awaitable, Callable, Coroutine, Mapping
from datetime import datetime, timedelta
from typing import Any

from keycloak.exceptions import KeycloakError

from ..exceptions import KeycloakAuthError
from ..tokens import _usable_access_token
from .bearer import GRANTED, sendable
from .lower import is_lower_failure, unusable_response

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


def _carried(response: dict[str, Any]) -> dict[str, Any]:
    """세터에 넘길 그랜트 응답 — access_token 이 쓸 수 있고 bearer 규칙에 맞으며
    `expires_in` 을 세터가 쓸 수 있으면 그 값을 다듬은 응답, 아니면 `KeycloakAuthError`.
    세터 앞이라 거부한 토큰은 캐시되지 않는다(`bearer.py`)."""
    token = _usable_access_token(response)
    bearer = sendable(token)
    if bearer is None:
        raise KeycloakAuthError(GRANTED)
    _usable_expiry(response)
    return response if bearer == token else {**response, "access_token": bearer}


def _usable_expiry(response: Mapping[str, Any]) -> None:
    """python-keycloak 의 세터가 `now + timedelta(seconds=int(0.9 * value["expires_in"]))` 로 쓰는
    값 — 그 셈이 넘치지 않는 유한한 수여야 한다. 없으면 `KeyError`, 문자열·null 이면 `TypeError`,
    무한대 · 날짜를 넘치는 수(`1e300` · `300000000000` · `-1e12`)면 `OverflowError` 였다(뒤의 것은
    독립 레그가 찾음). 쓸 수 없는 값의 메시지는 auth 레인(`tokens._expires_at`)과 같다 — 단 auth
    레인은 숫자 문자열과 없음도 받는다(그 소비자는 세터가 아니다)."""
    expires_in = response.get("expires_in")
    if expires_in is None:
        raise KeycloakAuthError("token response has no expires_in")
    usable = isinstance(expires_in, (int, float)) and math.isfinite(expires_in)
    if usable:
        try:
            # 세터의 셈 그대로 — 비율(0.9)을 빼 보수적으로 잰다: x 가 넘치지 않으면 0.9x 도
            # 넘치지 않는다.
            datetime.now() + timedelta(seconds=int(expires_in))
        except (OverflowError, ValueError):
            usable = False
    # ⚠️ 거부는 `except` **밖**이다 — 안에서 던지면 `OverflowError` 가 `__context__` 로 매달린다.
    if not usable:
        raise KeycloakAuthError("token response has an invalid expires_in")


def _unusable(exc: Exception) -> KeycloakAuthError | None:
    """그랜트에서 빠져나온 python-keycloak 의 비-`KeycloakError` 실패 — 전송 실패는
    python-keycloak 이 전부 `KeycloakConnectionError` 로 감싸므로 이것은 끝까지 온 응답을 못
    쓴 것이고, auth 레인과 같은 판정이다(`unusable_response`). python-keycloak 밖의 예외(우리
    코드)는 `None` — 그대로 다시 던진다."""
    return unusable_response(exc) if is_lower_failure(exc) else None


def _checked(grant: _Grant) -> _Grant:
    def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        refused: KeycloakAuthError | None = None
        try:
            response = grant(*args, **kwargs)
        except KeycloakError as exc:
            _FAILED_GRANTS.add(exc)
            raise
        except Exception as exc:
            refused = _unusable(exc)
            if refused is None:
                raise
        # ⚠️ 거부는 `except` **밖**에서 던진다 — 안에서 던지면 본문을 인용한 `TypeError` 가
        # `__context__` 로 매달린다.
        if refused is not None:
            raise refused
        return _carried(response)

    return checked


def _achecked(grant: _AsyncGrant) -> Callable[..., Coroutine[Any, Any, dict[str, Any]]]:
    async def checked(*args: Any, **kwargs: Any) -> dict[str, Any]:
        refused: KeycloakAuthError | None = None
        try:
            response = await grant(*args, **kwargs)
        except KeycloakError as exc:
            _FAILED_GRANTS.add(exc)
            raise
        except Exception as exc:
            refused = _unusable(exc)
            if refused is None:
                raise
        if refused is not None:
            raise refused
        return _carried(response)

    return checked
