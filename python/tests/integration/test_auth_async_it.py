"""async 인증 흐름 E2E — 실제 Keycloak 컨테이너 대상 (WBS 5, `keycloak_sdk.aio`).

sync `test_auth_it.py`의 async 미러다. `AsyncAuthClient.validate`(WBS 2)가 실제
다중 aud(`["it-client", ...]`) 토큰(오디언스 매퍼가 `it-client`를 추가)에 대해
포함검사를 올바르게 통과시키는지 검증한다.
"""

from __future__ import annotations

import pytest

from keycloak_sdk import TokenKeyError
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from tests.integration.test_auth_it import foreign_rs256_token

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


async def test_a_kid_missing_from_the_realm_jwks_is_refused_after_one_forced_refetch(
    keycloak_url: str,
) -> None:
    """sync 미러와 같다 — kid 가 realm JWKS 에 없으면 한 번 강제로 다시 받고 `TokenKeyError` 다."""
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        # 키셋을 먼저 받아 둔다 — 아래의 재조회가 콜드 적재가 아니라 강제 재조회가 되게.
        await kc.auth.validate((await kc.auth.client_credentials_token()).access_token)
        with pytest.raises(TokenKeyError):
            await kc.auth.validate(foreign_rs256_token(f"{keycloak_url}/realms/it-realm"))


async def test_introspect_reports_active(keycloak_url: str) -> None:
    async with AsyncKeycloakClient.create(_config(keycloak_url)) as kc:
        token_set = await kc.auth.client_credentials_token()
        result = await kc.auth.introspect(token_set.access_token)
        assert result.active is True
