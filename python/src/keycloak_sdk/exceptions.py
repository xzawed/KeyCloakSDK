"""SDK 예외 계층. 공개 API에 python-keycloak 예외 타입을 노출하지 않는다."""

from __future__ import annotations


class KeycloakSdkError(Exception):
    """모든 SDK 예외의 기반."""


class KeycloakConfigError(KeycloakSdkError):
    """잘못된 설정."""


class KeycloakAuthError(KeycloakSdkError):
    """인증/토큰 교환 실패. OAuth error 코드 보존."""

    def __init__(self, message: str, error: str | None = None) -> None:
        super().__init__(message)
        self.error = error


class TokenValidationError(KeycloakSdkError):
    """JWT 서명·클레임 검증 실패."""


class TokenSignatureError(TokenValidationError):
    """서명/알고리즘 검증 실패(클레임 실패와 구분되는 상위 타입).

    서명 불일치·미허용 알고리즘·미서명(`none`) 등 **재조회해도 소용없는** 실패를
    가리킨다. 키(kid) 해석 실패만 별도로 하위 타입 `TokenKeyError`로 나뉜다."""


class TokenKeyError(TokenSignatureError):
    """서명 키(kid)를 현재 JWKS에서 해석하지 못함 — 키 회전 가능성.

    `TokenSignatureError`의 하위 타입이라 서명 실패를 포괄로 잡던 기존 소비자는 그대로
    동작한다. `AuthClient`는 **이 타입에 한해서만** JWKS를 재조회·재시도한다 — 단순
    서명 위조(`BadSignatureError` → `TokenSignatureError`)는 재조회해도 소용없고, 위조
    토큰마다 `certs()`를 유발하는 미인증 DoS 증폭이 되므로 재조회하지 않는다. 재조회
    자체도 최소 간격으로 rate-limit되어 kid 변조 공격에 대한 상한이 있다."""


class KeycloakTransportError(KeycloakSdkError):
    """네트워크/전송 오류."""


class KeycloakAdminError(KeycloakSdkError):
    """관리 API 오류. HTTP status + Keycloak error 본문 보존."""

    def __init__(self, status_code: int, keycloak_error: str | None = None) -> None:
        super().__init__(f"Keycloak admin error (HTTP {status_code})")
        self.status_code = status_code
        self.keycloak_error = keycloak_error


class KeycloakNotFoundError(KeycloakAdminError):
    """404."""


class KeycloakConflictError(KeycloakAdminError):
    """409."""


class KeycloakForbiddenError(KeycloakAdminError):
    """403."""
