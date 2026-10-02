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

import copy
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock
from urllib.parse import parse_qs

import pytest
import requests
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


@pytest.mark.parametrize("lane", LANES)
async def test_a_copied_connection_is_checked_on_its_own_header(lane: str) -> None:
    """얕은 복사본은 원본의 훅을 인스턴스 속성째 물려받는다 — 그 훅은 **원본의** 헤더를 본다.
    복사본이 제 헤더를 따로 갖게 되면, 원본 것을 「이미 걸린 훅」으로 셈하는 한 복사본의 빈
    bearer 가 검사 없이 나갔다(수정 전 실측 sync `['Bearer ']`)."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        async with _client(lane, idp) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            raw = client.admin.raw
            dup = copy.copy(raw.connection)
            dup.headers = dict(dup.headers)  # 복사본이 제 헤더를 갖는다
            dup.token = {"access_token": "", "expires_in": 300}
            raw.connection = dup
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert result is None
    assert _refused_like_the_auth_lane(err, _auth_lane_verdict(_EMPTY)) == []
    assert idp.admin_requests() == [_Seen("GET", _USER, "", f"Bearer {ACCESS_OLD}")]


# 복사본이 물려받은 래퍼는 **원본의** 갱신(원본에 묶인 메서드)과 원본의 헤더 검사를 부른다. 그것을
# 다시 감싸기만 하면 바깥 래퍼가 복사본의 헤더를 보더라도 안쪽이 원본에서 돈다 — 그래서 물려받은
# 래퍼는 벗기고 복사본 자신의 것을 감싼다. 셋 다 수정 전 실측으로 실패했다(검증 레그).

_ACCESS_NEW = "AN3h7q-access-from-the-copys-own-refresh"
_TWIN_SECRET = "TS8w2e-secret-of-the-copied-grant-object"


@pytest.mark.parametrize("lane", LANES)
async def test_a_copy_that_carries_no_bearer_is_not_refused_for_the_originals_header(
    lane: str,
) -> None:
    """bearer 를 싣지 않는 요청은 검사가 거부하지 않는다 — 원본의 헤더가 비었어도, 그것은 이
    요청이 싣는 헤더가 아니다(수정 전: 원본 래퍼의 검사로 `KeycloakAuthError`, 요청 없음)."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        async with _client(lane, idp) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            raw = client.admin.raw
            original = raw.connection
            dup = copy.copy(original)
            dup.headers = {"Content-Type": "application/json"}  # 복사본은 bearer 를 싣지 않는다
            original.token = {"access_token": "", "expires_in": 300}  # 원본만 빈 bearer 다
            raw.connection = dup
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            raw.connection = original

    assert (result, err) == ({"id": "u1"}, None)
    assert idp.admin_requests() == [
        _Seen("GET", _USER, "", f"Bearer {ACCESS_OLD}"),
        _Seen("GET", _USER, "", None),
    ]


@pytest.mark.parametrize("lane", LANES)
async def test_a_copy_keeps_the_consumers_own_hook_it_inherited(lane: str) -> None:
    """원본에 소비자가 먼저 건 자기 훅이 있었으면, 복사본이 벗겨 감싸는 것은 그 훅이다 —
    `copy.copy` 가 SDK 없이 물려줬을 바로 그것(클래스의 메서드로 바꿔치지도, 원본의 검사를
    끌어오지도 않는다). 수정 전: 원본 래퍼째 다시 감싸 원본의 빈 bearer 로 거부됐다."""
    name = _BEARER_HOOKS[0] if lane == "sync" else _BEARER_HOOKS[1]
    with _fake_idp() as idp:
        admin = KeycloakAdmin(
            server_url=idp.url,
            realm_name="r",
            client_id="c",
            client_secret_key=SECRET,
            grant_type="client_credentials",
            token={"access_token": ACCESS_OLD, "expires_in": 300},
        )
        original = admin.connection
        inner = getattr(original, name)
        calls: list[int] = []

        def hook(*args: Any, **kwargs: Any) -> Any:  # 함수지만 SDK 의 것은 아니다
            calls.append(1)
            return inner(*args, **kwargs)

        setattr(original, name, hook)  # SDK 보다 먼저 건 소비자의 훅
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        dup = copy.copy(original)
        dup.headers = {"Content-Type": "application/json"}  # 복사본은 bearer 를 싣지 않는다
        original.token = {"access_token": "", "expires_in": 300}  # 원본만 빈 bearer 다
        admin.connection = dup
        result, err = await _attempt(lane, client, lambda c: c.users.get("u1"))
        admin.connection = original
        await _close(lane, client)

    assert (result, err) == ({"id": "u1"}, None)
    assert calls == [1], "복사본이 물려받은 소비자의 훅을 부르지 않았다"
    assert idp.admin_requests() == [_Seen("GET", _USER, "", None)]


@pytest.mark.parametrize("lane", LANES)
async def test_a_copy_refreshes_itself_not_the_connection_it_was_copied_from(lane: str) -> None:
    """만료된 복사본은 **제** 토큰을 갱신해 새 bearer 로 보낸다 — python-keycloak 그대로다(수정 전:
    갱신은 원본에서 돌고 복사본은 옛 토큰을 보냈다)."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [
            (200, _grant_body(ACCESS_OLD, expires_in=1, refresh_token=REFRESH_OLD))
        ]
        idp.grants["refresh_token"] = [
            (200, _grant_body(_ACCESS_NEW, expires_in=300, refresh_token=REFRESH_NEW))
        ]
        async with _client(lane, idp) as client:
            first, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            assert (first, err) == ({"id": "u1"}, None), "앞 호출이 성공하지 않았다"
            raw = client.admin.raw
            original = raw.connection
            dup = copy.copy(original)
            dup.headers = dict(dup.headers)
            raw.connection = dup
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))
            held = (dup.token["access_token"], original.token["access_token"])
            raw.connection = original

    assert (result, err) == ({"id": "u1"}, None)
    assert idp.grant_types() == ["client_credentials", "refresh_token"]
    assert idp.admin_requests()[-1] == _Seen("GET", _USER, "", f"Bearer {_ACCESS_NEW}")
    assert held == (_ACCESS_NEW, ACCESS_OLD), "갱신이 복사본이 아니라 원본에서 돌았다"


@pytest.mark.parametrize("lane", LANES)
async def test_a_copied_token_grant_object_grants_with_its_own_credentials(lane: str) -> None:
    """같은 부류의 그랜트 쪽 — 중첩 `KeycloakOpenID` 의 복사본도 물려받은 그랜트 래퍼를 벗긴다
    (수정 전: 복사본의 그랜트가 원본에 묶인 메서드로 **원본의** client_secret 을 실어 나갔다).
    공개 세터가 없어 비공개 필드로 끼운다 — 같은 감싸기 자리(`_plan_wrap`)를 재는 것이 목적이다."""
    secrets: list[str] = []
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        answer = idp.answer

        def recording(method: str, path: str, body: str, authorization: str | None) -> Any:
            secrets.extend(parse_qs(body).get("client_secret", []))
            return answer(method, path, body, authorization)

        idp.answer = recording  # type: ignore[method-assign]
        async with _client(lane, idp) as client:
            conn = client.admin.raw.connection
            twin = copy.copy(conn.keycloak_openid)
            twin.client_secret_key = _TWIN_SECRET
            conn._keycloak_openid = twin
            result, err = await _attempt(lane, client, lambda c: c.admin.users.get("u1"))

    assert (result, err) == ({"id": "u1"}, None)
    assert secrets == [_TWIN_SECRET], "복사본의 그랜트가 원본의 자격증명으로 나갔다"


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


class _RefusesSubclassing(KeycloakAdmin):
    """하위 클래스를 막는다 — 런타임 「final」의 흔한 꼴. 감시 하위 클래스를 만들 수 없다(수정 전:
    생성이 raw `TypeError` 였다)."""

    def __init_subclass__(cls, **kwargs: Any) -> None:
        raise TypeError("this admin class is final")


@pytest.mark.parametrize(
    ("cls", "match"),
    [
        (_RefusesItsClass, "class"),
        (_PlainConnection, r"connection is not a property"),
        (_RefusesSubclassing, r"subclassing _RefusesSubclassing\b"),
    ],
    ids=["클래스 교체 거부", "connection 이 프로퍼티가 아님", "하위 클래스 생성 거부"],
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


def _without_connection(url: str) -> KeycloakAdmin:
    admin = KeycloakAdmin(
        server_url=url,
        realm_name="r",
        client_id="c",
        client_secret_key=SECRET,
        grant_type="client_credentials",
    )
    del admin._connection
    return admin


@pytest.mark.parametrize("path", ["리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_deleted_connection_is_refused_as_construction_refuses_it(
    lane: str, path: str
) -> None:
    """연결 필드가 지워지면 요청 직전의 무장은 걸 곳이 없다 — 생성 때 같은 상태가 내는 것과 같은
    `KeycloakConfigError` 다(수정 전: 감시 게터가 원래 프로퍼티의 raw `AttributeError` 를 그대로
    냈고, 리소스로는 `KeycloakTransportError` 였다)."""
    with _fake_idp() as idp:
        with pytest.raises(KeycloakConfigError) as at_construction:
            _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=_without_connection(idp.url))
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url))
        raw = client.raw
        held = raw.connection
        del raw._connection
        direct = (
            (lambda _c: raw.get_users({})) if lane == "sync" else (lambda _c: raw.a_get_users({}))
        )
        act = (lambda c: c.users.search()) if path == "리소스" else direct
        result, err = await _attempt(lane, client, act)
        raw._connection = held
        await _close(lane, client)

    assert result is None
    assert (type(err), str(err)) == (KeycloakConfigError, str(at_construction.value))
    assert idp.seen == [], "연결 없이 무언가 보냈다"
    if path == "리소스":
        assert _inner_frames(err) == []
        assert err.__cause__ is None and err.__context__ is None


@dataclass(eq=True)
class _OwnHook:
    """소비자가 먼저 건 자기 훅 — `eq=True` 데이터클래스라 **해시되지 않는다**."""

    inner: Callable[..., Any]
    calls: int = 0

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        self.calls += 1
        return self.inner(*args, **kwargs)


@pytest.mark.parametrize("lane", LANES)
async def test_a_consumers_own_unhashable_hook_is_wrapped_not_a_crash(lane: str) -> None:
    """소비자가 먼저 건 훅은 지우지 않고 감싼다 — 해시되지 않는 객체여도(수정 전: 「우리 래퍼인가」
    대조가 그것을 해시하다 생성이 raw `TypeError` 였다). 감싼 뒤에도 훅은 불리고 검사는 선다."""
    name = _BEARER_HOOKS[0] if lane == "sync" else _BEARER_HOOKS[1]
    with _fake_idp() as idp:
        admin = _injected(idp.url, credentials=True, expires_in=300)  # 빈 bearer 를 쥐고 온다
        hook = _OwnHook(getattr(admin.connection, name))
        setattr(admin.connection, name, hook)
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        result, err = await _attempt(lane, client, lambda c: c.users.get("u1"))
        await _close(lane, client)

    assert result is None
    assert _refused_like_the_auth_lane(err, _auth_lane_verdict(_EMPTY)) == []
    assert hook.calls == 1, "소비자의 훅이 감싸지지 않고 사라졌다"
    assert idp.seen == []


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


# --- 2차 검증 레그 — 그래프를 읽다 나는 실패 · 재진입한 설치 · `__dict__` 밖에 사는 훅 ------------
#
# 셋 다 계약 3(전부이거나 아무것도, 실패는 `KeycloakConfigError`)의 구멍이었다.
# 수정 전 실측(a505b8b): 그래프를 읽다 난 `TypeError`·`ValueError` 는 raw 로 새거나
# 리소스로는 `KeycloakTransportError` 였고, 설치 도중 소비자 코드가 `admin.connection` 을
# 다시 읽으면 안쪽 설치가 다 건 것을 바깥 되돌림이 반만 되돌려 거부된 연결에 SDK 훅 일곱이
# 남았으며, 슬롯·곁 사전에 사는 소비자의 훅은 되돌림 뒤 SDK 훅으로 바뀌어 있었다.


def _graph_connection(cls: type[KeycloakOpenIDConnection], url: str) -> Any:
    return cls(
        server_url=url,
        realm_name="r",
        client_id="c",
        client_secret_key=SECRET,
        grant_type="client_credentials",
    )


class _UnreadableSession(KeycloakOpenIDConnection):
    """`_s` 를 읽으면 `TypeError` — 그래프를 읽다 나는 실패는 `AttributeError` 만이 아니다."""

    def __getattribute__(self, name: str) -> Any:
        if name == "_s" and object.__getattribute__(self, "__dict__").get("_broken"):
            raise TypeError("connection._s cannot be read")
        return super().__getattribute__(name)


class _RefusingDescriptor:
    def __get__(self, obj: Any, owner: Any = None) -> Any:
        if obj is not None and obj.__dict__.get("_broken"):
            raise TypeError("the refresh seam refuses to be read")
        return KeycloakOpenIDConnection._refresh_if_required.__get__(obj, owner)


class _UnreadableRefreshSeam(KeycloakOpenIDConnection):
    _refresh_if_required = _RefusingDescriptor()  # type: ignore[assignment]


class _UnbuildableGrantObject(KeycloakOpenIDConnection):
    """python-keycloak 이 중첩 그랜트 객체를 지연 생성하는 자리가 `ValueError` 를 던진다."""

    @property
    def keycloak_openid(self) -> KeycloakOpenID:
        if self.__dict__.get("_broken"):
            raise ValueError("cannot build the token grant object")
        return super().keycloak_openid


_UNREADABLE: dict[str, tuple[type[KeycloakOpenIDConnection], str]] = {
    "_s 를 읽으면 TypeError": (_UnreadableSession, "TypeError"),
    "갱신 자리 디스크립터가 TypeError": (_UnreadableRefreshSeam, "TypeError"),
    "중첩 그랜트 객체 생성이 ValueError": (_UnbuildableGrantObject, "ValueError"),
}


@pytest.mark.parametrize("path", ["생성", "리소스", "raw"])
@pytest.mark.parametrize("kind", list(_UNREADABLE))
@pytest.mark.parametrize("lane", LANES)
async def test_a_connection_graph_that_fails_to_be_read_is_refused_as_a_config_error(
    lane: str, kind: str, path: str
) -> None:
    """무장이 그래프를 읽다 실패하면 — 무엇을 던졌든 — 생성 때도 요청 직전에도 `KeycloakConfigError`
    이고 아무것도 보내지 않는다(수정 전: raw `TypeError`·`ValueError`, 리소스로는
    `KeycloakTransportError`)."""
    cls, thrown = _UNREADABLE[kind]
    with _fake_idp() as idp:
        broken = _graph_connection(cls, idp.url)
        broken.__dict__["_broken"] = True
        if path == "생성":
            admin = KeycloakAdmin(connection=broken)
            result, err = await _attempt(
                "sync", None, lambda _c: _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
            )
            assert type(admin) is KeycloakAdmin, "거부했는데 클래스를 바꿨다"
        else:
            client = _ADMIN_CLIENTS[lane](_cfg(idp.url))
            raw = client.raw
            old = raw.connection
            raw.connection = broken
            direct = (
                (lambda _c: raw.get_users({}))
                if lane == "sync"
                else (lambda _c: raw.a_get_users({}))
            )
            act = (lambda c: c.users.search()) if path == "리소스" else direct
            result, err = await _attempt(lane, client, act)
            raw.connection = old
            await _close(lane, client)
        broken.__dict__["_broken"] = False
        hooks = _hooks_left(broken)
        await _close_connection(lane, broken)

    assert result is None
    assert type(err) is KeycloakConfigError, f"{type(err).__qualname__}: {err}"
    assert f"failed ({thrown})" in str(err)
    assert idp.seen == [], "무장하지 못한 연결로 무언가 보냈다"
    assert hooks == []
    if path == "리소스":
        assert _inner_frames(err) == []
        assert err.__cause__ is None and err.__context__ is None


class _UnreadableConnection(KeycloakAdmin):
    """admin 자신의 `connection` 프로퍼티가 `TypeError` — 읽지 못한 연결에는 걸 곳이 없다."""

    @property
    def connection(self) -> Any:
        if self.__dict__.get("_broken"):
            raise TypeError("the admin's connection cannot be read")
        return self._connection

    @connection.setter
    def connection(self, value: Any) -> None:
        self._connection = value


@pytest.mark.parametrize("path", ["생성", "리소스", "raw"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_admin_whose_connection_cannot_be_read_is_refused_as_a_config_error(
    lane: str, path: str
) -> None:
    with _fake_idp() as idp:
        admin = _UnreadableConnection(
            server_url=idp.url,
            realm_name="r",
            client_id="c",
            client_secret_key=SECRET,
            grant_type="client_credentials",
        )
        if path == "생성":
            admin.__dict__["_broken"] = True
            result, err = await _attempt(
                "sync", None, lambda _c: _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
            )
            assert type(admin) is _UnreadableConnection, "거부했는데 클래스를 바꿨다"
            admin.__dict__["_broken"] = False
            await _close_connection(lane, admin.connection)
        else:
            client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
            admin.__dict__["_broken"] = True
            direct = (
                (lambda _c: admin.get_users({}))
                if lane == "sync"
                else (lambda _c: admin.a_get_users({}))
            )
            act = (lambda c: c.users.search()) if path == "리소스" else direct
            result, err = await _attempt(lane, client, act)
            admin.__dict__["_broken"] = False
            await _close(lane, client)

    assert result is None
    assert type(err) is KeycloakConfigError, f"{type(err).__qualname__}: {err}"
    assert "failed (TypeError)" in str(err)
    assert idp.seen == []
    if path == "리소스":
        assert _inner_frames(err) == []
        assert err.__cause__ is None and err.__context__ is None


@pytest.mark.parametrize("lane", LANES)
async def test_re_injecting_a_guarded_admin_that_cannot_be_armed_is_refused_alike(
    lane: str,
) -> None:
    """감시 중인 admin 을 다른 클라이언트에 넘기면 생성의 읽기가 곧 무장이다 — 그 거부는 요청
    직전과 같은 메시지 그대로 지난다(「읽기 실패」로 덧씌우지 않는다)."""
    first = _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"))
    raw = first.raw
    old = raw.connection
    raw.connection = None
    with pytest.raises(KeycloakConfigError) as at_request:
        raw.get_current_realm()
    with pytest.raises(KeycloakConfigError) as at_construction:
        _ADMIN_CLIENTS[lane](_cfg("http://127.0.0.1:9"), admin=raw)
    raw.connection = old
    await _close(lane, first)

    assert str(at_construction.value) == str(at_request.value)
    assert "cannot harden the admin REST call" in str(at_request.value)


class _ReentrantSession(requests.Session):
    """소비자 코드가 SDK 가 그래프를 만지는 도중 `admin.connection` 을 **한 번** 다시 읽는다 —
    `__setattr__`(훅을 쓸 때) 또는 `__getattribute__`(방금 쓴 훅을 확인할 때)에서."""

    def _reenter(self, via: str) -> None:
        state = object.__getattribute__(self, "__dict__")
        if state.get("_via") == via and state.get("_budget"):
            state["_budget"] = 0
            _ = state["_admin"].connection

    def __setattr__(self, name: str, value: Any) -> None:
        if name == "resolve_redirects":
            self._reenter("setattr")
        super().__setattr__(name, value)

    def __getattribute__(self, name: str) -> Any:
        if name == "resolve_redirects" and name in object.__getattribute__(self, "__dict__"):
            object.__getattribute__(self, "_reenter")("getattr")
        return super().__getattribute__(name)


class _TakesTheBearerHookOnce(KeycloakOpenIDConnection):
    """`a__refresh_if_required` 훅을 한 번만 받는다 — 재진입한 안쪽 설치는 성공하고, 그 뒤에 같은
    자리를 다시 거는 바깥 설치가 실패한다(쓰기로 거부하든, 처음 받은 훅만 보여 주든)."""

    def __setattr__(self, name: str, value: Any) -> None:
        if name == _BEARER_HOOKS[1]:
            count = self.__dict__.get("_sets", 0) + 1
            self.__dict__["_sets"] = count
            if count == 2:
                raise AttributeError("the bearer hook was already taken")
        super().__setattr__(name, value)

    def __getattribute__(self, name: str) -> Any:
        state = object.__getattribute__(self, "__dict__")
        if name == _BEARER_HOOKS[1] and name in state:
            return state.setdefault("_first", state[name])
        return super().__getattribute__(name)


@pytest.mark.parametrize("via", ["setattr", "getattr"])
@pytest.mark.parametrize("lane", LANES)
async def test_an_install_re_entered_by_the_consumers_code_is_all_or_nothing(
    lane: str, via: str
) -> None:
    """RLock 은 같은 스레드의 재진입을 막지 않는다 — 설치 도중 `admin.connection` 을 다시
    읽으면 안쪽 설치가 끝까지 걸고, 바깥 설치가 실패해 되돌리면 자기가 처음 건 자리만 지운다
    (수정 전 실측: 거부된 연결에 SDK 훅 일곱). 끝 상태는 둘 중 하나여야 한다 — 다 걸려
    보냈거나, 하나도 없이 거부했거나."""
    with _fake_idp() as idp:
        idp.grants["client_credentials"] = [(200, _GOOD)]
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url))
        raw = client.raw
        old = raw.connection
        conn = _graph_connection(_TakesTheBearerHookOnce, idp.url)
        session = _ReentrantSession()
        session.__dict__.update(vars(conn._s))
        session.__dict__.update(_admin=raw, _via=via, _budget=1)
        conn.__dict__["_s"] = session
        raw.connection = conn
        act = (
            (lambda _c: raw.get_user("u1")) if lane == "sync" else (lambda _c: raw.a_get_user("u1"))
        )
        result, err = await _attempt(lane, client, act)
        hooks = _hooks_left(conn)
        raw.connection = old
        await _close(lane, client)
        await _close_connection(lane, conn)

    if err is None:
        assert result == {"id": "u1"}
        assert len(hooks) == len(_GRANTS) + 4, hooks  # 두 세션 + 그랜트 넷 + bearer 둘
    else:
        assert type(err) is KeycloakConfigError, f"{type(err).__qualname__}: {err}"
        assert hooks == [], "거부한 설치가 SDK 훅을 남겼다 — 전부이거나 아무것도가 아니다"
        assert idp.seen == []


def _consumers_own_redirect_hook(*_args: Any, **_kwargs: Any) -> Any:
    return iter(())


class _SideStoredHook(requests.Session):
    """`resolve_redirects` 를 인스턴스 `__dict__` 가 아닌 곁 사전에 두고 거기서 읽는다."""

    def __setattr__(self, name: str, value: Any) -> None:
        if name == "resolve_redirects":
            self.__dict__.setdefault("_side", {})[name] = value
            return
        super().__setattr__(name, value)

    def __getattribute__(self, name: str) -> Any:
        if name == "resolve_redirects":
            side = object.__getattribute__(self, "__dict__").get("_side", {})
            if name in side:
                return side[name]
        return super().__getattribute__(name)


class _SlottedHook(requests.Session):
    """`resolve_redirects` 가 슬롯이다 — 클래스의 데이터 디스크립터가 인스턴스 `__dict__` 를
    가린다."""

    __slots__ = ("resolve_redirects",)


class _RefusesTheRedirectHook(requests.Session):
    """둘째 자리(중첩 그랜트 세션)에 훅을 쓰면 실패한다 — 첫 자리를 건 **뒤**의 실패다."""

    def __setattr__(self, name: str, value: Any) -> None:
        if name == "resolve_redirects":
            raise AttributeError("the grant session refuses the redirect hook")
        super().__setattr__(name, value)


def _graft(cls: type[requests.Session], source: requests.Session) -> Any:
    session = cls()
    for name, value in vars(source).items():
        object.__setattr__(session, name, value)
    return session


_OUTSIDE_THE_DICT = {"곁 사전": _SideStoredHook, "슬롯": _SlottedHook}


@pytest.mark.parametrize("store", list(_OUTSIDE_THE_DICT))
@pytest.mark.parametrize("lane", LANES)
async def test_a_hook_the_consumer_keeps_outside_the_instance_dict_survives_a_refused_install(
    lane: str, store: str
) -> None:
    """되돌림은 인스턴스 `__dict__` 로 한다 — 설치가 다른 통로(소비자의 `__setattr__`·슬롯)로
    들어가면 되돌림이 못 보고, 소비자가 먼저 건 자기 훅이 SDK 훅으로 바뀐 채 남았다(수정 전
    실측: 둘 다 `_refuse_redirects`)."""
    with _fake_idp() as idp:
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url))
        raw = client.raw
        old = raw.connection
        conn = _connection(idp.url)
        conn._s = _graft(_OUTSIDE_THE_DICT[store], conn._s)
        conn._s.resolve_redirects = _consumers_own_redirect_hook  # SDK 보다 먼저 건 소비자의 훅
        nested = conn.keycloak_openid.connection
        nested._s = _graft(_RefusesTheRedirectHook, nested._s)
        raw.connection = conn
        act = (
            (lambda _c: raw.get_user("u1")) if lane == "sync" else (lambda _c: raw.a_get_user("u1"))
        )
        result, err = await _attempt(lane, client, act)
        kept = conn._s.resolve_redirects
        hooks = _hooks_left(conn)
        raw.connection = old
        await _close(lane, client)
        await _close_connection(lane, conn)

    assert result is None
    assert type(err) is KeycloakConfigError, f"{type(err).__qualname__}: {err}"
    assert kept is _consumers_own_redirect_hook, f"소비자의 훅이 {kept!r} 로 바뀌었다"
    assert hooks == []
    assert idp.seen == []
