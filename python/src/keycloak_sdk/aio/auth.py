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
import secrets
import time
from collections.abc import Awaitable
from typing import Any, TypeVar, cast
from urllib.parse import urlencode

from joserfc.jwk import KeySet, KeySetSerialization
from keycloak import KeycloakOpenID

from .._internal.backoff import JwksFailureBackoff
from .._internal.frames import ascrub_frames, scrub_frames
from .._internal.jwks_fetch import afetch_jwks
from .._internal.jwt import JwtValidator
from .._internal.lower import auth_failure, is_lower_failure, summarize
from .._internal.redirects import harden_openid
from .._internal.token_cap import cap_openid
from ..auth import AuthorizationUrl, _generate_pkce_pair
from ..config import KeycloakConfig
from ..exceptions import (
    KeycloakAuthError,
    KeycloakTransportError,
    TokenKeyError,
    TokenValidationError,
)
from ..oidc import OidcEndpoints
from ..tokens import IntrospectionResult, TokenSet, ValidatedToken, _introspection_result

T = TypeVar("T")


class AsyncAuthClient:
    """`KeycloakOpenID`의 `a_*` 메서드를 감싼 async 인증 파사드.

    `openid`는 테스트 주입용(미지정 시 config로부터 생성). sync `AuthClient`와 동일한
    메서드명·값타입·예외를 갖되, `authorization_url`만 네트워크가 필요 없어 동기
    메서드로 남아 있다(나머지는 `async def`).
    """

    # ⚠️ sync 미러와 같다 — 비밀을 다루는 공개 진입점은 전부 `@scrub_frames`/`@ascrub_frames` 다
    # (`_internal/frames.py`). 동기인 생성자·`authorization_url` 은 sync 데코레이터를 쓴다.
    @scrub_frames
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
        # async 전송(httpx)은 오늘 안전하지만, 이 객체는 쓰이지 않는 sync requests 세션도
        # 함께 들고 있다. 지금은 어떤 `a_*`도 sync `raw_*`로 내려가지 않음을 확인했으나,
        # 한 줄로 그 경로가 생길 가능성을 미리 닫아둔다(비용 0의 심층방어).
        harden_openid(self._openid)
        # 토큰·introspection 응답 본문은 상한까지만 읽는다 — `async_s` 에서는 푸는 일까지 여기서
        # 한다(`_internal/token_cap.py`).
        cap_openid(self._openid)
        self._jwks_cache: KeySet | None = None
        # 진행 중인 JWKS fetch — 호출자가 아니라 이 인스턴스가 소유한다(`_load_jwks`).
        self._jwks_fetch: asyncio.Task[KeySet] | None = None
        self._jwks_forced_at = float("-inf")  # 마지막 강제 재조회 시각(monotonic)
        # 강제 재조회 최소 간격(초) — DoS 증폭 상한
        self._jwks_min_refetch = config.jwks_min_refetch_seconds
        # 실패한 fetch 의 백오프 — 위 30초와 **다른 축**이다(콜드 캐시 + IdP 장애).
        self._jwks_backoff = JwksFailureBackoff()

    async def _awrap(self, awaitable: Awaitable[T]) -> T:
        """python-keycloak `a_*` 호출을 await하고 그 실패를 SDK 예외로 변환한다.

        sync `AuthClient._wrap`과 동일한 규칙(같은 `_internal/lower.py` 를 쓴다): `response_code`가
        있으면 인증/토큰 흐름 실패로 간주해 `KeycloakAuthError`로, 없으면 `KeycloakTransportError`로
        변환한다. ⚠️ 상류 메시지도 원본 예외도 옮기지 않는다 — 응답 본문을 싣는다.
        """
        try:
            return await awaitable
        except Exception as exc:
            if not is_lower_failure(exc):
                raise
            error, cause = auth_failure(exc), summarize(exc)
        raise error from cause

    @scrub_frames
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

    @ascrub_frames
    async def client_credentials_token(self) -> TokenSet:
        """`client_credentials` grant로 서비스 계정 토큰을 발급받는다."""
        response = await self._awrap(
            self._openid.a_token(
                grant_type="client_credentials",
                scope=" ".join(self._config.scopes),
            )
        )
        return TokenSet.from_response(response, issued_at=time.time())

    @ascrub_frames
    async def exchange_code(
        self, code: str, redirect_uri: str, code_verifier: str, nonce: str | None = None
    ) -> TokenSet:
        """인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` grant).

        `nonce`가 주어지면(authorization_url 이 돌려준 값) 응답 id_token을 강화
        `JwtValidator`로 서명·iss·aud·exp까지 검증한 뒤 nonce 클레임을 대조한다 — OIDC nonce
        재생 방지(sync `AuthClient.exchange_code` 동형). 불일치·부재·검증실패는 거부(fail-closed).
        id_token 의 `aud` 는 `expected_audience` 가 아니라 **`client_id`** 로 잰다(OIDC Core
        §2·§3.1.3.7) — `expected_audience` 는 `validate()` 가 보는 액세스 토큰 전용이다.
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
            validated = await self._validate_for(id_token, self._config.client_id)
        except TokenValidationError as exc:
            raise KeycloakAuthError("authorization code exchange failed: invalid id_token") from exc
        if validated.claims.get("nonce") != expected_nonce:
            raise KeycloakAuthError("authorization code exchange failed: unexpected nonce")

    @ascrub_frames
    async def refresh(self, refresh_token: str) -> TokenSet:
        """`refresh_token` grant로 접근 토큰을 갱신한다."""
        response = await self._awrap(self._openid.a_refresh_token(refresh_token))
        return TokenSet.from_response(response, issued_at=time.time())

    @ascrub_frames
    async def logout(self, refresh_token: str) -> None:
        """세션을 무효화한다(refresh token revoke)."""
        await self._awrap(self._openid.a_logout(refresh_token))

    @ascrub_frames
    async def introspect(self, token: str) -> IntrospectionResult:
        """RFC 7662 토큰 인트로스펙션. 비활성 토큰은 `active` 외 필드가 생략될 수 있다."""
        response = await self._awrap(self._openid.a_introspect(token))
        return _introspection_result(response)

    @ascrub_frames
    async def validate(self, access_token: str) -> ValidatedToken:
        """realm JWKS로 서명을 검증하고 issuer/audience/exp/nbf를 강제한다(sync `JwtValidator`).

        JWKS는 첫 호출 시 `openid.a_certs()`로 로드해 인스턴스에 캐시한다. 키 회전
        복원력은 sync `AuthClient.validate`와 동일하다 — 서명 키(kid) 미해결
        (`TokenKeyError`)에 한해 캐시를 무효화하고 `a_certs()`를 한 번 재조회해
        재시도한다. 단순 서명 위조(`TokenSignatureError`)는 재조회하지 않으며(DoS 증폭
        차단), 재조회는 `_jwks_min_refetch` 간격으로 rate-limit된다. 이 호출을 취소해도(시간
        초과 포함) 이미 시작한 재조회는 끝까지 가서 캐시를 채운다(`_load_jwks`).
        """
        # `expected_audience`가 설정되면 그 값을, 아니면 client_id를 기대한다(sync 동형).
        return await self._validate_for(
            access_token, self._config.expected_audience or self._config.client_id
        )

    async def _validate_for(self, token: str, audience: str) -> ValidatedToken:
        """`validate()` 의 본체(sync `AuthClient._validate_for` 동형) — audience 만 호출자가 정한다.

        ⚠️ JWKS 상태(캐시·강제 재조회 창·백오프)는 이 인스턴스의 `_load_jwks` 하나가 소유한다.
        """
        key_set = await self._load_jwks()
        validator = JwtValidator(
            issuer=self._endpoints.issuer,
            audience=audience,
            allowed_algs=self._config.signature_algorithms,
            clock_skew=self._config.clock_skew,
        )
        try:
            return validator.validate(token, key_set)
        except TokenKeyError:
            key_set = await self._load_jwks(force=True)
            return validator.validate(token, key_set)

    async def _load_jwks(self, *, force: bool = False) -> KeySet:
        """캐시된 키셋, 아니면 fetch 결과. 창·백오프 판정은 sync 미러와 같고 fetch 의 소유만 다르다.

        ⚠️ **fetch 는 호출자가 아니라 이 인스턴스의 태스크다**(`_refetch_jwks`). 호출자가 그것을
        `asyncio.shield` 너머로 기다리므로, 창에 도장을 찍은 뒤 호출자가 취소돼도(시간 초과 포함)
        fetch 는 SDK 의 HTTP 타임아웃 안에서 끝까지 가서 캐시를 채운다. 예전에는 fetch 가 호출자
        안에서 돌아 취소와 함께 버려졌고, 도장은 남아 창 30초 동안 회전한 키의 정상 토큰이
        거부됐다(실측: 요청이 IdP 에 닿기 전·도중 취소 모두). 창 안의 강제 호출자는 낡은 캐시 대신
        진행 중인 그 fetch 를 기다린다. ⚠️ 도장을 되돌리는 것으로 고치지 말 것 — 느린 IdP 앞에서
        시간 초과한 위조 kid 검증마다 IdP 요청이 하나씩 났다(실측 10 대 1). 실패한 fetch 는 여전히
        창을 쓴다.

        자물쇠가 없는 이유: 판정에서 태스크를 만들기까지 `await` 가 없어 다른 코루틴이 끼지 못한다.
        단일 비행(single-flight)은 진행 중인 태스크가 맡는다.
        """
        if not force and self._jwks_cache is not None:
            return self._jwks_cache
        fetch = self._jwks_fetch
        if fetch is None or fetch.done():
            if force and self._jwks_cache is not None:
                # rate-limit: 최근 강제 재조회 직후면 재사용 — kid 변조 위조 토큰의
                # 재조회 폭주 차단(정상 회전은 간격 경과 후 복원).
                now = time.monotonic()
                if now - self._jwks_forced_at < self._jwks_min_refetch:
                    return self._jwks_cache
                self._jwks_forced_at = now
            # ⚠️ sync 미러와 동일 — 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다.
            # 콜드 캐시에서는 위 분기가 통째로 건너뛰어지므로, 이 줄이 없으면 매 검증이 IdP 로
            # 나간다(원래 결함). 상태 기계는 sync 와 **같은 클래스**를 쓴다.
            remaining = self._jwks_backoff.remaining()
            if remaining > 0:
                raise KeycloakTransportError(
                    f"JWKS fetch backing off after {self._jwks_backoff.failures} "
                    f"consecutive failures (retry in {remaining:.2f}s)"
                )
            fetch = asyncio.ensure_future(self._refetch_jwks())
            fetch.add_done_callback(self._refetch_done)
            self._jwks_fetch = fetch
        return await asyncio.shield(fetch)

    async def _refetch_jwks(self) -> KeySet:
        """fetch → 키셋 → 캐시. 이 인스턴스의 태스크로 돈다 — 호출자의 취소가 닿지 않는다."""
        try:
            # 상류 `a_certs()` 와 달리 이 경로는 바이트 상한을 건다
            # (`_internal/jwks_fetch.py`). sync 미러와 **같은 모듈**을 쓴다.
            certs = await self._afetch_jwks()
            certs_typed = cast(KeySetSerialization, cast(Any, certs))
            # ⚠️ sync 미러와 동일 — 기형 JWKS에서 joserfc는 joserfc 타입도 아닌 stdlib
            # `binascii.Error`를 던진다. 그대로 두면 `keycloak_sdk.exceptions`를 잡는
            # 소비자가 아무것도 잡지 못한다(§4 위반). 두 미러가 갈라지지 않도록 같이 고친다.
            try:
                key_set = KeySet.import_key_set(certs_typed)
            except Exception as exc:
                raise TokenValidationError(
                    f"malformed JWKS from the identity provider: {exc}"
                ) from exc
        except Exception:
            self._jwks_backoff.record_failure()
            raise
        self._jwks_cache = key_set
        self._jwks_backoff.record_success()
        return key_set

    def _refetch_done(self, fetch: asyncio.Task[KeySet]) -> None:
        """끝난 fetch 를 놓고 그 실패를 거둔다 — 기다리던 호출자가 다 취소됐으면 아무도 거두지
        않아, asyncio 가 GC 때 「Task exception was never retrieved」를 찍는다."""
        if self._jwks_fetch is fetch:
            self._jwks_fetch = None
        if not fetch.cancelled():
            fetch.exception()

    async def _afetch_jwks(self) -> dict[str, Any]:
        """httpx 클라이언트로 JWKS 를 상한 안에서 가져온다.

        ⚠️ **sync 미러와 세션이 다르다** — 그쪽은 `connection._s`(requests), 여기는
        `connection.async_s`(httpx)다. 리다이렉트 방어도 갈린다(그쪽은 훅, 여기는 httpx
        기본값)이라 `jwks_fetch.afetch_jwks` 가 `follow_redirects=False` 를 명시한다.
        """
        conn = self._openid.connection
        return await afetch_jwks(
            conn.async_s,
            self._endpoints.jwks,
            timeout=getattr(conn, "timeout", None),
        )

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
