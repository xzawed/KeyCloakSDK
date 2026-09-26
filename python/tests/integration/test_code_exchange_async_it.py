"""인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로 (`keycloak_sdk.aio`).

sync `test_code_exchange_it.py` 의 async 미러다. 로그인(`browser_login`)은 SDK 가 아니라 브라우저
역할이라 sync 그대로 쓴다 — 검증 대상은 `AsyncAuthClient` 다.
"""

from __future__ import annotations

import logging
import traceback
from collections.abc import AsyncIterator

import pytest

from keycloak_sdk import KeycloakAuthError, TokenKeyError, TokenSignatureError
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.auth import AuthorizationUrl
from tests.integration.browser_login import browser_login
from tests.integration.conftest import (
    ALICE,
    REDIRECT_URI,
    WEB_CLIENT_SECRETS,
    strip_nonce,
    web_config,
)

pytestmark = pytest.mark.integration


@pytest.fixture
async def kc(keycloak_url: str) -> AsyncIterator[AsyncKeycloakClient]:
    async with AsyncKeycloakClient.create(web_config(keycloak_url)) as client:
        yield client


def _login(kc: AsyncKeycloakClient) -> tuple[AuthorizationUrl, str]:
    request = kc.auth.authorization_url(REDIRECT_URI)
    return request, browser_login(request, REDIRECT_URI, *ALICE)


async def test_exchange_code_binds_tokens_to_the_nonce_and_user(
    kc: AsyncKeycloakClient, alice_id: str
) -> None:
    request, code = _login(kc)
    tokens = await kc.auth.exchange_code(
        code, REDIRECT_URI, request.code_verifier, nonce=request.nonce
    )
    assert tokens.access_token
    assert tokens.refresh_token
    assert tokens.id_token
    id_claims = (await kc.auth.validate(tokens.id_token)).claims
    assert id_claims["nonce"] == request.nonce
    assert id_claims["sub"] == alice_id

    refreshed = await kc.auth.refresh(tokens.refresh_token)
    assert refreshed.access_token
    assert refreshed.access_token != tokens.access_token
    assert refreshed.refresh_token
    active = await kc.auth.introspect(refreshed.access_token)
    assert active.active is True
    assert active.username == ALICE[0]

    await kc.auth.logout(refreshed.refresh_token)
    with pytest.raises(KeycloakAuthError) as ended:
        await kc.auth.refresh(refreshed.refresh_token)
    assert ended.value.error == "invalid_grant"
    assert (await kc.auth.introspect(refreshed.access_token)).active is False


async def test_exchange_code_refuses_a_nonce_the_server_did_not_sign(
    kc: AsyncKeycloakClient,
) -> None:
    request, code = _login(kc)
    with pytest.raises(KeycloakAuthError) as refused:
        await kc.auth.exchange_code(
            code, REDIRECT_URI, request.code_verifier, nonce=f"x{request.nonce}"
        )
    assert str(refused.value) == "authorization code exchange failed: unexpected nonce"
    assert refused.value.error is None  # 서버가 아니라 SDK 가 거부했다


async def test_exchange_code_refuses_an_id_token_that_carries_no_nonce(
    kc: AsyncKeycloakClient,
) -> None:
    """nonce 를 빼고 인가받은 코드 — 서버는 nonce 없는 id_token 을 낸다. 부재도 거부다."""
    request = strip_nonce(kc.auth.authorization_url(REDIRECT_URI))
    # 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
    code = browser_login(request, REDIRECT_URI, *ALICE)
    unchecked = await kc.auth.exchange_code(code, REDIRECT_URI, request.code_verifier)
    assert unchecked.id_token
    assert "nonce" not in (await kc.auth.validate(unchecked.id_token)).claims

    code = browser_login(request, REDIRECT_URI, *ALICE)
    with pytest.raises(KeycloakAuthError) as refused:
        await kc.auth.exchange_code(code, REDIRECT_URI, request.code_verifier, nonce=request.nonce)
    assert str(refused.value) == "authorization code exchange failed: unexpected nonce"


async def test_reused_code_is_refused_without_leaking_it(
    kc: AsyncKeycloakClient,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    request, code = _login(kc)
    # 로그인 자체의 기록(콜백 URL 에 코드가 실린다)은 SDK 의 누출이 아니다 — 여기서부터 잰다.
    caplog.set_level(logging.DEBUG)
    caplog.clear()
    capsys.readouterr()
    tokens = await kc.auth.exchange_code(
        code, REDIRECT_URI, request.code_verifier, nonce=request.nonce
    )
    with pytest.raises(KeycloakAuthError) as reused:
        await kc.auth.exchange_code(code, REDIRECT_URI, request.code_verifier, nonce=request.nonce)
    assert reused.value.error == "invalid_grant"
    streams = capsys.readouterr()
    # 예외 사슬(logging.exception 이 찍을 것) · 모든 로거의 DEBUG 기록 · stdout/stderr
    printed = "".join(traceback.format_exception(reused.value))
    printed += caplog.text + streams.out + streams.err
    hidden: list[str | None] = [code, request.code_verifier, WEB_CLIENT_SECRETS["it-web"]]
    hidden += [tokens.access_token, tokens.refresh_token, tokens.id_token]
    for secret in hidden:
        assert secret
        assert secret not in str(reused.value)
        assert secret not in repr(reused.value)
        assert secret not in printed


@pytest.mark.parametrize(
    ("algorithms", "reason"),
    [
        (("RS256",), TokenSignatureError),  # 알고리즘 핀이 먼저 거부한다
        (("RS256", "HS256"), TokenKeyError),  # 핀을 열어도 그 키는 realm JWKS 에 없다
    ],
)
async def test_id_token_signed_by_a_key_outside_the_jwks_is_refused(
    keycloak_url: str, algorithms: tuple[str, ...], reason: type[Exception]
) -> None:
    """`it-web-hs256` 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다."""
    config = web_config(keycloak_url, "it-web-hs256", algorithms)
    async with AsyncKeycloakClient.create(config) as kc:
        request, code = _login(kc)
        with pytest.raises(KeycloakAuthError) as refused:
            await kc.auth.exchange_code(
                code, REDIRECT_URI, request.code_verifier, nonce=request.nonce
            )
    assert str(refused.value) == "authorization code exchange failed: invalid id_token"
    assert type(refused.value.__cause__) is reason
