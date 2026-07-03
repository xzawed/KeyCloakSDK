"""`AsyncClientsResource` — 클라이언트 CRUD(async). `KeycloakAdmin`의 `a_*` 메서드를
감싸고 `acall`로 python-keycloak 예외를 SDK 예외로 변환한다.
sync `ClientsResource`의 async 미러.

`id`는 클라이언트의 내부 UUID, `client_id`는 OAuth2 clientId 문자열이다 —
`find_by_client_id`가 문자열→UUID 조회를 담당한다.
"""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall


class AsyncClientsResource:
    """클라이언트 관리(async). `admin`은 `AsyncAdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        return await acall(self._admin.a_create_client(rep))

    async def get(self, id: str) -> dict[str, Any] | None:
        """내부 UUID(`id`)로 클라이언트를 조회한다. 존재하지 않으면
        `KeycloakNotFoundError`가 전파된다(None을 반환하지 않음)."""
        return await acall(self._admin.a_get_client(id))

    async def find_by_client_id(self, client_id: str) -> str | None:
        """OAuth2 `clientId` 문자열로 내부 UUID를 조회한다. 없으면 `None`."""
        return await acall(self._admin.a_get_client_id(client_id))

    async def update(self, id: str, rep: dict[str, Any]) -> None:
        await acall(self._admin.a_update_client(id, rep))

    async def delete(self, id: str) -> None:
        await acall(self._admin.a_delete_client(id))
