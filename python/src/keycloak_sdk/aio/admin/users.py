"""`AsyncUsersResource` — 사용자 CRUD(async). `KeycloakAdmin`의 `a_*` 메서드를 감싸고
`acall`로 python-keycloak 예외를 SDK 예외로 변환한다. sync `UsersResource`의 async 미러."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import acall


class AsyncUsersResource:
    """사용자 관리(async). `admin`은 `AsyncAdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        return await acall(self._admin.a_create_user(rep))

    async def get(self, user_id: str) -> dict[str, Any] | None:
        """`user_id`로 사용자를 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return await acall(self._admin.a_get_user(user_id))

    async def search(
        self, username: str | None = None, first: int = 0, max: int = 100
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {"first": first, "max": max}
        if username is not None:
            query["username"] = username
        return await acall(self._admin.a_get_users(query))

    async def update(self, user_id: str, rep: dict[str, Any]) -> None:
        await acall(self._admin.a_update_user(user_id, rep))

    async def delete(self, user_id: str) -> None:
        await acall(self._admin.a_delete_user(user_id))
