"""JWKS 문서에서 이 SDK 가 읽을 수 있는 키만 골라 키셋을 만든다 — sync/aio 공용.

⚠️ **키 하나씩 읽고, 못 읽는 키는 건너뛴다**(RFC 7517 §5 — 이해 못 하는 kty ·
빠진 필수 멤버 · 범위 밖 값의 키는 무시한다). joserfc 의 `KeySet.import_key_set` 은
1.7.x 에서 그런 키 하나로 키셋 전체를 거부하고, 1.8.0 도 모르는 kty 만 건너뛴다 —
곡선이 범위 밖인 키(P-192)는 날것의 `KeyError` 로 전체가 실패해, 같은 키셋의 정상
키로 서명한 토큰까지 거부됐다(등록부 `jwks-unsupported-key-rejects-set`).

⚠️ **여기서 나가는 오류는 전부 `TokenValidationError` 다(§4).** joserfc 는 기형 키에서
joserfc 타입도 아닌 stdlib 예외(`binascii.Error` · `KeyError`)를 던진다 — 그대로 두면
`keycloak_sdk.exceptions` 를 잡는 소비자가 아무것도 잡지 못한다. 쓸 수 있는 키가 하나도
없는 키셋도 거부한다 — 설치하면 검증기가 눈이 멀고, 호출자는 거부된 키셋을 캐시에 넣지
않으므로 이전 키셋이 수명(300초) 안에서 그대로 쓰인다.
"""

from __future__ import annotations

from typing import Any

from joserfc.jwk import JWKRegistry, Key, KeySet

from ..exceptions import TokenValidationError

_MALFORMED = "malformed JWKS from the identity provider"


def import_usable_keys(certs: Any) -> KeySet:
    """`{"keys": [...]}` 에서 읽을 수 있는 키만 담은 키셋. 하나도 없으면 `TokenValidationError`."""
    keys = certs.get("keys") if isinstance(certs, dict) else None
    if not isinstance(keys, list):
        raise TokenValidationError(f"{_MALFORMED}: no 'keys' array")
    usable = [key for key in map(_import_or_none, keys) if key is not None]
    if not usable:
        detail = f"no usable keys ({len(keys)} unreadable)" if keys else "no keys"
        raise TokenValidationError(f"{_MALFORMED}: {detail}")
    return KeySet(usable)


def _import_or_none(data: Any) -> Key | None:
    """키 하나 — 읽지 못하면 None. 어떤 예외든 그 키 하나의 문제다(위 RFC 7517 §5)."""
    try:
        return JWKRegistry.import_key(data)
    except Exception:
        return None
