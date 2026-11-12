"""인증 흐름 E2E — 실제 Keycloak 컨테이너 대상 (WBS 6.2).

`JwtValidator`(WBS 3.1)가 실제 다중 aud(`["it-client", ...]`) 토큰(오디언스
매퍼가 `it-client`를 추가)에 대해 포함검사를 올바르게 통과시키는지 검증한다.
"""

from __future__ import annotations

import time

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey

from keycloak_sdk import KeycloakClient, KeycloakConfig, TokenKeyError

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def kc(keycloak_url: str) -> KeycloakClient:
    config = KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )
    return KeycloakClient.create(config)


def test_client_credentials_token_has_access_token(kc: KeycloakClient) -> None:
    token_set = kc.auth.client_credentials_token()
    assert token_set.access_token


def test_validate_accepts_real_multi_valued_audience_token(kc: KeycloakClient) -> None:
    token_set = kc.auth.client_credentials_token()
    validated = kc.auth.validate(token_set.access_token)
    assert validated.issuer is not None
    assert validated.issuer.endswith("/realms/it-realm")


def test_a_kid_missing_from_the_realm_jwks_is_refused_after_one_forced_refetch(
    keycloak_url: str,
) -> None:
    """kid 가 realm JWKS 에 없는 RS256 토큰 — 받아 둔 키셋에 없으면 한 번 강제로 다시 받고,
    그래도 없으면 `TokenKeyError` 다(키 회전 복원력 · `_validate_for` 의 `except TokenKeyError`).
    실서버로 이 길을 지나던 것은 코드 교환의 HS256 칸이었는데, 그 칸은 이제 키를 찾기 전에
    거부된다(등록부 hs-refusal-rests-on-libraries)."""
    config = KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )
    with KeycloakClient.create(config) as kc:
        # 키셋을 먼저 받아 둔다 — 아래의 재조회가 콜드 적재가 아니라 강제 재조회가 되게.
        kc.auth.validate(kc.auth.client_credentials_token().access_token)
        with pytest.raises(TokenKeyError):
            kc.auth.validate(foreign_rs256_token(f"{keycloak_url}/realms/it-realm"))


def foreign_rs256_token(issuer: str) -> str:
    """realm 이 모르는 RSA 키로 서명한 RS256 토큰 — kid 가 realm JWKS 에 없다."""
    key = RSAKey.generate_key(2048, {"kid": "not-in-the-realm-jwks", "use": "sig"})
    claims = {"iss": issuer, "aud": "it-client", "sub": "x", "exp": int(time.time()) + 60}
    return jjwt.encode({"alg": "RS256", "kid": "not-in-the-realm-jwks"}, claims, key)


def test_introspect_reports_active(kc: KeycloakClient) -> None:
    token_set = kc.auth.client_credentials_token()
    result = kc.auth.introspect(token_set.access_token)
    assert result.active is True
