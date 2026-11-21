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
import string
from collections.abc import Iterable

from keycloak.exceptions import KeycloakError

from ..exceptions import KeycloakAuthError, KeycloakTransportError
from .token_cap import Answered, ResponseRefused

#: 등록된 OAuth 오류 코드의 모양(`invalid_grant` 등 — RFC 6749 §5.2 · IANA 레지스트리 · Keycloak 의
#: 코드가 전부 이렇다). `carried_code` 가 쓴다.
_OAUTH_ERROR_CODE = re.compile(r"[a-z_]{1,64}")
#: A-Z 만 a-z 로, 나머지 글자는 그대로 — 아홉 언어가 같은 답을 낸다(유니코드 소문자 `str.lower` 는
#: U+212A KELVIN SIGN 을 `k` 로 바꾼다). `carried_code` 가 비밀마다 이것으로 접는다.
_ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)
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


def oauth_error(exc: BaseException) -> object:
    """오류 응답 JSON 의 `error` 값 그대로(best-effort) — 본문이 JSON 객체가 아니면 `None`.
    무엇을 싣는지는 `carried_code` 가 정한다."""
    body = getattr(exc, "response_body", None)
    if not body:
        return None
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    return data.get("error")


def carried_code(value: object, sent: Iterable[str | None]) -> str | None:
    """`KeycloakAuthError.error` 와 메시지가 싣는 OAuth 코드 — 문자열이고 `[a-z_]{1,64}` 이며 그
    요청이 보낸 비어 있지 않은 비밀 어느 것과도 겹치지 않을 때(어느 쪽도 다른 쪽을 품지 않을 때 —
    ASCII 대소문자는 무시한다)만.

    ⚠️ `error` 도 응답 본문이다 — 보낸 것을 되울리는 IdP(나 그 앞의 프록시)는 client secret ·
    refresh token · introspect 한 토큰을 거기 싣는다. 예전에는 값이 무엇이든 `str()` 해 필드에
    실었다(Keycloak 모양 시크릿 · JWT 가 `vars(e)` 에, 소문자뿐인 시크릿은 메시지와 traceback 에도
    — 실측, 등록부 `token-error-code-secret-echo`). 겹침은 잘린 · 덧붙은 되울림도 막는다. 그 값:
    비밀이 등록 코드의 조각이면(`client`) 그 코드를 잃는다 — 상태는 메시지에 남고 새는 것은 없다.
    빈 비밀(공개 클라이언트)은 비교하지 않는다 — 빈 문자열은 모든 코드의 조각이다.
    """
    if not isinstance(value, str) or _OAUTH_ERROR_CODE.fullmatch(value) is None:
        return None
    if any(_overlaps(value, secret) for secret in sent):
        return None
    return value


def _overlaps(value: str, secret: str | None) -> bool:
    """`secret` 가 비어 있지 않고, ASCII 로 접은 그것과 `value` 중 하나가 다른 하나를 품는다."""
    if not secret:
        return False
    folded = secret.translate(_ASCII_LOWER)
    return folded in value or value in folded


def refused_body(exc: BaseException) -> KeycloakAuthError | KeycloakTransportError | None:
    """`exc` 가 이 SDK 의 응답 본문 거부(`token_cap.py`)를 감싼 python-keycloak 실패면, 같은
    메시지의 SDK 오류를 **새로** 만든다 — 아니면 `None`. 다 읽지 않은 응답(`incomplete` — 상한을
    넘은 본문 · 2xx 토큰 응답의 잘린 압축)은 `KeycloakTransportError`(아홉 언어의 규칙 — 등록부
    token-response-class-divergent · residue · 1.0.7 까지는 `KeycloakAuthError`), 끝까지 온 응답을
    쓸 수 없다는 거부(두 번 압축 — 본문을 읽기 전 · 풀 수 없는 압축 · 2xx 본문이 UTF-8 JSON 텍스트가
    아니거나 짝 없는 서로게이트 이스케이프를 품음)는 `KeycloakAuthError`.

    ⚠️ 그 거부는 세션 안에서 나므로 python-keycloak 의 `raw_*` 가 무엇이든
    `KeycloakConnectionError("Can't connect to server")` 로 감싼다. 그대로 두면 상한에 걸린 응답이
    연결 실패로 보고된다. 신호 자체는 원인으로 달지 않는다 — python-keycloak 프레임(보낼 폼)을
    지나왔다."""
    signal = exc.__cause__
    if not isinstance(signal, ResponseRefused):
        return None
    if signal.incomplete:
        return KeycloakTransportError(str(signal))
    return KeycloakAuthError(str(signal))


def auth_failure(
    exc: BaseException,
    *,
    carry_code: bool = True,
    sent: Iterable[str | None] = (),
    answered: Answered | None = None,
) -> KeycloakAuthError | KeycloakTransportError:
    """auth 경계의 분류 — HTTP 응답을 받았으면 `KeycloakAuthError`, 못 받았으면 전송 오류.

    응답을 받았지만 python-keycloak 이 쓸 수 없다고 던진 실패(`TypeError` 등)도 응답을 받은
    쪽이다 — `TokenSet.from_response` 가 쓸 수 없는 토큰 JSON 을 `KeycloakAuthError` 로 내는 것과
    같은 자리다(`unusable_answer` — 그 응답이 2xx 가 아니었으면 그 상태로 판정한다). 응답 본문이
    상한을 넘은 것은 다 읽지 않은 응답이라 전송 쪽이다(`refused_body`).
    OAuth 코드는 `carried_code` 가 허락한 것만 메시지와 `error` 에 함께 싣는다 — `sent` 는 그
    요청이 보낸 비밀 값이다. `carry_code` 가 거짓이면 둘 다 싣지 않는다(`grant_failure` 는 `error`
    만 따로 채운다)."""
    refused = refused_body(exc)
    if refused is not None:
        return refused
    if isinstance(exc, KeycloakError):
        status = exc.response_code
        if status is None:
            # 응답을 못 받았다 — 실을 본문이 없으므로 상류 메시지(연결 실패 사유)를 그대로 둔다.
            return KeycloakTransportError(str(exc))
        return oauth_failure(status, oauth_error(exc) if carry_code else None, sent)
    return unusable_answer(exc, answered)


def oauth_failure(
    status: int | None, value: object, sent: Iterable[str | None]
) -> KeycloakAuthError:
    """IdP 가 OAuth `error` 를 실어 거부한 응답의 판정 — 한 모양이다: `Keycloak request failed:
    HTTP <상태> (<코드>)`, 코드는 `carried_code` 가 허락한 것만(아니면 상태만). 오류 상태의 응답
    (`auth_failure`)과 성공 상태인데 `error` 를 실은 응답(`error_in_success`)이 함께 쓴다.

    `value` 가 `None` 이면 코드를 싣지 않는다(admin 자체 그랜트의 메시지 — `grant_failure`). 상태가 없으면
    (목처럼 세션을 지나지 않은 응답 — 상태는 세션이 적는다, `token_cap.Answered`) 상태를 지어내지
    않고 뺀다."""
    code = carried_code(value, sent)
    shown = "" if code is None else f" ({code})"
    http = "" if status is None else f": HTTP {status}"
    return KeycloakAuthError(f"Keycloak request failed{http}{shown}", error=code)


def error_in_success(
    answer: object,
    answered: Answered,
    *,
    sent: Iterable[str | None] = (),
    carry_code: bool = True,
) -> KeycloakAuthError | None:
    """python-keycloak 이 성공으로 받은 응답(그 레인이 받는 2xx)이 OAuth `error` 를 실었으면 그
    거부다 — 4xx 가 같은 `error` 를 실었을 때와 같은 판정(`oauth_failure`)이고, 아니면 `None`.

    ⚠️ 그 응답의 나머지(`access_token` · `refresh_token` · `id_token` · `active`)는 쓰지 않는다 —
    호출자는 이것을 응답의 **어떤** 검사보다 먼저 부른다. 예전에는 토큰이 있으면 받아들여
    돌려주고(admin 은 그것으로 요청을 보냈다), introspection 은 활성으로 읽었고, 토큰이 없으면 코드
    없는 「없음」 판정이었다(등록부 auth-2xx-error-code-divergent · 실측 2026-11-20 — .NET 은 이미
    실패했다). `error` 가 비어 있지 않은 문자열이 아니면(숫자 · 객체 · `""` · null) 예전 그대로다.
    `sent` 와 `carry_code` 는 그 레인의 오류 상태 판정이 쓰는 것 그대로다(`auth_failure`)."""
    if not isinstance(answer, dict):
        return None
    value = answer.get("error")
    if not isinstance(value, str) or not value:
        return None
    return oauth_failure(answered.status, value if carry_code else None, sent)


def unusable_answer(exc: BaseException, answered: Answered | None) -> KeycloakAuthError:
    """python-keycloak 이 끝까지 온 응답을 쓸 수 없다고 던진 실패(비-`KeycloakError`)의 판정.

    그 호출이 마지막으로 받은 응답(`answered`, `token_cap.py`)이 2xx 가 아니면 그 상태다 —
    `Keycloak request failed: HTTP <상태>`, 코드는 싣지 않는다(본문이 객체가 아니다).
    python-keycloak 이 2xx 가 아닌 응답에서 깨지는 자리는 오류 본문의 `["message"]` 하나다 —
    JSON 이 객체가 아니면 `TypeError`, 깊은 중첩이면 `RecursionError`(등록부
    python-auth-error-body-shape-status — 예전에는 상태 없는 `unusable_response` 였다).
    2xx 를 못 쓴 것은 `unusable_response` 그대로다."""
    status = None if answered is None else answered.status
    if status is not None and status >= 300:
        return KeycloakAuthError(f"Keycloak request failed: HTTP {status}")
    return unusable_response(exc)


def unusable_response(exc: BaseException) -> KeycloakAuthError:
    """응답은 받았는데 python-keycloak 이 그것을 쓸 수 없다고 던진 실패(본문을 인용한
    `TypeError` 등) — 타입 이름만 싣는다. auth 경계와 admin 자체 그랜트(`admin_grant.py`)가
    함께 쓴다."""
    return KeycloakAuthError(f"Keycloak returned an unusable response ({type(exc).__name__})")


def grant_failure(
    exc: BaseException, code: str | None
) -> KeycloakAuthError | KeycloakTransportError:
    """admin **자체** 토큰 그랜트의 실패 — auth 레인과 같은 판정이다(`auth_failure` · 등록부
    token-response-class-divergent D4). 끝까지 온 응답이면 상태가 무엇이든
    `KeycloakAuthError` 다 — 예전에는 그 상태로 admin 형을 골라 토큰 엔드포인트의 404 가
    `KeycloakNotFoundError` 였고, 토큰을 받지 못한 `users.delete` 가 admin 요청 0 번에
    「이미 없음」으로 읽혔다(실측 2026-11-10 · go #952 와 같은 위험).

    OAuth 코드는 `error` 에 auth 레인처럼 싣는다 — `code` 는 그 그랜트가 보낸 비밀(`client_secret`
    · 갱신이면 refresh token)에 대어 `carried_code` 가 허락한 것이다(`admin_grant._failed` — 경계는
    비밀을 모른다 · 등록부 oauth-error-code-surface-divergent: 예전에는 오류 상태에서 싣지 않았다).
    IdP 는 그 비밀을 `error` 자리에 되울릴 수 있고 소문자뿐인 비밀은 코드 모양이라 겹침이 막는다
    (`tests/unit/test_admin_grant_echo.py` · `test_oauth_error_code_echo.py`). 메시지는 예전대로
    상태뿐이다."""
    failure = auth_failure(exc, carry_code=False)
    if isinstance(failure, KeycloakAuthError):
        failure.error = code
    return failure
