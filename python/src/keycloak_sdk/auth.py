"""AuthClient — python-keycloak `KeycloakOpenID`를 감싼 인증(OIDC) 파사드.

공개 API에 `keycloak.exceptions.*`(python-keycloak) 타입을 노출하지 않는다 — 경계
(`_wrap`)에서 SDK 예외로 변환한다. 네트워크 경계라 커버리지 게이트에서 제외된다
(pyproject `[tool.coverage.run].omit`); `test_auth.py`가 목 기반으로 행동을 증명한다.
"""
from __future__ import annotations

import base64
import hashlib
import json
import secrets
import time
from dataclasses import dataclass
from typing import Callable, TypeVar, cast

from joserfc.jwk import KeySet, KeySetSerialization
from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakError

from .config import KeycloakConfig
from .exceptions import KeycloakAuthError, KeycloakTransportError
from .jwt import JwtValidator
from .oidc import OidcEndpoints
from .tokens import IntrospectionResult, TokenSet, ValidatedToken

T = TypeVar("T")


@dataclass(frozen=True)
class AuthorizationUrl:
    """PKCE 인가 코드 흐름 시작에 필요한 값 묶음. `code_verifier`는 `exchange_code`에
    전달할 때까지 호출자(세션)가 보관해야 한다 — SDK는 상태를 갖지 않는다."""

    url: str
    code_verifier: str
    state: str
    nonce: str


def _generate_pkce_pair() -> tuple[str, str]:
    """RFC 7636 S256 PKCE verifier/challenge 쌍을 stdlib만으로 생성한다.

    python-keycloak의 pkce 유틸에 의존하지 않는다(WBS 3.3 명시 요구) — verifier는
    `secrets.token_bytes(32)`를 base64url(패딩 제거) 인코딩, challenge는 verifier의
    ASCII 바이트에 대한 SHA-256을 동일하게 base64url 인코딩한다.
    """
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


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
        self._jwks_cache: KeySet | None = None

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

    def client_credentials_token(self) -> TokenSet:
        """`client_credentials` grant로 서비스 계정 토큰을 발급받는다."""
        response = self._wrap(lambda: self._openid.token(grant_type="client_credentials"))
        return TokenSet.from_response(response, issued_at=time.time())

    def authorization_url(self, redirect_uri: str) -> AuthorizationUrl:
        """PKCE(S256) 인가 코드 흐름의 시작 URL을 만든다.

        `code_verifier`는 이후 `exchange_code`에 전달돼야 하므로 호출자가 세션에
        보관한다(SDK는 무상태). `state`/`nonce`는 CSRF/재생 공격 방어용 난수.
        """
        code_verifier, code_challenge = _generate_pkce_pair()
        state = secrets.token_urlsafe(16)
        nonce = secrets.token_urlsafe(16)
        url = self._wrap(
            lambda: self._openid.auth_url(
                redirect_uri,
                scope=" ".join(self._config.scopes),
                state=state,
                nonce=nonce,
                code_challenge=code_challenge,
                code_challenge_method="S256",
            )
        )
        return AuthorizationUrl(url=url, code_verifier=code_verifier, state=state, nonce=nonce)

    def exchange_code(self, code: str, redirect_uri: str, code_verifier: str) -> TokenSet:
        """인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` grant)."""
        response = self._wrap(
            lambda: self._openid.token(
                grant_type="authorization_code",
                code=code,
                redirect_uri=redirect_uri,
                code_verifier=code_verifier,
            )
        )
        return TokenSet.from_response(response, issued_at=time.time())

    def refresh(self, refresh_token: str) -> TokenSet:
        """`refresh_token` grant로 접근 토큰을 갱신한다."""
        response = self._wrap(lambda: self._openid.refresh_token(refresh_token))
        return TokenSet.from_response(response, issued_at=time.time())

    def logout(self, refresh_token: str) -> None:
        """세션을 무효화한다(refresh token revoke)."""
        self._wrap(lambda: self._openid.logout(refresh_token))

    def introspect(self, token: str) -> IntrospectionResult:
        """RFC 7662 토큰 인트로스펙션. 비활성 토큰은 `active` 외 필드가 생략될 수 있다."""
        response = self._wrap(lambda: self._openid.introspect(token))
        return IntrospectionResult(
            active=bool(response.get("active", False)),
            username=response.get("username"),
            client_id=response.get("client_id"),
        )

    def validate(self, access_token: str) -> ValidatedToken:
        """realm JWKS로 서명을 검증하고 issuer/audience/exp/nbf를 강제한다(`JwtValidator`).

        JWKS는 첫 호출 시 `openid.certs()`로 로드해 인스턴스에 캐시한다 — 이후 호출은
        네트워크 왕복 없이 캐시된 `KeySet`을 재사용한다.
        """
        key_set = self._load_jwks()
        validator = JwtValidator(
            issuer=self._endpoints.issuer,
            audience=self._config.client_id,
            clock_skew=self._config.clock_skew,
        )
        return validator.validate(access_token, key_set)

    def _load_jwks(self) -> KeySet:
        if self._jwks_cache is None:
            certs = self._wrap(lambda: self._openid.certs())
            # python-keycloak types certs() as a bare `dict`; the realm JWKS endpoint
            # (RFC 7517) always returns `{"keys": [...]}`, matching joserfc's shape.
            self._jwks_cache = KeySet.import_key_set(cast(KeySetSerialization, certs))
        return self._jwks_cache
