"""JWKS 응답 바이트 상한 — sync 경로.

⚠️ **왜 실 HTTP 서버인가**: 상한은 HTTP 전송에서 걸리는데 기존 테스트는 그보다 **위**인
`openid.certs`를 목한다. 목을 아무리 크게 만들어도 상한을 통과하지 않으므로, 목 경계
아래에서 실제로 바이트를 흘려야 잰다.

⚠️ **거대 본문은 유효한 JSON + 패딩이다.** 쓰레기 바이트로 만들면 상한이 없어도 JSON
파싱이 실패해 「거부됐다」가 통과하고, 그 단언은 상한의 증거가 아니다(node #471 에서 실제로
겪은 거짓 초록).
"""

from __future__ import annotations

import json
import tracemalloc
import zlib
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests
from joserfc.jwk import RSAKey

from keycloak_sdk._internal.jwks_fetch import JWKS_MAX_BYTES, fetch_jwks
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError, TokenValidationError
from keycloak_sdk.oidc import OidcEndpoints
from tests.unit.conftest import RawBeforeMaxLength, gzip_padded


def _config(jwks_server: Any) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=jwks_server.url,
        realm="t",
        client_id="app",
        client_secret="s3cret",
        read_timeout=5.0,
    )


def _valid_jwks(pad_to: int = 0) -> bytes:
    """진짜 RSA 공개키 하나를 담은 유효한 JWKS. `pad_to`까지 무해한 필드로 부풀린다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    doc: dict[str, Any] = {"keys": [key.as_dict(private=False)]}
    body = json.dumps(doc).encode()
    if pad_to and len(body) < pad_to:
        doc["_pad"] = "A" * (pad_to - len(body) - 12)
        body = json.dumps(doc).encode()
    return body


def test_oversize_jwks_is_rejected(jwks_server: Any) -> None:
    """상한을 넘는 JWKS 는 SDK 오류로 거부된다 — 통째로 메모리에 올리지 않는다."""
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 2)
    assert len(jwks_server.body) > JWKS_MAX_BYTES
    cfg = _config(jwks_server)
    client = AuthClient(cfg, OidcEndpoints.for_realm(cfg))

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        client.validate("irrelevant.token.here")


def test_oversize_jwks_is_rejected_without_content_length(jwks_server: Any) -> None:
    """대조군: chunked 라 `Content-Length` 가 없어도 잡는다.

    ⚠️ 헤더만 보고 판정하면 헤더가 없거나 **거짓인** 응답을 놓친다 — 그 구현은 상한이
    있는 것처럼 보이면서 실제로는 없다.
    """
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 2)
    jwks_server.chunked = True
    cfg = _config(jwks_server)
    client = AuthClient(cfg, OidcEndpoints.for_realm(cfg))

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        client.validate("irrelevant.token.here")


def test_jwks_within_cap_is_accepted(jwks_server: Any) -> None:
    """음성 대조군: 상한 안의 정상 JWKS 는 통과한다(상한이 정상 발급을 끊지 않는다).

    토큰 자체는 가짜라 검증에서 떨어지지만, **JWKS 로딩까지는 도달**해야 한다 —
    상한 오류가 아닌 것으로 그것을 확인한다.
    """
    jwks_server.body = _valid_jwks()
    assert len(jwks_server.body) < JWKS_MAX_BYTES
    cfg = _config(jwks_server)
    client = AuthClient(cfg, OidcEndpoints.for_realm(cfg))

    with pytest.raises(Exception) as excinfo:
        client.validate("irrelevant.token.here")
    assert "exceeds" not in str(excinfo.value)
    assert jwks_server.hits == 1


def test_non_200_jwks_is_an_sdk_error(jwks_server: Any) -> None:
    """IdP 가 500 을 주면 SDK 타입으로 나온다(§4) — 그리고 빈 키셋으로 캐시되지 않는다."""
    jwks_server.body = b'{"error":"boom"}'
    jwks_server.status = 500
    cfg = _config(jwks_server)
    client = AuthClient(cfg, OidcEndpoints.for_realm(cfg))

    with pytest.raises(KeycloakTransportError):
        client.validate("irrelevant.token.here")


def test_non_json_body_is_an_sdk_error(jwks_server: Any) -> None:
    """§4 — 하위 파서 예외가 아니라 SDK 타입으로 나온다."""
    jwks_server.body = b"<html>not json</html>"
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError, match="not JSON"):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_json_that_is_not_an_object_is_an_sdk_error(jwks_server: Any) -> None:
    jwks_server.body = b"[1, 2, 3]"
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError, match="not a JSON object"):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_transport_failure_is_translated() -> None:
    """⚠️ requests 예외는 `_wrap` 이 잡지 않는다 — 이 모듈이 스스로 번역하지 않으면
    `requests.ConnectionError` 가 소비자에게 그대로 샌다(§4 위반)."""
    cfg = KeycloakConfig(
        server_url="http://127.0.0.1:1",  # 아무도 듣지 않는 포트
        realm="t",
        client_id="app",
        client_secret="s3cret",
        read_timeout=2.0,
    )

    with pytest.raises(KeycloakTransportError, match="fetch failed"):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_read_failure_midstream_is_translated(jwks_server: Any) -> None:
    """읽는 도중 끊기는 경우도 SDK 타입이다 — 서버가 약속한 길이보다 적게 보내고 끊는다."""
    jwks_server.body = b'{"keys": []}'
    jwks_server.truncate = True
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError, match="fetch failed"):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_oversize_error_body_is_also_capped(jwks_server: Any) -> None:
    """⚠️ 상한은 **상태와 무관하게** 건다.

    200 만 겨누면 오류 응답의 거대 본문이 그대로 들어온다 — php 가 정확히 그 순서로
    배포돼 있었다(#466). 여기서는 500 + 거대 본문이 상한에 걸려야 한다.
    """
    jwks_server.body = b'{"error":"' + b"A" * (JWKS_MAX_BYTES * 2) + b'"}'
    jwks_server.status = 500
    cfg = _config(jwks_server)
    client = AuthClient(cfg, OidcEndpoints.for_realm(cfg))

    with pytest.raises(KeycloakTransportError, match="exceeds"):
        client.validate("irrelevant.token.here")


def test_gzip_bomb_does_not_inflate_past_the_cap(jwks_server: Any) -> None:
    """압축폭탄 — 서버가 우리의 `identity` 요구를 **무시하고** 압축해 보내도 거부한다.

    ⚠️ 이 테스트만으로는 「메모리가 묶였다」를 증명하지 못한다(예외는 팽창 뒤에도 난다).
    그 속성을 관측하는 것은 `test_jwks_request_refuses_compression` 이고, 이쪽은 그 헤더가
    무시당한 경우까지 상한이 남아 있는지를 본다.
    """
    jwks_server.body = _valid_jwks(pad_to=JWKS_MAX_BYTES * 40)
    jwks_server.gzip = True
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_jwks_request_refuses_compression(jwks_server: Any) -> None:
    """압축 거부 — aio 미러와 같은 주장(그 파일의 주석이 근거를 소유한다)."""
    jwks_server.body = _valid_jwks()
    cfg = _config(jwks_server)

    # 토큰이 가짜라 검증에서 떨어진다 — 이 테스트의 관심은 그 앞에 나간 **요청 헤더**다.
    with pytest.raises(TokenValidationError):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")

    assert jwks_server.accept_encoding == "identity"


def test_a_gzip_bomb_is_inflated_here_within_the_cap_whatever_urllib3_does() -> None:
    """⚠️ sync JWKS 상한도 urllib3 버전에 달리면 안 된다 — `iter_content` 는 urllib3 에 풀기를
    맡기고, 2.6 미만 urllib3 는 원문 한 조각을 상한 없이 통째로 푼다(실측 2.5.0: `identity` 를
    무시한 16 MiB 폭탄에 한 번의 decompress 가 8,004,884 바이트 — 51,200 상한의 156 배, 피크
    22 MB). 그 urllib3 를 흉내 낸 원문을 주고, 원문을 청하는지(`decode_content=False`)와 피크를
    잰다."""
    raw = RawBeforeMaxLength(gzip_padded(b'{"keys": []}', 16 * 1024 * 1024))
    response = requests.Response()
    response.status_code = 200
    response.headers["Content-Encoding"] = "gzip"
    response.raw = raw
    session = MagicMock()
    session.get.return_value = response

    outcome: BaseException | None = None
    tracemalloc.start()
    try:
        try:
            fetch_jwks(session, "http://idp.test/certs", timeout=5.0, verify=True, cert=None)
        except Exception as exc:  # 판정은 아래 단언이 한다 — 청한 것과 피크가 먼저다
            outcome = exc
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert set(raw.asked) == {False}, f"asked urllib3 to inflate: {raw.asked[:3]}"
    assert peak < 1024 * 1024, f"16 MiB gzip bomb: peak {peak} bytes"
    assert type(outcome) is KeycloakTransportError
    assert str(outcome) == f"JWKS response exceeds {JWKS_MAX_BYTES} bytes"
    assert raw.closed


@pytest.mark.parametrize("encoding", ["gzip", "deflate"])
def test_a_body_that_is_not_the_compression_it_claims_is_an_sdk_error(
    encoding: str, jwks_server: Any
) -> None:
    """§4 — 이름표만 압축인 본문을 풀다 난 실패도 SDK 타입이다(stdlib `zlib.error` 가 아니다).
    sync 도 이제 aio 와 같은 자리(`_inflate`)에서 푼다."""
    jwks_server.body = _valid_jwks()
    jwks_server.fake_encoding = encoding
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError, match=rf"^JWKS response is not valid {encoding}: "):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")


def test_a_raw_deflate_body_is_inflated_like_a_wrapped_one(jwks_server: Any) -> None:
    """zlib 래퍼 없는 날 deflate 를 `deflate` 라 부르는 서버가 있다 — 토큰 상한과 같은
    인플레이터(`token_cap._inflater`)가 httpx·urllib3 처럼 받는다. urllib3 에 맡기던 sync 는 원래
    받았다 — 여기서 풀게 되면서 그것을 잃지 않는다."""
    comp = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    jwks_server.body = comp.compress(_valid_jwks()) + comp.flush()
    jwks_server.fake_encoding = "deflate"
    cfg = _config(jwks_server)

    # 토큰이 가짜라 검증에서 떨어진다 — 키셋까지는 받았다는 것이 이 테스트의 관심이다.
    with pytest.raises(TokenValidationError):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")

    assert jwks_server.hits == 1


def test_unsupported_content_encoding_is_refused(jwks_server: Any) -> None:
    """aio 미러와 같다(그 파일의 주석이 근거를 소유한다). sync 도 이제 원문을 받아 여기서 푼다 —
    urllib3 에 맡기면 결과가 `brotli` 설치 여부에 달렸다(없으면 원문을 그대로 받아들였다)."""
    jwks_server.body = _valid_jwks()
    jwks_server.fake_encoding = "br"
    cfg = _config(jwks_server)

    with pytest.raises(KeycloakTransportError, match="unsupported encoding"):
        AuthClient(cfg, OidcEndpoints.for_realm(cfg)).validate("irrelevant.token.here")
