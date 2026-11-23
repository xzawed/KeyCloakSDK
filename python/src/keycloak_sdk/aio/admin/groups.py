"""`AsyncGroupsResource` — group CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin` and
converts python-keycloak exceptions to SDK exceptions with `acall`. The async mirror of sync
`GroupsResource`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ...admin._translate import encodable
from ._translate import acall, acreate_call, awrite_call


class AsyncGroupsResource:
    """Group management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        """Creates a group and returns its id — the one the answer's `Location` names, resolved
        against the request URL (the last path segment, in the groups collection). Raises
        `KeycloakTransportError` when it names none."""
        # python-keycloak's a_create_group() returns None for an answer without a Location — the
        # facade reads the id from the answer itself (`acreate_call`), so that is the no-id error.
        encodable(rep)
        return await acreate_call(self._admin.a_create_group(rep))

    async def get(self, group_id: str) -> dict[str, Any] | None:
        """Looks up a group by `group_id`. If it does not exist, `KeycloakNotFoundError`
        propagates (None is not returned)."""
        return await acall(self._admin.a_get_group(group_id))

    async def list(self, first: int = 0, max: int = 100) -> list[dict[str, Any]]:
        return await acall(self._admin.a_get_groups({"first": first, "max": max}))

    async def update(self, group_id: str, rep: dict[str, Any]) -> None:
        """Updates the group, addressed by id (path/body kept separate — rename possible)."""
        encodable(rep)
        await awrite_call(self._admin.a_update_group(group_id, rep))

    async def delete(self, group_id: str) -> None:
        await awrite_call(self._admin.a_delete_group(group_id))
