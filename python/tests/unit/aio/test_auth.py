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
from joserfc.jwk import RSAKey
from keycloak.exceptions import KeycloakAuthenticationError, KeycloakGetError

from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthorizationUrl
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError, TokenValidationError
from keycloak_sdk.oidc import OidcEndpoints
from keycloak_sdk.tokens import IntrospectionResult, TokenSet, ValidatedToken


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


# --- validate() — a_certs 로드 후 JwtValidator(sync)에 위임 -------------------------


def _signed_token(key: RSAKey, issuer: str, audience: str, **extra_claims: object) -> str:
    claims = {"iss": issuer, "aud": audience, "sub": "user-1", "exp": int(time.time()) + 60}
    claims.update(extra_claims)
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


async def test_validate_loads_jwks_and_delegates_to_jwt_validator():
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    openid.a_certs = AsyncMock(return_value={"keys": [key.as_dict(private=False)]})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    openid.a_certs.assert_awaited_once_with()
    assert isinstance(result, ValidatedToken)
    assert result.issuer == endpoints.issuer
    assert result.subject == "user-1"
    assert config.client_id in result.audience


async def test_validate_caches_jwks_across_calls():
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    openid.a_certs = AsyncMock(return_value={"keys": [key.as_dict(private=False)]})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    await client.validate(token)
    await client.validate(token)

    assert openid.a_certs.await_count == 1


async def test_validate_concurrent_cold_cache_single_flights_a_certs():
    """동시성 하드닝: 콜드 캐시에서 두 `validate()`가 동시에 실행돼도 `a_certs()`는
    한 번만 호출돼야 한다(`asyncio.Lock` 단일화). `a_certs` side_effect에 진짜
    `await asyncio.sleep(0)` 지점을 둬 실제 컨텍스트 스위치를 강제한다 — 그렇지 않으면
    목이 동기적으로 완료돼 두 번째 호출이 이미 채워진 캐시를 보게 되어(잠금 유무와
    무관하게) 테스트가 아무것도 증명하지 못한다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()

    async def _certs_with_yield() -> dict[str, object]:
        await asyncio.sleep(0)
        return {"keys": [key.as_dict(private=False)]}

    openid.a_certs = AsyncMock(side_effect=_certs_with_yield)
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    results = await asyncio.gather(client.validate(token), client.validate(token))

    assert openid.a_certs.await_count == 1
    for result in results:
        assert isinstance(result, ValidatedToken)
        assert result.subject == "user-1"


async def test_validate_rejects_token_with_wrong_audience():
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    openid.a_certs = AsyncMock(return_value={"keys": [key.as_dict(private=False)]})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        await client.validate(token)


async def test_validate_refetches_jwks_and_retries_once_on_signature_failure():
    """키 회전 시나리오: sync와 동형 — 서명 실패(TokenSignatureError) 시 a_certs()를
    한 번 재조회한 뒤 재시도해 성공해야 한다."""
    old_key = RSAKey.generate_key(2048, {"kid": "old-kid", "use": "sig"})
    new_key = RSAKey.generate_key(2048, {"kid": "new-kid", "use": "sig"})
    openid = MagicMock()
    openid.a_certs = AsyncMock(
        side_effect=[
            {"keys": [old_key.as_dict(private=False)]},
            {"keys": [old_key.as_dict(private=False), new_key.as_dict(private=False)]},
        ]
    )
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(new_key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    assert isinstance(result, ValidatedToken)
    assert result.subject == "user-1"
    assert openid.a_certs.await_count == 2


async def test_validate_wraps_certs_transport_error():
    openid = MagicMock()
    openid.a_certs = AsyncMock(side_effect=KeycloakGetError(error_message="conn reset"))
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        await client.validate("irrelevant-token")


# --- 보안: JWKS 강제 재조회 DoS 증폭 방지 + 자원 정리 (감사 후속) -------------------


async def test_signature_forgery_does_not_refetch_jwks():
    """서명 위조(kid는 캐시에 있으나 서명 불일치)는 a_certs() 재조회를 유발하지 않는다 —
    sync와 동형의 미인증 DoS 증폭 방어."""
    cached_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    forger_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    openid.a_certs = AsyncMock(return_value={"keys": [cached_key.as_dict(private=False)]})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(forger_key, issuer=endpoints.issuer, audience=config.client_id)

    with pytest.raises(TokenValidationError):
        await client.validate(token)

    assert openid.a_certs.await_count == 1


async def test_aclose_closes_underlying_connection():
    """aclose()는 ConnectionManager.aclose()를 호출해 httpx AsyncClient를 닫는다 —
    미해제 시 async 소켓/FD 누수(EMFILE)."""
    openid = MagicMock()
    openid.connection.aclose = AsyncMock()
    client = _client(openid)

    await client.aclose()

    openid.connection.aclose.assert_awaited_once_with()
