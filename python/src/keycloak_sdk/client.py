"""KeycloakClient — unified entry point (facade): auth (eager) + admin (lazy).

`admin` authenticates with the client-credentials grant, so it ultimately needs
`config.client_secret` (the point where it is actually needed is the first access to
`AdminClient.raw` — WBS 4.1). The `KeycloakClient.admin` property by itself only defers
constructing the `AdminClient` instance — constructing it is cheap and does not trigger secret
validation, so auth-only use is supported even with a secretless public-client configuration
(no error occurs until admin is actually accessed).

When it is used as a context manager (`with KeycloakClient.create(config) as kc:`), `__exit__`
calls `close()` — the cleanup hook is delegated to `admin` only if `admin` was actually created.
"""

from __future__ import annotations

from types import TracebackType

from .admin import AdminClient
from .auth import AuthClient
from .config import KeycloakConfig
from .exceptions import KeycloakConfigError
from .oidc import OidcEndpoints


class KeycloakClient:
    """Unified facade: auth (eager) + admin (lazy). Created with `create()`; usable as a context
    manager."""

    def __init__(
        self,
        config: KeycloakConfig | None,
        auth: AuthClient,
        admin: AdminClient | None = None,
    ) -> None:
        self._config = config
        self._auth = auth
        self._admin = admin

    @classmethod
    def create(cls, config: KeycloakConfig) -> KeycloakClient:
        """Assembles `OidcEndpoints` + `AuthClient` from `config` eagerly.

        Creating `admin` is deferred until `.admin` is first accessed (lazy property).
        """
        endpoints = OidcEndpoints.for_realm(config)
        auth = AuthClient(config, endpoints)
        return cls(config, auth)

    @classmethod
    def _of(cls, auth: AuthClient, admin: AdminClient) -> KeycloakClient:
        """패키지 전용 테스트 시드. `auth`/`admin`을 그대로 주입해 지연 admin 생성
        경로를 우회한 인스턴스를 만든다 — `config`는 필요하지 않다(admin이 이미
        준비돼 있으므로 지연 생성이 트리거되지 않는다).
        """
        return cls(None, auth, admin)

    @property
    def auth(self) -> AuthClient:
        """The eagerly created `AuthClient`. Always usable, even without a secret."""
        return self._auth

    @property
    def admin(self) -> AdminClient:
        """The lazily created `AdminClient`. Built on first access, then reused from the cache."""
        if self._admin is None:
            if self._config is None:
                raise KeycloakConfigError(
                    "admin 접근에는 config가 필요합니다(KeycloakClient.create(config) 사용)"
                )
            self._admin = AdminClient(self._config)
        return self._admin

    def close(self) -> None:
        """Releases the underlying resources that were created — the auth session always, admin
        only if it was created.

        `auth` is always created in `create()`, so its requests session is closed (if it is not
        released, the connection pool leaks). If `admin` was never accessed, the admin cleanup is
        skipped — calling `close()` must not itself cause an unnecessary admin creation/network
        connection. It is guarded so that it stays safe even if `AdminClient` has no `close()`
        (a future implementation change).
        """
        self._auth.close()
        if self._admin is not None:
            close = getattr(self._admin, "close", None)
            if callable(close):
                close()

    def __enter__(self) -> KeycloakClient:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> None:
        self.close()
