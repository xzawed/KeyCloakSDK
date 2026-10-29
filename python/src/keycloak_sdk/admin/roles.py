"""`RolesResource` — realm role CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, write_call


class RolesResource:
    """Realm role management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> None:
        write_call(lambda: self._admin.create_realm_role(rep))

    def get(self, name: str) -> dict[str, Any] | None:
        """Looks up a role by name. If it does not exist, `KeycloakNotFoundError` propagates
        (None is not returned)."""
        return call(lambda: self._admin.get_realm_role(name))

    def list(self) -> list[dict[str, Any]]:
        return call(lambda: self._admin.get_realm_roles())

    def update(self, name: str, rep: dict[str, Any]) -> None:
        """Updates the role, addressed by its current name. A new name in `rep["name"]` is a
        rename.

        Do not merge the path (`name`) and the body (`rep`).
        """
        write_call(lambda: self._admin.update_realm_role(name, rep))

    def delete(self, name: str) -> None:
        write_call(lambda: self._admin.delete_realm_role(name))
