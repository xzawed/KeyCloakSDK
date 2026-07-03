"""`ClientsResource` — 클라이언트 CRUD. `KeycloakAdmin`을 감싸고 `_translate.call`로
python-keycloak 예외를 SDK 예외로 변환한다.

`id`는 클라이언트의 내부 UUID(python-keycloak `client_id` 파라미터명과 동일하나
실제로는 UUID), `client_id`는 OAuth2 clientId 문자열이다 —
`find_by_client_id`가 문자열→UUID 조회를 담당한다.
"""
from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call


class ClientsResource:
    """클라이언트 관리. `admin`은 `AdminClient.raw`(또는 테스트 목)로 주입된다."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> str:
        return call(lambda: self._admin.create_client(rep))

    def get(self, id: str) -> dict[str, Any] | None:
        """내부 UUID(`id`)로 클라이언트를 조회한다. 존재하지 않으면
        `KeycloakNotFoundError`가 전파된다(None을 반환하지 않음)."""
        return call(lambda: self._admin.get_client(id))

    def find_by_client_id(self, client_id: str) -> str | None:
        """OAuth2 `clientId` 문자열로 내부 UUID를 조회한다. 없으면 `None`."""
        return call(lambda: self._admin.get_client_id(client_id))

    def update(self, id: str, rep: dict[str, Any]) -> None:
        call(lambda: self._admin.update_client(id, rep))

    def delete(self, id: str) -> None:
        call(lambda: self._admin.delete_client(id))
