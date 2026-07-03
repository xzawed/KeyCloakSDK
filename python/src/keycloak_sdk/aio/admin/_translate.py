"""python-keycloak 예외 → SDK 예외 async 경계 변환.

sync `keycloak_sdk.admin._translate.translate`(상태 코드→예외 매핑)를 그대로
재사용한다(중복 금지) — `acall`은 `await` 후 예외 변환만 담당한다.
"""

from __future__ import annotations

from collections.abc import Awaitable
from typing import TypeVar

from keycloak.exceptions import KeycloakError

from ...admin._translate import translate

T = TypeVar("T")


async def acall(awaitable: Awaitable[T]) -> T:
    """`awaitable`을 await하고 `KeycloakError`를 SDK 예외로 변환해 재발생시킨다.

    `KeycloakError`가 아닌 예외는 그대로 전파한다(변환 대상이 아님). 리소스
    파사드는 `await acall(self._admin.a_...(...))` 형태로 이 함수를 사용한다.
    """
    try:
        return await awaitable
    except KeycloakError as e:
        raise translate(e) from e
