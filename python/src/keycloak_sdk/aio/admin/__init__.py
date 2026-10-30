"""AsyncAdminClient — the async administration (admin) facade wrapping the `a_*` methods of
python-keycloak's `KeycloakAdmin`.

`KeycloakAdmin` is created lazily — for the same reason as sync `AdminClient`: it authenticates
with the client credentials grant, so it needs `config.client_secret`, and its creation is
deferred until the point where it is actually needed (the first `raw`/resource access) so that
`AsyncAdminClient` itself can be constructed even with a secretless configuration (supporting
the case where a public client uses only auth and not admin). Being a network boundary, it is
excluded from the coverage gate (pyproject `[tool.coverage.run].omit`); the resource facades
(`users`/`clients`/`realms`/`roles`/`groups`) carry the logic and are unit-verified with mocks.
"""

from __future__ import annotations

from keycloak import KeycloakAdmin

from ..._internal.admin_guard import arm_admin, unarmed_connection
from ..._internal.frames import scrub_frames
from ...config import KeycloakConfig
from ...exceptions import KeycloakConfigError
from .clients import AsyncClientsResource
from .groups import AsyncGroupsResource
from .realms import AsyncRealmsResource
from .roles import AsyncRolesResource
from .users import AsyncUsersResource

__all__ = ["AsyncAdminClient"]


class AsyncAdminClient:
    """The async admin facade wrapping the `a_*` methods of `KeycloakAdmin`.

    `admin` is for test injection (when omitted, it is created on first use). On top of the
    same wiring as sync `AdminClient` (`raw`/resource properties), it provides `aclose()` for
    async lifecycle symmetry.
    """

    def __init__(self, config: KeycloakConfig, admin: KeycloakAdmin | None = None) -> None:
        self._config = config
        if admin is not None:
            arm_admin(admin)  # sync 미러와 같다(`_internal/admin_guard.py`)
        self._admin = admin

    @property
    @scrub_frames  # sync 미러와 같다 — 생성 실패 프레임이 client secret 을 쥔다
    def raw(self) -> KeycloakAdmin:
        """The inner `KeycloakAdmin` instance (escape hatch). If it has not been created yet, it
        is created now."""
        if self._admin is None:
            if self._config.client_secret is None:
                raise KeycloakConfigError(
                    "admin API access requires client_secret (client-credentials grant)"
                )
            admin = KeycloakAdmin(
                server_url=self._config.server_url,
                realm_name=self._config.realm,
                client_id=self._config.client_id,
                client_secret_key=self._config.client_secret,
                grant_type="client_credentials",
                verify=True,
                # read_timeout은 초 단위 float — int()로 자르면 0.5→0이 되어 httpx.Timeout(0)이
                # 되고 모든 admin 요청이 즉시 타임아웃한다. sync AdminClient와 동형으로 float를
                # 전달한다(python-keycloak 스텁은 int로 좁게 타이핑하나 런타임은 정상).
                timeout=self._config.read_timeout,  # type: ignore[arg-type]
            )
            arm_admin(admin)  # sync 미러와 같다 — 무장이 실패하면 캐시하지 않는다
            self._admin = admin
        return self._admin

    @property
    def users(self) -> AsyncUsersResource:
        return AsyncUsersResource(self.raw)

    @property
    def clients(self) -> AsyncClientsResource:
        return AsyncClientsResource(self.raw)

    @property
    def realms(self) -> AsyncRealmsResource:
        return AsyncRealmsResource(self.raw)

    @property
    def roles(self) -> AsyncRolesResource:
        return AsyncRolesResource(self.raw)

    @property
    def groups(self) -> AsyncGroupsResource:
        return AsyncGroupsResource(self.raw)

    async def aclose(self) -> None:
        """Closes **both** async httpx clients (and the sync sessions) of the underlying
        `KeycloakAdmin`.

        `KeycloakAdmin` has no `aclose` — the actual resource, `httpx.AsyncClient`, lives in the
        `ConnectionManager`, and its `aclose()` cleans it up (isomorphic with the async auth
        mirror).

        ⚠️ There are **two** of those ConnectionManagers (the very structure
        `_internal/admin_guard.py` already deals with in redirect hardening):

        1. `connection` — the admin REST calls.
        2. `connection.keycloak_openid.connection` — admin's own client-credentials
           token grant. It is a **lazy property**, created on the first admin call, so it is
           easy to miss.

        Closing only the first one leaves the second one's httpx.AsyncClient open, so an
        "unclosed transport" / "unclosed socket" ResourceWarning is emitted and one FD leaks
        per client that uses admin (EMFILE in a long-running service). This was measured by
        running the published 0.1.0rc1 against a real Keycloak — auth-only clients were clean,
        and only the ones that touched admin leaked.

        If `raw` was never created, `self._admin` is None, so this is a no-op (it does not go out
        of its way to create one). Even if the nested cleanup fails, the outer cleanup is always
        performed via `finally` — losing the other FD as well just because one of the two broke
        is the worst case. The failure itself is not hidden (the exception propagates as is — a
        loud failure is better than a silent leak).

        The connection is read **without arming it** — for the same reason as sync `close()`
        (`unarmed_connection`).
        """
        conn = unarmed_connection(self._admin)
        if conn is None:
            return
        nested = getattr(conn, "keycloak_openid", None)
        nested_conn = getattr(nested, "connection", None) if nested is not None else None
        nested_aclose = getattr(nested_conn, "aclose", None) if nested_conn is not None else None
        try:
            if callable(nested_aclose):
                await nested_aclose()
        finally:
            aclose = getattr(conn, "aclose", None)
            if callable(aclose):
                await aclose()
