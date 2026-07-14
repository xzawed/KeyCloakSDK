"""AsyncAuthClient — python-keycloak `KeycloakOpenID`의 `a_*` 비동기 메서드 래핑.

sync `keycloak_sdk.auth.AuthClient`의 async 미러다. 값 타입(`TokenSet`/`ValidatedToken`/
`IntrospectionResult`)·`AuthorizationUrl`·PKCE 생성(`_generate_pkce_pair`)·예외·
`JwtValidator`(sync 검증 로직)는 sync `keycloak_sdk`에서 그대로 재사용한다(중복 금지).

공개 API에 `keycloak.exceptions.*`(python-keycloak) 타입을 노출하지 않는다 — 경계
(`_awrap`)에서 SDK 예외로 변환한다. 네트워크 경계라 커버리지 게이트에서 제외된다
(pyproject `[tool.coverage.run].omit`); `test_auth.py`가 목 기반으로 행동을 증명한다.
"""

from __future__ import annotations

import asyncio
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
from ..exceptions import (
    KeycloakAuthError,
    KeycloakTransportError,
    TokenKeyError,
    TokenValidationError,
)
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
        self._openid = (
            openid
            if openid is not None
            else KeycloakOpenID(
                server_url=config.server_url,
                realm_name=config.realm,
                client_id=config.client_id,
                client_secret_key=config.client_secret,
                verify=True,
                # python-keycloak timeout은 정수 초(int) — sub-second 0-붕괴 방지.
                timeout=max(1, round(config.read_timeout)),
            )
        )
        self._jwks_cache: KeySet | None = None
        self._jwks_lock = asyncio.Lock()
        self._jwks_forced_at = float("-inf")  # 마지막 강제 재조회 시각(monotonic)
        self._jwks_min_refetch = 60.0  # 강제 재조회 최소 간격(초) — DoS 증폭 상한

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

        sync는 `openid.auth_url()`을 쓰지만, python-keycloak의 `auth_url`/`a_auth_url`
        모두 첫 호출 시 `well_known()`(서버 discovery 문서)을 지연 로드할 수 있다
        (`a_auth_url`은 정상적으로 await하므로 이벤트 루프를 블로킹하지는 않는다 — 문제는
        불필요한 discovery 네트워크 왕복 1회가 추가된다는 점이다). 이 메서드는 네트워크
        없이 `OidcEndpoints`에서 URL을 직접 조립해 그 왕복을 없앤다 — 그래서 sync와 달리
        `async def`가 아니다.
        """
        code_verifier, code_challenge = _generate_pkce_pair()
        state = secrets.token_urlsafe(16)
        nonce = secrets.token_urlsafe(16)
        params = urlencode(
            {
                "response_type": "code",
                "client_id": self._config.client_id,
                "redirect_uri": redirect_uri,
                "scope": " ".join(self._config.scopes),
                "state": state,
                "nonce": nonce,
                "code_challenge": code_challenge,
                "code_challenge_method": "S256",
            }
        )
        url = f"{self._endpoints.authorization}?{params}"
        return AuthorizationUrl(url=url, code_verifier=code_verifier, state=state, nonce=nonce)

    async def client_credentials_token(self) -> TokenSet:
        """`client_credentials` grant로 서비스 계정 토큰을 발급받는다."""
        response = await self._awrap(
            self._openid.a_token(
                grant_type="client_credentials",
                scope=" ".join(self._config.scopes),
            )
        )
        return TokenSet.from_response(response, issued_at=time.time())

    async def exchange_code(
        self, code: str, redirect_uri: str, code_verifier: str, nonce: str | None = None
    ) -> TokenSet:
        """인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` grant).

        `nonce`가 주어지면(create_authorization_request가 돌려준 값) 응답 id_token을 강화
        `JwtValidator`로 서명·iss·aud·exp까지 검증한 뒤 nonce 클레임을 대조한다 — OIDC nonce
        재생 방지(sync `AuthClient.exchange_code` 동형). 불일치·부재·검증실패는 거부(fail-closed).
        """
        response = await self._awrap(
            self._openid.a_token(
                grant_type="authorization_code",
                code=code,
                redirect_uri=redirect_uri,
                code_verifier=code_verifier,
            )
        )
        token_set = TokenSet.from_response(response, issued_at=time.time())
        if nonce is not None:
            await self._verify_nonce(token_set.id_token, nonce)
        return token_set

    async def _verify_nonce(self, id_token: str | None, expected_nonce: str) -> None:
        if id_token is None:
            raise KeycloakAuthError(
                "authorization code exchange failed: missing id_token for nonce validation"
            )
        try:
            validated = await self.validate(id_token)
        except TokenValidationError as exc:
            raise KeycloakAuthError("authorization code exchange failed: invalid id_token") from exc
        if validated.claims.get("nonce") != expected_nonce:
            raise KeycloakAuthError("authorization code exchange failed: unexpected nonce")

    async def refresh(self, refresh_token: str) -> TokenSet:
        """`refresh_token` grant로 접근 토큰을 갱신한다."""
        response = await self._awrap(self._openid.a_refresh_token(refresh_token))
        return TokenSet.from_response(response, issued_at=time.time())

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
        복원력은 sync `AuthClient.validate`와 동일하다 — 서명 키(kid) 미해결
        (`TokenKeyError`)에 한해 캐시를 무효화하고 `a_certs()`를 한 번 재조회해
        재시도한다. 단순 서명 위조(`TokenSignatureError`)는 재조회하지 않으며(DoS 증폭
        차단), 재조회는 `_jwks_min_refetch` 간격으로 rate-limit된다.
        """
        key_set = await self._load_jwks()
        validator = JwtValidator(
            issuer=self._endpoints.issuer,
            audience=self._config.client_id,
            allowed_algs=self._config.signature_algorithms,
            clock_skew=self._config.clock_skew,
        )
        try:
            return validator.validate(access_token, key_set)
        except TokenKeyError:
            key_set = await self._load_jwks(force=True)
            return validator.validate(access_token, key_set)

    async def _load_jwks(self, *, force: bool = False) -> KeySet:
        if not force and self._jwks_cache is not None:
            return self._jwks_cache
        async with self._jwks_lock:
            # Double-checked: another concurrent caller may have already populated
            # (or refreshed) the cache while we were waiting on the lock.
            if not force and self._jwks_cache is not None:
                return self._jwks_cache
            if force and self._jwks_cache is not None:
                # rate-limit: 최근 강제 재조회 직후면 재사용 — kid 변조 위조 토큰의
                # a_certs() 폭주 차단(정상 회전은 간격 경과 후 복원).
                now = time.monotonic()
                if now - self._jwks_forced_at < self._jwks_min_refetch:
                    return self._jwks_cache
                self._jwks_forced_at = now
            certs = await self._awrap(self._openid.a_certs())
            certs_typed = cast(KeySetSerialization, cast(Any, certs))
            self._jwks_cache = KeySet.import_key_set(certs_typed)
        return self._jwks_cache

    async def aclose(self) -> None:
        """하위 `KeycloakOpenID`의 async httpx 클라이언트(및 sync 세션)를 닫는다.

        python-keycloak `ConnectionManager.aclose()`가 `httpx.AsyncClient`와 requests
        세션을 함께 정리한다 — 미해제 시 async 소켓/FD가 누수돼 장기 서비스에서
        EMFILE에 이를 수 있다. 내부 구조 변경에도 안전하도록 가드한다.
        """
        conn = getattr(self._openid, "connection", None)
        aclose = getattr(conn, "aclose", None) if conn is not None else None
        if callable(aclose):
            await aclose()
