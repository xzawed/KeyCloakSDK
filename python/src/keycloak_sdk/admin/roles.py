"""`RolesResource` — realm 역할 CRUD. `KeycloakAdmin`을 감싸고 `_translate.call`로
python-keycloak 예외를 SDK 예외로 변환한다."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call


class RolesResource:
    """realm 역할 관리. `admin`은 `AdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> None:
        call(lambda: self._admin.create_realm_role(rep))

    def get(self, name: str) -> dict[str, Any] | None:
        """역할 이름으로 조회한다. 존재하지 않으면 `KeycloakNotFoundError`가
        전파된다(None을 반환하지 않음)."""
        return call(lambda: self._admin.get_realm_role(name))

    def list(self) -> list[dict[str, Any]]:
        return call(lambda: self._admin.get_realm_roles())

    def update(self, name: str, rep: dict[str, Any]) -> None:
        """현재 이름으로 주소를 잡아 갱신한다. `rep["name"]`에 새 이름을 주면 rename이다.

        경로(`name`)와 body(`rep`)를 합치지 말 것.
        """
        call(lambda: self._admin.update_realm_role(name, rep))

    def delete(self, name: str) -> None:
        call(lambda: self._admin.delete_realm_role(name))
