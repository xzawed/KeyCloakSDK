"""AsyncAuthClient 단위 테스트. python-keycloak `KeycloakOpenID`를 AsyncMock으로 주입한다.

`aio/auth.py`는 네트워크 경계라 커버리지 게이트(G3)에서 제외되지만(pyproject omit), 이
스위트는 커버리지가 아니라 매핑·PKCE·에러 변환·JWKS 배선 "행동"을 증명하기 위한 것이다.
sync `tests/unit/test_auth.py`와 동형(same coverage) — python-keycloak `a_*` 메서드만 다르다.
"""

from __future__ import annotations

import asyncio
import time
from unittest.mock import AsyncMock, MagicMock
from urllib.parse import parse_qs, urlparse

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import ECKey, RSAKey
from keycloak.exceptions import KeycloakAuthenticationError, KeycloakGetError

from keycloak_sdk._internal.backoff import JwksFailureBackoff
from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthorizationUrl
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError, TokenValidationError
from keycloak_sdk.oidc import OidcEndpoints
from keycloak_sdk.tokens import IntrospectionResult, TokenSet, ValidatedToken


class _FakeClock:
    """백오프 창을 결정적으로 넘기기 위한 시계 — sleep 하지 않는다."""

    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def _config(**overrides: object) -> KeycloakConfig:
    defaults: dict[str, object] = {
        "server_url": "https://kc.example.com",
        "realm": "r",
        "client_id": "app",
        "client_secret": "s3cret",
    }
    defaults.update(overrides)
    return KeycloakConfig(**defaults)  # type: ignore[arg-type]


def _client(openid: MagicMock, config: KeycloakConfig | None = None) -> AsyncAuthClient:
    cfg = config or _config()
    return AsyncAuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)


# --- client_credentials_token -----------------------------------------------------


async def test_client_credentials_maps_tokenset():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={"access_token": "a", "expires_in": 300, "token_type": "Bearer"}
    )
    ts = await _client(openid).client_credentials_token()
    assert isinstance(ts, TokenSet)
    assert ts.access_token == "a"
    openid.a_token.assert_awaited_once()


async def test_client_credentials_passes_scopes():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={"access_token": "a", "expires_in": 300, "token_type": "Bearer"}
    )
    config = _config(scopes=("openid", "profile"))
    await _client(openid, config=config).client_credentials_token()

    openid.a_token.assert_awaited_once_with(grant_type="client_credentials", scope="openid profile")


# --- _awrap exception translation --------------------------------------------------


async def test_awrap_translates_auth_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(side_effect=KeycloakAuthenticationError("bad", response_code=401))
    with pytest.raises(KeycloakAuthError):
        await _client(openid).client_credentials_token()


async def test_awrap_translates_error_without_response_code_to_transport_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(side_effect=KeycloakGetError(error_message="conn reset"))
    with pytest.raises(KeycloakTransportError):
        await _client(openid).client_credentials_token()


# --- authorization_url (sync — no network) -----------------------------------------


def test_authorization_url_is_sync_and_builds_directly_from_endpoints():
    openid = MagicMock()
    config = _config(scopes=("openid", "profile"))
    client = _client(openid, config=config)

    result = client.authorization_url("https://app.example.com/callback")

    assert isinstance(result, AuthorizationUrl)
    assert result.code_verifier and result.state and result.nonce
    assert len(result.code_verifier) >= 43  # RFC 7636 minimum length

    parsed = urlparse(result.url)
    endpoints = OidcEndpoints.for_realm(config)
    assert result.url.startswith(endpoints.authorization)
    qs = parse_qs(parsed.query)
    assert qs["response_type"] == ["code"]
    assert qs["client_id"] == ["app"]
    assert qs["redirect_uri"] == ["https://app.example.com/callback"]
    assert qs["scope"] == ["openid profile"]
    assert qs["state"] == [result.state]
    assert qs["code_challenge_method"] == ["S256"]
    assert "code_challenge" in qs

    # authorization_url must not touch the network — openid mock untouched.
    openid.assert_not_called()
    assert not openid.mock_calls


def test_authorization_url_generates_distinct_verifiers_per_call():
    openid = MagicMock()
    client = _client(openid)

    first = client.authorization_url("https://app/cb")
    second = client.authorization_url("https://app/cb")

    assert first.code_verifier != second.code_verifier
    assert first.state != second.state
    assert first.nonce != second.nonce


# --- exchange_code / refresh / logout / introspect ---------------------------------


async def test_exchange_code_maps_response_and_delegates_pkce_args():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={
            "access_token": "acc2",
            "refresh_token": "ref2",
            "id_token": "id2",
            "token_type": "Bearer",
            "scope": "openid profile",
            "expires_in": 60,
        }
    )
    client = _client(openid)

    result = await client.exchange_code("auth-code", "https://app/cb", "verifier-xyz")

    openid.a_token.assert_awaited_once_with(
        grant_type="authorization_code",
        code="auth-code",
        redirect_uri="https://app/cb",
        code_verifier="verifier-xyz",
    )
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc2"
    assert result.id_token == "id2"


async def test_exchange_code_wraps_auth_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        side_effect=KeycloakAuthenticationError(
            error_message='{"error": "invalid_grant"}',
            response_code=400,
            response_body=b'{"error": "invalid_grant"}',
        )
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        await client.exchange_code("bad-code", "https://app/cb", "verifier")


def _exchange_openid_with_id_token(key: RSAKey, id_token: str | None, ajwks) -> MagicMock:
    openid = MagicMock()
    response: dict[str, object] = {"access_token": "acc", "token_type": "Bearer", "expires_in": 60}
    if id_token is not None:
        response["id_token"] = id_token
    openid.a_token = AsyncMock(return_value=response)
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    return openid


async def test_exchange_code_validates_id_token_and_accepts_matching_nonce(ajwks):
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce"
    )
    client = _client(_exchange_openid_with_id_token(key, id_token, ajwks), config=config)

    result = await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")

    assert result.access_token == "acc"


async def test_exchange_code_rejects_mismatched_nonce(ajwks):
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce"
    )
    client = _client(_exchange_openid_with_id_token(key, id_token, ajwks), config=config)

    with pytest.raises(KeycloakAuthError, match="nonce"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="attacker-nonce")


async def test_exchange_code_rejects_missing_id_token_when_nonce_expected(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    client = _client(_exchange_openid_with_id_token(key, id_token=None, ajwks=ajwks))

    with pytest.raises(KeycloakAuthError, match="id_token"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")


async def test_refresh_maps_response_and_delegates():
    openid = MagicMock()
    openid.a_refresh_token = AsyncMock(
        return_value={
            "access_token": "acc3",
            "refresh_token": "ref3",
            "token_type": "Bearer",
            "scope": "openid",
            "expires_in": 120,
        }
    )
    client = _client(openid)

    result = await client.refresh("old-refresh")

    openid.a_refresh_token.assert_awaited_once_with("old-refresh")
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc3"


async def test_refresh_wraps_transport_error():
    openid = MagicMock()
    openid.a_refresh_token = AsyncMock(side_effect=KeycloakGetError(error_message="conn reset"))
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        await client.refresh("old-refresh")


async def test_logout_delegates_and_returns_none():
    openid = MagicMock()
    openid.a_logout = AsyncMock(return_value={})
    client = _client(openid)

    result = await client.logout("some-refresh")

    openid.a_logout.assert_awaited_once_with("some-refresh")
    assert result is None


async def test_logout_wraps_auth_error():
    openid = MagicMock()
    openid.a_logout = AsyncMock(
        side_effect=KeycloakAuthenticationError(
            error_message="already invalidated", response_code=400
        )
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        await client.logout("some-refresh")


async def test_introspect_maps_active_token():
    openid = MagicMock()
    openid.a_introspect = AsyncMock(
        return_value={"active": True, "username": "alice", "client_id": "app"}
    )
    client = _client(openid)

    result = await client.introspect("some-token")

    openid.a_introspect.assert_awaited_once_with("some-token")
    assert result == IntrospectionResult(active=True, username="alice", client_id="app")


async def test_introspect_maps_inactive_token_with_missing_fields():
    openid = MagicMock()
    openid.a_introspect = AsyncMock(return_value={"active": False})
    client = _client(openid)

    result = await client.introspect("expired-token")

    assert result == IntrospectionResult(active=False, username=None, client_id=None)


# --- validate() — JWKS fetch 로드 후 JwtValidator(sync)에 위임 -------------------------


def _signed_token(key: RSAKey, issuer: str, audience: str, **extra_claims: object) -> str:
    claims = {"iss": issuer, "aud": audience, "sub": "user-1", "exp": int(time.time()) + 60}
    claims.update(extra_claims)
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


async def test_validate_loads_jwks_and_delegates_to_jwt_validator(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    ajwks.assert_awaited_once()
    assert isinstance(result, ValidatedToken)
    assert result.issuer == endpoints.issuer
    assert result.subject == "user-1"
    assert config.client_id in result.audience


async def test_validate_caches_jwks_across_calls(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    await client.validate(token)
    await client.validate(token)

    assert ajwks.call_count == 1


async def test_validate_concurrent_cold_cache_single_flights_a_certs(ajwks):
    """동시성 하드닝: 콜드 캐시에서 두 `validate()`가 동시에 실행돼도 JWKS fetch는
    한 번만 호출돼야 한다(`asyncio.Lock` 단일화). JWKS fetch side_effect에 진짜
    `await asyncio.sleep(0)` 지점을 둬 실제 컨텍스트 스위치를 강제한다 — 그렇지 않으면
    목이 동기적으로 완료돼 두 번째 호출이 이미 채워진 캐시를 보게 되어(잠금 유무와
    무관하게) 테스트가 아무것도 증명하지 못한다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()

    async def _certs_with_yield(*_args: object, **_kwargs: object) -> dict[str, object]:
        await asyncio.sleep(0)
        return {"keys": [key.as_dict(private=False)]}

    ajwks.side_effect = _certs_with_yield
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    results = await asyncio.gather(client.validate(token), client.validate(token))

    assert ajwks.call_count == 1
    for result in results:
        assert isinstance(result, ValidatedToken)
        assert result.subject == "user-1"


async def test_validate_rejects_token_with_wrong_audience(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        await client.validate(token)


def _validate_client(
    config: KeycloakConfig, ajwks
) -> tuple[AsyncAuthClient, RSAKey, OidcEndpoints]:
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    return _client(openid, config=config), key, OidcEndpoints.for_realm(config)


async def test_validate_defaults_expected_audience_to_client_id(ajwks):
    """`expected_audience` 미지정 시 기대 audience는 client_id다(sync 동형·기존 동작 유지)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    client_id_token = _signed_token(key, issuer=endpoints.issuer, audience="app")
    api_token = _signed_token(key, issuer=endpoints.issuer, audience="some-api")

    result = await client.validate(client_id_token)

    assert "app" in result.audience
    with pytest.raises(TokenValidationError):
        await client.validate(api_token)


async def test_validate_uses_configured_expected_audience(ajwks):
    """`expected_audience`를 설정하면 client_id 대신 그 값을 `aud`에서 찾는다(sync 동형)."""
    client, key, endpoints = _validate_client(_config(expected_audience="some-api"), ajwks)
    api_token = _signed_token(key, issuer=endpoints.issuer, audience="some-api")
    client_id_token = _signed_token(key, issuer=endpoints.issuer, audience="app")

    result = await client.validate(api_token)

    assert "some-api" in result.audience
    with pytest.raises(TokenValidationError):
        await client.validate(client_id_token)


async def test_validate_refetches_jwks_and_retries_once_on_signature_failure(ajwks):
    """키 회전 시나리오: sync와 동형 — 서명 실패(TokenSignatureError) 시 JWKS fetch를
    한 번 재조회한 뒤 재시도해 성공해야 한다."""
    old_key = RSAKey.generate_key(2048, {"kid": "old-kid", "use": "sig"})
    new_key = RSAKey.generate_key(2048, {"kid": "new-kid", "use": "sig"})
    openid = MagicMock()
    ajwks.side_effect = [
        {"keys": [old_key.as_dict(private=False)]},
        {"keys": [old_key.as_dict(private=False), new_key.as_dict(private=False)]},
    ]
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(new_key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    assert isinstance(result, ValidatedToken)
    assert result.subject == "user-1"
    assert ajwks.call_count == 2


async def test_validate_wraps_certs_transport_error(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("conn reset")
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        await client.validate("irrelevant-token")


# --- 보안: JWKS 강제 재조회 DoS 증폭 방지 + 자원 정리 (감사 후속) -------------------


async def test_signature_forgery_does_not_refetch_jwks(ajwks):
    """서명 위조(kid는 캐시에 있으나 서명 불일치)는 JWKS fetch 재조회를 유발하지 않는다 —
    sync와 동형의 미인증 DoS 증폭 방어."""
    cached_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    forger_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [cached_key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(forger_key, issuer=endpoints.issuer, audience=config.client_id)

    with pytest.raises(TokenValidationError):
        await client.validate(token)

    assert ajwks.call_count == 1


async def test_aclose_closes_underlying_connection():
    """aclose()는 ConnectionManager.aclose()를 호출해 httpx AsyncClient를 닫는다 —
    미해제 시 async 소켓/FD 누수(EMFILE)."""
    openid = MagicMock()
    openid.connection.aclose = AsyncMock()
    client = _client(openid)

    await client.aclose()

    openid.connection.aclose.assert_awaited_once_with()


async def test_malformed_jwks_yields_sdk_error_not_a_raw_library_exception(ajwks):
    """sync 미러와 동일한 계약 — 기형 JWKS는 SDK 오류로 나와야 한다(동형 최소집합 5번).

    두 미러가 갈라지지 않도록 async에도 같은 프로브를 둔다. 고치기 전에는 joserfc가 joserfc
    타입도 아닌 stdlib `binascii.Error`를 던져 `keycloak_sdk.exceptions`를 잡는 소비자가
    아무것도 잡지 못했다(§4 위반).
    """
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    openid = MagicMock()
    ajwks.return_value = {
        "keys": [
            {
                "kty": "RSA",
                "kid": "k1",
                "use": "sig",
                "alg": "RS256",
                "n": "!!!not-base64!!!",
                "e": "AQAB",
            }
        ]
    }
    client = _client(openid, config=config)

    with pytest.raises(TokenValidationError):
        await client.validate(token)


# ⚠️ 콜드 캐시 + IdP 장애 축 — sync 미러와 **대칭으로** 둔다. 이 저장소는 「sync 에만 있는
# 보안 테스트」를 이미 결함 부류로 추적한다(`python-aio-security-test-asymmetry`).
# 상태 기계는 `tests/unit/test_backoff.py` 가 재고, 여기서는 배선만 증명한다.
async def test_cold_cache_failing_idp_collapses_to_one_certs_call(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("idp down")
    client = _client(openid)

    for _ in range(20):
        with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
            await client._load_jwks()

    assert ajwks.call_count == 1, (
        "cold cache + failing IdP: 20 loads must collapse to one outbound request"
    )


# ⚠️ **이 테스트를 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 차단」으로도 통과한다.**
async def test_backoff_window_expires_and_the_next_load_reaches_the_idp(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("idp down")
    client = _client(openid)
    clock = _FakeClock()
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)

    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    assert ajwks.call_count == 1

    with pytest.raises(KeycloakTransportError, match="backing off"):
        await client._load_jwks()
    assert ajwks.call_count == 1

    clock.advance(10.0)
    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    assert ajwks.call_count == 2


# --- 보안 단언 미러 — sync 에만 있던 여덟 -------------------------------------
#
# ⚠️ **두 미러가 갈리면 한쪽만 고쳐지고 나머지는 조용히 남는다.** 아래 여덟은 sync 에만
# 있던 **보안** 단언이다(2026-09-12 대칭 diff). 프로덕션 aio 코드는 이미 이 성질들을
# 갖고 있으므로 이 테스트들은 **행동을 바꾸지 않고 고정**한다 — 그러나 고정되지 않은
# 성질은 다음 리팩터에서 조용히 사라진다. alg 핀닝은 CLAUDE.md 가 교차언어 불변식으로
# 못박은 것인데 aio 에는 단언이 **0** 이었다.


def _es256_setup(config: KeycloakConfig, ajwks) -> tuple[AsyncAuthClient, str]:
    key = ECKey.generate_key("P-256", {"kid": "k1", "use": "sig"})
    endpoints = OidcEndpoints.for_realm(config)
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(MagicMock(), config=config)
    token = jjwt.encode(
        {"alg": "ES256", "kid": key.kid},
        {
            "iss": endpoints.issuer,
            "aud": config.client_id,
            "sub": "user-1",
            "exp": int(time.time()) + 60,
        },
        key,
    )
    return client, token


async def test_validate_accepts_token_signed_with_configured_algorithm(ajwks):
    """signature_algorithms 를 ES256 으로 설정한 realm 의 ES256 토큰은 통과한다."""
    client, token = _es256_setup(_config(signature_algorithms=("ES256",)), ajwks)

    result = await client.validate(token)

    assert result.subject == "user-1"


async def test_validate_rejects_algorithm_not_in_configured_set(ajwks):
    """⚠️ **alg 핀닝** — 기본(RS256만)에서 ES256 토큰은 거부된다. 라이브러리 기본값은
    아홉 언어 어디서도 안전하지 않다(CLAUDE.md 교차언어 불변식)."""
    client, token = _es256_setup(_config(), ajwks)

    with pytest.raises(TokenValidationError):
        await client.validate(token)


async def test_validate_does_not_refetch_jwks_on_claim_failure(ajwks):
    """클레임 실패는 서명 실패가 아니므로 재조회를 트리거하지 않는다 — 그렇지 않으면
    무효 토큰 하나마다 IdP 왕복이 생긴다(DoS 증폭)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        await client.validate(token)

    assert ajwks.call_count == 1


async def test_forced_jwks_refetch_is_rate_limited(ajwks):
    """kid 를 무작위로 바꾼 위조 토큰이 연속 도착해도 강제 재조회는 rate-limit 되어
    JWKS fetch 가 상한(최초 로드 1 + 최초 강제 재조회 1 = 2)을 넘지 않는다."""
    cached_key = RSAKey.generate_key(2048, {"kid": "cached", "use": "sig"})
    ajwks.return_value = {"keys": [cached_key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(MagicMock(), config=config)
    tokens = [
        _signed_token(
            RSAKey.generate_key(2048, {"kid": kid, "use": "sig"}),
            issuer=endpoints.issuer,
            audience=config.client_id,
        )
        for kid in ("x1", "x2")
    ]

    for tok in tokens:
        with pytest.raises(TokenValidationError):
            await client.validate(tok)

    assert ajwks.call_count == 2


async def test_recovered_idp_resets_the_backoff(ajwks):
    """대조군 — 복구 후 성공이 카운터를 되돌린다. 되돌리지 않으면 장수 프로세스가
    상한에 고정된다(`security.md` 규칙 3)."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    ajwks.side_effect = [
        KeycloakTransportError("idp down"),
        {"keys": [key.as_dict(private=False)]},
    ]
    client = _client(MagicMock())
    clock = _FakeClock()
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)

    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    clock.advance(10.0)
    await client._load_jwks()

    assert client._jwks_backoff.failures == 0
    assert client._jwks_backoff.remaining() == 0.0


async def test_exchange_code_skips_id_token_validation_without_nonce(ajwks):
    """nonce 를 주지 않으면 id_token 검증을 건너뛴다 — JWKS 를 부르지 않는 것으로 잰다."""
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce"
    )
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={
            "access_token": "acc",
            "id_token": id_token,
            "token_type": "Bearer",
            "expires_in": 60,
        }
    )
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(openid, config=config)

    result = await client.exchange_code("code", "https://app/cb", "verifier")

    assert result.access_token == "acc"
    ajwks.assert_not_called()


def test_authorization_url_repr_masks_verifier():
    """⚠️ **마스킹** — 기본 dataclass repr 은 평문 PKCE verifier 를 로그·트레이스에 흘린다."""
    client = _client(MagicMock())

    result = client.authorization_url("https://app.example.com/callback")

    rendered = repr(result)
    assert result.code_verifier not in rendered
    assert result.url in rendered
    assert result.state in rendered
    assert result.nonce in rendered


def test_authorization_url_percent_encodes_and_resists_param_injection():
    """⚠️ **#442 의 회귀 테스트가 aio 에만 없었다.** 인코딩이 없으면 `redirect_uri` 안의
    `&` 가 별도 파라미터를 **주입**한다(그 결함은 sync 에서 실제로 배포돼 있었다)."""
    client = _client(MagicMock(), config=_config(scopes=("openid",)))

    hostile = "https://app.example.com/cb?x=1 y&z=2"
    result = client.authorization_url(hostile)

    assert " " not in result.url, f"원문 공백이 남았다: {result.url}"
    qs = parse_qs(urlparse(result.url).query)
    assert qs["redirect_uri"] == [hostile]
