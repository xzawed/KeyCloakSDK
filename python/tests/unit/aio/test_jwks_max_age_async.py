"""JWKS 키 집합의 수명 300초 — aio 미러.

sync(`tests/unit/test_jwks_max_age.py`)와 **같은 주장을 같은 순서로** 둔다. 규칙·이유는 sync
머리 주석이 소유한다. 여기만 더 있는 것: 300초가 지난 뒤 동시에 온 검증들이 **한 fetch** 를
함께 기다린다(콜드 캐시와 같은 단일 비행 — aio 에서는 인스턴스가 소유한 태스크다).
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any
from unittest.mock import MagicMock

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.backoff import JwksFailureBackoff
from keycloak_sdk._internal.jwks_cache import JwksKeyCache
from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError, TokenKeyError
from keycloak_sdk.oidc import OidcEndpoints

pytestmark = pytest.mark.asyncio

_K1 = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
_K2 = RSAKey.generate_key(2048, {"kid": "k2", "use": "sig"})


class _FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def _keys(*keys: RSAKey) -> bytes:
    return json.dumps({"keys": [k.as_dict(private=False) for k in keys]}).encode()


def _client(server: Any, clock: _FakeClock) -> tuple[AsyncAuthClient, str]:
    cfg = KeycloakConfig(
        server_url=server.url, realm="t", client_id="app", client_secret="s3cret", read_timeout=5.0
    )
    endpoints = OidcEndpoints.for_realm(cfg)
    client = AsyncAuthClient(cfg, endpoints)
    client._jwks_keys = JwksKeyCache(clock=clock)
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)
    return client, endpoints.issuer


def _token(key: RSAKey, issuer: str) -> str:
    claims = {"iss": issuer, "aud": "app", "sub": key.kid, "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


async def test_t1_the_key_set_is_reused_until_300s_and_fetched_exactly_once_after(
    jwks_server: Any,
) -> None:
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    try:
        token = _token(_K1, issuer)
        assert (await client.validate(token)).subject == "k1"
        assert jwks_server.hits == 1

        clock.advance(299)
        assert (await client.validate(token)).subject == "k1"
        assert jwks_server.hits == 1, "a key set 299 s old must be reused without a fetch"

        clock.advance(2)  # t0 + 301
        assert (await client.validate(token)).subject == "k1"
        assert jwks_server.hits == 2, "after 300 s the next validation must fetch exactly once"
    finally:
        await client.aclose()


async def test_t2_an_outage_after_300s_rejects_backs_off_and_recovers(jwks_server: Any) -> None:
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    try:
        token = _token(_K1, issuer)
        await client.validate(token)
        jwks_server.status = 503

        clock.advance(301)
        with pytest.raises(KeycloakTransportError, match="HTTP 503"):
            await client.validate(token)
        assert jwks_server.hits == 2, "exactly one fetch attempt — and no fallback to the old keys"

        for _ in range(5):  # 백오프 창(0.2초 · jitter 1.0) 안 — IdP 로 나가지 않고 거부한다
            with pytest.raises(KeycloakTransportError, match="backing off"):
                await client.validate(token)
        assert jwks_server.hits == 2

        jwks_server.status = 200
        clock.advance(1)  # 창이 지났다
        assert (await client.validate(token)).subject == "k1"
        assert jwks_server.hits == 3
    finally:
        await client.aclose()


async def test_t3_a_key_the_idp_removed_is_rejected_after_300s(jwks_server: Any) -> None:
    clock = _FakeClock()
    jwks_server.body = _keys(_K1, _K2)
    client, issuer = _client(jwks_server, clock)
    try:
        await client.validate(_token(_K1, issuer))
        jwks_server.body = _keys(_K2)

        clock.advance(301)
        with pytest.raises(TokenKeyError):
            await client.validate(_token(_K1, issuer))
        # 나이로 다시 가져온 것 하나 + 미해결 kid 의 강제 재조회 하나(30초 창의 첫 회).
        assert jwks_server.hits == 3

        assert (await client.validate(_token(_K2, issuer))).subject == "k2"
        assert jwks_server.hits == 3
    finally:
        await client.aclose()


async def test_t4_a_forced_refetch_restarts_the_age(jwks_server: Any) -> None:
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    try:
        await client.validate(_token(_K1, issuer))
        jwks_server.body = _keys(_K1, _K2)

        clock.advance(100)
        # 미해결 kid → 강제 재조회
        assert (await client.validate(_token(_K2, issuer))).subject == "k2"
        assert jwks_server.hits == 2

        clock.advance(250)  # t0 + 350 — 강제 재조회로부터는 250초다
        assert (await client.validate(_token(_K1, issuer))).subject == "k1"
        assert jwks_server.hits == 2, "the forced refetch must have restarted the 300 s age"
    finally:
        await client.aclose()


def _mocked_client(clock: _FakeClock) -> tuple[AsyncAuthClient, str]:
    cfg = KeycloakConfig(server_url="https://kc.example.com", realm="r", client_id="app")
    endpoints = OidcEndpoints.for_realm(cfg)
    client = AsyncAuthClient(cfg, endpoints, openid=MagicMock())
    client._jwks_keys = JwksKeyCache(clock=clock)
    return client, endpoints.issuer


async def test_the_age_counts_from_when_the_fetch_completed(ajwks: Any) -> None:
    """수명의 시작은 fetch 가 **끝난** 때다.

    10초 걸린 fetch 의 집합은 시작으로부터 305초에 아직 295초다."""
    clock = _FakeClock()
    client, issuer = _mocked_client(clock)

    async def slow_fetch(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
        clock.advance(10)
        return {"keys": [_K1.as_dict(private=False)]}

    ajwks.side_effect = slow_fetch
    token = _token(_K1, issuer)
    await client.validate(token)

    clock.advance(295)
    await client.validate(token)
    assert ajwks.call_count == 1


async def test_validations_after_300s_share_one_fetch(ajwks: Any) -> None:
    clock = _FakeClock()
    client, issuer = _mocked_client(clock)
    gate = asyncio.Event()
    calls = 0

    async def fetch(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
        nonlocal calls
        calls += 1
        if calls == 2:  # 나이로 다시 가져오는 fetch — 응답을 늦춘다
            await gate.wait()
        return {"keys": [_K1.as_dict(private=False)]}

    ajwks.side_effect = fetch
    token = _token(_K1, issuer)
    await client.validate(token)

    clock.advance(301)
    waiting = [asyncio.ensure_future(client.validate(token)) for _ in range(5)]
    for _ in range(10):
        await asyncio.sleep(0)  # 다섯이 모두 같은 fetch 앞에 섰다
    assert calls == 2 and not any(w.done() for w in waiting)
    gate.set()

    assert [(await w).subject for w in waiting] == ["k1"] * 5
    assert ajwks.call_count == 2
