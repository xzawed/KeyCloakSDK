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
