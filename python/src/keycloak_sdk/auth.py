"""AuthClient — python-keycloak `KeycloakOpenID`를 감싼 인증(OIDC) 파사드.

공개 API에 `keycloak.exceptions.*`(python-keycloak) 타입을 노출하지 않는다 — 경계
(`_wrap`)에서 SDK 예외로 변환한다. 네트워크 경계라 커버리지 게이트에서 제외된다
(pyproject `[tool.coverage.run].omit`); `test_auth.py`가 목 기반으로 행동을 증명한다.
"""
from __future__ import annotations

import json
from typing import Callable, TypeVar

from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakError

from .config import KeycloakConfig
from .exceptions import KeycloakAuthError, KeycloakTransportError
from .oidc import OidcEndpoints

T = TypeVar("T")


class AuthClient:
    """`KeycloakOpenID` 래핑. `openid`는 테스트 주입용(미지정 시 config로부터 생성)."""

    def __init__(
        self,
        config: KeycloakConfig,
        endpoints: OidcEndpoints,
        openid: KeycloakOpenID | None = None,
    ) -> None:
        self._config = config
        self._endpoints = endpoints
        self._openid = openid if openid is not None else KeycloakOpenID(
            server_url=config.server_url,
            realm_name=config.realm,
            client_id=config.client_id,
            client_secret_key=config.client_secret,
            verify=True,
        )

    def _wrap(self, fn: Callable[[], T]) -> T:
        """python-keycloak 호출을 실행하고 `KeycloakError`를 SDK 예외로 변환한다.

        `response_code`가 있으면(HTTP 응답을 받았으나 실패) 인증/토큰 흐름 실패로
        간주해 `KeycloakAuthError`로, 없으면(네트워크/전송 계층 실패) `KeycloakTransportError`로
        변환한다. OAuth `error` 코드는 response_body(JSON)에서 best-effort로 추출한다.
        """
        try:
            return fn()
        except KeycloakError as exc:
            status = getattr(exc, "response_code", None)
            if status is None:
                raise KeycloakTransportError(str(exc)) from exc
            raise KeycloakAuthError(str(exc), error=self._extract_oauth_error(exc)) from exc

    @staticmethod
    def _extract_oauth_error(exc: KeycloakError) -> str | None:
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
