"""KeycloakClient — auth(즉시) + admin(지연) 통합 진입점(파사드).

`admin`은 client-credentials grant로 인증하므로 궁극적으로 `config.client_secret`이
필요하다(실제 필요 시점은 `AdminClient.raw`의 최초 접근 — WBS 4.1). `KeycloakClient.admin`
프로퍼티는 그 자체로는 `AdminClient` 인스턴스 구성만 지연시킨다 — 구성 자체는 저렴하고
secret 검증을 트리거하지 않으므로, 시크릿 없는 public client 설정으로도 `auth`만 쓰는
사용을 지원한다(admin에 실제 접근하기 전까지는 에러가 나지 않는다).

컨텍스트 매니저(`with KeycloakClient.create(config) as kc:`)로 사용하면 `__exit__`이
`close()`를 호출한다 — `admin`이 실제로 생성된 경우에만 정리 훅을 위임한다.
"""
from __future__ import annotations

from types import TracebackType

from .admin import AdminClient
from .auth import AuthClient
from .config import KeycloakConfig
from .exceptions import KeycloakConfigError
from .oidc import OidcEndpoints


class KeycloakClient:
    """auth(즉시) + admin(지연) 통합 파사드. `create()`로 생성, 컨텍스트 매니저 지원."""

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
    def create(cls, config: KeycloakConfig) -> "KeycloakClient":
        """`config`로부터 `OidcEndpoints`+`AuthClient`를 즉시 조립한다.

        `admin`은 `.admin` 최초 접근 시까지 생성을 미룬다(지연 프로퍼티).
        """
        endpoints = OidcEndpoints.for_realm(config)
        auth = AuthClient(config, endpoints)
        return cls(config, auth)

    @classmethod
    def _of(cls, auth: AuthClient, admin: AdminClient) -> "KeycloakClient":
        """패키지 전용 테스트 시드. `auth`/`admin`을 그대로 주입해 지연 admin 생성
        경로를 우회한 인스턴스를 만든다 — `config`는 필요하지 않다(admin이 이미
        준비돼 있으므로 지연 생성이 트리거되지 않는다).
        """
        return cls(None, auth, admin)

    @property
    def auth(self) -> AuthClient:
        """즉시 생성된 `AuthClient`. secret 없이도 항상 사용 가능하다."""
        return self._auth

    @property
    def admin(self) -> AdminClient:
        """지연 생성된 `AdminClient`. 최초 접근 시 구성하고 이후 캐시를 재사용한다."""
        if self._admin is None:
            if self._config is None:
                raise KeycloakConfigError(
                    "admin 접근에는 config가 필요합니다(KeycloakClient.create(config) 사용)"
                )
            self._admin = AdminClient(self._config)
        return self._admin

    def close(self) -> None:
        """생성된 하위 자원을 정리한다.

        `admin`이 한 번도 접근되지 않았다면(지연 생성이 아직 트리거되지 않았다면)
        아무 것도 하지 않는다 — `close()` 호출 자체가 불필요한 admin 생성/네트워크
        연결을 유발해서는 안 된다. `AdminClient`에 `close()`가 없는 경우에도(향후
        구현이 바뀌어도) 안전하도록 `hasattr`(callable 여부)로 가드한다.
        """
        if self._admin is not None:
            close = getattr(self._admin, "close", None)
            if callable(close):
                close()

    def __enter__(self) -> "KeycloakClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> None:
        self.close()
