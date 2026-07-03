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
    """서명/알고리즘/키 결정(kid) 실패에 한정된 하위 타입.

    클레임(issuer/audience/exp/nbf) 검증 실패와 구분하기 위해 존재한다 — 키 회전으로
    캐시된 JWKS에 없는 kid가 도착한 경우가 대표적이며, 호출자(`AuthClient`)가 이
    타입만 근거로 JWKS를 재조회·재시도할 수 있게 한다. 클레임 실패까지 재조회를
    트리거하면 무효 토큰 하나마다 `certs()` 호출이 발생해 남용될 수 있다."""


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
