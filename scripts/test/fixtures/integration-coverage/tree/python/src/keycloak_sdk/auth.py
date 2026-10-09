"""Fixture boundary module (sync auth)."""

LIMIT = 3


class AuthorizationUrl:
    def __init__(self, url: str) -> None:
        self.url = url

    def __repr__(self) -> str:
        return "AuthorizationUrl(***)"


class AuthClient:
    def __init__(self, client_id: str) -> None:
        self.client_id = client_id

    def token(self) -> str:
        if not self.client_id:
            return "anon"
        return "tok-" + self.client_id

    def logout(self) -> None:
        self.client_id = ""


def helper(x: int) -> int:
    def inner(y: int) -> int:
        return y * 2

    return inner(x) + LIMIT
