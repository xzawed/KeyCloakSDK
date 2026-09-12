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
