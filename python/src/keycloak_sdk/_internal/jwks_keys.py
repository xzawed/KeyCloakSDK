"""JWKS 문서에서 이 SDK 가 읽을 수 있는 키만 골라 키셋을 만든다 — sync/aio 공용.

⚠️ **키 하나씩 읽고, 못 읽는 키는 건너뛴다**(RFC 7517 §5 — 이해 못 하는 kty ·
빠진 필수 멤버 · 범위 밖 값의 키는 무시한다). joserfc 의 `KeySet.import_key_set` 은
1.7.x 에서 그런 키 하나로 키셋 전체를 거부하고, 1.8.0 도 `InvalidKeyTypeError`(모르는
kty · 객체가 아닌 원소)만 건너뛴다 — 곡선이 범위 밖인 키(P-192) · 기형/빠진 멤버 하나로
전체가 실패해, 같은 키셋의 정상 키로 서명한 토큰까지 거부됐다(등록부
`jwks-unsupported-key-rejects-set`).

⚠️ **어떤 예외든 그 키 하나의 문제다.** joserfc 는 키마다 다른 예외를 던지고 일부는 joserfc
타입도 아닌 stdlib 예외다(`binascii.Error` · `KeyError` · `TypeError` · `ValueError`). 잡는 범위를
좁히면 그 예외가 `keycloak_sdk.exceptions` 를 잡는 소비자를 지나 샌다(§4). 쓸 수 있는 키가 하나도
없는 키셋도 거부하고(첫 원소의 예외를 원인으로 단다), 호출자는 거부된 키셋을 캐시에 넣지 않으므로
이전 키셋이 수명(300초) 안에서 그대로 쓰인다.
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
    if not keys:
        raise TokenValidationError(f"{_MALFORMED}: no keys")
    usable: list[Key] = []
    first: Exception | None = None
    for data in keys:
        try:
            usable.append(JWKRegistry.import_key(data))
        except Exception as exc:  # 그 키 하나의 문제다(위 RFC 7517 §5)
            first = first or exc
    if not usable:
        cause = f"{type(first).__name__}: {first}"
        raise TokenValidationError(
            f"{_MALFORMED}: no usable keys ({len(keys)} unreadable, first: {cause})"
        ) from first
    return KeySet(usable)
