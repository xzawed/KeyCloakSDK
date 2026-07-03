"""`UsersResource` — 사용자 CRUD. `KeycloakAdmin`을 감싸고 `_translate.call`로
python-keycloak 예외를 SDK 예외로 변환한다."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call


class UsersResource:
    """사용자 관리. `admin`은 `AdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        return call(lambda: self._admin.create_user(rep))

    def get(self, user_id: str) -> dict[str, Any] | None:
        """`user_id`로 사용자를 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return call(lambda: self._admin.get_user(user_id))

    def search(
        self, username: str | None = None, first: int = 0, max: int = 100
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {"first": first, "max": max}
        if username is not None:
            query["username"] = username
        return call(lambda: self._admin.get_users(query))

    def update(self, user_id: str, rep: dict[str, Any]) -> None:
        call(lambda: self._admin.update_user(user_id, rep))

    def delete(self, user_id: str) -> None:
        call(lambda: self._admin.delete_user(user_id))
