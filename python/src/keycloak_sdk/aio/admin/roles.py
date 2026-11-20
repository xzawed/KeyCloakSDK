"""`AsyncRolesResource` — realm role CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin`
and converts python-keycloak exceptions to SDK exceptions with `acall`.
The async mirror of sync `RolesResource`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ...admin._translate import encodable
from ._translate import acall, acreate_call, awrite_call


class AsyncRolesResource:
    """Realm role management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> None:
        """Creates a realm role. python-keycloak reads the answer's `Location`, so a create whose
        answer names no role in the roles collection fails as the id-returning creates do."""
        encodable(rep)
        await acreate_call(self._admin.a_create_realm_role(rep))

    async def get(self, name: str) -> dict[str, Any] | None:
        """Looks up a role by name. If it does not exist, `KeycloakNotFoundError` propagates
        (None is not returned)."""
        return await acall(self._admin.a_get_realm_role(name))

    async def list(self) -> list[dict[str, Any]]:
        return await acall(self._admin.a_get_realm_roles())

    async def update(self, name: str, rep: dict[str, Any]) -> None:
        """Updates the role, addressed by its current name (path/body kept separate — rename
        possible)."""
        encodable(rep)
        await awrite_call(self._admin.a_update_realm_role(name, rep))

    async def delete(self, name: str) -> None:
        await awrite_call(self._admin.a_delete_realm_role(name))
