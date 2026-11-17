"""인가 요청의 redirect_uri — RFC 6749 §3.1.2 가 금하는 값은 URL 에 싣지 않는다.

등록부 `authz-request-redirect-unvalidated`. 예전에는 sync·aio 의 `authorization_url` 이 어떤
문자열이든 그대로 실었다(`cb` · `not a url` · `https://app/cb#f`). 규칙은 순서대로 셋이다.

- R1 절대 URI: scheme 과 `:` 로 시작한다. 문자열이 아닌 값도 R1 이다.
- R2 fragment 없음: `#` 가 어디에도 없다. 빈 fragment(`https://app/cb#`)도 fragment 다.
- R3 Keycloak 이 읽는 URI: 서버는 `java.net.URI.create` 가 던지는 값을 거부한다(RFC 3986 §2).

위반은 `KeycloakConfigError` 이고 메시지는 입력을 인용하지 않는다. 받은 값은 고쳐 쓰지 않는다 —
교환이 같은 문자열을 그대로 보낸다(고쳐 쓰면 두 요청이 갈린다 — #1133 의 결함 부류).
"""

from __future__ import annotations

from collections.abc import Callable
from unittest.mock import MagicMock
from urllib.parse import parse_qs, urlsplit

import pytest
from keycloak import KeycloakOpenID

from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthClient, AuthorizationUrl
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakConfigError
from keycloak_sdk.oidc import OidcEndpoints

NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"
FRAGMENT = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"
NOT_VALID = "invalid redirect_uri: not a valid URI (RFC 3986 §2)"

FACADES = ["sync", "aio"]
_MODULE = {"sync": "keycloak_sdk.auth", "aio": "keycloak_sdk.aio.auth"}
_CONFIG = KeycloakConfig(
    server_url="https://kc.example.com", realm="r", client_id="app", client_secret="s3cret"
)

#: R3 의 글자 — U+0000-U+0020, U+007F-U+00A0, 그리고 아홉 개. 33 + 34 + 9.
R3_CHARS = [chr(c) for c in (*range(0x21), *range(0x7F, 0xA1))] + list('"<>\\^`{|}')

Build = Callable[[str], AuthorizationUrl]


def _authorization_url(facade: str) -> Build:
    """그 미러의 공개 `authorization_url` — 조립은 네트워크가 없다(openid 는 손대지 않는다)."""
    endpoints = OidcEndpoints.for_realm(_CONFIG)
    openid = MagicMock(spec=KeycloakOpenID)
    if facade == "sync":
        return AuthClient(_CONFIG, endpoints, openid=openid).authorization_url
    return AsyncAuthClient(_CONFIG, endpoints, openid=openid).authorization_url


def _refusal(build: Build, value: object) -> str:
    with pytest.raises(KeycloakConfigError) as excinfo:
        build(value)  # type: ignore[arg-type]
    return str(excinfo.value)


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize("value", ["", "cb", "/cb", "//app/cb", "not a url", "cb#f"])
def test_a_value_that_is_not_an_absolute_uri_is_refused(facade: str, value: str) -> None:
    """`cb#f` 는 순서의 증명이다 — R1 이 R2 보다 앞이다."""
    assert _refusal(_authorization_url(facade), value) == NOT_ABSOLUTE


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize("value", [None, 42, b"https://app/cb"])
def test_a_value_that_is_not_a_string_is_not_an_absolute_uri(facade: str, value: object) -> None:
    """서명은 `str` 이지만 런타임에는 무엇이든 온다.

    예전에는 `None` 이 문자열 "None" 으로, `42` 가 "42" 로 실렸다(실측)."""
    assert _refusal(_authorization_url(facade), value) == NOT_ABSOLUTE


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize("value", ["https://app/cb#", "https://app/cb#f", "https://app/c b#f"])
def test_a_fragment_is_refused(facade: str, value: str) -> None:
    """`https://app/c b#f` 는 순서의 증명이다 — R2 가 R3 보다 앞이다."""
    assert _refusal(_authorization_url(facade), value) == FRAGMENT


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize(
    "value",
    [
        "https://app/c b",
        "https://app/cb\n",
        "https://app/c\\b",  # 역슬래시 하나
        "https://app/c%zz",
        "https://app/c\xa0b",  # NBSP
        "https://app/c%2",  # 끝에서 잘린 퍼센트 인코딩
        "https://app/c%",
        "https://app/c%g0",
    ],
)
def test_a_value_keycloak_cannot_parse_is_refused(facade: str, value: str) -> None:
    assert _refusal(_authorization_url(facade), value) == NOT_VALID


@pytest.mark.parametrize("facade", FACADES)
def test_every_character_keycloak_refuses_is_refused(facade: str) -> None:
    """R3 의 글자 전부를 하나씩 — 범위의 양 끝(U+0020 · U+007F · U+00A0)이 빠지지 않게."""
    assert len(R3_CHARS) == 76  # 빈 집합이면 아래 단언이 공허하게 통과한다
    build = _authorization_url(facade)
    missed: list[str] = []
    for ch in R3_CHARS:
        try:
            build(f"https://app/c{ch}b")
        except KeycloakConfigError as exc:
            if str(exc) != NOT_VALID:
                missed.append(f"U+{ord(ch):04X}: {exc}")
        else:
            missed.append(f"U+{ord(ch):04X}: accepted")
    assert missed == []


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("cb-CANARY-7d1f", NOT_ABSOLUTE),
        ("https://app/CANARY#f", FRAGMENT),
        ("https://app/CANARY b", NOT_VALID),
    ],
)
def test_the_message_does_not_quote_the_value(facade: str, value: str, message: str) -> None:
    with pytest.raises(KeycloakConfigError) as excinfo:
        _authorization_url(facade)(value)
    assert str(excinfo.value) == message
    assert "CANARY" not in str(excinfo.value)
    assert "CANARY" not in repr(excinfo.value)


@pytest.mark.parametrize("facade", FACADES)
@pytest.mark.parametrize(
    "value",
    [
        "https://app/cb",
        "https://app/cb?x=1",
        "myapp:/cb",
        "com.example.app:/oauth2redirect",
        "HTTP://LOCALHOST/cb",
        "https://app/c%20b",
        "https://app/c\xfcb",  # u-umlaut
        "https://app/cb?x=[1]",
        "https://app/c'b",
        "https://app/c+*!b",
        "https://app/c~b",  # U+007E — R3 범위 바로 앞
        "https://app/c\xa1b",  # U+00A1 — R3 범위 바로 뒤
        "https://app/c%2Fb",
    ],
)
def test_an_absolute_uri_is_carried_exactly_as_given(facade: str, value: str) -> None:
    """검사는 고쳐 쓰지 않는다 — URL 의 redirect_uri 를 풀면 넘긴 문자열 그대로다."""
    result = _authorization_url(facade)(value)
    assert parse_qs(urlsplit(result.url).query)["redirect_uri"] == [value]


@pytest.mark.parametrize("facade", FACADES)
def test_the_check_runs_before_any_value_is_generated(
    monkeypatch: pytest.MonkeyPatch, facade: str
) -> None:
    """거부는 PKCE·state·nonce 를 만들기 전이다 — 첫 생성 단계가 불리면 이 테스트가 운다."""

    def generated() -> tuple[str, str]:
        raise AssertionError("PKCE was generated before the redirect_uri check")

    monkeypatch.setattr(f"{_MODULE[facade]}._generate_pkce_pair", generated)
    assert _refusal(_authorization_url(facade), "cb") == NOT_ABSOLUTE
