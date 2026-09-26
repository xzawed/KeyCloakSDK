"""`_internal/lower.py` — 하위 라이브러리 실패를 SDK 예외로 옮길 때 **옮기지 않는 것**.

python-keycloak 의 실패는 응답 본문을 싣는다(`KeycloakError.__str__` 과 본문을 인용한
`TypeError`). 경계는 메시지를 상태·OAuth 코드로 새로 쓰고, 원인으로는 타입 이름·상태·던진 자리만
담은 요약을 단다. 전 경로 측정은 `test_token_response_leaks.py` 다.
"""

from __future__ import annotations

from typing import Any

import pytest
from keycloak.exceptions import KeycloakConnectionError, KeycloakPostError

from keycloak_sdk._internal.lower import (
    LowerLibraryError,
    auth_failure,
    is_lower_failure,
    oauth_error,
    summarize,
)
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError

TOKEN = "ZQ4-token-in-body-canary"
_BODY = b'{"error": "invalid_client", "error_description": "' + TOKEN.encode() + b'"}'


def _raised(fn: Any) -> Exception:
    try:
        fn()
    except Exception as exc:
        return exc
    raise AssertionError("아무것도 던지지 않았다")


# --- is_lower_failure --------------------------------------------------------------------


def test_keycloak_error_is_a_lower_failure_wherever_it_was_raised() -> None:
    assert is_lower_failure(KeycloakPostError("x", response_code=400))


def test_type_error_raised_inside_python_keycloak_is_a_lower_failure(lower_type_error: Any) -> None:
    assert is_lower_failure(lower_type_error(TOKEN.encode()))


def test_our_own_bug_is_not_a_lower_failure() -> None:
    """우리 코드의 버그(호출 서명 불일치 등)는 python-keycloak 프레임을 지나지 않는다 — 옮기지
    않고 그대로 전파돼야 디버깅이 된다."""
    assert not is_lower_failure(_raised(lambda: int("x")))
    assert not is_lower_failure(TypeError("unexpected keyword argument"))


def test_an_sdk_error_is_never_translated_again() -> None:
    assert not is_lower_failure(KeycloakAuthError("already ours"))


# --- summarize ---------------------------------------------------------------------------


def test_summary_keeps_type_status_and_origin_but_not_the_body(lower_post_error: Any) -> None:
    exc = lower_post_error(400, _BODY)
    assert TOKEN in str(exc), "대조군 — python-keycloak 은 본문을 메시지에 싣는다"

    summary = summarize(exc)

    assert isinstance(summary, LowerLibraryError)
    text = str(summary)
    assert text.startswith("keycloak.exceptions.KeycloakPostError (HTTP 400) at ")
    assert "keycloak.exceptions.raise_error_from_response:" in text
    assert TOKEN not in text
    assert summary.__cause__ is None and summary.__context__ is None


def test_summary_of_a_quoting_type_error_names_where_python_keycloak_threw_it(
    lower_type_error: Any,
) -> None:
    text = str(summarize(lower_type_error(TOKEN.encode())))

    assert text.startswith("builtins.TypeError at keycloak.keycloak_openid.token:")
    assert TOKEN not in text and "HTTP" not in text


def test_summary_without_python_keycloak_frames_has_no_origin() -> None:
    assert str(summarize(KeycloakConnectionError("down"))) == (
        "keycloak.exceptions.KeycloakConnectionError"
    )


# --- oauth_error -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        (None, None),
        (b"", None),
        (b"<html>not json</html>", None),
        (b'["invalid_grant"]', None),
        (b'{"error_description": "x"}', None),
        (b'{"error": "invalid_grant"}', "invalid_grant"),
        (b'{"error": 7}', "7"),
    ],
)
def test_oauth_error_is_best_effort(body: bytes | None, expected: str | None) -> None:
    assert oauth_error(KeycloakPostError("x", response_code=400, response_body=body)) == expected


# --- auth_failure ------------------------------------------------------------------------


def test_http_failure_message_is_status_and_code_not_the_body(lower_post_error: Any) -> None:
    error = auth_failure(lower_post_error(401, _BODY))

    assert isinstance(error, KeycloakAuthError)
    assert str(error) == "Keycloak request failed: HTTP 401 (invalid_client)"
    assert error.error == "invalid_client"


def test_a_code_that_is_not_shaped_like_an_oauth_code_stays_out_of_the_message(
    lower_post_error: Any,
) -> None:
    """`error` 자리에 토큰을 실어 온 응답 — 메시지로 밀어 넣지 못한다. 필드는 예전대로 보존한다."""
    error = auth_failure(lower_post_error(400, b'{"error": "' + TOKEN.encode() + b'"}'))

    assert str(error) == "Keycloak request failed: HTTP 400"
    assert isinstance(error, KeycloakAuthError) and error.error == TOKEN


def test_no_response_is_a_transport_error_with_the_upstream_reason() -> None:
    error = auth_failure(KeycloakConnectionError("Can't connect to server (refused)"))

    assert isinstance(error, KeycloakTransportError)
    assert str(error) == "Can't connect to server (refused)"


def test_an_unusable_response_is_an_auth_error_without_the_quoted_body(
    lower_type_error: Any,
) -> None:
    error = auth_failure(lower_type_error(TOKEN.encode()))

    assert isinstance(error, KeycloakAuthError)
    assert str(error) == "Keycloak returned an unusable response (TypeError)"
    assert error.error is None
