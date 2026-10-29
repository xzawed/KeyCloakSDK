"""JWKS 키 집합의 수명 — 성공한 fetch 가 끝난 때부터 300초. sync 미러.

aio 는 `aio/test_jwks_max_age_async.py`. 등록부 `jwks-cache-lifetime-divergent`(판정
2026-10-29) — 아홉 언어가 같은 규칙이다. 300초가 지난 집합은 콜드 캐시와 **똑같이**
다룬다(같은 단일 비행 · 같은 실패 백오프). ⚠️ **낡은 집합으로 물러서지 않는다** — IdP 장애
중에도. 그 전에는 수명이 없어 미해결 kid 가 아니면 다시 가져오지 않았고, IdP 가 지운 키도
장애 중의 낡은 키도 영원히 받아들였다.

⚠️ 시각은 **리터럴**(299 · 301 · 350)이다 — 상수에서 파생하면 상수를 바꾼 변이를 따라가
초록으로 남는다. 시계는 `JwksKeyCache` 와 `JwksFailureBackoff` 에 **같은** 가짜 시계를 넣어
넘긴다(sleep 없음, jitter 1.0). IdP 는 실 HTTP 서버다(`jwks_server`) — T2 의 503 은 실제
상태 코드다.
"""

from __future__ import annotations

import json
import time
from typing import Any
from unittest.mock import MagicMock

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey
from keycloak import KeycloakOpenID

from keycloak_sdk._internal.backoff import JwksFailureBackoff
from keycloak_sdk._internal.jwks_cache import JwksKeyCache
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError, TokenKeyError
from keycloak_sdk.oidc import OidcEndpoints

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


def _client(server: Any, clock: _FakeClock) -> tuple[AuthClient, str]:
    cfg = KeycloakConfig(
        server_url=server.url, realm="t", client_id="app", client_secret="s3cret", read_timeout=5.0
    )
    endpoints = OidcEndpoints.for_realm(cfg)
    client = AuthClient(cfg, endpoints)
    client._jwks_keys = JwksKeyCache(clock=clock)
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)
    return client, endpoints.issuer


def _token(key: RSAKey, issuer: str) -> str:
    claims = {"iss": issuer, "aud": "app", "sub": key.kid, "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


def test_t1_the_key_set_is_reused_until_300s_and_fetched_exactly_once_after(jwks_server: Any):
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    token = _token(_K1, issuer)
    assert client.validate(token).subject == "k1"
    assert jwks_server.hits == 1

    clock.advance(299)
    assert client.validate(token).subject == "k1"
    assert jwks_server.hits == 1, "a key set 299 s old must be reused without a fetch"

    clock.advance(2)  # t0 + 301
    assert client.validate(token).subject == "k1"
    assert jwks_server.hits == 2, "after 300 s the next validation must fetch exactly once"


def test_t2_an_outage_after_300s_rejects_backs_off_and_recovers(jwks_server: Any):
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    token = _token(_K1, issuer)
    client.validate(token)
    jwks_server.status = 503

    clock.advance(301)
    with pytest.raises(KeycloakTransportError, match="HTTP 503"):
        client.validate(token)
    assert jwks_server.hits == 2, "exactly one fetch attempt — and no fallback to the old keys"

    for _ in range(5):  # 백오프 창(0.2초 · jitter 1.0) 안 — IdP 로 나가지 않고 거부한다
        with pytest.raises(KeycloakTransportError, match="backing off"):
            client.validate(token)
    assert jwks_server.hits == 2

    jwks_server.status = 200
    clock.advance(1)  # 창이 지났다
    assert client.validate(token).subject == "k1"
    assert jwks_server.hits == 3


def test_t3_a_key_the_idp_removed_is_rejected_after_300s(jwks_server: Any):
    clock = _FakeClock()
    jwks_server.body = _keys(_K1, _K2)
    client, issuer = _client(jwks_server, clock)
    client.validate(_token(_K1, issuer))
    jwks_server.body = _keys(_K2)

    clock.advance(301)
    with pytest.raises(TokenKeyError):
        client.validate(_token(_K1, issuer))
    # 나이로 다시 가져온 것 하나 + 미해결 kid 의 강제 재조회 하나(30초 창의 첫 회).
    assert jwks_server.hits == 3

    assert client.validate(_token(_K2, issuer)).subject == "k2"
    assert jwks_server.hits == 3


def test_t4_a_forced_refetch_restarts_the_age(jwks_server: Any):
    clock = _FakeClock()
    jwks_server.body = _keys(_K1)
    client, issuer = _client(jwks_server, clock)
    client.validate(_token(_K1, issuer))
    jwks_server.body = _keys(_K1, _K2)

    clock.advance(100)
    assert client.validate(_token(_K2, issuer)).subject == "k2"  # 미해결 kid → 강제 재조회
    assert jwks_server.hits == 2

    clock.advance(250)  # t0 + 350 — 처음 받은 것으로는 300초를 넘었지만 강제 재조회로부터는 250초다
    assert client.validate(_token(_K1, issuer)).subject == "k1"
    assert jwks_server.hits == 2, "the forced refetch must have restarted the 300 s age"


def test_the_age_counts_from_when_the_fetch_completed(jwks: Any):
    """수명의 시작은 fetch 를 **시작한** 때가 아니라 **끝난** 때다.

    10초 걸린 fetch 의 집합은 시작으로부터 305초에 아직 295초다."""
    clock = _FakeClock()
    cfg = KeycloakConfig(server_url="https://kc.example.com", realm="r", client_id="app")
    endpoints = OidcEndpoints.for_realm(cfg)
    client = AuthClient(cfg, endpoints, openid=MagicMock(spec=KeycloakOpenID))
    client._jwks_keys = JwksKeyCache(clock=clock)

    def slow_fetch(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
        clock.advance(10)
        return {"keys": [_K1.as_dict(private=False)]}

    jwks.side_effect = slow_fetch
    token = _token(_K1, endpoints.issuer)
    client.validate(token)

    clock.advance(295)  # fetch 시작으로부터 305초 · 끝으로부터 295초
    client.validate(token)
    assert jwks.call_count == 1
