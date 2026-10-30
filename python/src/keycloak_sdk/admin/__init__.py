"""AdminClient — the administration (admin) facade wrapping python-keycloak's `KeycloakAdmin`.

`KeycloakAdmin` is created lazily — it authenticates with the client-credentials grant, so it
needs `config.client_secret`, and its creation is deferred until the point where it is actually
needed (the first `raw`/resource access) so that `AdminClient` itself can be constructed even
with a secretless configuration (supporting the case where a public client uses only auth and
not admin). Being a network boundary, it is excluded from the coverage gate (pyproject
`[tool.coverage.run].omit`); the resource facades (4.2 through 4.4) carry the logic and are
unit-verified with mocks.

The resource accessors (`users`/`clients`/`realms`/`roles`/`groups`) are added step by step in
WBS 4.2 through 4.4.
"""

from __future__ import annotations

from keycloak import KeycloakAdmin

from .._internal.admin_guard import arm_admin, unarmed_connection
from .._internal.frames import scrub_frames
from ..config import KeycloakConfig
from ..exceptions import KeycloakConfigError
from .clients import ClientsResource
from .groups import GroupsResource
from .realms import RealmsResource
from .roles import RolesResource
from .users import UsersResource


class AdminClient:
    """Wraps `KeycloakAdmin`. `admin` is for test injection (when omitted, it is created on
    first use)."""

    def __init__(self, config: KeycloakConfig, admin: KeycloakAdmin | None = None) -> None:
        self._config = config
        if admin is not None:
            arm_admin(admin)  # 주입도 생성과 같은 하드닝 — `_internal/admin_guard.py`
        self._admin = admin

    @property
    @scrub_frames  # 생성 실패 시 `KeycloakAdmin` 프레임이 client secret 을 쥔다(`_internal/frames`)
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
                # read_timeout은 초 단위 float — int()로 자르면 0.5초 등이 0이 되어 urllib3가
                # 매 요청마다 ValueError로 거부한다. requests/urllib3는 float 타임아웃을 지원하나
                # python-keycloak 스텁이 timeout을 int로 좁게 타이핑해 float 전달에 mypy가 실패한다
                # (런타임은 requests로 흘러 float 정상 동작 — 스텁 부정확).
                timeout=self._config.read_timeout,  # type: ignore[arg-type]
            )
            # 생성 직후·첫 호출 전에 무장한다(`KeycloakAdmin.__init__` 은 네트워크를 타지 않는다).
            # 리다이렉트 하드닝·그랜트 응답 검사·보낼 bearer 검사를 걸고, 이후 admin 요청마다
            # 살아 있는 연결에 다시 본다(`_internal/admin_guard.py`). 무장이 실패하면 캐시하지
            # 않는다 — 실패한 객체를 다음 `raw` 가 무방비로 돌려주면 안 된다.
            arm_admin(admin)
            self._admin = admin
        return self._admin

    @property
    def users(self) -> UsersResource:
        return UsersResource(self.raw)

    @property
    def clients(self) -> ClientsResource:
        return ClientsResource(self.raw)

    @property
    def realms(self) -> RealmsResource:
        return RealmsResource(self.raw)

    @property
    def roles(self) -> RolesResource:
        return RolesResource(self.raw)

    @property
    def groups(self) -> GroupsResource:
        return GroupsResource(self.raw)

    def close(self) -> None:
        """Closes **both** sync `requests.Session`s of the underlying `KeycloakAdmin`.

        ⚠️ This used to be `return None` (a no-op). Yet the aio mirror (`aclose()` in
        `aio/admin/__init__.py`) was actually closing at the same spot — a **sync/aio
        asymmetry**, and `test_close_is_noop` was pinning that asymmetry as "intended".

        `ConnectionManager` has no public `close()` — there are only `aclose()` (async `httpx`
        only) and `__del__`, so the sync session stayed open **until it was GC'd**. In a
        long-running service that moment is not guaranteed.

        ⚠️ There are **two** managers (the structure `_internal/admin_guard.py` deals with in
        redirect hardening):

        1. `connection._s` — the admin REST calls.
        2. `connection.keycloak_openid.connection._s` — admin's own client-credentials
           token grant.

        If `raw` was never created, `self._admin` is None, so this is a no-op (it does not go out
        of its way to create one — the same contract as aio `aclose()`). Even if the nested
        cleanup fails, the outer cleanup is always performed via `finally`: losing the other FD
        as well just because one of the two broke is the worst case. The failure itself is not
        hidden (a loud failure is better than a silent leak).

        ⚠️ **`async_s` cannot be closed here — do not oversell this.** The sync
        `ConnectionManager` also creates an `httpx.AsyncClient`, but closing it requires
        `await`. The resource that can be reclaimed on the sync path is the `requests.Session`,
        and that is all this hook closes.

        The connection is read **without arming it** (`unarmed_connection`) — cleanup sends no
        request, so even a connection that has changed so that it can no longer be protected is
        not prevented from being closed.
        """
        conn = unarmed_connection(self._admin)
        if conn is None:
            return
        nested = getattr(conn, "keycloak_openid", None)
        nested_conn = getattr(nested, "connection", None) if nested is not None else None
        nested_session = getattr(nested_conn, "_s", None) if nested_conn is not None else None
        try:
            if nested_session is not None:
                nested_session.close()
        finally:
            session = getattr(conn, "_s", None)
            if session is not None:
                session.close()
