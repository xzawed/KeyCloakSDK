"""`AsyncGroupsResource` — 그룹 CRUD(async). `KeycloakAdmin`의 `a_*` 메서드를 감싸고
`acall`로 python-keycloak 예외를 SDK 예외로 변환한다. sync `GroupsResource`의 async 미러."""

from __future__ import annotations

from typing import Any, cast

from keycloak import KeycloakAdmin

from ._translate import acall


class AsyncGroupsResource:
    """그룹 관리(async). `admin`은 `AsyncAdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    async def create(self, rep: dict[str, Any]) -> str:
        # python-keycloak types a_create_group() -> str | None (None only when
        # skip_exists=True and the group already exists; we call with the
        # default skip_exists=False, which raises instead — so this always
        # yields the new group's id in practice).
        return cast(str, await acall(self._admin.a_create_group(rep)))

    async def get(self, group_id: str) -> dict[str, Any] | None:
        """`group_id`로 그룹을 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return await acall(self._admin.a_get_group(group_id))

    async def list(self, first: int = 0, max: int = 100) -> list[dict[str, Any]]:
        return await acall(self._admin.a_get_groups({"first": first, "max": max}))

    async def update(self, group_id: str, rep: dict[str, Any]) -> None:
        """id로 주소를 잡아 갱신한다(경로/body 분리 — rename 가능)."""
        await acall(self._admin.a_update_group(group_id, rep))

    async def delete(self, group_id: str) -> None:
        await acall(self._admin.a_delete_group(group_id))
