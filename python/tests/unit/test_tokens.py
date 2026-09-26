import pytest

from keycloak_sdk.exceptions import KeycloakAuthError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet, _introspection_result


def test_is_expired_respects_skew():
    t = TokenSet("acc", None, None, "Bearer", None, 30.0)
    assert t.is_expired(now=5.0, skew=30.0) is True
    assert t.is_expired(now=5.0, skew=10.0) is False
    assert TokenSet("a", None, None, "Bearer", None, None).is_expired(0.0, 0.0) is True


def test_repr_masks():
    t = TokenSet("supersecret", "refreshsecret", None, "Bearer", None, 0.0)
    r = repr(t)
    assert "supersecret" not in r and "refreshsecret" not in r


def test_from_response():
    t = TokenSet.from_response(
        {"access_token": "a", "expires_in": 300, "token_type": "Bearer"}, issued_at=1000.0
    )
    assert t.access_token == "a" and t.expires_at == 1300.0


def test_from_response_without_expires_in_has_no_expires_at():
    t = TokenSet.from_response({"access_token": "a", "token_type": "Bearer"}, issued_at=1000.0)
    assert t.expires_at is None


@pytest.mark.parametrize("bad", [12345, None, {"a": 1}, [], ""])
def test_non_string_access_token_is_rejected(bad: object) -> None:
    """⚠️ **존재 검사는 타입 검사가 아니다.**

    예전에는 `data["access_token"]` 이라 숫자·객체가 그대로 `TokenSet.access_token` 에
    들어갔다(타입 힌트는 `str` 인데도). 소비자는 그것을 Bearer 로 실어 보내고 매번 401 을
    받는다 — 조용한 반복 실패다.

    ⚠️ 그리고 **키가 없으면 raw `KeyError`** 가 샜다. `_wrap` 은 상류 오류만 번역하고
    `from_response` 는 그 밖이라, `keycloak_sdk.exceptions` 를 잡는 소비자가 아무것도
    잡지 못했다(§4 위반).

    아홉 언어 전수 측정에서 **다섯이 이 부류**였다(java·kotlin·node·go 는 이미 거부).
    """
    with pytest.raises(KeycloakAuthError):
        TokenSet.from_response({"access_token": bad, "token_type": "Bearer"}, issued_at=0.0)


def test_missing_access_token_is_an_sdk_error() -> None:
    """§4 — raw `KeyError` 가 아니라 SDK 타입으로 나온다."""
    with pytest.raises(KeycloakAuthError):
        TokenSet.from_response({"token_type": "Bearer"}, issued_at=0.0)


_CANARY = "VX8-token-shaped-canary"


@pytest.mark.parametrize(
    ("name", "bad"),
    [
        ("refresh_token", 12345),
        ("id_token", {"echo": _CANARY}),
        ("token_type", {"echo": _CANARY}),
        ("scope", [_CANARY]),
    ],
)
def test_wrong_typed_field_is_rejected_by_name_only(name: str, bad: object) -> None:
    """존재 검사는 타입 검사가 아니다 — 나머지 필드도. 예전에는 객체 모양 `token_type` 이 그대로
    들어와 `repr(TokenSet)` 이 그 안의 토큰을 찍었다. 거부 메시지에는 **필드 이름만** 싣는다."""
    with pytest.raises(KeycloakAuthError) as excinfo:
        TokenSet.from_response({"access_token": "a", name: bad}, issued_at=0.0)

    assert str(excinfo.value) == f"token response has an invalid {name}"
    assert excinfo.value.__cause__ is None
    assert excinfo.value.__context__ is None


def test_absent_or_null_token_type_defaults_to_bearer() -> None:
    absent = TokenSet.from_response({"access_token": "a"}, issued_at=0.0)
    null = TokenSet.from_response({"access_token": "a", "token_type": None}, issued_at=0.0)
    assert absent.token_type == null.token_type == "Bearer"


def test_numeric_string_expires_in_is_still_accepted() -> None:
    """일부 IdP 는 `expires_in` 을 문자열로 준다 — 예전처럼 받는다."""
    t = TokenSet.from_response({"access_token": "a", "expires_in": "300"}, issued_at=1000.0)
    assert t.expires_at == 1300.0


@pytest.mark.parametrize("bad", [_CANARY, {"echo": _CANARY}, [], "inf", "nan", float("inf")])
def test_unusable_expires_in_is_rejected_without_quoting_it(bad: object) -> None:
    """⚠️ `float()` 의 `ValueError` 는 입력을 인용한다 — 예전에는 그 raw `ValueError` 가 그대로 샜다.
    거부는 `except` 밖이라 그 예외가 `__context__` 로도 매달리지 않는다. 무한대·NaN 은 `is_expired`
    를 영원히 거짓으로 만든다."""
    with pytest.raises(KeycloakAuthError) as excinfo:
        TokenSet.from_response({"access_token": "a", "expires_in": bad}, issued_at=0.0)

    assert str(excinfo.value) == "token response has an invalid expires_in"
    assert excinfo.value.__context__ is None


# --- introspection (RFC 7662) --------------------------------------------------------------


def test_introspection_maps_fields() -> None:
    result = _introspection_result({"active": True, "username": "svc", "client_id": "app"})
    assert result == IntrospectionResult(active=True, username="svc", client_id="app")


@pytest.mark.parametrize("data", [{}, {"active": None}, {"active": False, "username": None}])
def test_absent_or_null_active_is_inactive(data: dict[str, object]) -> None:
    """예전과 같다 — 없거나 null 이면 비활성(fail-closed)."""
    assert _introspection_result(data) == IntrospectionResult(False, None, None)


@pytest.mark.parametrize("bad", ["false", "true", 1, 0, [], {"v": True}])
def test_non_boolean_active_is_rejected(bad: object) -> None:
    """⚠️ 예전 `bool(response.get("active"))` 는 문자열 `"false"` 를 **활성**으로 읽었다(fail-open).
    RFC 7662 의 `active` 는 JSON boolean 이다 — 그 밖의 모양은 추측하지 않고 거부한다."""
    with pytest.raises(KeycloakAuthError) as excinfo:
        _introspection_result({"active": bad})

    assert str(excinfo.value) == "introspection response has an invalid active"


@pytest.mark.parametrize(
    ("name", "bad"), [("username", {"echo": _CANARY}), ("client_id", [_CANARY])]
)
def test_introspection_field_of_wrong_type_is_rejected_by_name_only(name: str, bad: object) -> None:
    """객체 모양 `username`·`client_id` 는 기본 dataclass repr 이 그 안의 토큰을 찍었다(Grok 레그,
    실측). 거부 메시지에는 필드 이름만 싣는다."""
    with pytest.raises(KeycloakAuthError) as excinfo:
        _introspection_result({"active": True, name: bad})

    assert str(excinfo.value) == f"introspection response has an invalid {name}"
    assert _CANARY not in repr(excinfo.value)
