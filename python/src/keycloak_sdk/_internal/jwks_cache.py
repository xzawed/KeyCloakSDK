"""캐시한 JWKS 키 집합과 그 나이 — fetch 가 끝난 때부터 `JWKS_MAX_AGE_SECONDS` 동안만 쓴다.

⚠️ **아홉 언어가 함께 움직이는 값이다**(등록부 `jwks-cache-lifetime-divergent`,
판정 2026-10-29). 그 나이에 닿은 집합은 **없는 것과 같다** — 다음 검증은 콜드 캐시와
똑같이(같은 단일 비행 · 같은 실패 백오프) 다시 가져오고, 그 fetch 가 실패하면 검증이
실패한다. ⚠️ **낡은 집합으로 물러서지 않는다** — IdP 장애 중에도. 그래서 읽는 길이
`fresh()` 하나다: 나이를 보지 않고 키 집합에 닿는 길을 남기지 않는다.

강제(미해결 kid) 재조회의 성공도 `store()` 로 집합을 바꾸고 나이를 다시 센다. 30초 강제
재조회 창은 그대로다(`.claude/rules/security.md`) — 그 창은 나이가 남은 집합에서만
걸린다(`fresh()` 가 `None` 이면 콜드 경로다).

sync 와 aio 가 **같은 타입**을 쓴다(`backoff.py` 와 같은 이유 — 상태 기계에 await 가 없다).
`auth.py`/`aio/auth.py` 는 커버리지 omit 이지만 이 모듈은 아니므로, 로직은 여기서 잰다.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from joserfc.jwk import KeySet

#: 성공한 JWKS fetch 가 끝난 때부터 그 키 집합을 쓰는 최대 초(아홉 언어 공통).
JWKS_MAX_AGE_SECONDS = 300


class JwksKeyCache:
    """키 집합 하나와 그것을 저장한 시각. 쓰기의 동기화는 호출자(락 안에서 쓴다)의 몫이다."""

    def __init__(self, *, clock: Callable[[], float] = time.monotonic) -> None:
        # 시계는 주입한다 — 테스트가 300초를 sleep 없이 넘긴다(`backoff.py` 와 같은 이음매).
        # 기본은 monotonic 이다 — 벽시계를 뒤로 돌리면 낡은 집합이 젊어진다.
        self._clock = clock
        # 집합과 시각을 한 튜플로 둔다 — 락 밖 빠른 경로가 한 번 읽어 둘이 갈리지 않는다.
        self._entry: tuple[KeySet, float] | None = None

    def fresh(self) -> KeySet | None:
        """저장한 지 `JWKS_MAX_AGE_SECONDS` 가 안 된 키 집합, 아니면 `None`(= 콜드 캐시)."""
        entry = self._entry
        if entry is None or self._clock() - entry[1] >= JWKS_MAX_AGE_SECONDS:
            return None
        return entry[0]

    def store(self, key_set: KeySet) -> None:
        """fetch 가 **끝난** 지금부터 나이를 센다."""
        self._entry = (key_set, self._clock())
