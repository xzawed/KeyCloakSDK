"""`JwksKeyCache` 의 상태 기계 — 키 집합의 나이(300초).

배선은 `test_jwks_max_age.py`(sync·aio)가 증명한다. `auth.py`/`aio/auth.py` 는 커버리지
omit 이지만 이 모듈은 아니라서 경계를 여기서 잰다(`test_backoff.py` 와 같은 꼴).
"""

from __future__ import annotations

import time

from joserfc.jwk import KeySet, RSAKey

from keycloak_sdk._internal.jwks_cache import JWKS_MAX_AGE_SECONDS, JwksKeyCache

_KEYS = KeySet([RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})])


class FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def test_the_max_age_is_300_seconds():
    assert JWKS_MAX_AGE_SECONDS == 300


def test_an_empty_cache_is_cold():
    assert JwksKeyCache(clock=FakeClock()).fresh() is None


# ⚠️ 경계 — 「그 나이에 닿으면」 콜드다(`>=`). 300 에서 아직 쓰면 규칙보다 한 순간 길다.
def test_a_stored_set_is_fresh_below_300s_and_cold_at_300s():
    clock = FakeClock()
    cache = JwksKeyCache(clock=clock)
    cache.store(_KEYS)
    clock.advance(299.999)
    assert cache.fresh() is _KEYS
    clock.advance(0.001)
    assert cache.fresh() is None


def test_storing_again_restarts_the_age():
    clock = FakeClock()
    cache = JwksKeyCache(clock=clock)
    cache.store(_KEYS)
    clock.advance(200)
    replacement = KeySet([RSAKey.generate_key(2048, {"kid": "k2", "use": "sig"})])
    cache.store(replacement)
    clock.advance(200)  # 처음 것으로부터 400초 · 바꾼 것으로부터 200초
    assert cache.fresh() is replacement


def test_the_default_clock_is_monotonic():
    # 벽시계(`time.time`)면 시계를 뒤로 돌린 만큼 낡은 집합이 젊어진다.
    assert JwksKeyCache()._clock is time.monotonic
