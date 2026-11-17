"""액세스 검증의 종류 규칙을 실서버(Keycloak 26.6)로 잰다 — 등록부 `access-token-typ-deny-list`.

액세스 경로는 Keycloak 자신의 규칙(`TokenVerifier.TokenTypeCheck` — `equalsIgnoreCase`
허용 목록, 부재는 거부)을 따른다: 페이로드 `typ` 이 대소문자를 무시하고 `Bearer` · `DPoP`
일 때만 받는다. 여기서 재는 것:

1. client_credentials 액세스 토큰의 `typ` 은 `Bearer` 다 — `validate` 가 받는다.
2. 클라이언트 옵션 `token.response.type.bearer.lower-case` 를 켠 클라이언트의 액세스 토큰.
   소스(26.6.9 `TokenManager.initToken` → `formatTokenType`)로는 페이로드 `typ` 도
   소문자다 — Grok 레그는 응답의 `token_type` 만 바뀐다고 했다. 이 칸이 실서버로 가른다.
   어느 쪽이든 `validate` 는 받아야 한다.
3. JARM(`response_mode=query.jwt`) 인가 응답 JWT — realm 키로 서명되고 `aud` 가 client id
   인데 `typ` 이 없다(`AuthorizationResponseToken`). 거부 목록이던 때 `validate` 는 이것을
   액세스 토큰으로 받았다 — 이제 거부한다(sync · aio).
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from urllib.parse import parse_qs, urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import TokenValidationError
from tests.integration.browser_login import login_callback
from tests.integration.conftest import ALICE, REDIRECT_URI, unverified_claims, web_config

pytestmark = pytest.mark.integration

#: 다섯 알려진 종류가 아닌 `typ`(부재 포함)의 거부 문구 — 토큰이 고른 값을 싣지 않는 상수다.
NOT_AN_ACCESS_TOKEN = "Token is not an access token (typ is not Bearer or DPoP)"


def _it_client(keycloak_url: str) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=keycloak_url, realm="it-realm", client_id="it-client", client_secret="it-secret"
    )


def test_a_client_credentials_access_token_is_typed_bearer(keycloak_url: str) -> None:
    with KeycloakClient.create(_it_client(keycloak_url)) as kc:
        token = kc.auth.client_credentials_token().access_token
        assert unverified_claims(token).get("typ") == "Bearer"
        kc.auth.validate(token)


@pytest.fixture
def lower_case_client(keycloak_url: str) -> Iterator[KeycloakConfig]:
    """`token.response.type.bearer.lower-case` 를 켠 기밀 클라이언트 — 자기 client id 를 액세스 토큰
    `aud` 에 넣는다(`it-client` 와 같은 audience 매퍼). 시험이 끝나면 지운다."""
    client_id = f"it-lower-{uuid.uuid4().hex[:8]}"
    secret = "it-lower-secret"
    rep = {
        "clientId": client_id,
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": False,
        "secret": secret,
        "serviceAccountsEnabled": True,
        "standardFlowEnabled": False,
        "attributes": {"token.response.type.bearer.lower-case": "true"},
        "protocolMappers": [
            {
                "name": "self-audience",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-audience-mapper",
                "consentRequired": False,
                "config": {
                    "included.custom.audience": client_id,
                    "id.token.claim": "false",
                    "access.token.claim": "true",
                },
            }
        ],
    }
    with KeycloakClient.create(_it_client(keycloak_url)) as admin:
        internal_id = admin.admin.clients.create(rep)
        try:
            yield KeycloakConfig(
                server_url=keycloak_url, realm="it-realm", client_id=client_id, client_secret=secret
            )
        finally:
            admin.admin.clients.delete(internal_id)


def test_the_lower_case_bearer_option_types_the_payload_in_lower_case_and_validate_accepts_it(
    lower_case_client: KeycloakConfig,
) -> None:
    with KeycloakClient.create(lower_case_client) as kc:
        token = kc.auth.client_credentials_token().access_token
        typ = unverified_claims(token).get("typ")
        # 소스(formatTokenType)의 예측 — 실서버가 다르면 이 단언이 측정값을 보여 준다.
        assert typ == "bearer", f"payload typ under the lower-case option: {typ!r}"
        kc.auth.validate(token)


def _jarm(keycloak_url: str) -> str:
    """`it-web` 으로 `response_mode=query.jwt` 인가를 끝까지 밟아 콜백의 `response`(JARM
    JWT)를 꺼낸다 — 그 JWT 가 거부 목록을 지나던 모양인지(전제)도 서명 없이 읽어 본다."""
    with KeycloakClient.create(web_config(keycloak_url)) as kc:
        request = kc.auth.authorization_url(REDIRECT_URI)
    location = login_callback(f"{request.url}&response_mode=query.jwt", REDIRECT_URI, *ALICE)
    responses = parse_qs(urlsplit(location).query).get("response")
    assert responses is not None and len(responses) == 1, location
    jarm = responses[0]
    claims = unverified_claims(jarm)
    assert "typ" not in claims, claims
    assert claims.get("aud") in ("it-web", ["it-web"]), claims
    assert "exp" in claims and "code" in claims, sorted(claims)
    return jarm


def test_a_jarm_response_jwt_is_not_an_access_token(keycloak_url: str) -> None:
    jarm = _jarm(keycloak_url)
    with (
        KeycloakClient.create(web_config(keycloak_url)) as kc,
        pytest.raises(TokenValidationError) as refused,
    ):
        kc.auth.validate(jarm)
    assert str(refused.value) == NOT_AN_ACCESS_TOKEN


async def test_a_jarm_response_jwt_is_not_an_access_token_aio(keycloak_url: str) -> None:
    jarm = _jarm(keycloak_url)
    async with AsyncKeycloakClient.create(web_config(keycloak_url)) as kc:
        with pytest.raises(TokenValidationError) as refused:
            await kc.auth.validate(jarm)
    assert str(refused.value) == NOT_AN_ACCESS_TOKEN
