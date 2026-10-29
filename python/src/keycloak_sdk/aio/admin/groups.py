"""`AsyncGroupsResource` — group CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin` and
converts python-keycloak exceptions to SDK exceptions with `acall`. The async mirror of sync
`GroupsResource`."""

from __future__ import annotations

from typing import Any, cast

from keycloak import KeycloakAdmin

from ._translate import acall, awrite_call


class AsyncGroupsResource:
    """Group management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        # python-keycloak types a_create_group() -> str | None (None only when
        # skip_exists=True and the group already exists; we call with the
        # default skip_exists=False, which raises instead — so this always
        # yields the new group's id in practice).
        return cast(str, await awrite_call(self._admin.a_create_group(rep)))

    async def get(self, group_id: str) -> dict[str, Any] | None:
        """Looks up a group by `group_id`. If it does not exist, `KeycloakNotFoundError`
        propagates (None is not returned)."""
        return await acall(self._admin.a_get_group(group_id))

    async def list(self, first: int = 0, max: int = 100) -> list[dict[str, Any]]:
        return await acall(self._admin.a_get_groups({"first": first, "max": max}))

    async def update(self, group_id: str, rep: dict[str, Any]) -> None:
        """Updates the group, addressed by id (path/body kept separate — rename possible)."""
        await awrite_call(self._admin.a_update_group(group_id, rep))

    async def delete(self, group_id: str) -> None:
        await awrite_call(self._admin.a_delete_group(group_id))
