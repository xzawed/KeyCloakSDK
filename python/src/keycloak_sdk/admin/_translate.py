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

from .._internal.lower import is_lower_failure, summarize
from ..exceptions import (
    KeycloakAdminError,
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
    """
    status = getattr(exc, "response_code", None)
    body = getattr(exc, "response_body", None)
    body_str: str | None
    if isinstance(body, (bytes, bytearray)):
        body_str = body.decode()
    else:
        body_str = str(body) if body else None
    if status is None:
        return KeycloakTransportError(str(exc))
    if status == 404:
        return KeycloakNotFoundError(status, body_str)
    if status == 409:
        return KeycloakConflictError(status, body_str)
    if status == 403:
        return KeycloakForbiddenError(status, body_str)
    return KeycloakAdminError(status, body_str)


def admin_failure(exc: BaseException) -> KeycloakAdminError | KeycloakTransportError:
    """`is_lower_failure` 인 실패의 분류.

    `KeycloakError` 는 `translate` 그대로다. 그 밖의 python-keycloak 실패(응답 모양이 틀려 그
    안에서 난 `TypeError`·`KeyError` — admin 토큰 그랜트의 응답이 쓸 수 없을 때도 여기다)는
    HTTP 상태가 없으므로 이 경계의 규칙대로 전송 쪽이다. 예전에는 raw 로 새어 본문을 인용했다.
    """
    if isinstance(exc, KeycloakError):
        return translate(exc)
    return KeycloakTransportError(
        f"Keycloak admin API returned an unusable response ({type(exc).__name__})"
    )


def call(fn: Callable[[], T]) -> T:
    """`fn`을 실행하고 python-keycloak 의 실패를 SDK 예외로 변환해 재발생시킨다.

    python-keycloak 의 실패가 아닌 예외(우리 코드의 버그)는 그대로 전파한다(변환 대상이 아님).
    원본은 `except` **밖에서** 다시 던져 `__context__` 로도 닿지 않게 한다.
    """
    try:
        return fn()
    except Exception as e:
        if not is_lower_failure(e):
            raise
        error, cause = admin_failure(e), summarize(e)
    raise error from cause
