"""인증 흐름 E2E — 실제 Keycloak 컨테이너 대상 (WBS 6.2).

`JwtValidator`(WBS 3.1)가 실제 다중 aud(`["it-client", ...]`) 토큰(오디언스
매퍼가 `it-client`를 추가)에 대해 포함검사를 올바르게 통과시키는지 검증한다.
"""
from __future__ import annotations

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig

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


def test_introspect_reports_active(kc: KeycloakClient) -> None:
    token_set = kc.auth.client_credentials_token()
    result = kc.auth.introspect(token_set.access_token)
    assert result.active is True
