"""AuthClient — the authentication (OIDC) facade wrapping python-keycloak's `KeycloakOpenID`.

`keycloak.exceptions.*` (python-keycloak) types are not exposed in the public API — they are
converted to SDK exceptions at the boundary (`_wrap`). Being a network boundary, it is excluded
from the coverage gate (pyproject `[tool.coverage.run].omit`); `test_auth.py` proves the
behavior with mocks.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, TypeVar
from urllib.parse import urlencode

from joserfc.jwk import KeySet
from keycloak import KeycloakOpenID

from ._internal.backoff import JwksFailureBackoff
from ._internal.frames import scrub_frames
from ._internal.jwks_cache import JwksKeyCache
from ._internal.jwks_fetch import fetch_jwks
from ._internal.jwks_keys import import_usable_keys
from ._internal.jwt import JwtValidator, TokenKind, check_token_size, refuse_hs_algorithm
from ._internal.lower import auth_failure, is_lower_failure, summarize
from ._internal.redirect_uri import checked_redirect_uri
from ._internal.redirects import harden_openid
from ._internal.retries import forbid_retries
from ._internal.secrets import mask
from ._internal.token_cap import Answered, answering, cap_openid
from ._internal.wire import bound_reads
from .config import KeycloakConfig
from .exceptions import (
    KeycloakAuthError,
    KeycloakTransportError,
    TokenKeyError,
    TokenValidationError,
)
from .oidc import OidcEndpoints
from .tokens import IntrospectionResult, TokenSet, ValidatedToken, _introspection_result

T = TypeVar("T")


@dataclass(frozen=True)
class AuthorizationUrl:
    """The bundle of values needed to start a PKCE authorization-code flow. The caller (session)
    must keep `code_verifier` until it is passed to `exchange_code` — the SDK holds no state."""

    url: str
    code_verifier: str
    state: str
    nonce: str

    def __repr__(self) -> str:
        return (
            f"AuthorizationUrl(url={self.url!r}, "
            f"code_verifier={mask(self.code_verifier)!r}, "
            f"state={self.state!r}, nonce={self.nonce!r})"
        )


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
    """Wraps `KeycloakOpenID`. `openid` is for test injection (when omitted, it is built from
    config)."""

    # ⚠️ 비밀을 다루는 공개 진입점은 전부 `@scrub_frames` 다 — 실패할 때 프레임 로컬(토큰 응답·
    # 인자로 받은 토큰·code·verifier, 하위 생성자가 받은 client secret)이 traceback 으로 오류
    # 수집기에 닿지 않게(`_internal/frames.py`). 생성자·인가 URL 두 자리는 Grok 레그가 찾았다.
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
                # python-keycloak의 timeout은 정수 초(int)다. int()로 자르면
                # sub-second(0.5→0)가 "타임아웃 0"으로 붕괴하므로 round+최소 1초로 가드.
                timeout=max(1, round(config.read_timeout)),
            )
        )
        # 백채널은 3xx를 따라가지 않는다 — 주입된 인스턴스도 동일하게 막는다(주입 경로가
        # 프로덕션 경로보다 느슨해지면 테스트가 증명하는 것이 실제와 달라진다).
        harden_openid(self._openid)
        # 토큰·introspection 응답 본문은 상한까지만 읽는다(`_internal/token_cap.py`).
        cap_openid(self._openid)
        # 처리됐을지 모르는 요청(그랜트·introspect·logout)을 저절로 다시 보내지 않는다 —
        # python-keycloak 의 어댑터는 POST 까지 다시 보낸다(`_internal/retries.py`).
        forbid_retries(self._openid)
        # 응답은 요청 타임아웃 안에, 본문 상한 + 틀 몫까지만 소켓에서 읽는다 — 머리·청크 틀·
        # 트레일러까지 원문 읽기마다 본다(`_internal/wire.py`).
        bound_reads(self._openid)
        self._jwks_keys = JwksKeyCache()  # 읽는 길은 `fresh()` 하나다(`_internal/jwks_cache.py`)
        self._jwks_lock = threading.Lock()
        self._jwks_forced_at = float("-inf")  # 마지막 강제 재조회 시각(monotonic)
        # 강제 재조회 최소 간격(초) — DoS 증폭 상한
        self._jwks_min_refetch = config.jwks_min_refetch_seconds
        # 실패한 fetch 의 백오프 — 위 30초와 **다른 축**이다(콜드 캐시 + IdP 장애).
        self._jwks_backoff = JwksFailureBackoff()

    def _wrap(self, fn: Callable[[], T], *sent: str) -> T:
        """python-keycloak 호출을 실행하고 그 실패를 SDK 예외로 변환한다.

        `response_code`가 있으면(HTTP 응답을 받았으나 실패) 인증/토큰 흐름 실패로
        간주해 `KeycloakAuthError`로, 없으면(네트워크/전송 계층 실패) `KeycloakTransportError`로
        변환한다. OAuth `error` 코드는 response_body(JSON)에서 best-effort로 추출한다 — `sent` 는
        그 요청이 client secret 말고 보낸 비밀 값이다(되울림은 싣지 않는다, `carried_code`).

        ⚠️ **상류 메시지도 원본 예외도 옮기지 않는다** — python-keycloak 은 거기에 응답 본문을
        싣는다(토큰·되돌린 `client_secret`). 규칙과 실측은 `_internal/lower.py`. 원본은 `except`
        **밖에서** 다시 던져 `__context__` 로도 닿지 않게 한다.
        """
        answered = Answered()  # 그 호출이 받은 마지막 응답의 상태(`token_cap.py`)
        try:
            with answering(answered):
                return fn()
        except Exception as exc:
            if not is_lower_failure(exc):
                raise
            error = auth_failure(exc, sent=(self._config.client_secret, *sent), answered=answered)
            cause = summarize(exc)
        raise error from cause

    @scrub_frames
    def client_credentials_token(self) -> TokenSet:
        """Issues a service-account token with the `client_credentials` grant.

        `config.scopes` is passed explicitly — when it is not passed, python-keycloak pins the
        scope to `"openid"`, so configured extra scopes (e.g. a custom audience) are ignored.
        """
        response = self._wrap(
            lambda: self._openid.token(
                grant_type="client_credentials",
                scope=" ".join(self._config.scopes),
            )
        )
        return TokenSet.from_response(response, issued_at=time.time())

    @scrub_frames
    def authorization_url(self, redirect_uri: str) -> AuthorizationUrl:
        """Builds the start URL of a PKCE (S256) authorization-code flow.

        `code_verifier` has to be passed to `exchange_code` later, so the caller keeps it in the
        session (the SDK is stateless). `state`/`nonce` are random values that defend against
        CSRF/replay attacks.

        ⚠️ **It does not delegate to `openid.auth_url()` — that helper does no percent-encoding.**
        python-keycloak 7.1.1's `auth_url` is a single `URL_AUTH.format(...)` line, so it
        concatenates the values as they are (confirmed by running that function directly). As a
        result, the value following a `&` inside `redirect_uri` was **injected as a top-level
        query parameter**, and spaces also stayed raw, so the URL became unusable. On top of
        that, that path took one more `well_known()` discovery round trip. Here the URL is
        assembled directly from `OidcEndpoints`, **isomorphic with** the `aio` mirror — no
        network is needed.

        `redirect_uri` must be an absolute URI (RFC 6749 §3.1.2) without a fragment that
        Keycloak can parse (RFC 3986 §2) — otherwise `KeycloakConfigError` is raised before
        anything is generated. A value that is not a `str` is converted with `str()`, as the
        URL builder always did (a URL object such as Starlette's `request.url_for(...)` works;
        `None` and `bytes` do not); the string checked is the string sent, exactly as given —
        pass the same string to `exchange_code`.
        """
        redirect_uri = checked_redirect_uri(redirect_uri)
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

    @scrub_frames
    def exchange_code(
        self, code: str, redirect_uri: str, code_verifier: str, nonce: str | None = None
    ) -> TokenSet:
        """Exchanges an authorization code + PKCE verifier for tokens (`authorization_code` grant).

        When `nonce` is given (the value authorization_url returned), the response's id_token is
        validated with the hardened `JwtValidator` through signature · iss · aud · exp, and then
        its nonce claim is compared — OIDC nonce replay protection. Mismatch, absence and
        validation failure are all rejected (fail-closed). When it is omitted, id_token
        validation is skipped. The id_token's `aud` is checked against **`client_id`**, not
        `expected_audience` (OIDC Core §2·§3.1.3.7) — `expected_audience` is only for the access
        token that `validate()` checks. Its `azp` must also be `client_id` when present, and must
        be present when `aud` has several values (OIDC Core §3.1.3.7, steps 4 and 5). That
        id_token check is `validate_id_token`'s — the same function, so the payload `typ` must
        also be exactly `"ID"`.
        """
        response = self._wrap(
            lambda: self._openid.token(
                grant_type="authorization_code",
                code=code,
                redirect_uri=redirect_uri,
                code_verifier=code_verifier,
            ),
            code,
            code_verifier,
        )
        token_set = TokenSet.from_response(response, issued_at=time.time())
        if nonce is not None:
            self._verify_nonce(token_set.id_token, nonce)
        return token_set

    def _verify_nonce(self, id_token: str | None, expected_nonce: str) -> None:
        if id_token is None:
            raise KeycloakAuthError(
                "authorization code exchange failed: missing id_token for nonce validation"
            )
        try:
            validated = self._validate_id_token(id_token)
        except TokenValidationError as exc:
            raise KeycloakAuthError("authorization code exchange failed: invalid id_token") from exc
        if validated.claims.get("nonce") != expected_nonce:
            raise KeycloakAuthError("authorization code exchange failed: unexpected nonce")

    @scrub_frames
    def refresh(self, refresh_token: str) -> TokenSet:
        """Renews the access token with the `refresh_token` grant."""
        response = self._wrap(lambda: self._openid.refresh_token(refresh_token), refresh_token)
        return TokenSet.from_response(response, issued_at=time.time())

    @scrub_frames
    def logout(self, refresh_token: str) -> None:
        """Invalidates the session (refresh token revoke)."""
        self._wrap(lambda: self._openid.logout(refresh_token), refresh_token)

    @scrub_frames
    def introspect(self, token: str) -> IntrospectionResult:
        """RFC 7662 token introspection. For an inactive token, fields other than `active` may
        be omitted."""
        response = self._wrap(lambda: self._openid.introspect(token), token)
        return _introspection_result(response)

    @scrub_frames
    def validate(self, access_token: str) -> ValidatedToken:
        """Verifies the signature against the realm JWKS and enforces issuer/audience/exp/nbf
        (`JwtValidator`), then accepts only an access token: the `typ` claim must equal `Bearer` or
        `DPoP` ignoring ASCII case, as Keycloak's own resource-side check does. A missing,
        non-string or other `typ` is refused — another Keycloak token (`ID`, `Refresh`, `Offline`,
        `Logout`, `Serialized-ID`) or a realm-signed JWT without `typ` (a JARM authorization
        response) never passes as an access token.

        The JWKS is loaded on the first call and cached on the instance — calls within 300
        seconds (`JWKS_MAX_AGE_SECONDS`) of receiving it reuse that `KeySet` without a network
        round trip, and later calls fetch it again. If that fetch fails, validation fails too —
        it does not fall back to stale keys.

        Key-rotation resilience: if the signing key (kid) cannot be resolved in the cached JWKS
        (`TokenKeyError`), the cache is invalidated, `certs()` is refetched once, and the
        validation is retried. **A plain forged signature (`TokenSignatureError`) is not
        refetched** — a refetch would not help, and it would become an unauthenticated DoS
        amplification in which every forged token triggers `certs()`. The refetch itself is also
        rate-limited to the `_jwks_min_refetch` interval, so kid-tampering attacks have an upper
        bound. A claim failure (`TokenValidationError`) does not trigger a refetch either.
        """
        # `expected_audience`가 설정되면 그 값을, 아니면 client_id를 기대한다(기존 동작).
        return self._validate_for(
            access_token, self._config.expected_audience or self._config.client_id, kind="access"
        )

    @scrub_frames
    def validate_id_token(self, id_token: str) -> ValidatedToken:
        """Validates an id_token with exactly the check `exchange_code` runs on the id_token before
        it compares the nonce — both call the same function.

        The signature is verified against the realm JWKS through the same key cache `validate()`
        uses (one cache, one forced-refetch window, one backoff), under the
        `signature_algorithms` pin (an HS algorithm is refused even when allowed — a JWKS holds
        public keys only) and the 256,000-byte length cap. `iss` must match exactly, `aud` must
        contain the configured **`client_id`** (not `expected_audience`, which restricts access
        tokens), and `exp` is required, checked with the clock skew. Then the token kind: the
        payload `typ` claim must be exactly the string `"ID"` — a missing, non-string or other
        value is refused. Last, the authorized party (OIDC Core §3.1.3.7, steps 4 and 5): with
        more than one `aud` an `azp` is required, and an `azp` that is present (JSON null
        included) must be `client_id`.

        The nonce is not compared — that stays in `exchange_code`. A failed check raises
        `TokenValidationError` (its `TokenSignatureError` / `TokenKeyError` subtypes for a
        signature or key failure), as `validate()` does.
        """
        return self._validate_id_token(id_token)

    def _validate_id_token(self, id_token: str) -> ValidatedToken:
        """id_token 검사의 한 길 — 공개 `validate_id_token` 과 교환(`_verify_nonce`)이 함께 부른다.
        기대 aud(와 azp 의 기준)는 `expected_audience` 가 아니라 client_id 다
        (OIDC Core §2·§3.1.3.7). 판정 규칙(종류 · azp)은 측정되는 `_internal/jwt.py` 에 있다 —
        이 파일은 커버리지 밖이다."""
        return self._validate_for(id_token, self._config.client_id, kind="id_token")

    def _validate_for(self, token: str, audience: str, *, kind: TokenKind) -> ValidatedToken:
        """`validate()` 의 본체 — 기대 audience 와 토큰 종류만 호출자가 정한다.

        ⚠️ `kind` 는 기본값이 없다 — 두 호출자(access · id_token)가 각자 적는다. access 는 typ
        허용 목록(Bearer · DPoP)을, id_token 은 typ 허용 목록(`ID`)과 azp 를 본다
        (`JwtValidator`). id_token 에 access 의 typ 검사가 걸리면 Keycloak 의 진짜 id_token(`ID`)이
        거부되고, access 에 azp 검사가 걸리면 다른 클라이언트가 받은 정상 access 토큰이 거부된다.

        ⚠️ **JWKS 상태는 여기서 만들지 않는다** — 캐시·30초 강제 재조회 창·콜드 캐시 백오프는
        이 인스턴스의 `_load_jwks` 하나가 소유하고, 두 경로가 그것을 함께 쓴다. `JwtValidator` 는
        키를 들지 않는 규칙 묶음이라 매번 새로 만들어도 저장소가 갈라지지 않는다.

        ⚠️ 길이 상한이 `_load_jwks()` **보다 앞**이다 — 뒤에 두면 콜드 캐시에서 상한 밖
        쓰레기 토큰 하나가 JWKS 요청 하나가 된다(`check_token_size`). 허용된 HS 의 거부도
        그 앞이다 — 키를 찾기 전에 거부한다(`refuse_hs_algorithm`).
        """
        check_token_size(token)
        refuse_hs_algorithm(token, self._config.signature_algorithms)
        key_set = self._load_jwks()
        validator = JwtValidator(
            issuer=self._endpoints.issuer,
            audience=audience,
            allowed_algs=self._config.signature_algorithms,
            clock_skew=self._config.clock_skew,
            kind=kind,
        )
        try:
            return validator.validate(token, key_set)
        except TokenKeyError:
            key_set = self._load_jwks(force=True)
            return validator.validate(token, key_set)

    def _load_jwks(self, *, force: bool = False) -> KeySet:
        cached = self._jwks_keys.fresh()
        if not force and cached is not None:
            return cached
        with self._jwks_lock:
            # Double-check: 다른 스레드가 락 대기 중 이미 (재)로드했을 수 있다.
            cached = self._jwks_keys.fresh()
            if not force and cached is not None:
                return cached
            if force and cached is not None:
                # rate-limit: 최근 강제 재조회 직후면 재사용 — kid를 무작위로 바꾼
                # 위조 토큰이 certs()를 폭주시키는 것을 막는다(정상 회전은 간격 경과
                # 후 복원). 최초 강제 재조회는 항상 허용(_jwks_forced_at=-inf).
                now = time.monotonic()
                if now - self._jwks_forced_at < self._jwks_min_refetch:
                    return cached
                self._jwks_forced_at = now
            # ⚠️ 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다. 콜드 캐시에서는 위
            # 분기가 통째로 건너뛰어지므로, 이 줄이 없으면 매 검증이 IdP 로 나간다(원래 결함).
            remaining = self._jwks_backoff.remaining()
            if remaining > 0:
                raise KeycloakTransportError(
                    f"JWKS fetch backing off after {self._jwks_backoff.failures} "
                    f"consecutive failures (retry in {remaining:.2f}s)"
                )
            try:
                certs = self._fetch_jwks()
                # 상류 `certs()` 와 달리 이 경로는 바이트 상한을 건다(`_internal/jwks_fetch.py`).
                # 반환 모양은 같다 — realm JWKS 엔드포인트(RFC 7517)는 `{"keys": [...]}` 다.
                # ⚠️ 파싱은 `_wrap`이 덮지 않는다 — `_wrap`은 전송 오류용이고 여기는 **응답
                # 내용**이 문제인 경우다. 키를 하나씩 읽어 못 읽는 키는 건너뛰고, 기형·빈 키셋은
                # SDK 타입으로 거부한다(`_internal/jwks_keys.py`). IdP가 기형 JWKS를 주는 것은
                # 가정이 아니다 — 프록시 오구성·부분 배포·중간자가 모두 이 모양이 된다.
                key_set = import_usable_keys(certs)
            except Exception:
                self._jwks_backoff.record_failure()
                raise
            self._jwks_keys.store(key_set)
            self._jwks_backoff.record_success()
        return key_set

    def _fetch_jwks(self) -> dict[str, Any]:
        """하드닝된 세션으로 JWKS 를 상한 안에서 가져온다.

        세션·전송 설정은 상류 `ConnectionManager` 에서 그대로 읽는다 — `raw_get` 이 쓰는
        것과 같은 값이라 TLS 검증·클라이언트 인증서·타임아웃 동작이 갈리지 않는다.
        `connection._s` 의 존재는 생성 시 `harden_openid` 가 이미 강제했다.
        """
        conn = self._openid.connection
        return fetch_jwks(
            conn._s,
            self._endpoints.jwks,
            timeout=getattr(conn, "timeout", None),
            verify=getattr(conn, "verify", True),
            cert=getattr(conn, "cert", None),
        )

    def close(self) -> None:
        """Closes the requests session of the underlying `KeycloakOpenID`.

        python-keycloak offers no public close for sync use, so the internal session
        (`connection._s`) is closed defensively (getattr guards) — if it is not released, the
        connection pool lingers until the GC finalizer.
        """
        conn = getattr(self._openid, "connection", None)
        session = getattr(conn, "_s", None) if conn is not None else None
        close = getattr(session, "close", None) if session is not None else None
        if callable(close):
            close()
