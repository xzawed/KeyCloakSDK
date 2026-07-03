"""AuthClient 단위 테스트. python-keycloak `KeycloakOpenID`를 목으로 주입한다.

`auth.py`는 네트워크 경계라 커버리지 게이트(G3)에서 제외되지만(pyproject omit), 이
스위트는 커버리지가 아니라 매핑·PKCE·에러 변환·JWKS 배선 "행동"을 증명하기 위한 것이다.
"""
from __future__ import annotations

import base64
import hashlib
import time
from unittest.mock import MagicMock

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey
from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakAuthenticationError, KeycloakGetError

from keycloak_sdk.auth import AuthClient
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


def _client(openid: MagicMock, config: KeycloakConfig | None = None) -> AuthClient:
    cfg = config or _config()
    endpoints = OidcEndpoints.for_realm(cfg)
    return AuthClient(cfg, endpoints, openid=openid)


def test_constructs_real_openid_when_not_injected():
    """openid 미지정 시 config로부터 실제 KeycloakOpenID를 생성한다(네트워크 호출 없음)."""
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)

    client = AuthClient(config, endpoints)

    assert isinstance(client._openid, KeycloakOpenID)
    assert client._openid.realm_name == "r"
    assert client._openid.client_id == "app"


def test_injected_openid_is_used_verbatim():
    openid = MagicMock(spec=KeycloakOpenID)
    client = _client(openid)

    assert client._openid is openid


def test_wrap_translates_authentication_error_to_auth_error():
    """`_wrap`은 401(KeycloakAuthenticationError)을 KeycloakAuthError로 변환하고
    OAuth `error` 코드를 response_body에서 파싱해 보존한다."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakAuthenticationError(
            error_message=b'{"error": "invalid_grant", "error_description": "bad creds"}',
            response_code=401,
            response_body=b'{"error": "invalid_grant", "error_description": "bad creds"}',
        )

    with pytest.raises(KeycloakAuthError) as excinfo:
        client._wrap(boom)

    assert excinfo.value.error == "invalid_grant"


def test_wrap_translates_error_with_response_code_but_no_json_body():
    """response_body가 JSON이 아니거나 없으면 error 코드는 None으로 남는다(크래시 없음)."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakAuthenticationError(error_message="nope", response_code=400)

    with pytest.raises(KeycloakAuthError) as excinfo:
        client._wrap(boom)

    assert excinfo.value.error is None


def test_wrap_translates_error_without_response_code_to_transport_error():
    """response_code가 없으면(네트워크/전송 계층 오류) KeycloakTransportError로 변환한다."""
    client = _client(MagicMock(spec=KeycloakOpenID))

    def boom() -> None:
        raise KeycloakGetError(error_message="connection reset")

    with pytest.raises(KeycloakTransportError):
        client._wrap(boom)


def test_wrap_passes_through_successful_result():
    client = _client(MagicMock(spec=KeycloakOpenID))

    assert client._wrap(lambda: 42) == 42


# --- 3.3: client_credentials_token + PKCE authorization_url ---------------------


def test_client_credentials_token_maps_response():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.return_value = {
        "access_token": "acc",
        "refresh_token": "ref",
        "token_type": "Bearer",
        "scope": "openid",
        "expires_in": 300,
    }
    client = _client(openid)

    before = time.time()
    result = client.client_credentials_token()
    after = time.time()

    openid.token.assert_called_once_with(grant_type="client_credentials", scope="openid")
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc"
    assert result.refresh_token == "ref"
    assert result.expires_at is not None
    assert before + 300 <= result.expires_at <= after + 300


def test_client_credentials_passes_scopes():
    """`config.scopes`가 `token()` 호출에 스페이스 조인된 `scope`로 전달돼야 한다 —
    미전달 시 python-keycloak이 `"openid"`로 고정해 추가 스코프가 무시된다."""
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.return_value = {
        "access_token": "acc",
        "token_type": "Bearer",
        "scope": "openid profile",
        "expires_in": 300,
    }
    config = _config(scopes=("openid", "profile"))
    client = _client(openid, config=config)

    client.client_credentials_token()

    _, kwargs = openid.token.call_args
    assert "profile" in kwargs["scope"]
    openid.token.assert_called_once_with(grant_type="client_credentials", scope="openid profile")


def test_client_credentials_token_wraps_auth_error():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.side_effect = KeycloakAuthenticationError(
        error_message="bad secret", response_code=401,
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        client.client_credentials_token()


def test_authorization_url_contains_pkce_state_and_nonce():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.auth_url.return_value = "https://kc.example.com/auth?mocked=1"
    config = _config(scopes=("openid", "profile"))
    client = _client(openid, config=config)

    result = client.authorization_url("https://app.example.com/callback")

    assert result.url == "https://kc.example.com/auth?mocked=1"
    assert result.code_verifier and result.state and result.nonce
    # PKCE verifier/state/nonce are unpredictable secrets — ensure the client
    # doesn't degenerate to fixed/empty values.
    assert len(result.code_verifier) >= 43  # RFC 7636 minimum length
    assert result.state != result.nonce

    expected_challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(result.code_verifier.encode()).digest())
        .rstrip(b"=")
        .decode()
    )
    openid.auth_url.assert_called_once_with(
        "https://app.example.com/callback",
        scope="openid profile",
        state=result.state,
        nonce=result.nonce,
        code_challenge=expected_challenge,
        code_challenge_method="S256",
    )


def test_authorization_url_repr_masks_verifier():
    """`AuthorizationUrl.__repr__`은 PKCE `code_verifier`를 마스킹해야 한다 — 기본
    dataclass repr은 평문 verifier를 로그/예외 트레이스에 노출시킨다(보안 결함)."""
    openid = MagicMock(spec=KeycloakOpenID)
    openid.auth_url.return_value = "https://kc.example.com/auth?mocked=1"
    client = _client(openid)

    result = client.authorization_url("https://app.example.com/callback")

    rendered = repr(result)
    assert result.code_verifier not in rendered
    assert result.url in rendered
    assert result.state in rendered
    assert result.nonce in rendered


def test_authorization_url_generates_distinct_verifiers_per_call():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.auth_url.return_value = "https://kc.example.com/auth"
    client = _client(openid)

    first = client.authorization_url("https://app/cb")
    second = client.authorization_url("https://app/cb")

    assert first.code_verifier != second.code_verifier
    assert first.state != second.state
    assert first.nonce != second.nonce


def test_authorization_url_wraps_transport_error():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.auth_url.side_effect = KeycloakGetError(error_message="dns failure")
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        client.authorization_url("https://app/cb")


# --- 3.4: exchange_code / refresh / logout / introspect --------------------------


def test_exchange_code_maps_response_and_delegates_pkce_args():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.return_value = {
        "access_token": "acc2",
        "refresh_token": "ref2",
        "id_token": "id2",
        "token_type": "Bearer",
        "scope": "openid profile",
        "expires_in": 60,
    }
    client = _client(openid)

    result = client.exchange_code("auth-code", "https://app/cb", "verifier-xyz")

    openid.token.assert_called_once_with(
        grant_type="authorization_code",
        code="auth-code",
        redirect_uri="https://app/cb",
        code_verifier="verifier-xyz",
    )
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc2"
    assert result.id_token == "id2"


def test_exchange_code_wraps_auth_error_on_invalid_grant():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.side_effect = KeycloakAuthenticationError(
        error_message='{"error": "invalid_grant"}',
        response_code=400,
        response_body=b'{"error": "invalid_grant"}',
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError) as excinfo:
        client.exchange_code("bad-code", "https://app/cb", "verifier")

    assert excinfo.value.error == "invalid_grant"


def test_refresh_maps_response_and_delegates():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.refresh_token.return_value = {
        "access_token": "acc3",
        "refresh_token": "ref3",
        "token_type": "Bearer",
        "scope": "openid",
        "expires_in": 120,
    }
    client = _client(openid)

    result = client.refresh("old-refresh")

    openid.refresh_token.assert_called_once_with("old-refresh")
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc3"
    assert result.refresh_token == "ref3"


def test_refresh_wraps_transport_error():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.refresh_token.side_effect = KeycloakGetError(error_message="conn reset")
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        client.refresh("old-refresh")


def test_logout_delegates_and_returns_none():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.logout.return_value = {}
    client = _client(openid)

    result = client.logout("some-refresh")

    openid.logout.assert_called_once_with("some-refresh")
    assert result is None


def test_logout_wraps_auth_error():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.logout.side_effect = KeycloakAuthenticationError(
        error_message="already invalidated", response_code=400,
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        client.logout("some-refresh")


def test_introspect_maps_active_token():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.introspect.return_value = {
        "active": True,
        "username": "alice",
        "client_id": "app",
    }
    client = _client(openid)

    result = client.introspect("some-token")

    openid.introspect.assert_called_once_with("some-token")
    assert result == IntrospectionResult(active=True, username="alice", client_id="app")


def test_introspect_maps_inactive_token_with_missing_fields():
    """비활성 토큰은 RFC 7662상 `active` 외 필드가 생략될 수 있다."""
    openid = MagicMock(spec=KeycloakOpenID)
    openid.introspect.return_value = {"active": False}
    client = _client(openid)

    result = client.introspect("expired-token")

    assert result == IntrospectionResult(active=False, username=None, client_id=None)


# --- 3.5: validate() — JWKS 로드(+캐시) 후 JwtValidator에 위임 -------------------


def _signed_token(key: RSAKey, issuer: str, audience: str, **extra_claims: object) -> str:
    claims = {"iss": issuer, "aud": audience, "sub": "user-1", "exp": int(time.time()) + 60}
    claims.update(extra_claims)
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


def test_validate_loads_jwks_and_delegates_to_jwt_validator():
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    result = client.validate(token)

    openid.certs.assert_called_once_with()
    assert isinstance(result, ValidatedToken)
    assert result.issuer == endpoints.issuer
    assert result.subject == "user-1"
    assert config.client_id in result.audience


def test_validate_caches_jwks_across_calls():
    """JWKS는 인스턴스에 캐시돼야 한다 — 두 번째 validate()는 certs()를 재호출하지 않는다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    client.validate(token)
    client.validate(token)

    assert openid.certs.call_count == 1


def test_validate_rejects_token_with_wrong_audience():
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        client.validate(token)


def test_validate_wraps_certs_transport_error():
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.side_effect = KeycloakGetError(error_message="conn reset")
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        client.validate("irrelevant-token")


# --- FIX I.2: JWKS 키 회전 복원력 — 서명 실패 시 certs() 재조회 + 1회 재시도 -----


def test_validate_refetches_jwks_and_retries_once_on_signature_failure():
    """키 회전 시나리오: 캐시된 JWKS에는 없는 새 kid로 서명된 토큰이 도착하면, 최초
    검증은 서명 실패(TokenSignatureError)하지만 certs()를 한 번 재조회한 뒤 재시도해
    성공해야 한다. certs()는 정확히 두 번 호출돼야 한다(최초 로드 + 재조회 1회)."""
    old_key = RSAKey.generate_key(2048, {"kid": "old-kid", "use": "sig"})
    new_key = RSAKey.generate_key(2048, {"kid": "new-kid", "use": "sig"})
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.side_effect = [
        {"keys": [old_key.as_dict(private=False)]},
        {"keys": [old_key.as_dict(private=False), new_key.as_dict(private=False)]},
    ]
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(new_key, issuer=endpoints.issuer, audience=config.client_id)

    result = client.validate(token)

    assert isinstance(result, ValidatedToken)
    assert result.subject == "user-1"
    assert openid.certs.call_count == 2


def test_validate_does_not_refetch_jwks_on_claim_failure():
    """클레임 실패(예: audience 불일치)는 서명 실패가 아니므로 JWKS 재조회를 트리거
    하면 안 된다 — 그렇지 않으면 무효 토큰 하나마다 certs() 호출이 발생한다.
    certs()는 정확히 한 번만 호출돼야 한다(최초 로드뿐, 재조회 없음)."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock(spec=KeycloakOpenID)
    openid.certs.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        client.validate(token)

    assert openid.certs.call_count == 1
