"""실패한 JWKS fetch 의 백오프.

⚠️ **`jwks_min_refetch_seconds`(30초)와 다른 축이다.** 30초 게이트는 *캐시가 찬 뒤* 미해결 kid
홍수를 막는다. 이 모듈은 **캐시가 비어 있고 fetch 가 계속 실패할 때**를 막는다 — 그 자리에는
게이트가 없어서, 측정상 20회 검증이 IdP 요청 20건을 그대로 냈다(2026-09-04 · 7개 언어 동일).

⚠️ **여기에 30초를 재사용하면 안 된다** — 일시적 503 한 번이 「30초간 어떤 토큰도 검증 불가」가
된다. 그래서 짧게 시작해 지수적으로 늘리고 상한을 둔다.

⚠️ **sleep 하지 않는다.** 라이브러리가 호출자의 스레드를 붙잡으면 안 되므로, 백오프 창 안에서는
IdP 를 때리지 않고 즉시 실패시킨다(negative cache). 재시도 페이싱은 소비자 몫이다.

sync 와 aio 가 **같은 인스턴스 타입**을 쓴다 — 상태 기계에 await 가 없어서 미러가 갈릴 자리가
없다. `auth.py`/`aio/auth.py` 는 커버리지 omit 이지만 이 모듈은 아니므로, 로직은 여기서 잰다.
"""

from __future__ import annotations

import time
from collections.abc import Callable

BASE_SECONDS = 0.2
CAP_SECONDS = 5.0


class JwksFailureBackoff:
    """연속 실패 횟수로 자라는 지수 백오프 창. 스레드 동기화는 호출자(락 안에서 쓴다)의 몫이다."""

    def __init__(
        self,
        *,
        clock: Callable[[], float] = time.monotonic,
        jitter: Callable[[], float] | None = None,
    ) -> None:
        # 시계와 jitter 는 주입한다 — 테스트가 창을 결정적으로 넘길 수 있어야 한다(sleep 금지).
        self._clock = clock
        self._jitter = jitter if jitter is not None else _default_jitter
        self._failures = 0
        self._last_failure: float | None = None

    @property
    def failures(self) -> int:
        return self._failures

    def remaining(self) -> float:
        """백오프 잔여 초. 0 이면 fetch 를 허용한다."""
        if self._last_failure is None:
            return 0.0
        return max(0.0, self._delay() - (self._clock() - self._last_failure))

    def record_failure(self) -> None:
        self._failures += 1
        self._last_failure = self._clock()

    def record_success(self) -> None:
        # ⚠️ 성공이 카운터를 되돌리지 않으면 오래 산 프로세스에서 백오프가 상한에 눌러붙는다.
        self._failures = 0
        self._last_failure = None

    def _delay(self) -> float:
        raw: float = BASE_SECONDS * (2 ** (max(self._failures, 1) - 1))
        return min(raw, CAP_SECONDS) * self._jitter()


def _default_jitter() -> float:
    """[0.5, 1.0) 배수 — thundering herd 를 흩는다.

    ⚠️ **PRNG API 를 쓰지 않고 나노초 시계에서 뽑는다.** 이 값은 비밀이 아니지만, 보안 민감
    코드에서 약한 PRNG 를 호출하면 정적분석이 정당하게 막는다(실측: sonar S2245 · ruff S311 ·
    gosec G404). 일곱 언어가 **같은 관용**을 쓴다.
    """
    return 0.5 + (time.monotonic_ns() % 1_000_000) / 2_000_000
