"""토큰·introspection 응답 본문의 바이트 상한 — aio 레인 다섯 + logout(sync 미러는
`tests/unit/test_token_response_cap.py` — 같은 판정을 같은 이름으로 잰다).

⚠️ 두 미러 모두 원문을 받아 SDK 가 상한 안에서 푼다(`_internal/token_cap.py`) — httpx 의 디코더에는
상한이 없고(`_internal/jwks_fetch.py` 실측: 20 MB 폭탄에 피크 84 MB) urllib3 는 2.6.0 부터만 `amt`
까지 푼다. 그래서 이 미러도 gzip 폭탄과, 상한 안에서 풀 수 없는 인코딩(`br`·`zstd`)을 요구하지
않는지를 본다 — 레인마다(logout 포함).
"""

from __future__ import annotations

import json
import tracemalloc
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import pytest
from keycloak import KeycloakOpenIDConnection
from keycloak.connection import ConnectionManager

from keycloak_sdk._internal.lower import LowerLibraryError
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakAuthError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet

CAP = 1_048_576
LARGEST_DEFAULT_BEARER = 65_459  # Keycloak 26.6 기본 설정이 받는 가장 긴 bearer(실측 2026-10-03)
HUGE = 16 * 1024 * 1024
LANES = ("cc", "refresh", "code", "introspect", "admin")
#: logout 도 같은 세션(`connection.async_s`)으로 나간다 — 성공이 본문 없는 204 라 받는 쪽 시험에는
#: 없고, 거부하는 쪽 시험과 인코딩 시험에 낀다.
REFUSING = (*LANES, "logout")
_WHAT = {"introspect": "introspection response", "logout": "logout response"}
_INVALID_GRANT = b'{"error":"invalid_grant"}'
_BOUNDED_PEAK = 4 * 1024 * 1024

pytestmark = pytest.mark.usefixtures("fast_tls")


def _config(idp: Any) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=idp.url, realm="r", client_id="c", client_secret="s3cret", read_timeout=10.0
    )


def _head(lane: str, token: str) -> bytes:
    if lane == "introspect":
        return json.dumps({"active": True, "username": "u", "client_id": "c"}).encode()
    return json.dumps({"access_token": token, "token_type": "Bearer", "expires_in": 300}).encode()


@asynccontextmanager
async def _client(idp: Any) -> AsyncIterator[AsyncKeycloakClient]:
    async with AsyncKeycloakClient.create(_config(idp)) as kc:
        _ = kc.admin.raw  # 재는 것은 호출이지 생성이 아니다(네트워크 없음)
        yield kc


async def _call(lane: str, kc: AsyncKeycloakClient, token: str) -> object:
    if lane == "cc":
        return await kc.auth.client_credentials_token()
    if lane == "refresh":
        return await kc.auth.refresh("refresh-token")
    if lane == "code":
        return await kc.auth.exchange_code("code", "http://127.0.0.1/cb", "v" * 43)
    if lane == "introspect":
        return await kc.auth.introspect(token)
    if lane == "logout":
        return await kc.auth.logout("refresh-token")
    return await kc.admin.realms.list()


def _serve_success(idp: Any, lane: str, token: str) -> None:
    """그 레인의 성공 응답 — logout 은 본문 없는 204 다."""
    if lane == "logout":
        idp.status, idp.head = 204, b""
    else:
        idp.head = _head(lane, token)


def _assert_accepted(lane: str, idp: Any, result: object, token: str) -> None:
    if lane == "logout":
        assert result is None
    elif lane == "introspect":
        assert isinstance(result, IntrospectionResult)
        assert result.active is True
        assert idp.introspected_len == len(token)
    elif lane == "admin":
        assert result == []
        assert idp.bearer_len == len("Bearer ") + len(token)
    else:
        assert isinstance(result, TokenSet)
        assert result.access_token == token


def _assert_refused(lane: str, idp: Any, exc: BaseException) -> None:
    """sync 미러와 같다 — 원인은 `a_raw_post` 가 감싼 실패의 요약 하나뿐이고 `__context__` 는
    비어 있다(§4, `_internal/lower.py`)."""
    assert type(exc) is KeycloakAuthError, f"{type(exc).__module__}.{type(exc).__qualname__}"
    assert str(exc) == f"{_WHAT.get(lane, 'token response')} exceeds {CAP} bytes"
    assert exc.error is None
    assert exc.__context__ is None, repr(exc.__context__)
    cause = exc.__cause__
    assert type(cause) is LowerLibraryError, repr(cause)
    assert str(cause).partition(" ")[0] == "keycloak.exceptions.KeycloakConnectionError", str(cause)
    assert cause.__cause__ is None and cause.__context__ is None
    assert not [p for p in idp.hits if p.startswith("/admin/")], "admin REST request went out"


@pytest.mark.parametrize("lane", LANES)
async def test_the_largest_default_bearer_passes_every_lane(lane: str, token_idp: Any) -> None:
    token = "A" * LARGEST_DEFAULT_BEARER
    token_idp.head = _head(lane, token)

    async with _client(token_idp) as kc:
        result = await _call(lane, kc, token)

    _assert_accepted(lane, token_idp, result, token)


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_body_of_exactly_the_cap_is_accepted(
    lane: str, chunked: bool, token_idp: Any
) -> None:
    token = "B" * 40
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, token), CAP, chunked

    async with _client(token_idp) as kc:
        result = await _call(lane, kc, token)

    _assert_accepted(lane, token_idp, result, token)


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", REFUSING)
async def test_one_byte_over_the_cap_is_refused(lane: str, chunked: bool, token_idp: Any) -> None:
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "C" * 40), CAP + 1, chunked

    async with _client(token_idp) as kc:
        with pytest.raises(Exception) as excinfo:
            await _call(lane, kc, "C" * 40)

    _assert_refused(lane, token_idp, excinfo.value)


@pytest.mark.parametrize(("size", "refused"), [(CAP, False), (CAP + 1, True)], ids=["cap", "cap+1"])
@pytest.mark.parametrize("lane", REFUSING)
async def test_an_error_status_is_held_to_the_same_cap(
    lane: str, size: int, refused: bool, token_idp: Any
) -> None:
    """sync 미러와 같다 — 판정은 크기지 상태가 아니다. 상한 안이면 분류는 상태가 정한다(대조군)."""
    token_idp.head, token_idp.size, token_idp.status = _INVALID_GRANT, size, 400

    async with _client(token_idp) as kc:
        with pytest.raises(Exception) as excinfo:
            await _call(lane, kc, "K" * 40)

    error = excinfo.value
    if refused:
        _assert_refused(lane, token_idp, error)
    elif lane == "admin":
        assert type(error) is KeycloakAdminError, repr(error)
        assert (error.status_code, error.keycloak_error) == (400, None)
    else:
        assert type(error) is KeycloakAuthError, repr(error)
        assert str(error) == "Keycloak request failed: HTTP 400 (invalid_grant)"


async def test_a_logout_without_a_body_passes_through_the_capped_session(token_idp: Any) -> None:
    """sync 미러와 같다 — 204 는 본문 없이 같은 세션의 상한을 지난다."""
    _serve_success(token_idp, "logout", "L" * 40)

    async with _client(token_idp) as kc:
        _assert_accepted("logout", token_idp, await _call("logout", kc, "L" * 40), "L" * 40)

    assert token_idp.hits == ["/realms/r/protocol/openid-connect/logout"]


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", LANES)
async def test_a_huge_body_is_refused_holding_only_what_was_read(
    lane: str, chunked: bool, token_idp: Any
) -> None:
    """sync 미러와 같다 — `Content-Length` 로 온 본문도 따로 잰다(선언된 길이로 조각을 묶는 읽기는
    청크 본문에서는 드러나지 않는다). 이 틀의 피크는 청크보다 높지만 본문 크기와 무관하다 — cc 실측
    2.90~3.10 MB(청크 1.56~1.73 MB, 윈도우·python:3.13-alpine 각 5 회), 윈도우에서 본문 4·16·64
    MiB 가 같은 피크다. 상한이 새면 본문을 따라 자란다."""
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "D" * 40), HUGE, chunked

    async with _client(token_idp) as kc:
        tracemalloc.start()
        try:
            with pytest.raises(Exception) as excinfo:
                await _call(lane, kc, "D" * 40)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_refused(lane, token_idp, excinfo.value)
    assert peak < _BOUNDED_PEAK, f"16 MiB body: peak {peak} bytes"


@pytest.mark.parametrize("lane", ["cc", "admin"])
async def test_a_gzip_bomb_is_refused_after_inflating_only_up_to_the_cap(
    lane: str, token_idp: Any
) -> None:
    """⚠️ httpx 의 `GZipDecoder` 는 `decompress(data)` 에 상한이 없다 — 상한을 원문(압축) 바이트에
    걸면 수십 KB 가 통과해 16 MiB 로 부푼다. 피크를 잰다."""
    token_idp.serve_gzip(_head(lane, "E" * 40), HUGE)
    assert len(token_idp.gzip_body) < CAP // 16

    async with _client(token_idp) as kc:
        tracemalloc.start()
        try:
            with pytest.raises(Exception) as excinfo:
                await _call(lane, kc, "E" * 40)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_refused(lane, token_idp, excinfo.value)
    assert peak < _BOUNDED_PEAK, f"gzip bomb: peak {peak} bytes"


@pytest.mark.parametrize(("size", "accepted"), [(CAP, True), (CAP + 1, False)])
async def test_a_compressed_body_counts_inflated_bytes(
    size: int, accepted: bool, token_idp: Any
) -> None:
    token_idp.serve_gzip(_head("cc", "F" * 40), size)

    async with _client(token_idp) as kc:
        if accepted:
            _assert_accepted("cc", token_idp, await _call("cc", kc, "F" * 40), "F" * 40)
        else:
            with pytest.raises(Exception) as excinfo:
                await _call("cc", kc, "F" * 40)
            _assert_refused("cc", token_idp, excinfo.value)


def _swap_connection(raw: Any, url: str) -> None:
    raw.connection = KeycloakOpenIDConnection(  # KeycloakAdmin 의 공개 세터
        server_url=url,
        realm_name="r",
        client_id="c",
        client_secret_key="s3cret",
        grant_type="client_credentials",
    )


def _swap_grant_connection(raw: Any, url: str) -> None:
    raw.connection.keycloak_openid.connection = ConnectionManager(base_url=url)  # 중첩 세터


@pytest.mark.parametrize("swap", [_swap_connection, _swap_grant_connection], ids=["admin", "grant"])
async def test_a_replaced_connection_is_capped_before_its_first_grant(
    swap: Any, token_idp: Any
) -> None:
    """sync 미러와 같다 — 상한은 요청마다 살아 있는 그랜트 세션(`async_s`)에 다시 걸린다."""
    token_idp.head, token_idp.size = _head("admin", "J" * 40), CAP + 1

    async with _client(token_idp) as kc:
        swap(kc.admin.raw, token_idp.url)
        with pytest.raises(Exception) as excinfo:
            await kc.admin.realms.list()

    _assert_refused("admin", token_idp, excinfo.value)
    assert token_idp.hits == ["/realms/r/protocol/openid-connect/token"]


@pytest.mark.parametrize("lane", REFUSING)
async def test_only_encodings_it_can_inflate_within_the_cap_are_asked_for(
    lane: str, token_idp: Any
) -> None:
    """httpx 는 `brotli`·`zstandard` 가 깔려 있으면 `br`·`zstd` 도 요구한다 — 그 디코더에는 상한이
    없다. 깔린 상태를 클라이언트 기본 헤더로 흉내 내고, 나가는 요청이 상한 안에서 풀 수 있는 것만
    요구하는지 본다. 레인마다 본다 — 경로(`/token` · `/token/introspect` · `/logout`)는 갈려도 그
    요구는 같아야 한다."""
    _serve_success(token_idp, lane, "I" * 40)

    async with _client(token_idp) as kc:
        sessions = [kc.auth._openid.connection.async_s]
        sessions.append(kc.admin.raw.connection.keycloak_openid.connection.async_s)
        for session in sessions:
            session.headers["Accept-Encoding"] = "gzip, deflate, br, zstd"
        _assert_accepted(lane, token_idp, await _call(lane, kc, "I" * 40), "I" * 40)

    assert token_idp.accept_encoding == "gzip, deflate"


@pytest.mark.parametrize("lane", LANES)
async def test_judging_a_small_body_allocates_nothing_near_the_cap(
    lane: str, token_idp: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """sync 미러와 같다 — ~2 KiB 응답을 판정하는 데 상한 크기의 버퍼를 미리 잡지 않는다(읽은 만큼만
    자란다). 레인마다 잰다(admin 은 잰 호출도 그랜트를 보내게 캐시된 토큰을 버린다).

    ⚠️ 리눅스의 asyncio 셀렉터 전송은 읽을 때마다 `sock.recv(max_size)` 로 256 KiB 를 먼저 잡는다
    (`_SelectorTransport.max_size` — SDK 와 무관한 전송 버퍼라 피크를 지배한다: python:3.13-alpine
    실측 285~310 KB, 8192 로 묶으면 32~70 KB). sync 미러가 `makefile()` 의 기본값만 묶듯 이 값만
    묶는다. 윈도우의 Proactor 전송은 이 값을 쓰지 않는다 — 연결마다 한 번 잡는 버퍼는 데운 연결을
    다시 쓰므로 잰 구간 밖이다(윈도우 실측 30~73 KB, 묶든 말든 같다)."""
    monkeypatch.setattr("asyncio.selector_events._SelectorTransport.max_size", 8192)
    token = "H" * 2000
    token_idp.head = _head(lane, token)

    async with _client(token_idp) as kc:
        await _call(lane, kc, token)  # 연결·지연 생성을 먼저 데운다
        if lane == "admin":
            kc.admin.raw.connection.token = None  # 잰 호출도 그랜트를 보낸다
        tracemalloc.start()
        try:
            result = await _call(lane, kc, token)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_accepted(lane, token_idp, result, token)
    assert len(token_idp.hits) == (4 if lane == "admin" else 2)  # 잰 호출이 그 응답을 받았다
    assert peak < 128 * 1024, f"peak {peak} bytes for a {len(token_idp.head)}-byte body"
