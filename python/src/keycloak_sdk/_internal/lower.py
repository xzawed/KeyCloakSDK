"""하위 라이브러리(python-keycloak) 실패를 경계에서 SDK 예외로 옮길 때 **옮기지 않는 것**.

⚠️ python-keycloak 의 실패는 **응답 본문을 싣는다.** `KeycloakError.__str__` 은
`"{상태}: {본문}"`(오류 JSON 에 `message` 키가 있으면 그 값)이고, 200 인데 JSON 객체가 아닌
응답에는 본문을 `value ...` 로 인용한 `TypeError` 를 던진다. 예전 경계는 `str(exc)` 를 SDK
메시지로 옮기고 원본을 `from exc` 로 달았다 — 형식이 틀리거나 요청을 되돌리는 응답(프록시 오류
페이지·`error_description` 되돌림)이 실은 토큰과 `client_secret` 이 `str(e)`·`repr(e)`·
`logging.exception` 에 그대로 찍혔다(실측 2026-09-26, `tests/unit/test_token_response_leaks.py`).

그래서 경계는 (1) 메시지를 HTTP 상태와 OAuth 오류 코드로 **새로 쓰고**, (2) 원본 대신 타입
이름·상태·던진 자리만 담은 `LowerLibraryError` 를 원인으로 단다. 호출자는 SDK 예외를 `except`
**밖에서** 던진다 — 안에서 던지면 `__context__` 가 원본을 붙들어 사슬로 닿는다(§4: 하위 타입도
새지 않는다).
"""

from __future__ import annotations

import json
import re

from keycloak.exceptions import KeycloakError

from ..exceptions import KeycloakAuthError, KeycloakTransportError

#: 등록된 OAuth 오류 코드의 모양(`invalid_grant` 등). 이 모양만 메시지에 싣는다 — `error` 자리에
#: 다른 것을 실어 온 응답이 그 값을 메시지로 밀어 넣지 못하게. 값 자체는 `KeycloakAuthError.error`
#: 에 예전대로 남는다(찍히지 않는 필드다).
_OAUTH_ERROR_CODE = re.compile(r"[a-z_]{1,64}")
_LOWER_PACKAGE = "keycloak"
_OWN_PACKAGE = __name__.partition(".")[0]


class LowerLibraryError(Exception):
    """하위 라이브러리 실패의 요약 — 타입 이름, HTTP 상태, 던진 자리(`모듈.함수:줄`)뿐이다.

    SDK 예외의 `__cause__` 로 달린다. 메시지·응답 본문·원본 사슬은 싣지 않는다."""


def _lower_frame(exc: BaseException) -> str | None:
    """`exc` 가 지나온 python-keycloak 프레임 중 가장 안쪽 — `모듈.함수:줄`, 없으면 `None`."""
    where = None
    tb = exc.__traceback__
    while tb is not None:
        module = tb.tb_frame.f_globals.get("__name__")
        if isinstance(module, str) and module.partition(".")[0] == _LOWER_PACKAGE:
            where = f"{module}.{tb.tb_frame.f_code.co_name}:{tb.tb_lineno}"
        tb = tb.tb_next
    return where


def is_lower_failure(exc: BaseException) -> bool:
    """python-keycloak 의 실패인가 — 그 예외 타입이거나, python-keycloak 프레임 **안에서** 났다.

    후자는 응답 모양이 틀렸을 때 python-keycloak 이 던지는 `TypeError`·`KeyError` 다(본문을 인용한
    `TypeError` 가 그중 하나다). 우리 코드의 버그(호출 서명 불일치 등)는 python-keycloak 프레임을
    지나지 않으므로 여기 걸리지 않고 그대로 전파된다. 이미 SDK 예외인 것(python-keycloak 이 되부른
    우리 코드가 던졌더라도)은 옮기지 않는다 — 타입의 **패키지**로 가른다."""
    if type(exc).__module__.partition(".")[0] == _OWN_PACKAGE:
        return False
    return isinstance(exc, KeycloakError) or _lower_frame(exc) is not None


def summarize(exc: BaseException) -> LowerLibraryError:
    """원인으로 달 요약. 메시지는 옮기지 않는다 — 대신 던진 자리로 디버깅을 잇는다."""
    cls = type(exc)
    text = f"{cls.__module__}.{cls.__qualname__}"
    status = getattr(exc, "response_code", None)
    if isinstance(status, int):
        text += f" (HTTP {status})"
    where = _lower_frame(exc)
    if where is not None:
        text += f" at {where}"
    return LowerLibraryError(text)


def oauth_error(exc: BaseException) -> str | None:
    """오류 응답 JSON 의 `error` 코드(best-effort). 본문이 JSON 객체가 아니면 `None`."""
    body = getattr(exc, "response_body", None)
    if not body:
        return None
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    error = data.get("error")
    return str(error) if error is not None else None


def auth_failure(exc: BaseException) -> KeycloakAuthError | KeycloakTransportError:
    """auth 경계의 분류 — HTTP 응답을 받았으면 `KeycloakAuthError`, 못 받았으면 전송 오류.

    응답을 받았지만 python-keycloak 이 쓸 수 없다고 던진 실패(`TypeError` 등)도 응답을 받은
    쪽이다 — `TokenSet.from_response` 가 쓸 수 없는 토큰 JSON 을 `KeycloakAuthError` 로 내는 것과
    같은 자리다."""
    if isinstance(exc, KeycloakError):
        status = exc.response_code
        if status is None:
            # 응답을 못 받았다 — 실을 본문이 없으므로 상류 메시지(연결 실패 사유)를 그대로 둔다.
            return KeycloakTransportError(str(exc))
        code = oauth_error(exc)
        shown = f" ({code})" if code is not None and _OAUTH_ERROR_CODE.fullmatch(code) else ""
        return KeycloakAuthError(f"Keycloak request failed: HTTP {status}{shown}", error=code)
    return KeycloakAuthError(f"Keycloak returned an unusable response ({type(exc).__name__})")
