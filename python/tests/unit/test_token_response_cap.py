"""토큰·introspection 응답 본문의 바이트 상한 — sync 레인 다섯 + logout(공개 API 로만 잰다).

⚠️ **실 HTTP 서버(`token_idp`)로 잰다** — 상한은 전송에서 걸리므로 python-keycloak 을 목하면 상한을
지나지 않는다. 레인 다섯(cc·refresh·code·introspect·admin 자체 그랜트)마다:

1. Keycloak 26.6 이 기본 설정으로 받는 가장 긴 bearer(65,459 바이트, 실측 2026-10-03)를 받는다.
2. 정확히 1,048,576 바이트의 본문은 받고, 1,048,577 바이트는 SDK 의 실패한 토큰(introspection)
   응답 타입 `KeycloakAuthError` 로 거부한다 — admin 은 REST 요청을 보내지 않는다. 판정은 크기다 —
   200 밖의 상태(400)도, 같은 세션으로 나가는 logout 도 같다. 거부의 사슬은 요약 하나뿐이다.
3. 16 MiB 본문은 읽은 만큼만 메모리를 잡고 거부한다(tracemalloc 피크) — `Content-Length` 로 온
   것도 청크로 온 것도. gzip 폭탄도 같다 — 상한은 **푼 뒤** 바이트에 걸린다.
4. 작은 본문을 판정하는 데 상한 크기의 버퍼를 잡지 않는다 — 레인마다, 전송 틀(길이·청크·연결
   닫힘)마다.

상한 값은 상수를 import 하지 않고 **리터럴로** 고정한다 — 상수가 바뀌면 이 파일이 운다(교차 언어
가드가 같은 값을 읽는다). aio 미러는 `tests/unit/aio/test_token_response_cap_async.py`.
"""

from __future__ import annotations

import json
import socket
import tracemalloc
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import pytest
import urllib3
from keycloak import KeycloakOpenIDConnection
from keycloak.connection import ConnectionManager

from keycloak_sdk._internal.lower import LowerLibraryError
from keycloak_sdk.client import KeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAdminError, KeycloakAuthError
from keycloak_sdk.tokens import IntrospectionResult, TokenSet

CAP = 1_048_576
LARGEST_DEFAULT_BEARER = 65_459  # Keycloak 26.6 기본 설정이 받는 가장 긴 bearer(실측 2026-10-03)
HUGE = 16 * 1024 * 1024
LANES = ("cc", "refresh", "code", "introspect", "admin")
#: logout 도 같은 세션(`connection._s`)으로 나간다 — 성공이 본문 없는 204 라 받는 쪽 시험에는 없고,
#: 거부하는 쪽 시험에 낀다.
REFUSING = (*LANES, "logout")
_WHAT = {"introspect": "introspection response", "logout": "logout response"}
_INVALID_GRANT = b'{"error":"invalid_grant"}'
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
    if lane == "logout":
        return kc.auth.logout("refresh-token")
    return kc.admin.realms.list()


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
    """거부의 모양 — 타입·메시지와 **사슬**. 거부 신호는 python-keycloak `raw_post` 안(보낼 폼,
    곧 `client_secret`)을 지나와 그 `KeycloakConnectionError` 의 원인으로 잡힌다 — 경계는 그 실패의
    요약(`LowerLibraryError`) 하나만 원인으로 달고 `__context__` 는 비운다(§4 — 하위 타입이 사슬로
    닿지 않는다, `_internal/lower.py`)."""
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
@pytest.mark.parametrize("lane", REFUSING)
def test_one_byte_over_the_cap_is_refused(lane: str, chunked: bool, token_idp: Any) -> None:
    """⚠️ 쓸 수 있는 토큰을 담았어도 거부한다 — 판정은 크기다. chunked 는 `Content-Length` 만
    믿는 상한을 걸러내는 대조군이다."""
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "C" * 40), CAP + 1, chunked

    with _client(token_idp) as kc, pytest.raises(Exception) as excinfo:
        _call(lane, kc, "C" * 40)

    _assert_refused(lane, token_idp, excinfo.value)


@pytest.mark.parametrize(("size", "refused"), [(CAP, False), (CAP + 1, True)], ids=["cap", "cap+1"])
@pytest.mark.parametrize("lane", REFUSING)
def test_an_error_status_is_held_to_the_same_cap(
    lane: str, size: int, refused: bool, token_idp: Any
) -> None:
    """판정은 크기지 상태가 아니다 — 400 오류 본문도 cap+1 이면 같은 거부다(오류 본문만 상한
    없이 상류에 넘기면 상류가 `r.content` 로 통째로 읽는다). 상한 안이면 분류는 상태가 정한다 —
    그 대조군이 거부가 상태에서 온 것이 아님을 가른다."""
    token_idp.head, token_idp.size, token_idp.status = _INVALID_GRANT, size, 400

    with _client(token_idp) as kc, pytest.raises(Exception) as excinfo:
        _call(lane, kc, "K" * 40)

    error = excinfo.value
    if refused:
        _assert_refused(lane, token_idp, error)
    elif lane == "admin":  # 그랜트 실패는 admin 계층이다 — 본문(토큰 엔드포인트의 것)은 싣지 않는다
        assert type(error) is KeycloakAdminError, repr(error)
        assert (error.status_code, error.keycloak_error) == (400, None)
    else:
        assert type(error) is KeycloakAuthError, repr(error)
        assert str(error) == "Keycloak request failed: HTTP 400 (invalid_grant)"


def test_a_logout_without_a_body_passes_through_the_capped_session(token_idp: Any) -> None:
    """logout 의 성공(204, 본문 없음)도 같은 세션의 상한을 지난다 — 읽을 본문이 없어도 판정은
    끝난다. 요청은 상한 안에서 풀 수 있는 인코딩만 청한다(`br`·`zstd` 가 깔린 세션 기본 헤더를
    흉내 낸다 — 아래 인코딩 시험과 같다)."""
    token_idp.status, token_idp.head = 204, b""

    with _client(token_idp) as kc:
        kc.auth._openid.connection._s.headers["Accept-Encoding"] = "gzip, deflate, br, zstd"
        _assert_accepted("logout", token_idp, _call("logout", kc, "L" * 40), "L" * 40)

    assert token_idp.hits == ["/realms/r/protocol/openid-connect/logout"]
    assert token_idp.accept_encoding == "gzip, deflate"


@pytest.mark.parametrize("chunked", [False, True], ids=["content-length", "chunked"])
@pytest.mark.parametrize("lane", LANES)
def test_a_huge_body_is_refused_holding_only_what_was_read(
    lane: str, chunked: bool, token_idp: Any
) -> None:
    """⚠️ 「예외가 났다」는 상한의 증거가 아니다 — 통째로 읽은 뒤에도 예외는 날 수 있다.
    피크를 잰다. ⚠️ `Content-Length` 로 온 본문도 따로 잰다 — 선언된 길이를 믿고 한 번에 청하는
    읽기는 청크 본문에서는 드러나지 않는다."""
    token_idp.head, token_idp.size, token_idp.chunked = _head(lane, "D" * 40), HUGE, chunked

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


@pytest.mark.parametrize("framing", ["content-length", "chunked", "close-delimited"])
@pytest.mark.parametrize("lane", LANES)
def test_judging_a_small_body_allocates_nothing_near_the_cap(
    lane: str, framing: str, token_idp: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """~2 KiB 응답을 판정하는 데 상한 크기의 버퍼를 미리 잡지 않는다(읽은 만큼만 자란다).
    수정 전 실측 피크 24 KB — 128 KiB 는 그 다섯 배, 상한의 1/8 이다.

    레인마다 잰다 — 레인은 응답 이름(`_kind`)으로 갈리고 admin 은 그랜트 세션이 따로다(잰 호출도
    그랜트를 보내게 캐시된 토큰을 버린다). ⚠️ 전송 틀마다 잰다 — **연결 닫힘으로 끝나는 본문만이**
    SDK 가 청한 읽기 크기를 그대로 드러낸다. 길이가 있으면 http.client 가 남은 길이로 자르고 청크는
    청크 크기로 읽지만, 이 틀에서는 `BufferedReader.read(n)` 가 청한 `n` 바이트를 먼저 잡는다.

    ⚠️ 전송의 응답 읽기 버퍼는 3.13 까지의 크기(8 KiB)로 고정하고 잰다 — http.client 가 응답마다
    `sock.makefile("rb")` 로 잡는 `io.DEFAULT_BUFFER_SIZE` 가 3.14 부터 128 KiB 라, SDK 와 무관한 그
    버퍼가 피크를 지배한다(3.14.8 실측 146 KB, 이 값만 8192 로 두면 24 KB — SDK 를 수정 전 소스로
    바꿔도 146~148 KB). 피크에서 빼지 않는 것은 그 버퍼가 본문을 다 읽으면 풀리기 때문이다 — 빼면
    그 뒤의 할당을 버퍼 크기만큼 덜 잰다.

    ⚠️ 고정하는 것은 `makefile()` 이 크기를 받지 않았을 때 고르는 값뿐이다 — 전역
    `io.DEFAULT_BUFFER_SIZE` 를 바꾸면 그 값으로 크기를 정하는 SDK 할당까지 3.14 에서 1/16 로 잰다
    (3.14 에서 상한 그 자체인 `bytearray(io.DEFAULT_BUFFER_SIZE * 8)` 가 94 KB 로 통과했다)."""
    real_makefile = socket.socket.makefile

    def makefile(
        self: socket.socket, mode: str = "r", buffering: int | None = None, **kwargs: Any
    ) -> Any:
        if buffering is None or buffering < 0:
            buffering = 8192  # 3.13 까지 makefile() 이 고르던 값(io.DEFAULT_BUFFER_SIZE)
        return real_makefile(self, mode, buffering, **kwargs)

    monkeypatch.setattr(socket.socket, "makefile", makefile)
    token = "H" * 2000
    token_idp.head = _head(lane, token)
    token_idp.chunked = framing == "chunked"
    token_idp.close_delimited = framing == "close-delimited"

    with _client(token_idp) as kc:
        _call(lane, kc, token)  # 연결·지연 생성을 먼저 데운다
        if lane == "admin":
            kc.admin.raw.connection.token = None  # 잰 호출도 그랜트를 보낸다
        tracemalloc.start()
        try:
            result = _call(lane, kc, token)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

    _assert_accepted(lane, token_idp, result, token)
    assert len(token_idp.hits) == (4 if lane == "admin" else 2)  # 잰 호출이 그 응답을 받았다
    assert peak < 128 * 1024, f"peak {peak} bytes for a {len(token_idp.head)}-byte body"
