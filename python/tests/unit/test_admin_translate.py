"""`_translate` 단위 테스트 — python-keycloak 예외 → SDK 예외 경계 변환.

`call()`은 admin 리소스 파사드(4.2~4.4)가 모든 `KeycloakAdmin` 호출을 감싸는 데
쓰는 헬퍼다. 이 스위트는 상태 코드별 매핑과 `response_body` 보존, `response_code`가
없는 경우(전송 계층 오류)의 폴백을 증명한다.
"""

from __future__ import annotations

import pytest
from keycloak.exceptions import (
    KeycloakDeleteError,
    KeycloakGetError,
    KeycloakPostError,
    KeycloakPutError,
)

from keycloak_sdk.admin._translate import call, translate
from keycloak_sdk.exceptions import (
    KeycloakAdminError,
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
