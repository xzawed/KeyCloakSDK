"""Fixture boundary module — pyproject's omit takes it out of the unit gate, so only the ledger measures its unit reach."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable

LIMIT = 3


class AuthClient:
    def __init__(self, realm: str) -> None:
        self.realm = realm

    def exchange(self, code: str) -> str:
        if not code:
            raise ValueError("empty code")
        return f"token-for-{code}"

    def scope(self, value: str) -> str:
        if value:
            value = value.strip()
        return value

    def fallback(self, value: str) -> str:
        return value if value else "anon"

    def apply(self, items: Iterable[int]) -> list[int]:
        def one(x: int) -> int:
            if x < 0:
                raise ValueError("negative")
            return x * LIMIT

        return [one(i) for i in items]

    async def token(self, code: str) -> str:
        if not code:
            return ""
        return self.exchange(code)

    def describe(self) -> str:
        return f"AuthClient({self.realm})"

    def logout_url(self) -> str:
        return f"/realms/{self.realm}/logout"
