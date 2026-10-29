"""Keycloak SDK for Python — public API entry point.

The public surface of the facade layer that wraps `python-keycloak`
(`KeycloakOpenID`/`KeycloakAdmin`). `keycloak.*` (python-keycloak) types are not re-exported
here — exceptions are converted to SDK exceptions at the boundary (`exceptions.py`), and
request/response payloads pass through as plain `dict[str, Any]`.
"""

from __future__ import annotations

from importlib import metadata as _metadata

from ._internal.secrets import mask
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
    TokenKeyError,
    TokenSignatureError,
    TokenValidationError,
)
from .tokens import IntrospectionResult, TokenSet, ValidatedToken


def _detect_version() -> str:
    # 배포 메타데이터가 유일한 버전 소스다(pyproject.toml [project].version에서 유래).
    # 한때 여기 하드코딩된 "0.1.0"이 pyproject의 0.1.0rc1 범프를 따라가지 못해 게시된
    # 휠이 자신을 잘못된 버전으로 보고했다 — 파생은 그 드리프트 부류를 제거한다.
    # 폴백은 미설치 소스트리 임포트에서만 쓰인다(PEP 440 로컬 버전으로 식별 가능하게).
    try:
        return _metadata.version("keycloak-sdk")
    except _metadata.PackageNotFoundError:
        return "0.0.0+source"


__version__ = _detect_version()

__all__ = [
    "IntrospectionResult",
    "KeycloakAdminError",
    "KeycloakAuthError",
    "KeycloakClient",
    "KeycloakConfig",
    "KeycloakConfigError",
    "KeycloakConflictError",
    "KeycloakForbiddenError",
    "KeycloakNotFoundError",
    "KeycloakSdkError",
    "KeycloakTransportError",
    "TokenKeyError",
    "TokenSet",
    "TokenSignatureError",
    "TokenValidationError",
    "ValidatedToken",
    "__version__",
    # 시크릿 마스킹 유틸 — Java `Secrets.mask`가 공개 API인 것과 동형(§4). 예제·문서가
    # `keycloak_sdk._internal.secrets`를 직접 임포트하도록 가르치던 것을 대체한다.
    "mask",
]
