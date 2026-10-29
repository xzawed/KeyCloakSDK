"""`AsyncRealmsResource` — realm CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin` and
converts python-keycloak exceptions to SDK exceptions with `acall`. The async mirror of sync
`RealmsResource`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall, awrite_call


class AsyncRealmsResource:
    """Realm management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> None:
        await awrite_call(self._admin.a_create_realm(rep))

    async def get(self, realm_name: str) -> dict[str, Any] | None:
        """Looks up a realm by name. If it does not exist, `KeycloakNotFoundError` propagates
        (None is not returned)."""
        return await acall(self._admin.a_get_realm(realm_name))

    async def list(self) -> list[dict[str, Any]]:
        """Every realm the caller can see. Isomorphic with sync `RealmsResource.list`."""
        return await acall(self._admin.a_get_realms())

    async def update(self, realm_name: str, rep: dict[str, Any]) -> None:
        """Updates the realm, addressed by its current name (path/body kept separate — rename
        possible)."""
        await awrite_call(self._admin.a_update_realm(realm_name, rep))

    async def delete(self, realm_name: str) -> None:
        await awrite_call(self._admin.a_delete_realm(realm_name))
