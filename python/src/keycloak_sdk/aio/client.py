"""AsyncKeycloakClient — auth(즉시) + admin(지연) 통합 진입점(파사드).

sync `keycloak_sdk.client.KeycloakClient`의 async 미러다. `admin`은
client-credentials grant로 인증하므로 궁극적으로 `config.client_secret`이
필요하다(실제 필요 시점은 `AsyncAdminClient.raw`의 최초 접근). `AsyncKeycloakClient.admin`
프로퍼티는 그 자체로는 `AsyncAdminClient` 인스턴스 구성만 지연시킨다 — 구성 자체는
저렴하고 secret 검증을 트리거하지 않으므로, 시크릿 없는 public client 설정으로도
`auth`만 쓰는 사용을 지원한다(admin에 실제 접근하기 전까지는 에러가 나지 않는다).

async 컨텍스트 매니저(`async with AsyncKeycloakClient.create(config) as kc:`)로
사용하면 `__aexit__`이 `aclose()`를 호출한다 — `admin`이 실제로 생성된 경우에만
정리 훅을 위임한다. 네트워크 경계가 아니므로(하위 `AsyncAuthClient`/`AsyncAdminClient`
생성 자체만 하고 여기서 직접 I/O하지 않는다) 커버리지 게이트에서 제외되지 않는다.
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
    """auth(즉시) + admin(지연) 통합 async 파사드. `create()`로 생성, async 컨텍스트
    매니저 지원."""

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
        """`config`로부터 `OidcEndpoints`+`AsyncAuthClient`를 즉시 조립한다.

        `admin`은 `.admin` 최초 접근 시까지 생성을 미룬다(지연 프로퍼티).
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
        """즉시 생성된 `AsyncAuthClient`. secret 없이도 항상 사용 가능하다."""
        return self._auth

    @property
    def admin(self) -> AsyncAdminClient:
        """지연 생성된 `AsyncAdminClient`. 최초 접근 시 구성하고 이후 캐시를 재사용한다."""
        if self._admin is None:
            if self._config is None:
                raise KeycloakConfigError(
                    "admin 접근에는 config가 필요합니다(AsyncKeycloakClient.create(config) 사용)"
                )
            self._admin = AsyncAdminClient(self._config)
        return self._admin

    async def aclose(self) -> None:
        """생성된 하위 자원을 정리한다 — auth는 항상, admin은 생성된 경우에만.

        `auth`는 `create()`에서 항상 생성되므로 httpx 클라이언트를 닫는다(미해제 시
        async 소켓/FD 누수 → EMFILE). `admin`이 한 번도 접근되지 않았다면 admin 정리는
        건너뛴다 — `aclose()` 호출 자체가 불필요한 admin 생성/네트워크 연결을 유발해서는
        안 된다.
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
