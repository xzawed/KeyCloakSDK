"""토큰·introspection 응답 본문의 바이트 상한 — aio 레인 다섯(sync 미러는
`tests/unit/test_token_response_cap.py`).

⚠️ aio 는 sync 와 **푸는 자리가 다르다.** urllib3 는 `read(amt)` 로 `amt` 까지만 풀지만 httpx 의
디코더에는 상한이 없다(`_internal/jwks_fetch.py` 실측: 20 MB 폭탄에 피크 84 MB). 그래서 이 미러는
gzip 폭탄과, 상한 안에서 풀 수 없는 인코딩(`br`·`zstd`)을 요구하지 않는지를 따로 본다.
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

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet

CAP = 1_048_576
LARGEST_DEFAULT_BEARER = 65_459  # Keycloak 26.6 기본 설정이 받는 가장 긴 bearer(실측 2026-10-03)
HUGE = 16 * 1024 * 1024
LANES = ("cc", "refresh", "code", "introspect", "admin")
_WHAT = {"introspect": "introspection response"}
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
    return await kc.admin.realms.list()


def _assert_accepted(lane: str, idp: Any, result: object, token: str) -> None:
    if lane == "introspect":
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
    assert type(exc) is KeycloakAuthError, f"{type(exc).__module__}.{type(exc).__qualname__}"
    assert str(exc) == f"{_WHAT.get(lane, 'token response')} exceeds {CAP} bytes"
    assert exc.error is None
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
@pytest.mark.parametrize("lane", LANES)
async def test_one_byte_over_the_cap_is_refused(lane: str, chunked: bool, token_idp: Any) -> None:
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "C" * 40), CAP + 1, chunked

    async with _client(token_idp) as kc:
        with pytest.raises(Exception) as excinfo:
            await _call(lane, kc, "C" * 40)

    _assert_refused(lane, token_idp, excinfo.value)


@pytest.mark.parametrize("lane", LANES)
async def test_a_huge_body_is_refused_holding_only_what_was_read(lane: str, token_idp: Any) -> None:
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "D" * 40), HUGE, True

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


@pytest.mark.parametrize("lane", ["cc", "admin"])
async def test_only_encodings_it_can_inflate_within_the_cap_are_asked_for(
    lane: str, token_idp: Any
) -> None:
    """httpx 는 `brotli`·`zstandard` 가 깔려 있으면 `br`·`zstd` 도 요구한다 — 그 디코더에는 상한이
    없다. 깔린 상태를 클라이언트 기본 헤더로 흉내 내고, 나가는 요청이 상한 안에서 풀 수 있는 것만
    요구하는지 본다."""
    token_idp.head = _head(lane, "I" * 40)

    async with _client(token_idp) as kc:
        sessions = [kc.auth._openid.connection.async_s]
        sessions.append(kc.admin.raw.connection.keycloak_openid.connection.async_s)
        for session in sessions:
            session.headers["Accept-Encoding"] = "gzip, deflate, br, zstd"
        _assert_accepted(lane, token_idp, await _call(lane, kc, "I" * 40), "I" * 40)

    assert token_idp.accept_encoding == "gzip, deflate"
