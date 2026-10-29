"""`UsersResource` — user CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, write_call


class UsersResource:
    """User management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        return write_call(lambda: self._admin.create_user(rep))

    def get(self, user_id: str) -> dict[str, Any] | None:
        """Looks up a user by `user_id`. If it does not exist, `KeycloakNotFoundError`
        propagates (None is not returned)."""
        return call(lambda: self._admin.get_user(user_id))

    def search(
        self, username: str | None = None, first: int = 0, max: int = 100
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {"first": first, "max": max}
        if username is not None:
            query["username"] = username
        return call(lambda: self._admin.get_users(query))

    def update(self, user_id: str, rep: dict[str, Any]) -> None:
        write_call(lambda: self._admin.update_user(user_id, rep))

    def delete(self, user_id: str) -> None:
        write_call(lambda: self._admin.delete_user(user_id))
