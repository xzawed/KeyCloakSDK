"""AdminClient — python-keycloak `KeycloakAdmin`을 감싼 관리(admin) 파사드.

`KeycloakAdmin` 생성은 지연(lazy) 수행된다 — client-credentials grant로 인증하므로
`config.client_secret`이 필요하고, 실제 필요 시점(첫 `raw`/리소스 접근)까지 생성을
미뤄 시크릿 없는 설정으로도 `AdminClient` 자체는 구성할 수 있게 한다(공개 client는
auth만 쓰고 admin은 안 쓰는 경우를 지원). 네트워크 경계라 커버리지 게이트에서
제외된다(pyproject `[tool.coverage.run].omit`); 리소스 파사드(4.2~4.4)가 로직을
담당하고 목 기반으로 단위 검증된다.

리소스 접근자(`users`/`clients`/`realms`/`roles`/`groups`)는 WBS 4.2~4.4에서
단계적으로 추가된다.
"""
from __future__ import annotations

from keycloak import KeycloakAdmin

from ..config import KeycloakConfig
from ..exceptions import KeycloakConfigError
from .users import UsersResource


class AdminClient:
    """`KeycloakAdmin` 래핑. `admin`은 테스트 주입용(미지정 시 첫 사용 시점에 생성)."""

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
    def users(self) -> UsersResource:
        return UsersResource(self.raw)
