"""백채널 리다이렉트 차단 — sync(requests) 경로.

**대조군을 같은 테스트 안에 둔다.** 각 케이스는 먼저 하드닝하지 않은 stock
`python-keycloak` 객체를 같은 덫 서버에 붙여 *실제로 리다이렉트를 따라가고 자격증명을
넘기며 거짓 성공을 반환한다*는 것을 증명한 뒤, 같은 서버에 SDK를 붙여 차이를 주장한다.
대조군이 없으면 덫이 고장나도(Location 오타·상태코드 오기) "아무 요청도 안 갔다"가 그냥
통과한다.

Docker가 필요 없다 — 루프백 `http.server` 두 개(idp/evil)만 쓴다.
"""

from __future__ import annotations

from typing import Any

import pytest
from keycloak import KeycloakAdmin, KeycloakOpenID

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakConfigError,
)
from keycloak_sdk.oidc import OidcEndpoints
from tests.unit.conftest import ACCESS_TOKEN, CLIENT_SECRET, REFRESH_TOKEN, Trap


def _config(trap: Trap) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=trap.idp_url,
        realm="t",
        client_id="app",
        client_secret=CLIENT_SECRET,
        read_timeout=5.0,
    )


def _stock_openid(trap: Trap) -> KeycloakOpenID:
    """하드닝하지 않은 python-keycloak — 대조군."""
    return KeycloakOpenID(
        server_url=trap.idp_url,
        realm_name="t",
        client_id="app",
        client_secret_key=CLIENT_SECRET,
        verify=False,
        timeout=5,
    )


def _auth(trap: Trap) -> AuthClient:
    config = _config(trap)
    return AuthClient(config, OidcEndpoints.for_realm(config))


# --------------------------------------------------------------------------- auth 백채널


def test_control_group_stock_python_keycloak_does_follow_and_leak(trap: Trap) -> None:
    """덫이 실제로 무장돼 있음을 증명한다 — 이 테스트가 깨지면 아래 주장은 전부 공허하다."""
    stock = _stock_openid(trap)

    assert stock.introspect(ACCESS_TOKEN) == {"active": True, "username": "victim"}

    assert len(trap.hits) == 1, "stock python-keycloak이 리다이렉트를 따라가지 않았다 — 덫 고장"
    assert CLIENT_SECRET in trap.hits[0].body
    assert ACCESS_TOKEN in trap.hits[0].body


@pytest.mark.parametrize(
    ("operation", "control", "subject"),
    [
        pytest.param(
            "introspect",
            lambda o: o.introspect(ACCESS_TOKEN),
            lambda c: c.introspect(ACCESS_TOKEN),
            id="introspect",
        ),
        pytest.param(
            "logout",
            lambda o: o.logout(REFRESH_TOKEN),
            lambda c: c.logout(REFRESH_TOKEN),
            id="logout",
        ),
        pytest.param(
            "token",
            lambda o: o.token(grant_type="client_credentials"),
            lambda c: c.client_credentials_token(),
            id="client_credentials_token",
        ),
        pytest.param(
            "refresh",
            lambda o: o.refresh_token(REFRESH_TOKEN),
            lambda c: c.refresh(REFRESH_TOKEN),
            id="refresh",
        ),
        pytest.param(
            "exchange_code",
            lambda o: o.token(grant_type="authorization_code", code="c", redirect_uri="/cb"),
            lambda c: c.exchange_code("c", "/cb", "verifier"),
            id="exchange_code",
        ),
        pytest.param(
            "certs",
            lambda o: o.certs(),
            lambda c: c.validate("not.a.real.token"),
            id="jwks_load",
        ),
    ],
)
def test_auth_backchannel_refuses_redirects(
    trap: Trap,
    operation: str,
    control: Any,
    subject: Any,
) -> None:
    # --- 대조군: 하드닝 없는 stock은 따라가고, 리다이렉트 대상의 답을 받아들인다 ---
    control(_stock_openid(trap))
    assert len(trap.hits) == 1, f"{operation}: 덫이 무장되지 않았다(stock이 따라가지 않음)"
    followed = trap.hits[0]
    trap.reset()

    # --- 대상: SDK는 따라가지 않고, 성공을 반환하지도 않는다 ---
    with pytest.raises(KeycloakAuthError) as exc_info:
        subject(_auth(trap))

    assert trap.hits == [], f"{operation}: SDK가 리다이렉트 대상으로 요청을 보냈다"
    # 조용한 거짓 성공이 아니라 표면화된 실패여야 한다. 상태코드가 메시지에 남는다.
    assert "307" in str(exc_info.value)
    # 대조군이 실제로 자격증명을 흘렸음을 남겨 회귀 시 무엇을 잃는지 드러낸다.
    if operation in {"introspect", "logout", "token", "refresh", "exchange_code"}:
        assert CLIENT_SECRET in followed.body


def test_jwks_is_not_poisoned_by_a_redirect(trap: Trap) -> None:
    """certs()가 리다이렉트를 따라가면 공격자 JWKS가 검증 키로 **캐시**된다."""
    stock = _stock_openid(trap)
    assert stock.certs() == {"keys": [{"kid": "ATTACKER-KEY", "kty": "oct"}]}  # 대조군
    trap.reset()

    client = _auth(trap)
    with pytest.raises(KeycloakAuthError):
        client.validate("not.a.real.token")

    assert trap.hits == []
    assert client._jwks_cache is None, "공격자 JWKS가 캐시됐다"


def test_logout_would_have_reported_success(trap: Trap) -> None:
    """다른 언어들과 같은 '조용한 거짓 성공' 모드가 Python sync에도 있다.

    리다이렉트 대상이 204를 돌려주면 stock은 로그아웃 성공(`{}`)을 반환한다 — 세션은
    살아있고 refresh token은 이미 공격자에게 넘어간 뒤다. introspect는 한 술 더 떠
    `{"active": true}`를 그대로 통과시킨다(인가 우회).
    """
    stock = _stock_openid(trap)

    assert stock.logout(REFRESH_TOKEN) == {}, "대조군이 거짓 성공을 재현하지 못했다"
    assert REFRESH_TOKEN in trap.hits[0].body
    trap.reset()

    with pytest.raises(KeycloakAuthError):
        _auth(trap).logout(REFRESH_TOKEN)
    assert trap.hits == []


# --------------------------------------------------------------------------- admin 경로


def _stock_admin(trap: Trap) -> KeycloakAdmin:
    return KeycloakAdmin(
        server_url=trap.idp_url,
        realm_name="t",
        client_id="app",
        client_secret_key=CLIENT_SECRET,
        grant_type="client_credentials",
        verify=False,
        timeout=5,
    )


def test_admin_refuses_redirects_on_both_of_its_sessions(trap: Trap) -> None:
    """admin 경로에는 세션이 **둘**이다 — REST 세션과 (지연 생성되는) 토큰 그랜트 세션.

    대조군은 두 요청을 모두 리다이렉트 대상에 흘린다: client_secret을 실은 토큰 그랜트와
    Bearer를 실은 REST 호출. 바깥 세션만 막으면 토큰 그랜트는 그대로 샌다.
    """
    stock = _stock_admin(trap)
    assert stock.get_users({}) == [{"id": "planted", "username": "planted"}]
    assert len(trap.hits) == 2, "대조군이 두 세션 모두에서 새지 않았다"
    grant, rest = trap.hits[0], trap.hits[1]
    assert "token" in grant.path and CLIENT_SECRET in grant.body
    assert "/users" in rest.path
    trap.reset()

    client = AdminClient(_config(trap))
    with pytest.raises(KeycloakAdminError) as exc_info:
        client.users.search()

    assert trap.hits == [], "SDK admin이 리다이렉트 대상으로 요청을 보냈다"
    assert exc_info.value.status_code == 307


def test_admin_rest_session_leaks_bearer_on_a_same_origin_redirect(trap: Trap) -> None:
    """교차 출처에서는 requests가 `Authorization`을 벗기지만(rebuild_auth), **동일 출처**
    리다이렉트에서는 Bearer가 그대로 따라간다 — admin REST 세션을 막아야 하는 이유.

    (교차 출처에서도 POST **본문**의 client_secret은 벗겨지지 않는다 — 위 테스트 참조.)
    """
    trap.same_origin = True
    stock = _stock_admin(trap)
    stock.get_users({})

    rest = next(h for h in trap.hits if "/users" in h.path)
    assert rest.authorization is not None and rest.authorization.startswith("Bearer ")
    trap.reset()

    client = AdminClient(_config(trap))
    with pytest.raises(KeycloakAdminError):
        client.users.search()
    assert trap.hits == []


# --------------------------------------------------------------------------- 형태 변화 가드


def test_raises_when_python_keycloak_moves_the_session() -> None:
    """`_s`가 사라지면 조용히 하드닝되지 않은 클라이언트를 만들지 않고 생성에서 실패한다."""

    class MovedSession:
        connection = type("Conn", (), {"renamed_s": object()})()

    with pytest.raises(KeycloakConfigError, match="cannot harden"):
        AuthClient.__init__(
            object.__new__(AuthClient),  # type: ignore[arg-type]
            _config(Trap(idp_url="http://127.0.0.1:1", evil_url="http://127.0.0.1:2")),
            OidcEndpoints.for_realm(
                _config(Trap(idp_url="http://127.0.0.1:1", evil_url="http://127.0.0.1:2"))
            ),
            openid=MovedSession(),  # type: ignore[arg-type]
        )


def test_raises_when_the_hook_is_not_callable() -> None:
    from keycloak_sdk._internal.redirects import harden_openid

    class NoHook:
        connection = type("Conn", (), {"_s": type("S", (), {"resolve_redirects": None})()})()

    with pytest.raises(KeycloakConfigError, match="cannot harden"):
        harden_openid(NoHook())


def test_raises_when_admin_nested_token_session_is_unreachable() -> None:
    """중첩 토큰 그랜트 세션에 닿지 못해도 조용히 넘어가지 않는다."""
    import requests

    from keycloak_sdk._internal.redirects import harden_admin

    class Conn:
        _s = requests.Session()

        @property
        def keycloak_openid(self) -> Any:
            raise AttributeError("gone")

    with pytest.raises(KeycloakConfigError, match="admin token grant"):
        harden_admin(type("A", (), {"connection": Conn()})())
