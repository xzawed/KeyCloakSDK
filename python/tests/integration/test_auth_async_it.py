"""async 인증 흐름 E2E — 실제 Keycloak 컨테이너 대상 (WBS 5, `keycloak_sdk.aio`).

sync `test_auth_it.py`의 async 미러다. `AsyncAuthClient.validate`(WBS 2)가 실제
다중 aud(`["it-client", ...]`) 토큰(오디언스 매퍼가 `it-client`를 추가)에 대해
포함검사를 올바르게 통과시키는지 검증한다.
"""

from __future__ import annotations

import pytest

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig

pytestmark = pytest.mark.integration


def _config(keycloak_url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url,
        realm="it-realm",
        client_id="it-client",
        client_secret="it-secret",
    )


async def test_client_credentials_token_has_access_token(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        token_set = await kc.auth.client_credentials_token()
        assert token_set.access_token


async def test_validate_accepts_real_multi_valued_audience_token(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        token_set = await kc.auth.client_credentials_token()
        validated = await kc.auth.validate(token_set.access_token)
        assert validated.issuer is not None
        assert validated.issuer.endswith("/realms/it-realm")


async def test_introspect_reports_active(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        token_set = await kc.auth.client_credentials_token()
        result = await kc.auth.introspect(token_set.access_token)
        assert result.active is True
