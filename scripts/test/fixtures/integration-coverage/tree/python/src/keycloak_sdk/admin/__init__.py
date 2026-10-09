"""Fixture boundary module (admin facade)."""


class AdminClient:
    def users(self) -> str:
        return "users"

    @property
    def clients(self) -> str:
        return "clients"
