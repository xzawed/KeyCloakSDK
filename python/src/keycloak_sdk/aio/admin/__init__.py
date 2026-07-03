"""AsyncAdminClient — python-keycloak `KeycloakAdmin`의 `a_*` 메서드를 감싼 관리(admin)
비동기 파사드.

`KeycloakAdmin` 생성은 지연(lazy) 수행된다 — sync `AdminClient`와 동일한 이유: client
credentials grant로 인증하므로 `config.client_secret`이 필요하고, 실제 필요 시점(첫
`raw`/리소스 접근)까지 생성을 미뤄 시크릿 없는 설정으로도 `AsyncAdminClient` 자체는
구성할 수 있게 한다(공개 client는 auth만 쓰고 admin은 안 쓰는 경우를 지원). 네트워크
경계라 커버리지 게이트에서 제외된다(pyproject `[tool.coverage.run].omit`); 리소스
파사드(`users`/`clients`/`realms`/`roles`/`groups`)가 로직을 담당하고 목 기반으로
단위 검증된다.
"""

from __future__ import annotations

from keycloak import KeycloakAdmin

from ...config import KeycloakConfig
from ...exceptions import KeycloakConfigError
from .clients import AsyncClientsResource
from .groups import AsyncGroupsResource
from .realms import AsyncRealmsResource
from .roles import AsyncRolesResource
from .users import AsyncUsersResource

__all__ = ["AsyncAdminClient"]


class AsyncAdminClient:
    """`KeycloakAdmin`의 `a_*` 메서드를 감싼 async 관리 파사드.

    `admin`은 테스트 주입용(미지정 시 첫 사용 시점에 생성). sync `AdminClient`와
    동일한 배선(`raw`/리소스 프로퍼티)에 더해, async 수명주기 대칭을 위한
    `aclose()`를 제공한다.
    """

    def __init__(self, config: KeycloakConfig, admin: KeycloakAdmin | None = None) -> None:
        self._config = config
        self._admin = admin

    @property
    def raw(self) -> KeycloakAdmin:
        """내부 `KeycloakAdmin` 인스턴스(탈출구). 미생성 상태면 지금 생성한다."""
        if self._admin is None:
            if self._config.client_secret is None:
                raise KeycloakConfigError(
                    "admin API 접근에는 client_secret이 필요합니다(client-credentials grant)"
                )
            self._admin = KeycloakAdmin(
                server_url=self._config.server_url,
                realm_name=self._config.realm,
                client_id=self._config.client_id,
                client_secret_key=self._config.client_secret,
                grant_type="client_credentials",
                verify=True,
                timeout=int(self._config.read_timeout),
            )
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
        """자원 정리 훅. 아직 `raw`가 생성되지 않았다면 no-op(굳이 생성하지 않음).

        python-keycloak `KeycloakAdmin`에는 현재 async close가 없으므로 사실상
        항상 no-op이지만, 있다면(향후 커넥션 풀 등이 추가되면) 위임한다.
        `AsyncKeycloakClient`(WBS 4)의 async 컨텍스트 매니저 프로토콜과 대칭을
        이루기 위해 인터페이스를 유지한다.
        """
        aclose = getattr(self._admin, "aclose", None)
        if aclose is not None:
            await aclose()
