"""`_translate` 단위 테스트 — python-keycloak 예외 → SDK 예외 경계 변환.

`call()`은 admin 리소스 파사드(4.2~4.4)가 모든 `KeycloakAdmin` 호출을 감싸는 데
쓰는 헬퍼다. 이 스위트는 상태 코드별 매핑과 `response_body` 보존, `response_code`가
없는 경우(전송 계층 오류)의 폴백을 증명한다.
"""

from __future__ import annotations

import traceback
from collections.abc import Callable
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
from keycloak_sdk.admin._translate import call, translate
from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakTransportError,
)


def test_404_maps_notfound():
    def boom() -> None:
        raise KeycloakGetError("nope", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        call(boom)


def test_409_maps_conflict():
    def boom() -> None:
        raise KeycloakGetError("dup", response_code=409)

    with pytest.raises(KeycloakConflictError):
        call(boom)


def test_403_maps_forbidden():
    def boom() -> None:
        raise KeycloakGetError("nope", response_code=403)

    with pytest.raises(KeycloakForbiddenError):
        call(boom)


def test_other_status_maps_generic_admin_error():
    def boom() -> None:
        raise KeycloakPostError("boom", response_code=500)

    with pytest.raises(KeycloakAdminError) as excinfo:
        call(boom)

    assert not isinstance(excinfo.value, KeycloakNotFoundError)
    assert not isinstance(excinfo.value, KeycloakConflictError)
    assert not isinstance(excinfo.value, KeycloakForbiddenError)
    assert excinfo.value.status_code == 500


def test_missing_response_code_maps_transport_error():
    def boom() -> None:
        raise KeycloakPutError("connection reset")

    with pytest.raises(KeycloakTransportError):
        call(boom)


def test_delete_error_translates_too():
    def boom() -> None:
        raise KeycloakDeleteError("nope", response_code=404)

    with pytest.raises(KeycloakNotFoundError):
        call(boom)


def test_response_body_bytes_decoded_and_preserved():
    def boom() -> None:
        raise KeycloakGetError(
            "nope", response_code=404, response_body=b'{"error":"User not found"}'
        )

    with pytest.raises(KeycloakNotFoundError) as excinfo:
        call(boom)

    assert excinfo.value.keycloak_error == '{"error":"User not found"}'


def test_response_body_none_preserved_as_none():
    exc = KeycloakGetError("nope", response_code=404)

    translated = translate(exc)

    assert isinstance(translated, KeycloakNotFoundError)
    assert translated.keycloak_error is None


def test_call_passes_through_successful_result():
    assert call(lambda: 42) == 42


def test_call_does_not_catch_non_keycloak_exceptions():
    def boom() -> None:
        raise ValueError("not a keycloak error")

    with pytest.raises(ValueError):
        call(boom)


_CANARY = "WK2-token-in-body-canary"
_BODY = b'{"error": "invalid_client", "error_description": "' + _CANARY.encode() + b'"}'


def _raiser(exc: Exception) -> Callable[[], None]:
    def boom() -> None:
        raise exc

    return boom


def test_the_raw_lower_error_is_not_attached_only_a_summary(lower_post_error: Any) -> None:
    """⚠️ python-keycloak 의 오류는 메시지가 응답 본문이다 — 원인으로 달면 `logging.exception` 이
    그것을 찍는다. 요약만 달고, 원본은 `__context__` 로도 닿지 않는다(except 밖에서 던진다)."""
    with pytest.raises(KeycloakAdminError) as excinfo:
        call(_raiser(lower_post_error(400, _BODY)))

    error = excinfo.value
    assert isinstance(error.__cause__, LowerLibraryError)
    assert str(error.__cause__).startswith("keycloak.exceptions.KeycloakPostError (HTTP 400)")
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))
    # `keycloak_error` 는 문서화된 필드로 본문을 예전대로 보존한다(찍히지 않는다).
    assert error.keycloak_error is not None
    assert _CANARY in error.keycloak_error


def test_unusable_response_inside_python_keycloak_is_a_transport_error(
    lower_type_error: Any,
) -> None:
    """python-keycloak 은 모양이 틀린 응답에 본문을 인용한 `TypeError` 를 던진다 — 예전에는 그것이
    raw 로 새어 `str(e)` 가 본문을 찍었다. HTTP 상태가 없으므로 이 경계의 규칙대로 전송 쪽이다."""
    with pytest.raises(KeycloakTransportError) as excinfo:
        call(_raiser(lower_type_error(_CANARY.encode())))

    error = excinfo.value
    assert str(error) == "Keycloak admin API returned an unusable response (TypeError)"
    assert str(error.__cause__).startswith("builtins.TypeError at keycloak.keycloak_openid.token:")
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))


#: UTF-8 이 아닌 오류 본문 — 0xFF(어디서도 시작 바이트가 아니다)와 UTF-8 로 인코딩한 서로게이트
#: (ED A0 80, 엄격한 디코더가 거부한다). 둘 다 수정 전에는 raw `UnicodeDecodeError` 가 샜다.
_NOT_UTF8 = {
    "0xFF": b'{"errorMessage":"\xff ' + _CANARY.encode() + b'"}',
    "ED A0 80": b'{"errorMessage":"\xed\xa0\x80 ' + _CANARY.encode() + b'"}',
}


@pytest.mark.parametrize("status", [400, 404])
@pytest.mark.parametrize("body", list(_NOT_UTF8.values()), ids=list(_NOT_UTF8))
def test_an_error_body_that_is_not_utf8_is_an_sdk_error_with_no_body_in_its_chain(
    lower_post_error: Any, status: int, body: bytes
) -> None:
    """§4 — 예전에는 엄격한 `body.decode()` 가 `except` 안에서 raw `UnicodeDecodeError` 를 냈고,
    그 `__context__` 가 응답 본문을 쥔 python-keycloak 오류였다. 이제 SDK 타입이고 사슬은
    요약뿐이다."""
    with pytest.raises(KeycloakAdminError) as excinfo:
        call(_raiser(lower_post_error(status, body)))

    error = excinfo.value
    assert error.status_code == status
    assert isinstance(error.__cause__, LowerLibraryError)
    assert error.__context__ is None
    assert _CANARY not in "".join(traceback.format_exception(error))
    # 문서화된 필드는 본문을 예전대로 보존한다 — 풀 수 없는 바이트는 버리지도(ignore) 바꾸지도
    # (replace) 않고 이스케이프로 보인다.
    assert error.keycloak_error == body.decode("utf-8", "backslashreplace")


def test_translate_never_raises_on_a_body_it_cannot_decode() -> None:
    translated = translate(KeycloakGetError("x", response_code=400, response_body=b"\xff\xfe"))

    assert isinstance(translated, KeycloakAdminError)
    assert translated.keycloak_error == "\\xff\\xfe"


def _refused_grant_body() -> KeycloakConnectionError:
    """admin 그랜트 세션이 상한을 넘는 본문을 거부했을 때 `raw_post` 가 만드는 오류 그대로다."""
    try:
        raise KeycloakConnectionError("Can't connect to server") from ResponseRefused(
            "token response exceeds 1048576 bytes"
        )
    except KeycloakConnectionError as exc:
        return exc


def test_a_grant_body_over_the_cap_is_the_auth_lanes_refusal_not_a_transport_error() -> None:
    with pytest.raises(KeycloakAuthError) as excinfo:
        call(_raiser(_refused_grant_body()))

    error = excinfo.value
    assert type(error) is KeycloakAuthError
    assert str(error) == "token response exceeds 1048576 bytes"
    assert isinstance(error.__cause__, LowerLibraryError)
    assert error.__context__ is None
