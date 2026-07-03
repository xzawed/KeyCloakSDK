"""`AsyncRolesResource` — realm 역할 CRUD(async). `KeycloakAdmin`의 `a_*` 메서드를
감싸고 `acall`로 python-keycloak 예외를 SDK 예외로 변환한다.
sync `RolesResource`의 async 미러."""
from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall


class AsyncRolesResource:
    """realm 역할 관리(async). `admin`은 `AsyncAdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> None:
        await acall(self._admin.a_create_realm_role(rep))

    async def get(self, name: str) -> dict[str, Any] | None:
        """역할 이름으로 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return await acall(self._admin.a_get_realm_role(name))

    async def list(self) -> list[dict[str, Any]]:
        return await acall(self._admin.a_get_realm_roles())

    async def delete(self, name: str) -> None:
        await acall(self._admin.a_delete_realm_role(name))
