"""python-keycloak 예외 → SDK 예외 async 경계 변환.

sync `keycloak_sdk.admin._translate`(분류 `admin_failure`)를 그대로 재사용한다(중복 금지) —
`acall`은 `await` 후 예외 변환만 담당한다. ⚠️ 원본 예외를 원인으로 달지 않는 이유는 sync 쪽과
`_internal/lower.py` 에 있다.
"""

from __future__ import annotations

from collections.abc import Awaitable
from typing import TypeVar

from ..._internal.lower import is_lower_failure, summarize
from ...admin._translate import admin_failure

T = TypeVar("T")


async def acall(awaitable: Awaitable[T]) -> T:
    """`awaitable`을 await하고 python-keycloak 의 실패를 SDK 예외로 변환해 재발생시킨다.

    python-keycloak 의 실패가 아닌 예외는 그대로 전파한다(변환 대상이 아님). 리소스
    파사드는 `await acall(self._admin.a_...(...))` 형태로 이 함수를 사용한다.
    """
    try:
        return await awaitable
    except Exception as e:
        if not is_lower_failure(e):
            raise
        error, cause = admin_failure(e), summarize(e)
    raise error from cause
