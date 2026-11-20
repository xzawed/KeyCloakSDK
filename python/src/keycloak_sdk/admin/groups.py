"""`GroupsResource` — group CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, create_call, encodable, write_call


class GroupsResource:
    """Group management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        """Creates a group and returns its id — the one the answer's `Location` names, resolved
        against the request URL (the last path segment, in the groups collection)."""
        # python-keycloak's create_group() returns None for an answer without a Location — the
        # facade reads the id from the answer itself (`create_call`), so that is the no-id error.
        encodable(rep)
        return create_call(lambda: self._admin.create_group(rep))

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
        encodable(rep)
        write_call(lambda: self._admin.update_group(group_id, rep))

    def delete(self, group_id: str) -> None:
        write_call(lambda: self._admin.delete_group(group_id))
