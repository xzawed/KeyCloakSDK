"""Keycloak SDK for Python — 공개 API 진입점.

`python-keycloak`(`KeycloakOpenID`/`KeycloakAdmin`)을 감싼 파사드 계층의 공개
표면이다. `keycloak.*`(python-keycloak) 타입은 여기서 재노출하지 않는다 — 예외는
경계에서 SDK 예외로 변환되고(`exceptions.py`), 요청/응답 페이로드는 plain
`dict[str, Any]`로 통과한다.
"""
from __future__ import annotations

from .client import KeycloakClient
from .config import KeycloakConfig
from .exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConfigError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakSdkError,
    KeycloakTransportError,
    TokenValidationError,
)
from .tokens import IntrospectionResult, TokenSet, ValidatedToken

__version__ = "0.1.0"

__all__ = [
    "__version__",
    "KeycloakClient",
    "KeycloakConfig",
    "TokenSet",
    "ValidatedToken",
    "IntrospectionResult",
    "KeycloakSdkError",
    "KeycloakConfigError",
    "KeycloakAuthError",
    "TokenValidationError",
    "KeycloakAdminError",
    "KeycloakNotFoundError",
    "KeycloakConflictError",
    "KeycloakForbiddenError",
    "KeycloakTransportError",
]
