"""토큰·introspection 응답 본문의 바이트 상한 — sync 레인 다섯(공개 API 로만 잰다).

⚠️ **실 HTTP 서버(`token_idp`)로 잰다** — 상한은 전송에서 걸리므로 python-keycloak 을 목하면 상한을
지나지 않는다. 레인 다섯(cc·refresh·code·introspect·admin 자체 그랜트)마다:

1. Keycloak 26.6 이 기본 설정으로 받는 가장 긴 bearer(65,459 바이트, 실측 2026-10-03)를 받는다.
2. 정확히 1,048,576 바이트의 본문은 받고, 1,048,577 바이트는 SDK 의 실패한 토큰(introspection)
   응답 타입 `KeycloakAuthError` 로 거부한다 — admin 은 REST 요청을 보내지 않는다.
3. 16 MiB 본문은 읽은 만큼만 메모리를 잡고 거부한다(tracemalloc 피크). gzip 폭탄도 같다 — 상한은
   **푼 뒤** 바이트에 걸린다.

상한 값은 상수를 import 하지 않고 **리터럴로** 고정한다 — 상수가 바뀌면 이 파일이 운다(교차 언어
가드가 같은 값을 읽는다). aio 미러는 `tests/unit/aio/test_token_response_cap_async.py`.
"""

from __future__ import annotations

import json
import tracemalloc
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import pytest
import urllib3
from keycloak import KeycloakOpenIDConnection
from keycloak.connection import ConnectionManager

from keycloak_sdk.client import KeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet

CAP = 1_048_576
LARGEST_DEFAULT_BEARER = 65_459  # Keycloak 26.6 기본 설정이 받는 가장 긴 bearer(실측 2026-10-03)
HUGE = 16 * 1024 * 1024
LANES = ("cc", "refresh", "code", "introspect", "admin")
_WHAT = {"introspect": "introspection response"}
#: 읽은 만큼만 잡는다면 피크는 상한(1 MiB)의 몇 배 안이다 — 통째로 읽던 때는 본문의 두 배였다.
_BOUNDED_PEAK = 4 * 1024 * 1024


def _config(idp: Any) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=idp.url, realm="r", client_id="c", client_secret="s3cret", read_timeout=10.0
    )


def _head(lane: str, token: str) -> bytes:
    if lane == "introspect":
        return json.dumps({"active": True, "username": "u", "client_id": "c"}).encode()
    return json.dumps({"access_token": token, "token_type": "Bearer", "expires_in": 300}).encode()


@contextmanager
def _client(idp: Any) -> Iterator[KeycloakClient]:
    kc = KeycloakClient.create(_config(idp))
    try:
        _ = kc.admin.raw  # admin 을 미리 만든다 — 재는 것은 호출이지 생성이 아니다(네트워크 없음)
        yield kc
    finally:
        kc.close()


def _call(lane: str, kc: KeycloakClient, token: str) -> object:
    if lane == "cc":
        return kc.auth.client_credentials_token()
    if lane == "refresh":
        return kc.auth.refresh("refresh-token")
    if lane == "code":
        return kc.auth.exchange_code("code", "http://127.0.0.1/cb", "v" * 43)
    if lane == "introspect":
        return kc.auth.introspect(token)
    return kc.admin.realms.list()


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
def test_the_largest_default_bearer_passes_every_lane(lane: str, token_idp: Any) -> None:
    token = "A" * LARGEST_DEFAULT_BEARER
    token_idp.head = _head(lane, token)

    with _client(token_idp) as kc:
        result = _call(lane, kc, token)

    _assert_accepted(lane, token_idp, result, token)


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", LANES)
def test_a_body_of_exactly_the_cap_is_accepted(lane: str, chunked: bool, token_idp: Any) -> None:
    token = "B" * 40
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, token), CAP, chunked

    with _client(token_idp) as kc:
        result = _call(lane, kc, token)

    _assert_accepted(lane, token_idp, result, token)


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", LANES)
def test_one_byte_over_the_cap_is_refused(lane: str, chunked: bool, token_idp: Any) -> None:
    """⚠️ 쓸 수 있는 토큰을 담았어도 거부한다 — 판정은 크기다. chunked 는 `Content-Length` 만
    믿는 상한을 걸러내는 대조군이다."""
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "C" * 40), CAP + 1, chunked

    with _client(token_idp) as kc, pytest.raises(Exception) as excinfo:
        _call(lane, kc, "C" * 40)

    _assert_refused(lane, token_idp, excinfo.value)


@pytest.mark.parametrize("lane", LANES)
def test_a_huge_body_is_refused_holding_only_what_was_read(lane: str, token_idp: Any) -> None:
    """⚠️ 「예외가 났다」는 상한의 증거가 아니다 — 통째로 읽은 뒤에도 예외는 날 수 있다.
    피크를 잰다."""
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "D" * 40), HUGE, True

    with _client(token_idp) as kc:
        tracemalloc.start()
        try:
            with pytest.raises(Exception) as excinfo:
                _call(lane, kc, "D" * 40)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_refused(lane, token_idp, excinfo.value)
    assert peak < _BOUNDED_PEAK, f"16 MiB body: peak {peak} bytes"


@pytest.mark.parametrize("lane", ["cc", "admin"])
def test_a_gzip_bomb_is_refused_after_inflating_only_up_to_the_cap(
    lane: str, token_idp: Any
) -> None:
    """전송은 작고(수십 KB) 푼 뒤가 16 MiB 다 — 상한은 **푼 뒤** 바이트에 걸려야 한다."""
    token_idp.serve_gzip(_head(lane, "E" * 40), HUGE)
    assert len(token_idp.gzip_body) < CAP // 16

    with _client(token_idp) as kc:
        tracemalloc.start()
        try:
            with pytest.raises(Exception) as excinfo:
                _call(lane, kc, "E" * 40)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_refused(lane, token_idp, excinfo.value)
    assert peak < _BOUNDED_PEAK, f"gzip bomb: peak {peak} bytes"


@pytest.mark.parametrize(("size", "accepted"), [(CAP, True), (CAP + 1, False)])
def test_a_compressed_body_counts_inflated_bytes(size: int, accepted: bool, token_idp: Any) -> None:
    """같은 판정이 압축 본문에도 선다 — 전송 바이트가 아니라 푼 바이트로 센다."""
    token_idp.serve_gzip(_head("cc", "F" * 40), size)

    with _client(token_idp) as kc:
        if accepted:
            _assert_accepted("cc", token_idp, _call("cc", kc, "F" * 40), "F" * 40)
        else:
            with pytest.raises(Exception) as excinfo:
                _call("cc", kc, "F" * 40)
            _assert_refused("cc", token_idp, excinfo.value)


def test_reads_never_ask_for_more_than_one_byte_past_the_cap(
    token_idp: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """읽기 크기를 SDK 가 정하는 자리(urllib3 `read(amt)`)에서는 받은 것 + 요청한 것이 cap+1 을 넘지
    않는다 — 마지막 읽기는 그 1 바이트만 청한다."""
    reads: list[tuple[int | None, int]] = []
    real = urllib3.response.HTTPResponse.read

    def spy(self: Any, amt: int | None = None, *args: Any, **kwargs: Any) -> bytes:
        data = real(self, amt, *args, **kwargs)
        reads.append((amt, len(data)))
        return data

    monkeypatch.setattr(urllib3.response.HTTPResponse, "read", spy)
    token_idp.head, token_idp.size, token_idp.chunked = _head("cc", "G" * 40), HUGE, True

    with _client(token_idp) as kc, pytest.raises(KeycloakAuthError):
        _call("cc", kc, "G" * 40)

    received = 0
    for amt, got in reads:
        assert amt is not None, "an unbounded read"
        assert received + amt <= CAP + 1, f"asked {amt} after {received} bytes"
        received += got
    assert received == CAP + 1


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
def test_a_replaced_connection_is_capped_before_its_first_grant(swap: Any, token_idp: Any) -> None:
    """admin 은 python-keycloak 의 공개 세터로 연결을 갈아 끼울 수 있다 — 상한은 생성 때 한 번이
    아니라 요청마다 살아 있는 그랜트 세션에 다시 걸린다(`_internal/admin_guard.py`)."""
    token_idp.head, token_idp.size = _head("admin", "J" * 40), CAP + 1

    with _client(token_idp) as kc:
        swap(kc.admin.raw, token_idp.url)
        with pytest.raises(Exception) as excinfo:
            kc.admin.realms.list()

    _assert_refused("admin", token_idp, excinfo.value)
    assert token_idp.hits == ["/realms/r/protocol/openid-connect/token"]


@pytest.mark.parametrize("lane", ["cc", "admin"])
def test_only_encodings_it_can_inflate_within_the_cap_are_asked_for(
    lane: str, token_idp: Any
) -> None:
    """aio 미러와 같다 — 본문은 SDK 가 원문으로 받아 스스로 푼다(`_internal/token_cap.py`).
    requests 는 `brotli`·`zstandard` 가 깔려 있으면 `br`·`zstd` 도 요구하는데(urllib3
    `make_headers`) SDK 는 그것을 상한 안에서 풀 수 없다. 깔린 상태를 세션 기본 헤더로 흉내 내고,
    나가는 요청을 본다."""
    token_idp.head = _head(lane, "I" * 40)

    with _client(token_idp) as kc:
        sessions = [kc.auth._openid.connection._s]
        sessions.append(kc.admin.raw.connection.keycloak_openid.connection._s)
        for session in sessions:
            session.headers["Accept-Encoding"] = "gzip, deflate, br, zstd"
        _assert_accepted(lane, token_idp, _call(lane, kc, "I" * 40), "I" * 40)

    assert token_idp.accept_encoding == "gzip, deflate"


def test_judging_a_small_body_allocates_nothing_near_the_cap(token_idp: Any) -> None:
    """~2 KiB 응답을 판정하는 데 상한 크기의 버퍼를 미리 잡지 않는다(읽은 만큼만 자란다).
    수정 전 실측 피크 24 KB — 128 KiB 는 그 다섯 배, 상한의 1/8 이다."""
    token = "H" * 2000
    token_idp.head = _head("cc", token)

    with _client(token_idp) as kc:
        _call("cc", kc, token)  # 연결·지연 생성을 먼저 데운다
        tracemalloc.start()
        try:
            result = _call("cc", kc, token)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_accepted("cc", token_idp, result, token)
    assert peak < 128 * 1024, f"peak {peak} bytes for a {len(token_idp.head)}-byte body"
