"""실패한 JWKS fetch 백오프의 상태 기계.

⚠️ 여기가 콜드 캐시 + IdP 장애 축이다. `jwks_min_refetch_seconds`(30초) 게이트는 *캐시가 찬 뒤*
미해결 kid 홍수만 막는다 — 캐시가 비어 있고 fetch 가 계속 실패하면 그 게이트에 닿지도 못한다.
실측(2026-09-04): 20회 검증 → IdP 요청 **20건**, 7개 언어 동일.

`auth.py`/`aio/auth.py` 는 커버리지 omit(네트워크 경계)이지만 이 모듈은 아니다 — 그래서 상태
기계를 여기서 잰다. 배선은 `test_auth.py`/`aio/test_auth.py` 가 목으로 증명한다.
"""

from __future__ import annotations

import itertools

import pytest

from keycloak_sdk._internal.backoff import (
    BASE_SECONDS,
    CAP_SECONDS,
    JwksFailureBackoff,
    _default_jitter,
)


class FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def _backoff(clock: FakeClock, jitter: float = 1.0) -> JwksFailureBackoff:
    return JwksFailureBackoff(clock=clock, jitter=lambda: jitter)


def test_fresh_backoff_allows_a_fetch():
    assert _backoff(FakeClock()).remaining() == 0.0


def test_failure_opens_a_window_and_blocks_without_touching_the_idp():
    clock = FakeClock()
    b = _backoff(clock)
    b.record_failure()
    assert b.failures == 1
    assert b.remaining() == BASE_SECONDS


# ⚠️ **이 테스트를 지우지 말 것 — 「한 번 실패하면 영원히 차단」도 결함 테스트는 통과한다.**
# 그 동작은 원래 결함보다 나쁘다(IdP 가 복구돼도 SDK 가 영영 못 쓴다).
def test_window_expires_and_allows_a_retry():
    clock = FakeClock()
    b = _backoff(clock)
    b.record_failure()
    clock.advance(BASE_SECONDS)
    assert b.remaining() == 0.0


def test_delay_grows_exponentially_and_is_capped():
    clock = FakeClock()
    b = _backoff(clock)
    seen = []
    for _ in range(8):
        b.record_failure()
        seen.append(b.remaining())
    assert seen[0] == BASE_SECONDS
    assert seen[1] == BASE_SECONDS * 2
    assert seen[2] == BASE_SECONDS * 4
    assert seen[-1] == CAP_SECONDS  # 상한에 눌린다
    assert max(seen) == CAP_SECONDS


# ⚠️ 대조군 — 성공이 카운터를 되돌리지 않으면 오래 산 프로세스에서 백오프가 상한에 눌러붙는다.
def test_success_resets_the_counter_and_the_window():
    clock = FakeClock()
    b = _backoff(clock)
    for _ in range(5):
        b.record_failure()
    assert b.failures == 5
    b.record_success()
    assert b.failures == 0
    assert b.remaining() == 0.0
    # 다음 실패는 상한이 아니라 base 에서 다시 시작한다.
    b.record_failure()
    assert b.remaining() == BASE_SECONDS


def test_jitter_scales_the_window_into_the_half_to_full_band():
    clock = FakeClock()
    b = _backoff(clock, jitter=0.5)
    b.record_failure()
    assert b.remaining() == BASE_SECONDS * 0.5


def test_jitter_is_drawn_once_when_the_failure_is_recorded():
    """등록부 `backoff-jitter-redrawn-per-check` — 배수는 실패를 **기록할 때** 한 번 뽑는다.

    검사마다 뽑으면 같은 실패 하나가 같은 순간에 거부와 통과를 오가고(190ms 에 거부 · 191ms 에
    통과), 창의 끝이 검사마다 움직인다. 뽑을 때마다 다른 배수를 주는 RNG 로 그것을 드러낸다."""
    clock = FakeClock()
    draws = itertools.cycle([0.99, 0.5])
    b = JwksFailureBackoff(clock=clock, jitter=lambda: next(draws))
    b.record_failure()

    at_record = [b.remaining() for _ in range(6)]
    assert len(set(at_record)) == 1, f"같은 순간의 같은 실패가 답을 바꿨다: {at_record}"

    end = clock() + at_record[0]
    clock.advance(at_record[0] / 2)
    ends = [clock() + b.remaining() for _ in range(6)]
    assert ends == [pytest.approx(end)] * 6, "창의 끝이 검사 사이에 움직였다"

    # 다음 실패는 **새로** 뽑는다 — 인스턴스마다 한 번만 뽑는 것과 가른다(창을 흩는 이유다).
    b.record_failure()
    assert b.remaining() == pytest.approx(BASE_SECONDS * 2 * 0.5)


# ⚠️ 지수를 자르지 않으면 1,025 번째 연속 실패부터 `0.2 * 2**1024` 가 float 로 넘친다
# (`OverflowError`) — 창이 상한(5초)이라 실패 하나에 2.5~5초, IdP 가 한 시간쯤 내려가 있으면
# 닿는 수다. 그 뒤로는 fetch 를 다시 하지 않아 IdP 가 돌아와도 회복하지 못했다.
def test_a_long_outage_keeps_the_window_at_the_cap_instead_of_overflowing():
    clock = FakeClock()
    b = _backoff(clock)
    for _ in range(1100):
        b.record_failure()
    assert b.remaining() == CAP_SECONDS


def test_default_jitter_stays_within_the_band():
    # 100회면 밴드를 벗어나는 구현(예: 0..1)이 잡힌다.
    values = [_default_jitter() for _ in range(100)]
    assert all(0.5 <= v < 1.0 for v in values)
    assert len(set(values)) > 1, "jitter 가 상수면 thundering herd 를 흩지 못한다"
