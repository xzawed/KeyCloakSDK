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

MALFORMED = "malformed JWKS from the identity provider: "


def test_keeps_only_the_keys_it_can_read(unreadable_jwk: dict[str, object]) -> None:
    good = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"}).as_dict(private=False)

    key_set = import_usable_keys({"keys": [unreadable_jwk, good, unreadable_jwk]})

    assert [key.kid for key in key_set.keys] == ["k1"]


@pytest.mark.parametrize(
    ("certs", "detail", "caused"),
    [
        ({"keys": []}, "no keys", False),
        (
            {"keys": list(UNREADABLE_JWKS.values())},
            f"no usable keys ({len(UNREADABLE_JWKS)} skipped, first: ",
            True,
        ),
        ({"keys": [None, 1, "x", []]}, "no usable keys (4 skipped, first: ", True),
        ({}, "no 'keys' array", False),
        ({"keys": None}, "no 'keys' array", False),
        ({"keys": {"kty": "RSA"}}, "no 'keys' array", False),
        ([{"kty": "RSA"}], "no 'keys' array", False),
        (None, "no 'keys' array", False),
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
def test_a_set_without_a_usable_key_is_refused_as_an_sdk_error(
    certs: Any, detail: str, caused: bool
) -> None:
    """빈 · 기형 · 전부 못 읽는 키셋은 전부 `TokenValidationError` — 설치하면 검증기가 눈이 먼다.
    전부 못 읽는 키셋만 원인(첫 원소의 예외)을 단다."""
    with pytest.raises(TokenValidationError, match=f"^{re.escape(MALFORMED + detail)}") as caught:
        import_usable_keys(certs)
    assert (caught.value.__cause__ is not None) is caused


def test_the_refusal_names_and_chains_the_first_elements_error() -> None:
    """원인을 잃지 않는다 — 메시지에 첫 원소의 예외를 적고 `__cause__` 로 잇는다
    (go 의 `Cause` 와 같다). ⚠️ stdlib 예외의 **문구**는 단언하지 않는다 — 3.14 가 이 `TypeError`
    의 문구를 바꿨다(CI 3.14 레그 실측). 형과 사슬만 본다."""
    with pytest.raises(TokenValidationError, match=r"first: TypeError: ") as caught:
        import_usable_keys({"keys": [{"kty": ["RSA"]}, {"kid": "nokty"}]})
    assert isinstance(caught.value.__cause__, TypeError)
