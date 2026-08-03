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

from ..._internal.redirects import harden_admin
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
        if admin is not None:
            harden_admin(admin)
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
                # read_timeout은 초 단위 float — int()로 자르면 0.5→0이 되어 httpx.Timeout(0)이
                # 되고 모든 admin 요청이 즉시 타임아웃한다. sync AdminClient와 동형으로 float를
                # 전달한다(python-keycloak 스텁은 int로 좁게 타이핑하나 런타임은 정상).
                timeout=self._config.read_timeout,  # type: ignore[arg-type]
            )
            harden_admin(self._admin)
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
        """하위 `KeycloakAdmin`의 async httpx 클라이언트(및 sync 세션)를 **둘 다** 닫는다.

        `KeycloakAdmin`에는 `aclose`가 없다 — 실제 자원인 `httpx.AsyncClient`는
        `ConnectionManager`에 있고 그 `aclose()`가 정리한다(async auth 미러와 동형).

        ⚠️ 그 ConnectionManager가 **둘**이다(`harden_admin`이 리다이렉트 하드닝에서 이미
        다루는 바로 그 구조 — `_internal/redirects.py`):

        1. `connection` — admin REST 호출.
        2. `connection.keycloak_openid.connection` — admin 자신의 client-credentials
           토큰 그랜트. **지연 프로퍼티**라 첫 admin 호출 때 생겨서 눈에 잘 띄지 않는다.

        1번만 닫으면 2번의 httpx.AsyncClient가 열린 채 남아 "unclosed transport" /
        "unclosed socket" ResourceWarning이 뜨고 admin을 쓰는 클라이언트마다 FD가 하나씩
        샌다(장기 서비스에서 EMFILE). 게시된 0.1.0rc1을 실 Keycloak에 대해 돌려 실측했다 —
        auth 전용 클라이언트는 깨끗했고 admin을 건드린 경우만 샜다.

        `raw` 미생성이면 `self._admin`이 None이라 no-op이다(굳이 생성하지 않음).
        중첩 정리가 실패해도 바깥 정리는 `finally`로 반드시 수행한다 — 둘 중 하나가
        깨졌다고 나머지 FD까지 함께 잃는 것이 최악이다. 실패 자체는 숨기지 않는다
        (예외는 그대로 전파된다 — 조용한 누수보다 시끄러운 실패가 낫다).
        """
        conn = getattr(self._admin, "connection", None)
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
