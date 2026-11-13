"""python-keycloak 예외 → SDK 예외 경계 변환.

리소스 파사드(4.2~4.4)는 `KeycloakAdmin`을 호출할 때 항상 `call(...)`로 감싼다 —
`keycloak.exceptions.*`(python-keycloak) 타입이 공개 API에 노출되지 않도록 여기서
`KeycloakAdminError` 계층(및 하위 `KeycloakTransportError`)으로 변환한다.

⚠️ **원본 예외를 원인으로 달지 않는다** — python-keycloak 은 거기에 응답 본문을 싣고(admin 의
토큰 그랜트가 받은 토큰·되돌린 `client_secret` 까지), 형식이 틀린 응답에는 본문을 인용한
`TypeError` 를 던진다. 규칙과 실측은 `_internal/lower.py`.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TypeVar

from keycloak.exceptions import KeycloakError

from .._internal.admin_body import RedirectionStatus, facade, no_body
from .._internal.admin_grant import is_grant_failure
from .._internal.lower import grant_failure, is_lower_failure, refused_body, summarize
from ..exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConfigError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakTransportError,
)

T = TypeVar("T")


def translate(exc: KeycloakError) -> KeycloakAdminError | KeycloakTransportError:
    """`KeycloakError`를 HTTP 상태 코드에 따라 SDK 예외로 매핑한다.

    `response_code`가 없으면(네트워크/전송 계층 실패 — HTTP 응답 자체를 못 받음)
    `KeycloakTransportError`로, 있으면 상태별(`404`→NotFound, `409`→Conflict,
    `403`→Forbidden, 그 외→일반 `KeycloakAdminError`)로 변환한다. `response_body`는
    가능하면 문자열로 보존한다.

    ⚠️ **이 함수는 던지지 않는다** — `call`·`acall` 이 `except` **안에서** 부르므로, 여기서 난
    예외는 SDK 타입이 아닌 채로 새고 그 `__context__` 가 응답 본문을 쥔 python-keycloak 오류다.
    예전의 엄격한 `body.decode()` 가 UTF-8 이 아닌 오류 본문에서 바로 그렇게 raw
    `UnicodeDecodeError` 를 냈다(실측: 0xFF · UTF-8 로 인코딩한 서로게이트 ED A0 80, sync·aio).
    풀 수 없는 바이트는 버리지도 바꾸지도 않고 `\\xff` 처럼 이스케이프로 남긴다.

    ⚠️ admin **자체 토큰 그랜트**의 실패는 여기 오지 않는다 — `admin_failure` 가 auth 레인과
    같은 판정으로 먼저 가른다(`grant_failure`). 여기 오는 것은 admin REST 응답의 오류(리소스의
    401 포함)이고 본문을 싣는다.
    """
    status = getattr(exc, "response_code", None)
    if status is None:
        return KeycloakTransportError(str(exc))
    return by_status(status, getattr(exc, "response_body", None))


def by_status(status: int, body: object) -> KeycloakAdminError:
    """상태로 고른 admin 오류(`translate` 의 매핑) — 본문은 그대로 문자열로 싣는다. 파사드
    요청이 받은 3xx(`_internal/admin_body.py` 의 `RedirectionStatus`)도 이것으로 4xx 와 같은
    판정을 받는다."""
    body_str: str | None
    if isinstance(body, (bytes, bytearray)):
        body_str = body.decode("utf-8", "backslashreplace")
    else:
        body_str = str(body) if body else None
    if status == 404:
        return KeycloakNotFoundError(status, body_str)
    if status == 409:
        return KeycloakConflictError(status, body_str)
    if status == 403:
        return KeycloakForbiddenError(status, body_str)
    return KeycloakAdminError(status, body_str)


def admin_failure(
    exc: BaseException,
) -> KeycloakAdminError | KeycloakTransportError | KeycloakAuthError:
    """`is_lower_failure` 인 실패의 분류.

    admin **자체 토큰 그랜트**의 실패(`_internal/admin_grant.py` 가 표시한 것)는 auth 레인과
    같은 판정이다(`grant_failure` — 끝까지 온 응답이면 `KeycloakAuthError`, 상한 초과·연결
    실패는 `KeycloakTransportError`). 그랜트 응답을 python-keycloak 이 못 쓴 실패와
    `access_token`·`expires_in` 을 못 쓰는 응답은 여기 오기 전에 그 모듈이 같은 판정의
    `KeycloakAuthError` 로 거부한다(`refused_grant`).

    그 밖의 `KeycloakError`(admin REST 응답)는 `translate` 그대로다. python-keycloak 이 admin
    REST 응답을 못 쓴 실패(`TypeError`·`KeyError`)는 HTTP 상태가 없으므로 이 경계의 규칙대로
    전송 쪽이다. 예전에는 raw 로 새어 본문을 인용했다.

    파사드 요청이 받은 3xx 는 python-keycloak 에 닿지 않는다 — 세션이 던진 `RedirectionStatus`
    (`raw_*` 가 감싼 원인)를 그 상태의 오류로 새로 만든다(`by_status` — 4xx 와 같은 판정).
    """
    if is_grant_failure(exc):
        return grant_failure(exc)
    refused = refused_body(exc)
    if refused is not None:
        return refused
    signal = exc.__cause__
    if isinstance(signal, RedirectionStatus):
        return by_status(signal.status, signal.body)
    if isinstance(exc, KeycloakError):
        return translate(exc)
    return KeycloakTransportError(
        f"Keycloak admin API returned an unusable response ({type(exc).__name__})"
    )


def refused_grant(exc: KeycloakAuthError) -> KeycloakAuthError:
    """admin 자체 그랜트의 응답 검사(`_internal/admin_grant.py`)나 보낼 bearer 검사
    (`_internal/admin_guard.py`)가 python-keycloak **안에서** 던진 거부를 같은 타입·메시지로 새로
    만든다.

    원본은 그 안쪽 프레임(거부된 응답·이전 refresh token·보낼 요청 본문)을 traceback 으로 쥐고,
    `Refresh token expired` 폴백에서 났으면 python-keycloak 의 `except` 안이라 `__context__` 가 그
    400(응답 본문)이다 — 호출자는 원본을 버리고 이것을 `except` **밖에서** 던진다."""
    return KeycloakAuthError(str(exc), exc.error)


def refused_guard(exc: KeycloakConfigError) -> KeycloakConfigError:
    """요청 직전에 살아 있는 연결을 무장하지 못한 거부(`_internal/admin_guard.py`)를 새로 만든다 —
    python-keycloak 의 admin 메서드 프레임 안(보낼 representation 을 쥔다)에서 났기 때문이다."""
    return KeycloakConfigError(str(exc))


def write_call(fn: Callable[[], T]) -> T:
    """`call` 과 같되 성공 응답의 본문을 읽지 않는다(`_internal/admin_body.py`) — 파사드의
    쓰기 호출(create 는 `Location` 을, update·delete 는 상태만 쓴다). 오류 응답의 본문은
    상한까지 그대로 실린다."""
    with no_body():
        return call(fn)


def call(fn: Callable[[], T]) -> T:
    """`fn`을 실행하고 python-keycloak 의 실패를 SDK 예외로 변환해 재발생시킨다.

    python-keycloak 의 실패가 아닌 예외(우리 코드의 버그)는 그대로 전파한다(변환 대상이 아님).
    admin 하드닝의 거부(그랜트·bearer 검사, 연결 무장 실패)는 같은 타입으로 새로 만든다
    (`refused_grant`·`refused_guard`). 원본은 `except` **밖에서** 다시 던져 `__context__` 로도
    닿지 않게 한다. 파사드 호출임을 표시해(`facade`) 그 요청의 3xx 를 결과로 넘기지 않는다.
    """
    error: KeycloakAuthError | KeycloakConfigError | KeycloakAdminError | KeycloakTransportError
    cause: BaseException | None
    try:
        with facade():
            return fn()
    except KeycloakAuthError as e:
        error, cause = refused_grant(e), None
    except KeycloakConfigError as e:
        error, cause = refused_guard(e), None
    except Exception as e:
        if not is_lower_failure(e):
            raise
        error, cause = admin_failure(e), summarize(e)
    raise error from cause
