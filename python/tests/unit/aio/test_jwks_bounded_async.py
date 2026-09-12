"""JWKS 응답 바이트 상한 — aio 미러.

sync 미러(`tests/unit/test_jwks_bounded.py`)와 **같은 주장을 같은 순서로** 둔다. 두 미러가
갈라지면 한쪽만 고쳐지고 나머지가 조용히 남는다 — 이 저장소에서 실제로 여러 번 있었다.

⚠️ aio 는 세션이 다르다(`connection.async_s`, httpx). 리다이렉트 방어도 훅이 아니라
httpx 기본값이라, 여기서는 `afetch_jwks` 가 `follow_redirects=False` 를 명시하는 것이
계약이다.
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.jwks_fetch import JWKS_MAX_BYTES, afetch_jwks
from keycloak_sdk.exceptions import KeycloakTransportError

pytestmark = pytest.mark.asyncio


def _valid_jwks(pad_to: int = 0) -> bytes:
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    doc: dict[str, Any] = {"keys": [key.as_dict(private=False)]}
    body = json.dumps(doc).encode()
    if pad_to and len(body) < pad_to:
        doc["_pad"] = "A" * (pad_to - len(body) - 12)
        body = json.dumps(doc).encode()
    return body


async def _fetch(jwks_server: Any) -> dict[str, Any]:
    async with httpx.AsyncClient() as client:
        return await afetch_jwks(client, f"{jwks_server.url}/certs", timeout=5.0)


async def test_oversize_jwks_is_rejected(jwks_server: Any) -> None:
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 2)

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        await _fetch(jwks_server)


async def test_oversize_jwks_is_rejected_without_content_length(jwks_server: Any) -> None:
    """대조군: chunked 라 `Content-Length` 가 없어도 잡는다."""
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 2)
    jwks_server.chunked = True

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        await _fetch(jwks_server)


async def test_jwks_within_cap_is_accepted(jwks_server: Any) -> None:
    """음성 대조군 — 상한이 정상 발급을 끊지 않는다."""
    jwks_server.body = _valid_jwks()

    result = await _fetch(jwks_server)

    assert "keys" in result
    assert jwks_server.hits == 1


async def test_non_200_is_an_sdk_error(jwks_server: Any) -> None:
    jwks_server.body = b'{"error":"boom"}'
    jwks_server.status = 500

    with pytest.raises(KeycloakTransportError, match="HTTP 500"):
        await _fetch(jwks_server)


async def test_oversize_error_body_is_also_capped(jwks_server: Any) -> None:
    """상한은 **상태와 무관하게** 건다(#466 에서 php 가 정확히 이 순서로 배포돼 있었다)."""
    jwks_server.body = b'{"error":"' + b"A" * (JWKS_MAX_BYTES * 2) + b'"}'
    jwks_server.status = 500

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        await _fetch(jwks_server)


async def test_non_json_body_is_an_sdk_error(jwks_server: Any) -> None:
    """§4 — 하위 파서 예외가 아니라 SDK 타입으로 나온다."""
    jwks_server.body = b"<html>not json</html>"

    with pytest.raises(KeycloakTransportError, match="not JSON"):
        await _fetch(jwks_server)


async def test_json_that_is_not_an_object_is_an_sdk_error(jwks_server: Any) -> None:
    jwks_server.body = b"[1, 2, 3]"

    with pytest.raises(KeycloakTransportError, match="not a JSON object"):
        await _fetch(jwks_server)


async def test_transport_failure_is_translated(jwks_server: Any) -> None:
    """⚠️ httpx 예외는 `_awrap` 이 잡지 않는다 — 이 모듈이 스스로 번역하지 않으면
    `httpx.ConnectError` 가 소비자에게 그대로 샌다(§4 위반)."""
    async with httpx.AsyncClient() as client:
        with pytest.raises(KeycloakTransportError, match="fetch failed"):
            # 아무도 듣지 않는 포트 — 연결 자체가 실패한다.
            await afetch_jwks(client, "http://127.0.0.1:1/certs", timeout=2.0)


async def test_gzip_bomb_does_not_inflate_past_the_cap(jwks_server: Any) -> None:
    """⚠️ **압축폭탄** — 전송 바이트는 작고 팽창 후가 거대하다.

    독립 레그가 실측으로 지목했다: httpx 의 `aiter_bytes()` 를 인자 없이 부르면 **디코드된
    덩어리를 통째로** 주고, `GZipDecoder.decode` 는 `decompress(data)` 라 상한이 없다.
    그러면 상한을 「팽창 뒤」에 재는 우리 코드는 **이미 메모리를 내준 뒤에** 거부한다.

    ⚠️ 그래서 상한만으로는 부족하고 **압축을 아예 받지 않아야** 한다(`Accept-Encoding:
    identity`) — 그러면 세는 바이트가 곧 전송 바이트다. JWKS 는 정의상 상한 안이라
    압축을 포기하는 비용이 없다.
    """
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 40)  # 팽창 후 2MB 급
    jwks_server.gzip = True

    with pytest.raises(KeycloakTransportError):
        await _fetch(jwks_server)


async def test_jwks_request_refuses_compression(jwks_server: Any) -> None:
    """⚠️ **상한만으로는 압축폭탄을 못 막는다 — 압축을 아예 받지 않아야 한다.**

    두 라이브러리 모두 우리에게 **팽창된** 바이트를 준다. 상한을 팽창 뒤에 재면 이미
    메모리를 내준 뒤다(독립 레그 실측: httpx `aiter_bytes()` 가 2MB 를 한 덩어리로 줬다).
    `identity` 를 요구하면 **세는 바이트가 곧 전송 바이트**가 된다.

    이 단언이 그 속성을 **관측**한다 — 「예외가 났다」는 상한의 증거가 아니다(압축폭탄도
    결국 예외를 내지만 그때는 이미 팽창한 뒤다).
    """
    jwks_server.body = _valid_jwks()

    await _fetch(jwks_server)

    assert jwks_server.accept_encoding == "identity"
