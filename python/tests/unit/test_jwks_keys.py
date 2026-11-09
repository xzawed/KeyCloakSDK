"""`_internal/jwks_keys.py` — JWKS 키를 하나씩 읽고 못 읽는 키는 건너뛴다(RFC 7517 §5).

배선(두 미러가 이 모듈로 검증하는가)은 `test_auth.py` · `aio/test_auth.py` 의
`test_jwks_key_it_cannot_read_is_skipped_not_the_whole_set` 가 잰다. 여기서는 모양별 판정만 본다.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.jwks_keys import import_usable_keys
from keycloak_sdk.exceptions import TokenValidationError
from tests.unit.conftest import UNREADABLE_JWKS


def test_keeps_only_the_keys_it_can_read(unreadable_jwk: dict[str, str]) -> None:
    good = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"}).as_dict(private=False)

    key_set = import_usable_keys({"keys": [unreadable_jwk, good, unreadable_jwk]})

    assert [key.kid for key in key_set.keys] == ["k1"]


@pytest.mark.parametrize(
    ("certs", "detail"),
    [
        ({"keys": []}, "no keys"),
        ({"keys": list(UNREADABLE_JWKS.values())}, "no usable keys (2 unreadable)"),
        ({"keys": [None, 1, "x", []]}, "no usable keys (4 unreadable)"),
        ({}, "no 'keys' array"),
        ({"keys": None}, "no 'keys' array"),
        ({"keys": {"kty": "RSA"}}, "no 'keys' array"),
        ([{"kty": "RSA"}], "no 'keys' array"),
        (None, "no 'keys' array"),
    ],
    ids=[
        "empty",
        "all-unreadable",
        "not-objects",
        "no-keys",
        "keys-null",
        "keys-object",
        "top-level-array",
        "null",
    ],
)
def test_a_set_without_a_usable_key_is_refused_as_an_sdk_error(certs: Any, detail: str) -> None:
    """빈 · 기형 · 전부 못 읽는 키셋은 전부 `TokenValidationError` — 설치하면 검증기가 눈이 먼다."""
    expected = f"malformed JWKS from the identity provider: {detail}"
    with pytest.raises(TokenValidationError, match=f"^{re.escape(expected)}$"):
        import_usable_keys(certs)
