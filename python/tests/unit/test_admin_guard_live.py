"""admin 레인의 하드닝은 생성 때 한 번이 아니라 **요청을 보내는 순간에** 성립한다(등록부
`python-admin-grant-guard-install-time`).

#685 의 그랜트 검사(`_internal/admin_grant.py`)와 리다이렉트 하드닝(`_internal/redirects.py`)은
생성 때 **그 객체들에** 한 번 설치됐다. 그런데 python-keycloak 은 그것을 갈아 끼우는 공개 세터를
둔다 — `KeycloakAdmin.connection`·`KeycloakOpenID.connection`. 수정 전 실측(python-keycloak 7.1.1,
빈 `access_token` 을 주는 가짜 IdP):

* (H1) `raw.connection = KeycloakOpenIDConnection(...)` 뒤 sync 는 리소스 호출이든 `raw` 호출이든
  `Authorization: Bearer ` 로 admin 요청을 보냈고, aio 는 h11 이 그 헤더를 거부해
  `KeycloakTransportError`·`KeycloakConnectionError` 였다.
* (H2) 이미 빈 bearer 를 쥔 채 주입된 admin(`token={"access_token": ""}`)은 그랜트 없이 곧바로
  `Bearer ` 를 보냈다.
* (H3) 설치 중 `setattr` 이 실패하면 raw `AttributeError` 였고 `token`·`refresh_token` 만 감긴 채
  남았다(바깥 세션의 리다이렉트 하드닝도 남았다).

판정은 #685 와 같다 — auth 레인이 같은 응답에 내는 타입·메시지(`test_admin_grant.py` 의 하네스).
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any
from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakAdmin, KeycloakOpenID, KeycloakOpenIDConnection
from keycloak.connection import ConnectionManager

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakConfigError
from tests.unit.conftest import CLIENT_SECRET, Trap

from .test_admin_grant import (
    _USER,
    ACCESS_OLD,
    LANES,
    REFRESH_NEW,
    REFRESH_OLD,
    SECRET,
    _attempt,
    _auth_lane_verdict,
    _client,
    _fake_idp,
    _grant_body,
    _inner_frames,
    _refused_like_the_auth_lane,
    _Seen,
)

pytestmark = pytest.mark.usefixtures("fast_tls")

_EMPTY = _grant_body("", expires_in=300, refresh_token=REFRESH_NEW)
_GOOD = _grant_body(ACCESS_OLD, expires_in=300, refresh_token=REFRESH_OLD)
_ADMIN_CLIENTS: dict[str, Any] = {"sync": AdminClient, "aio": AsyncAdminClient}
_GRANTS = ("token", "refresh_token", "a_token", "a_refresh_token")
_BEARER_HOOKS = ("_refresh_if_required", "a__refresh_if_required")


def _cfg(url: str) -> KeycloakConfig:
    return KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret=SECRET)


def _connection(url: str, **overrides: Any) -> KeycloakOpenIDConnection:
    """소비자가 갈아 끼우는 새 연결 — SDK 를 거치지 않고 만든 python-keycloak 객체 그대로다."""
    kwargs: dict[str, Any] = {
        "server_url": url,
        "realm_name": "r",
        "client_id": "c",
        "client_secret_key": SECRET,
        "grant_type": "client_credentials",
    }
    kwargs.update(overrides)
    return KeycloakOpenIDConnection(**kwargs)


def _public_swap(admin: Any, conn: Any) -> None:
    admin.connection = conn  # KeycloakAdmin 의 공개 세터


def _private_swap(admin: Any, conn: Any) -> None:
    admin._connection = conn  # 세터를 거치지 않는 쓰기 — 공개 세터만 지키면 여기가 샌다


_SWAPS: dict[str, Callable[[Any, Any], None]] = {
    "공개 세터": _public_swap,
    "비공개 필드": _private_swap,
}


def _raw_get(lane: str, raw: Any) -> Callable[[Any], Any]:
    """`raw` 를 **먼저 받아 쥔 뒤** 부르는 호출 — 그 사이에 SDK 코드가 한 줄도 돌지 않는다."""
    return (lambda _c: raw.get_user("u1")) if lane == "sync" else (lambda _c: raw.a_get_user("u1"))


async def _close(lane: str, client: Any) -> None:
    if lane == "aio":
        await client.aclose()
    else:
        client.close()


async def _close_connection(lane: str, conn: Any) -> None:
    """갈아 끼워져 SDK 의 정리에서 빠진 옛 연결 — 테스트가 직접 닫는다."""
    nested = conn.keycloak_openid.connection
    if lane == "aio":
        await nested.aclose()
        await conn.aclose()
    nested._s.close()
    conn._s.close()


# --- (H1) 갈아 끼운 연결 ------------------------------------------------------------------------


@pytest.mark.parametrize("swap", list(_SWAPS))
@pytest.mark.parametrize("path", ["리소스", "쥔 raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_replaced_connection_is_guarded_before_its_first_request(
    lane: str, path: str, swap: str
) -> None:
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _EMPTY)]
        async with _client(lane, idp) as client:
            raw = client.admin.raw
            old = raw.connection
            _SWAPS[swap](raw, _connection(idp.url))
            act = (lambda c: c.admin.users.get("u1")) if path == "리소스" else _raw_get(lane, raw)
            result, err = await _attempt(lane, client, act)
            await _close_connection(lane, old)

    assert result is None
    assert idp.admin_requests() == [], "갈아 끼운 연결로 쓸 수 없는 bearer 를 보냈다"
    assert idp.grant_types() == ["client_credentials"], "새 연결의 그랜트에 닿지 않았다 — 공허하다"
    verdict = _auth_lane_verdict(_EMPTY)
    if path == "리소스":
        assert _refused_like_the_auth_lane(err, verdict) == []
    else:  # 경계가 없는 탈출구 — 타입·메시지가 같으면 된다(#685 의 raw 와 같다)
        assert (type(err), str(err)) == verdict


@pytest.mark.parametrize("lane", LANES)
async def test_a_bearer_set_on_the_live_connection_is_checked_too(lane: str) -> None:
    """토큰 세터도 공개다 — 생성 뒤에 실린 bearer 도 보내기 직전에 본다."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        async with _client(lane, idp) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            client.admin.raw.connection.token = {"access_token": "", "expires_in": 300}
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert result is None
    assert _refused_like_the_auth_lane(err, _auth_lane_verdict(_EMPTY)) == []
    assert idp.admin_requests() == [_Seen("GET", _USER, "", f"Bearer {ACCESS_OLD}")]


# --- (H2) 주입된 admin 이 이미 쥔 bearer ----------------------------------------------------------


def _injected(url: str, *, credentials: bool, expires_in: int) -> KeycloakAdmin:
    token: dict[str, object] = {"access_token": "", "expires_in": expires_in}
    if credentials:
        token["refresh_token"] = REFRESH_OLD
        return KeycloakAdmin(
            server_url=url,
            realm_name="r",
            client_id="c",
            client_secret_key=SECRET,
            grant_type="client_credentials",
            token=token,
        )
    # 자격증명 없이 토큰만 넘긴 admin — 만료되면 python-keycloak 은 토큰을 None 으로 비우지만
    # 헤더는 그대로 둔다. 그래서 보낼 bearer 는 저장된 토큰이 아니라 **헤더**에서 읽어야 한다.
    return KeycloakAdmin(server_url=url, realm_name="r", token=token)


@pytest.mark.parametrize(
    ("credentials", "expires_in"),
    [(True, 300), (False, 0)],
    ids=["자격증명·유효", "토큰만·만료(헤더만 남는다)"],
)
@pytest.mark.parametrize("path", ["리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_injected_admin_holding_an_unusable_bearer_sends_nothing(
    lane: str, path: str, credentials: bool, expires_in: int
) -> None:
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        admin = _injected(idp.url, credentials=credentials, expires_in=expires_in)
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        act = (lambda c: c.users.get("u1")) if path == "리소스" else _raw_get(lane, admin)
        result, err = await _attempt(lane, client, act)
        await _close(lane, client)

    assert result is None
    assert idp.admin_requests() == [], "주입된 admin 이 쓸 수 없는 bearer 를 보냈다"
    assert idp.grant_types() == []
    verdict = _auth_lane_verdict(_EMPTY)
    if path == "리소스":
        assert _refused_like_the_auth_lane(err, verdict) == []
    else:
        assert (type(err), str(err)) == verdict


# --- 리다이렉트 하드닝도 살아 있는 연결에 ------------------------------------------------


def test_a_replaced_connection_still_refuses_redirects(trap: Trap) -> None:
    """대조군을 같은 테스트에 둔다 — 하드닝 없는 새 연결은 307 을 따라가 client_secret 을 넘긴다."""
    stock = KeycloakAdmin(connection=_trap_connection(trap))
    assert stock.get_users({}) == [{"id": "planted", "username": "planted"}]
    assert len(trap.hits) == 2, "대조군이 두 세션 모두에서 새지 않았다 — 덫 고장"
    assert CLIENT_SECRET in trap.hits[0].body, "대조군의 그랜트가 client_secret 을 싣지 않았다"
    trap.reset()

    client = AdminClient(_trap_cfg(trap))
    client.raw.connection = _trap_connection(trap)
    with pytest.raises(KeycloakAdminError) as exc_info:
        client.users.search()

    assert trap.hits == [], "갈아 끼운 연결이 리다이렉트를 따라갔다"
    assert exc_info.value.status_code == 307


def test_a_replaced_token_grant_session_still_refuses_redirects(trap: Trap) -> None:
    """중첩 그랜트 객체의 연결도 공개 세터다(`KeycloakOpenID.connection`) — 바깥 REST 세션은 그대로
    막혀 있어도 그랜트 POST 가 `client_secret` 을 실어 리다이렉트 대상으로 간다."""
    stock = KeycloakAdmin(connection=_trap_connection(trap))
    stock.connection.keycloak_openid.connection = ConnectionManager(
        base_url=trap.idp_url, timeout=5
    )
    stock.get_users({})
    grant = trap.hits[0]
    assert "token" in grant.path and CLIENT_SECRET in grant.body, "대조군 덫이 무장되지 않았다"
    trap.reset()

    client = AdminClient(_trap_cfg(trap))
    client.raw.connection.keycloak_openid.connection = ConnectionManager(
        base_url=trap.idp_url, timeout=5
    )
    with pytest.raises(KeycloakAdminError) as exc_info:
        client.users.search()

    assert trap.hits == [], "갈아 끼운 그랜트 세션이 client_secret 을 리다이렉트 대상에 넘겼다"
    assert exc_info.value.status_code == 307


def _trap_cfg(trap: Trap) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=trap.idp_url,
        realm="t",
        client_id="app",
        client_secret=CLIENT_SECRET,
        read_timeout=5.0,
    )


def _trap_connection(trap: Trap) -> KeycloakOpenIDConnection:
    return KeycloakOpenIDConnection(
        server_url=trap.idp_url,
        realm_name="t",
        client_id="app",
        client_secret_key=CLIENT_SECRET,
        grant_type="client_credentials",
        timeout=5,
    )


# --- (H3) 설치는 전부이거나 아무것도 아니다 ----------------------------------------------


class _NoSetter(KeycloakOpenID):
    """`a_token` 을 인스턴스에서 다시 묶을 수 없다 — 세터 없는 프로퍼티."""

    @property
    def a_token(self) -> Any:  # type: ignore[override]
        return KeycloakOpenID.a_token.__get__(self)


class _IgnoresSetter(KeycloakOpenID):
    """세터는 있지만 값을 버린다 — `setattr` 은 성공하고 훅은 걸리지 않는다."""

    @property
    def a_token(self) -> Any:  # type: ignore[override]
        return KeycloakOpenID.a_token.__get__(self)

    @a_token.setter
    def a_token(self, _value: Any) -> None:
        pass


_SEALED = {"세터 없음": _NoSetter, "세터가 버림": _IgnoresSetter}


def _sealed(url: str, kind: str) -> KeycloakOpenID:
    return _SEALED[kind](server_url=url, realm_name="r", client_id="c", client_secret_key=SECRET)


def _hooks_left(conn: Any) -> list[str]:
    """`conn` 그래프에 인스턴스 속성으로 남은 **SDK 의** 훅 — 되돌렸으면 하나도 없다."""
    nested = conn.keycloak_openid  # 지연 프로퍼티 — 아직 없으면 훅 없는 새 객체가 생긴다
    spots = [
        ("connection._s", conn._s, ("resolve_redirects",)),
        ("keycloak_openid.connection._s", nested.connection._s, ("resolve_redirects",)),
        ("keycloak_openid", nested, _GRANTS),
        ("connection", conn, _BEARER_HOOKS),
    ]
    return [
        f"{where}.{name}"
        for where, obj, names in spots
        for name in names
        if str(getattr(vars(obj).get(name), "__module__", "")).startswith("keycloak_sdk.")
    ]


@pytest.mark.parametrize("kind", list(_SEALED))
@pytest.mark.parametrize("lane", LANES)
def test_an_install_that_fails_part_way_changes_nothing(lane: str, kind: str) -> None:
    admin = KeycloakAdmin(
        server_url="http://127.0.0.1:9",
        realm_name="r",
        client_id="c",
        client_secret_key=SECRET,
        grant_type="client_credentials",
    )
    admin.connection._keycloak_openid = _sealed("http://127.0.0.1:9", kind)

    with pytest.raises(KeycloakConfigError, match=r"keycloak_openid\.a_token\b"):
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=admin)

    assert _hooks_left(admin.connection) == []
    assert type(admin) is KeycloakAdmin


class _RefusesItsClass(KeycloakAdmin):
    def __setattr__(self, name: str, value: Any) -> None:
        if name == "__class__":
            raise TypeError("this admin keeps its class")
        super().__setattr__(name, value)


class _PlainConnection(KeycloakAdmin):
    connection = None  # 프로퍼티를 평범한 클래스 속성으로 가린다 — 가로챌 읽기 자리가 없다


@pytest.mark.parametrize(
    ("cls", "match"),
    [(_RefusesItsClass, "class"), (_PlainConnection, r"connection is not a property")],
    ids=["클래스 교체 거부", "connection 이 프로퍼티가 아님"],
)
@pytest.mark.parametrize("lane", LANES)
def test_an_admin_that_cannot_be_watched_is_refused_untouched(
    lane: str, cls: type[KeycloakAdmin], match: str
) -> None:
    admin = cls(
        server_url="http://127.0.0.1:9",
        realm_name="r",
        client_id="c",
        client_secret_key=SECRET,
        grant_type="client_credentials",
    )
    conn = vars(admin).get("connection") or vars(admin)["_connection"]

    with pytest.raises(KeycloakConfigError, match=match):
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=admin)

    assert _hooks_left(conn) == []
    assert type(admin) is cls


def _session_of(admin: KeycloakAdmin, which: str) -> Any:
    conn = admin.connection
    return conn._s if which == "admin REST call" else conn.keycloak_openid.connection._s


@pytest.mark.parametrize("which", ["admin REST call", "admin token grant"])
@pytest.mark.parametrize("lane", LANES)
def test_a_session_without_its_redirect_hook_is_refused_untouched(lane: str, which: str) -> None:
    """두 세션 어느 쪽이든 리다이렉트를 막을 자리가 없으면 만들지 않는다 — 다른 훅도 걸지 않는다."""
    admin = KeycloakAdmin(server_url="http://127.0.0.1:9", realm_name="r", client_id="c")
    _session_of(admin, which).resolve_redirects = None

    with pytest.raises(KeycloakConfigError, match=f"cannot harden the {which}"):
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=admin)

    assert _hooks_left(admin.connection) == []
    assert type(admin) is KeycloakAdmin


@pytest.mark.parametrize("name", _BEARER_HOOKS)
@pytest.mark.parametrize("lane", LANES)
def test_construction_is_refused_when_the_bearer_check_has_no_seam(lane: str, name: str) -> None:
    """python-keycloak 이 갱신 자리를 옮기면 bearer 검사 없이 조용히 만들지 않는다(그랜트
    검사와 같다). 목에도 건다 — 주입 경로가 생성 경로보다 느슨하면 주입으로 증명하는 테스트가
    실제와 달라진다."""
    admin = MagicMock(spec=KeycloakAdmin)
    delattr(admin.connection, name)

    # 이름만으로는 둘이 서로를 포함한다(`_refresh_if_required` ⊂ `a__refresh_if_required`).
    with pytest.raises(KeycloakConfigError, match=rf"connection\.{name}\b"):
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=admin)


@pytest.mark.parametrize("lane", LANES)
def test_an_already_guarded_admin_is_not_wrapped_twice(lane: str) -> None:
    """`raw` 를 다른 클라이언트에 넘겨도 감시 층은 하나다 — 그리고 여전히 감시한다."""
    first = _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"))
    raw = first.raw
    guarded = type(raw)

    second = _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=raw)

    assert second.raw is raw
    assert type(raw) is guarded and guarded.__mro__[1] is KeycloakAdmin
    raw.connection = None
    with pytest.raises(KeycloakConfigError):
        raw.get_current_realm()


@pytest.mark.parametrize("path", ["리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_replaced_connection_that_cannot_be_guarded_sends_nothing(
    lane: str, path: str
) -> None:
    """요청 시점의 재설치도 전부이거나 아무것도 아니다 — 실패하면 그 연결은 손대지 않은 채
    거부한다."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        async with _client(lane, idp) as client:
            raw = client.admin.raw
            old = raw.connection
            replacement = _connection(idp.url)
            replacement._keycloak_openid = _sealed(idp.url, "세터 없음")
            # 소비자가 먼저 건 자기 훅 — 되돌림은 이것을 지우지 않고 **그대로** 돌려놓는다.
            own_hook = replacement._s.resolve_redirects = _consumer_refuses_redirects
            raw.connection = replacement
            act = (lambda c: c.admin.users.get("u1")) if path == "리소스" else _raw_get(lane, raw)
            result, err = await _attempt(lane, client, act)
            await _close_connection(lane, old)

    assert result is None
    assert isinstance(err, KeycloakConfigError)
    assert idp.seen == [], "보호할 수 없는 연결로 요청을 보냈다"
    assert _hooks_left(replacement) == []
    assert vars(replacement._s)["resolve_redirects"] is own_hook
    if path == "리소스":  # 경계가 python-keycloak 프레임(요청 본문을 쥔다)을 떼고 새로 던진다
        assert _inner_frames(err) == []
        assert err.__cause__ is None and err.__context__ is None


def _consumer_refuses_redirects(*_args: Any, **_kwargs: Any) -> Any:
    return iter(())


@pytest.mark.parametrize("lane", LANES)
async def test_a_request_that_carries_no_bearer_is_left_to_the_server(lane: str) -> None:
    """검사는 **bearer** 를 본다 — 자격증명도 토큰도 없는 admin 은 python-keycloak 대로 헤더 없이
    보내고 판정은 서버가 한다. 지나치게 거부하지 않는다는 경계다."""
    with _fake_idp() as idp:
        client = _ADMIN_CLIENTS[lane](
            _cfg(idp.url), admin=KeycloakAdmin(server_url=idp.url, realm_name="r")
        )
        result, err = await _attempt(lane, client, lambda c: c.users.get("u1"))
        await _close(lane, client)

    assert (result, err) == ({"id": "u1"}, None)
    assert idp.admin_requests() == [_Seen("GET", _USER, "", None)]
    assert idp.grant_types() == []


# --- 정리는 무장하지 않는다 -----------------------------------------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_cleanup_does_not_arm_a_connection_it_only_closes(lane: str) -> None:
    """`close`·`aclose` 는 요청을 보내지 않는다 — 보호할 수 없는 연결이라도 정리는 막지 않는다."""
    client = _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"))
    raw = client.raw
    old = raw.connection
    raw.connection = None

    await _close(lane, client)  # 거부하지 않는다
    with pytest.raises(KeycloakConfigError):
        raw.get_current_realm()  # 연결을 쓰는 순간에는 거부한다

    del raw._connection  # 연결 필드 자체가 없어도 정리는 조용히 넘어간다(예전과 같다)
    await _close(lane, client)
    await _close_connection(lane, old)
