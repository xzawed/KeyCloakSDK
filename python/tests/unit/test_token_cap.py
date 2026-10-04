"""`_internal/token_cap.py` 단위 — 상수의 모양, 응답 이름, 상한 안의 풀기, 설치.

레인 전체(실 HTTP)는 `test_token_response_cap.py`·`aio/test_token_response_cap_async.py` 가 잰다.
여기는 그 경로들이 다 밟지 않는 갈래(날 deflate·겹친 압축·모르는 인코딩·끝난 스트림 뒤의 바이트·
스트리밍 통과·설치 거부)와, 설치된 urllib3 버전과 무관해야 하는 sync 원문 읽기다.
"""

from __future__ import annotations

import inspect
import re
import tracemalloc
import zlib
from collections.abc import Callable
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests
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
from tests.unit.conftest import RawBeforeMaxLength, gzip_padded

_BOMB = zlib.compress(b" " * (4 * 1024 * 1024))  # 4 MiB 공백 → 수 KB
_TOKEN_URL = "http://idp.test/realms/r/protocol/openid-connect/token"
#: 레인 테스트와 같은 자릿수 — 16 MiB 폭탄을 통째로 풀면 그 네 배를 넘는다.
_BOUNDED_PEAK = 4 * 1024 * 1024


def _sync_response(raw: RawBeforeMaxLength, encoding: str | None) -> requests.Response:
    response = requests.Response()
    response.status_code = 200
    if encoding is not None:
        response.headers["Content-Encoding"] = encoding
    response.raw = raw
    return response


def _sync_send(
    response: requests.Response,
) -> tuple[Callable[..., requests.Response], list[dict[str, Any]]]:
    seen: list[dict[str, Any]] = []

    def send(_request: Any, **kwargs: Any) -> requests.Response:
        seen.append(kwargs)
        return response

    return send, seen


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


@pytest.mark.parametrize(
    ("coding", "wbits"),
    [("gzip", zlib.MAX_WBITS | 16), ("deflate", zlib.MAX_WBITS), ("deflate", -zlib.MAX_WBITS)],
    ids=["gzip", "deflate", "raw-deflate"],
)
def test_bytes_after_the_end_of_the_stream_are_neither_inflated_nor_kept(
    coding: str, wbits: int
) -> None:
    """⚠️ zlib 의 `decompressobj` 는 스트림이 끝난 뒤 받은 입력을 **전부** `unused_data` 에 이어
    붙인다 — 상한은 푼 바이트에 걸리므로 그 꼬리는 세지도 막지도 못했다(aio 레인 실측: 작은 gzip
    뒤에 16 MiB 를 덧대면 피크 34 MB). 끝난 스트림 뒤의 입력은 풀지도 쥐지도 않는다."""
    comp = zlib.compressobj(9, zlib.DEFLATED, wbits)
    stream = comp.compress(b'{"access_token": "x"}') + comp.flush()
    inflate = _inflater([coding], "token response")
    trailing = bytes(65_536)

    assert inflate(stream, 1000) == b'{"access_token": "x"}'
    tracemalloc.start()
    try:
        for _ in range(64):  # 끝난 스트림 뒤로 4 MiB
            assert inflate(trailing, 1000) == b""
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert peak < 256 * 1024, f"4 MiB after the end of the stream: peak {peak} bytes"


def test_a_body_compressed_twice_is_refused() -> None:
    with pytest.raises(ResponseRefused, match=r"^token response is compressed more than once"):
        _inflater(["gzip", "deflate"], "token response")


def test_sync_reads_raw_bytes_and_inflates_them_itself_whatever_urllib3_does() -> None:
    """⚠️ sync 상한이 urllib3 버전에 달리면 안 된다 — 2.6 미만 urllib3 는 `read(amt,
    decode_content=True)` 의 원문 `amt` 를 상한 없이 통째로 푼다(실측 2.5.0: 16 MiB gzip 폭탄에 sync
    여섯 레인 피크 47.6 MB — 거부 메시지는 옳았다). 그 urllib3 를 흉내 낸 원문을 주고, SDK 가 원문을
    청하는지(`decode_content=False`)와 피크를 잰다 — 예외만으로는 상한의 증거가 아니다."""
    raw = RawBeforeMaxLength(gzip_padded(b'{"access_token": "x"}', 16 * 1024 * 1024))
    send, seen = _sync_send(_sync_response(raw, "gzip"))
    request = requests.Request("POST", _TOKEN_URL).prepare()

    outcome: BaseException | None = None
    tracemalloc.start()
    try:
        try:
            capped_send(send)(request)
        except Exception as exc:  # 판정은 아래 단언이 한다 — 청한 것과 피크가 먼저다
            outcome = exc
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert set(raw.asked) == {False}, f"asked urllib3 to inflate: {raw.asked[:3]}"
    assert peak < _BOUNDED_PEAK, f"16 MiB gzip bomb: peak {peak} bytes"
    assert type(outcome) is ResponseRefused
    assert str(outcome) == f"token response exceeds {TOKEN_RESPONSE_MAX_BYTES} bytes"
    assert seen == [{"stream": True}]
    assert raw.closed  # 남은 본문을 읽지 않고 연결째 버린다


@pytest.mark.parametrize("encoding", [None, "identity", "br"])
def test_a_sync_body_it_does_not_inflate_is_kept_as_it_arrives(encoding: str | None) -> None:
    """aio 와 같다 — 모르는 이름은 풀지 않고 원문 그대로 센다. urllib3 에 맡기면 `br` 의 결과가
    `brotli` 설치 여부에 달린다."""
    body = b'{"access_token": "x"}'
    raw = RawBeforeMaxLength(body, inflates=False)
    send, _ = _sync_send(_sync_response(raw, encoding))

    response = capped_send(send)(requests.Request("POST", _TOKEN_URL).prepare())

    assert response.content == body
    assert set(raw.asked) == {False}


def test_a_sync_body_compressed_twice_is_refused_before_it_is_read() -> None:
    """aio 와 같다 — 겹친 압축은 상한 안에서 묶어 풀 수 없으므로 읽기 전에 거부하고 연결째
    버린다."""
    raw = RawBeforeMaxLength(b"never read", inflates=False)
    send, _ = _sync_send(_sync_response(raw, "gzip, gzip"))
    request = requests.Request("POST", _TOKEN_URL).prepare()

    with pytest.raises(
        ResponseRefused, match=r"^token response is compressed more than once \(gzip, gzip\)$"
    ):
        capped_send(send)(request)

    assert raw.asked == []
    assert raw.closed


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
