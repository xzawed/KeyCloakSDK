"""`acall` 단위 테스트 — python-keycloak 예외 → SDK 예외 async 경계 변환.

sync `keycloak_sdk.admin._translate.translate`(상태 코드→예외 매핑)를 재사용하는지
증명한다(매핑 중복 금지). sync `tests/unit/test_admin_translate.py`와 동형.
"""

from __future__ import annotations

import traceback
from typing import Any

import pytest
from keycloak.exceptions import (
    KeycloakConnectionError,
    KeycloakDeleteError,
    KeycloakGetError,
    KeycloakPostError,
    KeycloakPutError,
)

from keycloak_sdk._internal.lower import LowerLibraryError
from keycloak_sdk._internal.token_cap import ResponseRefused
from keycloak_sdk.aio.admin._translate import acall
from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakTransportError,
)


async def _raise(exc: Exception) -> None:
    raise exc


async def test_404_maps_notfound():
    with pytest.raises(KeycloakNotFoundError):
        await acall(_raise(KeycloakGetError("nope", response_code=404)))


async def test_409_maps_conflict():
    with pytest.raises(KeycloakConflictError):
        await acall(_raise(KeycloakGetError("dup", response_code=409)))


async def test_403_maps_forbidden():
    with pytest.raises(KeycloakForbiddenError):
        await acall(_raise(KeycloakGetError("nope", response_code=403)))


async def test_other_status_maps_generic_admin_error():
    with pytest.raises(KeycloakAdminError) as excinfo:
        await acall(_raise(KeycloakPostError("boom", response_code=500)))

    assert not isinstance(excinfo.value, KeycloakNotFoundError)
    assert not isinstance(excinfo.value, KeycloakConflictError)
    assert not isinstance(excinfo.value, KeycloakForbiddenError)
    assert excinfo.value.status_code == 500


async def test_missing_response_code_maps_transport_error():
    with pytest.raises(KeycloakTransportError):
        await acall(_raise(KeycloakPutError("connection reset")))


async def test_delete_error_translates_too():
    with pytest.raises(KeycloakNotFoundError):
        await acall(_raise(KeycloakDeleteError("nope", response_code=404)))


async def test_response_body_bytes_decoded_and_preserved():
    with pytest.raises(KeycloakNotFoundError) as excinfo:
        await acall(
            _raise(
                KeycloakGetError(
                    "nope", response_code=404, response_body=b'{"error":"User not found"}'
                )
            )
        )

    assert excinfo.value.keycloak_error == '{"error":"User not found"}'


async def test_acall_passes_through_successful_result():
    async def ok() -> int:
        return 42

    assert await acall(ok()) == 42


async def test_acall_does_not_catch_non_keycloak_exceptions():
    async def boom() -> None:
        raise ValueError("not a keycloak error")

    with pytest.raises(ValueError):
        await acall(boom())


_CANARY = "WK3-token-in-body-canary"
_BODY = b'{"error": "forbidden", "error_description": "' + _CANARY.encode() + b'"}'


async def test_the_raw_lower_error_is_not_attached_only_a_summary(lower_post_error: Any) -> None:
    """sync `call` 과 동형 — 원본 대신 요약을 달고, `__context__` 로도 닿지 않는다."""
    with pytest.raises(KeycloakForbiddenError) as excinfo:
        await acall(_raise(lower_post_error(403, _BODY)))

    error = excinfo.value
    assert isinstance(error.__cause__, LowerLibraryError)
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))


async def test_unusable_response_inside_python_keycloak_is_a_transport_error(
    lower_type_error: Any,
) -> None:
    with pytest.raises(KeycloakTransportError) as excinfo:
        await acall(_raise(lower_type_error(_CANARY.encode())))

    error = excinfo.value
    assert str(error) == "Keycloak admin API returned an unusable response (TypeError)"
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))


@pytest.mark.parametrize("status", [400, 404])
@pytest.mark.parametrize(
    "body",
    [b'{"errorMessage":"\xff ' + _CANARY.encode() + b'"}', b'{"error":"\xed\xa0\x80"}'],
    ids=["0xFF", "ED A0 80"],
)
async def test_an_error_body_that_is_not_utf8_is_an_sdk_error_with_no_body_in_its_chain(
    lower_post_error: Any, status: int, body: bytes
) -> None:
    """sync `call` 과 동형 — raw `UnicodeDecodeError` 가 새지 않고, 사슬에 본문이 없다."""
    with pytest.raises(KeycloakAdminError) as excinfo:
        await acall(_raise(lower_post_error(status, body)))

    error = excinfo.value
    assert error.status_code == status
    assert isinstance(error.__cause__, LowerLibraryError)
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))
    assert error.keycloak_error == body.decode("utf-8", "backslashreplace")


async def test_a_grant_body_over_the_cap_is_the_auth_lanes_refusal_not_a_transport_error() -> None:
    """sync `call` 과 동형 — `a_raw_post` 가 감싼 상한 거부는 연결 실패가 아니다."""
    try:
        raise KeycloakConnectionError("Can't connect to server") from ResponseRefused(
            "token response exceeds 1048576 bytes"
        )
    except KeycloakConnectionError as exc:
        lower = exc

    with pytest.raises(KeycloakAuthError) as excinfo:
        await acall(_raise(lower))

    error = excinfo.value
    assert type(error) is KeycloakAuthError
    assert str(error) == "token response exceeds 1048576 bytes"
    assert isinstance(error.__cause__, LowerLibraryError)
    assert error.__context__ is None
