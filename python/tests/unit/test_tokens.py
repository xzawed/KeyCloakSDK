import pytest

from keycloak_sdk.exceptions import KeycloakAuthError
from keycloak_sdk.tokens import TokenSet


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
