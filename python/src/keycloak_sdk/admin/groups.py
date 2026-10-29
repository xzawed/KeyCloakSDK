"""`GroupsResource` — group CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any, cast

from keycloak import KeycloakAdmin

from ._translate import call, write_call


class GroupsResource:
    """Group management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        # python-keycloak types create_group() -> str | None (None only when
        # skip_exists=True and the group already exists; we call with the
        # default skip_exists=False, which raises instead — so this always
        # yields the new group's id in practice).
        return cast(str, write_call(lambda: self._admin.create_group(rep)))

    def get(self, group_id: str) -> dict[str, Any] | None:
        """Looks up a group by `group_id`. If it does not exist, `KeycloakNotFoundError`
        propagates (None is not returned)."""
        return call(lambda: self._admin.get_group(group_id))

    def list(self, first: int = 0, max: int = 100) -> list[dict[str, Any]]:
        return call(lambda: self._admin.get_groups({"first": first, "max": max}))

    def update(self, group_id: str, rep: dict[str, Any]) -> None:
        """Updates the group, addressed by id. A new name in `rep["name"]` is a rename.

        Do not merge the path (`group_id`) and the body (`rep`).
        """
        write_call(lambda: self._admin.update_group(group_id, rep))

    def delete(self, group_id: str) -> None:
        write_call(lambda: self._admin.delete_group(group_id))
