"""JWKS 응답에 바이트 상한을 걸어 가져온다 — sync/aio 공용.

⚠️ **왜 상류 `certs()`/`a_certs()` 를 안 쓰는가**: 그 경로는 본문을 통째로 메모리에 올린 뒤
`.json()` 한다. 바이트 상한도 `Content-Length` 검사도 없어서, 손상된 IdP 하나가 검증 경로를
메모리로 죽일 수 있다. 그리고 **상류에는 상한을 끼울 이음매가 없다** — `raw_get` 이 `**kwargs`
를 `params=` 로 보내므로 `stream=True` 를 넘기면 그것이 **쿼리 파라미터**가 된다(실측:
`keycloak/connection.py` 의 `raw_get`).

⚠️ **세션 전체에 상한을 걸지 않는다.** 그 세션은 token·refresh·exchange_code·logout·
introspect 가 함께 쓰고(`redirects.py` 의 `harden_openid` 참조), **역할이 많은 액세스 토큰은
정당하게 크다.** JWKS 방어가 정상 발급을 끊으면 안 된다 — 그래서 JWKS 요청 하나만 묶는다.
(같은 이유로 .NET 은 `MaxResponseContentBufferSize` 를 쓰지 않고 전용 리트리버를 만들었다.)

⚠️ **여기서 나가는 오류는 전부 SDK 타입이다(§4).** `_wrap`/`_awrap` 은 상류
`keycloak.exceptions.KeycloakError` **하나만** 번역하므로, 직접 HTTP 를 부르는 이 모듈이
`requests`/`httpx` 예외를 스스로 번역하지 않으면 소비자에게 하위 타입이 그대로 샌다.
"""

from __future__ import annotations

import json
import zlib
from typing import Any

from ..exceptions import KeycloakTransportError

# Nimbus `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT`. 아홉 언어가 **함께 움직이는** 값이라
# 하나만 바꾸지 말 것 — 가드 `scripts/test/test-security-defaults.sh` 의 JWKS 크기상한 축.
JWKS_MAX_BYTES = 51_200

_CHUNK = 8192

# ⚠️ **압축을 요구하지 않는다** — 그러면 정상 서버에서는 **세는 바이트가 곧 전송 바이트**가
# 되어 상한의 의미가 분명해진다. JWKS 는 정의상 상한 안이라 압축을 포기할 비용이 없다.
# ⚠️ 이 헤더는 **1차 방어일 뿐**이다. 무시하는 서버가 있으므로 팽창분에도 상한을 건다
# (`_inflate`) — 헤더 하나에 기대면 그것이 곧 압축폭탄 경로다.
_NO_COMPRESSION = {"Accept-Encoding": "identity"}


class _TooBig(Exception):
    """상한 초과를 전송 오류와 구분해 올리기 위한 내부 신호."""


def _too_big() -> KeycloakTransportError:
    return KeycloakTransportError(f"JWKS response exceeds {JWKS_MAX_BYTES} bytes")


def _inflate(data: bytes, encoding: str) -> bytes:
    """`aiter_raw` 가 준 원문을 필요하면 **상한 안에서** 푼다.

    우리는 `identity` 를 요구했으므로 정상 서버는 압축하지 않는다. 그것을 무시하는 서버가
    있으므로 여기서 풀되, **팽창분에도 같은 상한**을 건다 — 그러지 않으면 상한을 통과한
    작은 gzip 하나가 100MB 로 부푼다(압축폭탄).
    """
    if encoding in ("", "identity"):
        return data
    if encoding not in ("gzip", "deflate"):
        # 요구하지 않은 인코딩을 이해하는 척하지 않는다(fail-closed).
        raise KeycloakTransportError(f"JWKS response uses unsupported encoding {encoding!r}")
    obj = zlib.decompressobj(31 if encoding == "gzip" else 15)
    out = obj.decompress(data, JWKS_MAX_BYTES + 1)
    if len(out) > JWKS_MAX_BYTES or obj.unconsumed_tail:
        raise _too_big()
    return out


def _decode(body: bytes, status: int) -> dict[str, Any]:
    """상태 검사 → JSON 파싱. 둘 다 SDK 타입으로만 실패한다.

    ⚠️ 상태 검사는 **상한 뒤**에 온다. 200 만 겨누고 상한을 걸면 오류 응답의 거대 본문이
    그대로 들어온다 — php 가 정확히 그 순서로 배포돼 있었다(#466).
    """
    if not 200 <= status < 300:
        raise KeycloakTransportError(f"JWKS endpoint returned HTTP {status}")
    try:
        parsed = json.loads(body)
    except ValueError as exc:
        raise KeycloakTransportError(f"JWKS response is not JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise KeycloakTransportError("JWKS response is not a JSON object")
    return parsed


def fetch_jwks(session: Any, url: str, *, timeout: Any, verify: Any, cert: Any) -> dict[str, Any]:
    """하드닝된 requests 세션으로 JWKS 를 상한 안에서 가져온다.

    세션을 그대로 쓰므로 `harden_openid` 의 리다이렉트 거부 훅과 재시도 어댑터가 유지된다.
    """
    try:
        response = session.get(
            url,
            stream=True,
            headers=_NO_COMPRESSION,
            timeout=timeout,
            verify=verify,
            cert=cert,
        )
    except Exception as exc:
        raise KeycloakTransportError(f"JWKS fetch failed: {exc}") from exc

    try:
        body = bytearray()
        for chunk in response.iter_content(_CHUNK):
            body += chunk
            # ⚠️ 다 읽고 나서 길이를 재면 이미 메모리를 내준 뒤다. `Content-Length` 로만
            # 판정해도 안 된다 — 그 헤더는 없을 수도(chunked) 거짓일 수도 있다.
            if len(body) > JWKS_MAX_BYTES:
                raise _TooBig
        status = response.status_code
    except _TooBig as exc:
        raise _too_big() from exc
    except Exception as exc:
        raise KeycloakTransportError(f"JWKS fetch failed: {exc}") from exc
    finally:
        response.close()

    return _decode(bytes(body), status)


async def afetch_jwks(client: Any, url: str, *, timeout: Any) -> dict[str, Any]:
    """httpx AsyncClient 로 JWKS 를 상한 안에서 가져온다.

    ⚠️ **aio 는 sync 와 세션이 다르다.** `harden_openid` 가 겨누는 것은 `connection._s`
    (requests)이고 이 경로는 `connection.async_s`(httpx)로 나간다. 그쪽 리다이렉트 방어는
    우리가 건 훅이 아니라 **httpx 기본값 `follow_redirects=False`** 이므로 — 남의 기본값에
    얹혀 있다 — 여기서는 그것을 **명시**한다. 인스턴스에 `True` 가 설정돼 있어도 이 요청은
    따라가지 않는다. (행동 고정: `tests/unit/aio/test_redirects_async.py`)
    """
    try:
        async with client.stream(
            "GET",
            url,
            headers=_NO_COMPRESSION,
            timeout=timeout,
            follow_redirects=False,
        ) as response:
            body = bytearray()
            # ⚠️ **`aiter_bytes` 가 아니라 `aiter_raw` 다 — 압축 해제 *전* 바이트를 센다.**
            # 실측: `aiter_bytes` 로는 우리가 상한을 보기 전에 httpx 의 `GZipDecoder` 가
            # 통째로 팽창시킨다(`decompress(data)` 에 상한이 없다). 20MB 폭탄에서 피크
            # **84MB** 를 쟀다. 청크 크기를 넘겨도 소용없다 — 디코더가 청킹보다 앞이다.
            # sync 미러는 이 문제가 없다(urllib3 이 `max_length` 를 gzip 에 넘긴다).
            async for chunk in response.aiter_raw(_CHUNK):
                body += chunk
                if len(body) > JWKS_MAX_BYTES:
                    raise _TooBig
            status = response.status_code
            encoding = response.headers.get("content-encoding", "").strip().lower()
    except _TooBig as exc:
        raise _too_big() from exc
    except Exception as exc:
        raise KeycloakTransportError(f"JWKS fetch failed: {exc}") from exc

    return _decode(_inflate(bytes(body), encoding), status)
