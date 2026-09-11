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

from .._internal.redirects import harden_admin
from ..config import KeycloakConfig
from ..exceptions import KeycloakConfigError
from .clients import ClientsResource
from .groups import GroupsResource
from .realms import RealmsResource
from .roles import RolesResource
from .users import UsersResource


class AdminClient:
    """`KeycloakAdmin` 래핑. `admin`은 테스트 주입용(미지정 시 첫 사용 시점에 생성)."""

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
                # read_timeout은 초 단위 float — int()로 자르면 0.5초 등이 0이 되어 urllib3가
                # 매 요청마다 ValueError로 거부한다. requests/urllib3는 float 타임아웃을 지원하나
                # python-keycloak 스텁이 timeout을 int로 좁게 타이핑해 float 전달에 mypy가 실패한다
                # (런타임은 requests로 흘러 float 정상 동작 — 스텁 부정확).
                timeout=self._config.read_timeout,  # type: ignore[arg-type]
            )
            # 생성 직후·첫 호출 전에 막는다. `KeycloakAdmin.__init__`은 네트워크를
            # 타지 않으므로(토큰 그랜트는 첫 호출 때 지연 수행) 여기가 안전한 지점이다.
            harden_admin(self._admin)
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
        """하위 `KeycloakAdmin`의 sync `requests.Session`을 **둘 다** 닫는다.

        ⚠️ 예전에는 `return None`(no-op)이었다. 그런데 aio 미러(`aio/admin/__init__.py`의
        `aclose()`)는 같은 자리에서 실제로 닫고 있었다 — **sync/aio 비대칭**이고, 그 비대칭을
        `test_close_is_noop`이 「의도」로 고정하고 있었다.

        `ConnectionManager`에는 공개 `close()`가 없다 — `aclose()`(async `httpx` 전용)와
        `__del__`뿐이라, sync 세션은 **GC 될 때까지** 열려 있었다. 장기 서비스에서는 그
        시점이 보장되지 않는다.

        ⚠️ 매니저가 **둘**이다(`_internal/redirects.py`의 `harden_admin`이 다루는 바로 그 구조):

        1. `connection._s` — admin REST 호출.
        2. `connection.keycloak_openid.connection._s` — admin 자신의 client-credentials
           토큰 그랜트.

        `raw` 미생성이면 `self._admin`이 None이라 no-op이다(굳이 생성하지 않는다 — aio
        `aclose()`와 같은 계약). 중첩 정리가 실패해도 바깥 정리는 `finally`로 반드시
        수행한다: 둘 중 하나가 깨졌다고 나머지 FD까지 함께 잃는 것이 최악이다. 실패 자체는
        숨기지 않는다(조용한 누수보다 시끄러운 실패가 낫다).

        ⚠️ **`async_s`는 여기서 닫지 못한다 — 과대광고하지 말 것.** sync `ConnectionManager`도
        `httpx.AsyncClient`를 함께 만들지만 그것을 닫으려면 `await`가 필요하다. sync 경로에서
        회수 가능한 자원은 `requests.Session`이고, 이 훅이 닫는 것은 그것뿐이다.
        """
        conn = getattr(self._admin, "connection", None)
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
