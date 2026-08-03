"""Keycloak SDK for Python — 공개 API 진입점.

`python-keycloak`(`KeycloakOpenID`/`KeycloakAdmin`)을 감싼 파사드 계층의 공개
표면이다. `keycloak.*`(python-keycloak) 타입은 여기서 재노출하지 않는다 — 예외는
경계에서 SDK 예외로 변환되고(`exceptions.py`), 요청/응답 페이로드는 plain
`dict[str, Any]`로 통과한다.
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
