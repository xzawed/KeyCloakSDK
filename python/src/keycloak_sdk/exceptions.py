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
