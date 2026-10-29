"""`AsyncClientsResource` — client CRUD (async). Wraps the `a_*` methods of `KeycloakAdmin` and
converts python-keycloak exceptions to SDK exceptions with `acall`.
The async mirror of sync `ClientsResource`.

`id` is the client's internal UUID, and `client_id` is the OAuth2 clientId string —
`find_by_client_id` handles the string→UUID lookup.
"""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall, awrite_call


class AsyncClientsResource:
    """Client management (async). `admin` is injected as `AsyncAdminClient.raw` (or a test
    mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        return await awrite_call(self._admin.a_create_client(rep))

    async def get(self, id: str) -> dict[str, Any] | None:
        """Looks up a client by its internal UUID (`id`). If it does not exist,
        `KeycloakNotFoundError` propagates (None is not returned)."""
        return await acall(self._admin.a_get_client(id))

    async def find_by_client_id(self, client_id: str) -> str | None:
        """Looks up the internal UUID by the OAuth2 `clientId` string. `None` if there is none."""
        return await acall(self._admin.a_get_client_id(client_id))

    async def update(self, id: str, rep: dict[str, Any]) -> None:
        await awrite_call(self._admin.a_update_client(id, rep))

    async def delete(self, id: str) -> None:
        await awrite_call(self._admin.a_delete_client(id))
