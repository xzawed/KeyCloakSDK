"""AsyncKeycloakClient — unified entry point (facade): auth (eager) + admin (lazy).

The async mirror of sync `keycloak_sdk.client.KeycloakClient`. `admin` authenticates with the
client-credentials grant, so it ultimately needs `config.client_secret` (the point where it is
actually needed is the first access to `AsyncAdminClient.raw`). The `AsyncKeycloakClient.admin`
property by itself only defers constructing the `AsyncAdminClient` instance — constructing it
is cheap and does not trigger secret validation, so auth-only use is supported even with a
secretless public-client configuration (no error occurs until admin is actually accessed).

When it is used as an async context manager
(`async with AsyncKeycloakClient.create(config) as kc:`), `__aexit__` calls `aclose()` — the
cleanup hook is delegated to `admin` only if `admin` was actually created. It is not a network
boundary (it only creates the underlying `AsyncAuthClient`/`AsyncAdminClient` and does no I/O
directly here), so it is not excluded from the coverage gate.
"""

from __future__ import annotations

from types import TracebackType

from ..config import KeycloakConfig
from ..exceptions import KeycloakConfigError
from ..oidc import OidcEndpoints
from .admin import AsyncAdminClient
from .auth import AsyncAuthClient

__all__ = ["AsyncKeycloakClient"]


class AsyncKeycloakClient:
    """Unified async facade: auth (eager) + admin (lazy). Created with `create()`; usable as an
    async context manager."""

    def __init__(
        self,
        config: KeycloakConfig | None,
        auth: AsyncAuthClient,
        admin: AsyncAdminClient | None = None,
    ) -> None:
        self._config = config
        self._auth = auth
        self._admin = admin

    @classmethod
    def create(cls, config: KeycloakConfig) -> AsyncKeycloakClient:
        """Assembles `OidcEndpoints` + `AsyncAuthClient` from `config` eagerly.

        Creating `admin` is deferred until `.admin` is first accessed (lazy property).
        """
        endpoints = OidcEndpoints.for_realm(config)
        auth = AsyncAuthClient(config, endpoints)
        return cls(config, auth)

    @classmethod
    def _of(cls, auth: AsyncAuthClient, admin: AsyncAdminClient) -> AsyncKeycloakClient:
        """패키지 전용 테스트 시드. `auth`/`admin`을 그대로 주입해 지연 admin 생성
        경로를 우회한 인스턴스를 만든다 — `config`는 필요하지 않다(admin이 이미
        준비돼 있으므로 지연 생성이 트리거되지 않는다).
        """
        return cls(None, auth, admin)

    @property
    def auth(self) -> AsyncAuthClient:
        """The eagerly created `AsyncAuthClient`. Always usable, even without a secret."""
        return self._auth

    @property
    def admin(self) -> AsyncAdminClient:
        """The lazily created `AsyncAdminClient`. Built on first access, then reused from the
        cache."""
        if self._admin is None:
            if self._config is None:
                raise KeycloakConfigError(
                    "admin 접근에는 config가 필요합니다(AsyncKeycloakClient.create(config) 사용)"
                )
            self._admin = AsyncAdminClient(self._config)
        return self._admin

    async def aclose(self) -> None:
        """Releases the underlying resources that were created — auth always, admin only if it
        was created.

        `auth` is always created in `create()`, so its httpx client is closed (if it is not
        released, async sockets/FDs leak → EMFILE). If `admin` was never accessed, the admin
        cleanup is skipped — calling `aclose()` must not itself cause an unnecessary admin
        creation/network connection.
        """
        await self._auth.aclose()
        if self._admin is not None:
            await self._admin.aclose()

    async def __aenter__(self) -> AsyncKeycloakClient:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> None:
        await self.aclose()
