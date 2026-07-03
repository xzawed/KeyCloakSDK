"""python-keycloak 예외 → SDK 예외 경계 변환.

리소스 파사드(4.2~4.4)는 `KeycloakAdmin`을 호출할 때 항상 `call(...)`로 감싼다 —
`keycloak.exceptions.*`(python-keycloak) 타입이 공개 API에 노출되지 않도록 여기서
`KeycloakAdminError` 계층(및 하위 `KeycloakTransportError`)으로 변환한다.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TypeVar

from keycloak.exceptions import KeycloakError

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


def call(fn: Callable[[], T]) -> T:
    """`fn`을 실행하고 `KeycloakError`를 SDK 예외로 변환해 재발생시킨다.

    `KeycloakError`가 아닌 예외는 그대로 전파한다(변환 대상이 아님).
    """
    try:
        return fn()
    except KeycloakError as e:
        raise translate(e) from e
