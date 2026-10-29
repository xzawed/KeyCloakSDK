"""`AsyncUsersResource` — user CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin` and
converts python-keycloak exceptions to SDK exceptions with `acall`. The async mirror of sync
`UsersResource`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall, awrite_call


class AsyncUsersResource:
    """User management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        return await awrite_call(self._admin.a_create_user(rep))

    async def get(self, user_id: str) -> dict[str, Any] | None:
        """Looks up a user by `user_id`. If it does not exist, `KeycloakNotFoundError`
        propagates (None is not returned)."""
        return await acall(self._admin.a_get_user(user_id))

    async def search(
        self, username: str | None = None, first: int = 0, max: int = 100
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {"first": first, "max": max}
        if username is not None:
            query["username"] = username
        return await acall(self._admin.a_get_users(query))

    async def update(self, user_id: str, rep: dict[str, Any]) -> None:
        await awrite_call(self._admin.a_update_user(user_id, rep))

    async def delete(self, user_id: str) -> None:
        await awrite_call(self._admin.a_delete_user(user_id))
