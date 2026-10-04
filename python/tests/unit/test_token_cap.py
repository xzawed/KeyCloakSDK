"""`_internal/token_cap.py` 단위 — 상수의 모양, 응답 이름, 상한 안의 풀기, 설치.

레인 전체(실 HTTP)는 `test_token_response_cap.py`·`aio/test_token_response_cap_async.py` 가 잰다.
여기는 그 경로들이 다 밟지 않는 갈래(날 deflate·겹친 압축·모르는 인코딩·스트리밍 통과·설치 거부)다.
"""

from __future__ import annotations

import inspect
import re
import zlib
from typing import Any
from unittest.mock import MagicMock

import pytest
from keycloak import KeycloakOpenID

from keycloak_sdk._internal import token_cap
from keycloak_sdk._internal.token_cap import (
    TOKEN_RESPONSE_MAX_BYTES,
    ResponseRefused,
    _inflater,
    _kind,
    acapped_send,
    cap_openid,
    capped_send,
)
from keycloak_sdk.exceptions import KeycloakConfigError

_BOMB = zlib.compress(b" " * (4 * 1024 * 1024))  # 4 MiB 공백 → 수 KB


def test_the_cap_is_one_plain_decimal_literal() -> None:
    """교차 언어 가드가 이 선언을 읽는다 — 값과 함께 **모양**(리터럴, 식 아님)을 고정한다."""
    assert TOKEN_RESPONSE_MAX_BYTES == 1_048_576
    source = inspect.getsource(token_cap)
    assert re.findall(r"^TOKEN_RESPONSE_MAX_BYTES = (.+)$", source, re.M) == ["1_048_576"]


@pytest.mark.parametrize(
    ("path", "kind"),
    [
        ("/realms/r/protocol/openid-connect/token", "token response"),
        ("/auth/realms/r/protocol/openid-connect/token/", "token response"),
        ("/realms/r/protocol/openid-connect/token/introspect", "introspection response"),
        ("/realms/r/protocol/openid-connect/token/introspect?x=1", "introspection response"),
        ("/realms/r/protocol/openid-connect/logout", "logout response"),
        ("/realms/r/.well-known/openid-configuration", "identity provider response"),
    ],
)
def test_the_refusal_names_the_response(path: str, kind: str) -> None:
    assert _kind(path) == kind


def test_an_unencoded_body_is_counted_as_it_arrives_and_never_kept_past_the_limit() -> None:
    inflate = _inflater([], "token response")
    assert inflate(b"abcdef", 100) == b"abcdef"
    assert inflate(b"abcdef", 4) == b"abcd"  # 쌓는 본문은 cap+1 을 넘지 않는다


@pytest.mark.parametrize("codings", [["identity"], ["br"], ["UTF-8"], ["zstd"]])
def test_encodings_httpx_would_not_inflate_pass_through_raw(codings: list[str]) -> None:
    """httpx 와 같다 — 모르는 이름은 풀지 않는다(원문 그대로 센다)."""
    assert _inflater(codings, "token response")(b"\x1f\x8b raw", 100) == b"\x1f\x8b raw"


def test_gzip_never_inflates_past_the_limit() -> None:
    bomb = zlib.compressobj(9, zlib.DEFLATED, 31)
    payload = bomb.compress(b" " * (4 * 1024 * 1024)) + bomb.flush()
    inflate = _inflater([" GZip "], "token response")

    assert len(inflate(payload, 1000)) == 1000


@pytest.mark.parametrize("wbits", [zlib.MAX_WBITS, -zlib.MAX_WBITS], ids=["zlib", "raw"])
def test_deflate_inflates_zlib_and_raw_streams_within_the_limit(wbits: int) -> None:
    """`deflate` 는 zlib 래퍼가 표준이지만 날 deflate 를 보내는 서버가 있다 — httpx 처럼 둘 다
    푼다."""
    comp = zlib.compressobj(9, zlib.DEFLATED, wbits)
    payload = comp.compress(b"x" * 5000) + comp.flush()
    inflate = _inflater(["deflate"], "token response")

    assert inflate(payload[:10], 10_000) + inflate(payload[10:], 10_000) == b"x" * 5000
    assert len(_inflater(["deflate"], "token response")(_BOMB, 777)) == 777


def test_a_broken_deflate_stream_after_the_first_piece_is_a_decoding_error() -> None:
    inflate = _inflater(["deflate"], "token response")
    inflate(_BOMB[:10], 100)

    with pytest.raises(zlib.error):
        inflate(b"\xff" * 64, 100)


def test_a_body_compressed_twice_is_refused() -> None:
    with pytest.raises(ResponseRefused, match=r"^token response is compressed more than once"):
        _inflater(["gzip", "deflate"], "token response")


def test_a_streamed_sync_request_passes_through_untouched() -> None:
    """`stream=True` 로 온 요청(JWKS 의 직접 GET)은 그쪽이 51,200 상한을 스스로 건다."""
    sentinel = MagicMock()
    send = MagicMock(return_value=sentinel)

    assert capped_send(send)("prepared", stream=True, timeout=5) is sentinel
    send.assert_called_once_with("prepared", stream=True, timeout=5)
    sentinel.raw.read.assert_not_called()


async def test_a_streamed_aio_request_passes_through_untouched() -> None:
    sentinel = MagicMock()
    seen: list[tuple[Any, dict[str, Any]]] = []

    async def send(request: Any, **kwargs: Any) -> Any:
        seen.append((request, kwargs))
        return sentinel

    assert await acapped_send(send)("request", stream=True, auth=None) is sentinel
    assert seen == [("request", {"stream": True, "auth": None})]


def test_both_sessions_of_the_auth_lane_are_capped_once() -> None:
    openid = KeycloakOpenID(server_url="http://127.0.0.1:9", realm_name="r", client_id="c")
    cap_openid(openid)
    sync_send, aio_send = openid.connection._s.send, openid.connection.async_s.send

    cap_openid(openid)  # 같은 객체를 다시 받아도 두 번 감싸지 않는다

    conn = openid.connection
    assert vars(conn._s)["send"] is sync_send
    assert vars(conn.async_s)["send"] is aio_send
    assert sync_send.__module__ == aio_send.__module__ == token_cap.__name__


@pytest.mark.parametrize("attr", ["_s", "async_s"])
def test_a_session_it_cannot_cap_is_refused_at_construction(attr: str) -> None:
    openid = KeycloakOpenID(server_url="http://127.0.0.1:9", realm_name="r", client_id="c")
    setattr(openid.connection, attr, MagicMock(spec=["close", "aclose"]))  # `send` 가 없다

    with pytest.raises(KeycloakConfigError, match=rf"connection\.{attr}\.send"):
        cap_openid(openid)
