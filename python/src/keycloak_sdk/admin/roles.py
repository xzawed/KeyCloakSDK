"""`RolesResource` — realm role CRUD. Wraps `KeycloakAdmin` and converts python-keycloak
exceptions to SDK exceptions with `_translate.call`."""

from __future__ import annotations

from typing import Any

from keycloak import KeycloakAdmin

from ._translate import call, encodable, write_call


class RolesResource:
    """Realm role management. `admin` is injected as `AdminClient.raw` (or a test mock)."""

    def __init__(self, admin: KeycloakAdmin) -> None:
        self._admin = admin

    def create(self, rep: dict[str, Any]) -> None:
        # 이름으로 주소를 잡는 create — 서버가 매기는 id 가 없어 `create_call` 의
        # Location 규칙 밖이다(등록부 admin-create-relative-location). python-keycloak 이
        # 읽는 그대로다.
        encodable(rep)
        write_call(lambda: self._admin.create_realm_role(rep))

    def get(self, name: str) -> dict[str, Any] | None:
        """Looks up a role by name. If it does not exist, `KeycloakNotFoundError` propagates
        (None is not returned)."""
        return call(lambda: self._admin.get_realm_role(name))

    def list(self) -> list[dict[str, Any]]:
        return call(lambda: self._admin.get_realm_roles())

    def update(self, name: str, rep: dict[str, Any]) -> None:
        """Updates the role, addressed by its current name. A new name in `rep["name"]` is a
        rename.

        Do not merge the path (`name`) and the body (`rep`).
        """
        encodable(rep)
        write_call(lambda: self._admin.update_realm_role(name, rep))

    def delete(self, name: str) -> None:
        write_call(lambda: self._admin.delete_realm_role(name))
