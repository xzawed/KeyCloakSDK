"""`GroupsResource` — 그룹 CRUD. `KeycloakAdmin`을 감싸고 `_translate.call`로
python-keycloak 예외를 SDK 예외로 변환한다."""
from __future__ import annotations

from typing import Any, cast

from keycloak import KeycloakAdmin

from ._translate import call


class GroupsResource:
    """그룹 관리. `admin`은 `AdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        # python-keycloak types create_group() -> str | None (None only when
        # skip_exists=True and the group already exists; we call with the
        # default skip_exists=False, which raises instead — so this always
        # yields the new group's id in practice).
        return cast(str, call(lambda: self._admin.create_group(rep)))

    def get(self, group_id: str) -> dict[str, Any] | None:
        """`group_id`로 그룹을 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return call(lambda: self._admin.get_group(group_id))

    def list(self, first: int = 0, max: int = 100) -> list[dict[str, Any]]:
        return call(lambda: self._admin.get_groups({"first": first, "max": max}))

    def delete(self, group_id: str) -> None:
        call(lambda: self._admin.delete_group(group_id))
