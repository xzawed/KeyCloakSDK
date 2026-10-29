"""`ClientsResource` — client CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`.

`id` is the client's internal UUID (identical to python-keycloak's `client_id` parameter name,
but actually a UUID), and `client_id` is the OAuth2 clientId string —
`find_by_client_id` handles the string→UUID lookup.
"""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, write_call


class ClientsResource:
    """Client management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        return write_call(lambda: self._admin.create_client(rep))

    def get(self, id: str) -> dict[str, Any] | None:
        """Looks up a client by its internal UUID (`id`). If it does not exist,
        `KeycloakNotFoundError` propagates (None is not returned)."""
        return call(lambda: self._admin.get_client(id))

    def find_by_client_id(self, client_id: str) -> str | None:
        """Looks up the internal UUID by the OAuth2 `clientId` string. `None` if there is none."""
        return call(lambda: self._admin.get_client_id(client_id))

    def update(self, id: str, rep: dict[str, Any]) -> None:
        write_call(lambda: self._admin.update_client(id, rep))

    def delete(self, id: str) -> None:
        write_call(lambda: self._admin.delete_client(id))
