"""AsyncAuthClient — python-keycloak `KeycloakOpenID`의 `a_*` 비동기 메서드 래핑.

sync `keycloak_sdk.auth.AuthClient`의 async 미러다. 값 타입(`TokenSet`/`ValidatedToken`/
`IntrospectionResult`)·`AuthorizationUrl`·PKCE 생성(`_generate_pkce_pair`)·예외·
`JwtValidator`(sync 검증 로직)는 sync `keycloak_sdk`에서 그대로 재사용한다(중복 금지).

공개 API에 `keycloak.exceptions.*`(python-keycloak) 타입을 노출하지 않는다 — 경계
(`_awrap`)에서 SDK 예외로 변환한다. 네트워크 경계라 커버리지 게이트에서 제외된다
(pyproject `[tool.coverage.run].omit`); `test_auth.py`가 목 기반으로 행동을 증명한다.
"""
from __future__ import annotations

import json
import secrets
import time
from collections.abc import Awaitable
from typing import Any, TypeVar, cast
from urllib.parse import urlencode

from joserfc.jwk import KeySet, KeySetSerialization
from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakError

from ..auth import AuthorizationUrl, _generate_pkce_pair
from ..config import KeycloakConfig
from ..exceptions import KeycloakAuthError, KeycloakTransportError, TokenSignatureError
from ..jwt import JwtValidator
from ..oidc import OidcEndpoints
from ..tokens import IntrospectionResult, TokenSet, ValidatedToken

T = TypeVar("T")


class AsyncAuthClient:
    """`KeycloakOpenID`의 `a_*` 메서드를 감싼 async 인증 파사드.

    `openid`는 테스트 주입용(미지정 시 config로부터 생성). sync `AuthClient`와 동일한
    메서드명·값타입·예외를 갖되, `authorization_url`만 네트워크가 필요 없어 동기
    메서드로 남아 있다(나머지는 `async def`).
    """

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
            timeout=int(config.read_timeout),
        )
        self._jwks_cache: KeySet | None = None

    async def _awrap(self, awaitable: Awaitable[T]) -> T:
        """python-keycloak `a_*` 호출을 await하고 `KeycloakError`를 SDK 예외로 변환한다.

        sync `AuthClient._wrap`과 동일한 규칙: `response_code`가 있으면 인증/토큰 흐름
        실패로 간주해 `KeycloakAuthError`로, 없으면 `KeycloakTransportError`로 변환한다.
        """
        try:
            return await awaitable
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

    def authorization_url(self, redirect_uri: str) -> AuthorizationUrl:
        """PKCE(S256) 인가 코드 흐름의 시작 URL을 만든다.

        ⚠️ sync는 `openid.auth_url()`을 쓰지만, python-keycloak의 `auth_url`/`a_auth_url`
        모두 첫 호출 시 `well_known()`(서버 discovery 문서)을 지연 로드할 수 있어 async
        이벤트 루프를 블로킹할 위험이 있다. 이 메서드는 네트워크 없이 `OidcEndpoints`에서
        URL을 직접 조립한다 — 그래서 sync와 달리 `async def`가 아니다.
        """
        code_verifier, code_challenge = _generate_pkce_pair()
        state = secrets.token_urlsafe(16)
        nonce = secrets.token_urlsafe(16)
        params = urlencode({
            "response_type": "code",
            "client_id": self._config.client_id,
            "redirect_uri": redirect_uri,
            "scope": " ".join(self._config.scopes),
            "state": state,
            "nonce": nonce,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        })
        url = f"{self._endpoints.authorization}?{params}"
        return AuthorizationUrl(url=url, code_verifier=code_verifier, state=state, nonce=nonce)

    async def client_credentials_token(self) -> TokenSet:
        """`client_credentials` grant로 서비스 계정 토큰을 발급받는다."""
        issued = time.time()
        response = await self._awrap(
            self._openid.a_token(
                grant_type="client_credentials",
                scope=" ".join(self._config.scopes),
            )
        )
        return TokenSet.from_response(response, issued_at=issued)

    async def exchange_code(self, code: str, redirect_uri: str, code_verifier: str) -> TokenSet:
        """인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` grant)."""
        issued = time.time()
        response = await self._awrap(
            self._openid.a_token(
                grant_type="authorization_code",
                code=code,
                redirect_uri=redirect_uri,
                code_verifier=code_verifier,
            )
        )
        return TokenSet.from_response(response, issued_at=issued)

    async def refresh(self, refresh_token: str) -> TokenSet:
        """`refresh_token` grant로 접근 토큰을 갱신한다."""
        issued = time.time()
        response = await self._awrap(self._openid.a_refresh_token(refresh_token))
        return TokenSet.from_response(response, issued_at=issued)

    async def logout(self, refresh_token: str) -> None:
        """세션을 무효화한다(refresh token revoke)."""
        await self._awrap(self._openid.a_logout(refresh_token))

    async def introspect(self, token: str) -> IntrospectionResult:
        """RFC 7662 토큰 인트로스펙션. 비활성 토큰은 `active` 외 필드가 생략될 수 있다."""
        response = await self._awrap(self._openid.a_introspect(token))
        return IntrospectionResult(
            active=bool(response.get("active", False)),
            username=response.get("username"),
            client_id=response.get("client_id"),
        )

    async def validate(self, access_token: str) -> ValidatedToken:
        """realm JWKS로 서명을 검증하고 issuer/audience/exp/nbf를 강제한다(sync `JwtValidator`).

        JWKS는 첫 호출 시 `openid.a_certs()`로 로드해 인스턴스에 캐시한다. 키 회전
        복원력은 sync `AuthClient.validate`와 동일하다 — 서명 검증이
        `TokenSignatureError`로 실패하면 캐시를 무효화하고 `a_certs()`를 한 번
        재조회해 재시도한다.
        """
        key_set = await self._load_jwks()
        validator = JwtValidator(
            issuer=self._endpoints.issuer,
            audience=self._config.client_id,
            clock_skew=self._config.clock_skew,
        )
        try:
            return validator.validate(access_token, key_set)
        except TokenSignatureError:
            key_set = await self._load_jwks(force=True)
            return validator.validate(access_token, key_set)

    async def _load_jwks(self, *, force: bool = False) -> KeySet:
        if force or self._jwks_cache is None:
            certs = await self._awrap(self._openid.a_certs())
            certs_typed = cast(KeySetSerialization, cast(Any, certs))
            self._jwks_cache = KeySet.import_key_set(certs_typed)
        return self._jwks_cache
