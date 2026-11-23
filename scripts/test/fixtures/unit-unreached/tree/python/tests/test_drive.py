"""Unit drive — never an empty code, a blank scope or an item for apply; never calls describe or logout_url."""

import asyncio

from keycloak_sdk.auth_client import AuthClient


def test_drive() -> None:
    c = AuthClient("demo")
    assert c.exchange("abc") == "token-for-abc"
    assert c.scope(" openid ") == "openid"
    assert c.fallback("x") == "x"
    assert c.apply([]) == []
    assert asyncio.run(c.token("abc")) == "token-for-abc"
