"""`AsyncRealmsResource` — realm CRUD(async). `KeycloakAdmin`의 `a_*` 메서드를 감싸고
`acall`로 python-keycloak 예외를 SDK 예외로 변환한다. sync `RealmsResource`의 async 미러."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall


class AsyncRealmsResource:
    """realm 관리(async). `admin`은 `AsyncAdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> None:
        await acall(self._admin.a_create_realm(rep))

    async def get(self, realm_name: str) -> dict[str, Any] | None:
        """realm 이름으로 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return await acall(self._admin.a_get_realm(realm_name))

    async def list(self) -> list[dict[str, Any]]:
        """호출자가 볼 수 있는 realm 전부. sync `RealmsResource.list`와 동형."""
        return await acall(self._admin.a_get_realms())

    async def update(self, realm_name: str, rep: dict[str, Any]) -> None:
        """현재 이름으로 주소를 잡아 갱신한다(경로/body 분리 — rename 가능)."""
        await acall(self._admin.a_update_realm(realm_name, rep))

    async def delete(self, realm_name: str) -> None:
        await acall(self._admin.a_delete_realm(realm_name))
