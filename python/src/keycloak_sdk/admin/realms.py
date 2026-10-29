"""`RealmsResource` — realm CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, write_call


class RealmsResource:
    """Realm management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> None:
        write_call(lambda: self._admin.create_realm(rep))

    def get(self, realm_name: str) -> dict[str, Any] | None:
        """Looks up a realm by name. If it does not exist, `KeycloakNotFoundError` propagates
        (None is not returned)."""
        return call(lambda: self._admin.get_realm(realm_name))

    def list(self) -> list[dict[str, Any]]:
        """Every realm the caller can see. A service account usually sees only its own realm."""
        return call(lambda: self._admin.get_realms())

    def update(self, realm_name: str, rep: dict[str, Any]) -> None:
        """Updates the realm, addressed by its current name. A new name in `rep["realm"]` is a
        rename.

        Do not merge the path (`realm_name`) and the body (`rep`) — merging them turns the
        rename into a silent no-op.
        """
        write_call(lambda: self._admin.update_realm(realm_name, rep))

    def delete(self, realm_name: str) -> None:
        write_call(lambda: self._admin.delete_realm(realm_name))
