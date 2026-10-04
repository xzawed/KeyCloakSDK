"""취소가 강제 재조회 창(30초)을 버리지 않는다 — aio 만(sync `validate` 에는 취소가 없다).

수정 전 실측(별도 프로세스 가짜 IdP · 창 30초 · k1 으로 데운 뒤 IdP 가 k2 로 회전): 검증 #1 을
요청이 IdP 에 닿기 **전에**(`asyncio.timeout(0)`) 취소하든 **도중에** 취소하든 창에 도장이 찍히고
그 fetch 는 버려져, 창 안의 #2(정상 k2 토큰)가 `TokenKeyError` 로 거부됐다 — 30.1 초가 지나서야
받아들였다. 이제 도장 뒤의 fetch 는 인스턴스가 소유한 태스크라 호출자의 취소와 무관하게 끝까지 가서
캐시를 채우고, 창 안의 강제 호출자는 낡은 캐시 대신 진행 중인 그 fetch 를 기다린다.

⚠️ **도장을 되돌리는 것으로 고치지 말 것.** 실측(같은 날): 느린 IdP 앞에서 호출자가 시간 초과하면
취소된 위조 kid 검증마다 IdP 요청이 하나씩 났다(10 대 1). 아래 `..._cost_one_idp_request_...` 가 그
모양을 고정한다. 실패(503)한 fetch 는 여전히 창을 쓴다(의도한 의미 — 그대로 고정한다).

⚠️ Python 3.10 에는 `asyncio.timeout` 이 없다 — 취소는 태스크를 직접 `cancel()` 해 결정적으로 건다.
"""

from __future__ import annotations

import asyncio
import gc
import time
from contextlib import suppress
from typing import Any
from unittest.mock import MagicMock

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey

from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakTransportError, TokenKeyError, TokenValidationError
from keycloak_sdk.oidc import OidcEndpoints

_K1 = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
_K2 = RSAKey.generate_key(2048, {"kid": "k2", "use": "sig"})
_FORGER = RSAKey.generate_key(2048, {"kid": "forged", "use": "sig"})
_CONFIG = KeycloakConfig(
    server_url="https://kc.example.com", realm="r", client_id="app", client_secret="s3cret"
)
_ISSUER = OidcEndpoints.for_realm(_CONFIG).issuer


def _token(key: RSAKey, kid: str, subject: str) -> str:
    claims = {"iss": _ISSUER, "aud": "app", "sub": subject, "exp": int(time.time()) + 600}
    return jjwt.encode({"alg": "RS256", "kid": kid}, claims, key)


class _Idp:
    """`afetch_jwks` 자리의 가짜 IdP. `hits` 는 요청이 IdP 에 **닿은** 수다.

    `connect_steps` 만큼 먼저 양보한다 — 연결을 준비하는 동안 요청은 아직 IdP 에 닿지 않았다.
    `gate` 가 있으면 닿은 뒤 그것이 열릴 때까지 응답이 늦는다(느린 IdP)."""

    def __init__(self, key: RSAKey) -> None:
        self.jwks: dict[str, Any] = {"keys": [key.as_dict(private=False)]}
        self.hits = 0
        self.connect_steps = 0
        self.gate: asyncio.Event | None = None
        self.fail: Exception | None = None

    async def fetch(self, *_args: Any, **_kwargs: Any) -> dict[str, Any]:
        for _ in range(self.connect_steps):
            await asyncio.sleep(0)
        self.hits += 1
        if self.gate is not None:
            await self.gate.wait()
        if self.fail is not None:
            raise self.fail
        return self.jwks


async def _warm_then_rotate(ajwks: Any) -> tuple[AsyncAuthClient, _Idp, str]:
    """k1 으로 캐시를 데우고(요청 1) IdP 를 k2 로 회전시킨다. 창은 기본값(30초)이다."""
    idp = _Idp(_K1)
    ajwks.side_effect = idp.fetch  # 바운드 `async def` — AsyncMock 이 그 코루틴을 기다린다
    client = AsyncAuthClient(_CONFIG, OidcEndpoints.for_realm(_CONFIG), openid=MagicMock())
    assert (await client.validate(_token(_K1, "k1", "user-k1"))).subject == "user-k1"
    assert idp.hits == 1
    idp.jwks = {"keys": [_K2.as_dict(private=False)]}
    return client, idp, _token(_K2, "k2", "user-k2")


async def _until(predicate: Any) -> None:
    for _ in range(200):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("the condition never held")


async def test_a_validation_cancelled_before_its_refetch_reached_the_idp_keeps_the_window(
    ajwks: Any,
) -> None:
    client, idp, k2_token = await _warm_then_rotate(ajwks)
    idp.connect_steps = 1
    first = asyncio.ensure_future(client.validate(k2_token))
    await asyncio.sleep(0)  # #1 이 강제 재조회를 정하고(창 도장) 첫 정지점에 섰다
    assert idp.hits == 1, "the refetch must not have reached the IdP yet"

    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first

    result = await client.validate(k2_token)  # 창 안(30초)이다
    assert result.subject == "user-k2"
    assert idp.hits == 2, "one /certs request for the window"


async def test_a_validation_cancelled_mid_flight_lets_its_refetch_fill_the_cache(
    ajwks: Any,
) -> None:
    client, idp, k2_token = await _warm_then_rotate(ajwks)
    idp.gate = asyncio.Event()
    first = asyncio.ensure_future(client.validate(k2_token))
    await _until(lambda: idp.hits == 2)  # 요청이 IdP 에 닿았고 응답을 기다린다

    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first
    idp.gate.set()

    result = await client.validate(k2_token)
    assert result.subject == "user-k2"
    assert idp.hits == 2, "one /certs request for the window"


async def test_cancelling_one_caller_does_not_fail_another_waiting_on_the_same_refetch(
    ajwks: Any,
) -> None:
    client, idp, k2_token = await _warm_then_rotate(ajwks)
    idp.gate = asyncio.Event()
    first = asyncio.ensure_future(client.validate(k2_token))
    await _until(lambda: idp.hits == 2)
    second = asyncio.ensure_future(client.validate(k2_token))
    for _ in range(5):
        await asyncio.sleep(0)  # #2 도 같은 재조회를 기다리기 시작했다
    assert not second.done()

    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first
    idp.gate.set()

    assert (await second).subject == "user-k2"
    assert idp.hits == 2


async def test_a_refetch_that_fails_still_uses_the_window(ajwks: Any) -> None:
    """실패(503)는 의도대로 창을 쓴다 — 회전을 받아들이는 것은 창이 지난 뒤다."""
    client, idp, k2_token = await _warm_then_rotate(ajwks)
    idp.fail = KeycloakTransportError("JWKS endpoint returned HTTP 503")

    with pytest.raises(KeycloakTransportError, match="503"):
        await client.validate(k2_token)
    idp.fail = None
    with pytest.raises(TokenKeyError):
        await client.validate(k2_token)

    assert idp.hits == 2


async def test_cancelled_forged_kid_validations_cost_one_idp_request_per_window(
    ajwks: Any,
) -> None:
    """도장을 되돌리는 「수정」을 잡는다 — 느린 IdP 앞에서 호출자가 매번 포기하면, 되돌림은 위조
    kid 검증마다 IdP 요청을 하나씩 열었다(실측 10 대 1). 창 하나에 요청은 하나다."""
    client, idp, _ = await _warm_then_rotate(ajwks)
    idp.gate = asyncio.Event()  # IdP 가 느리다 — 범람 동안 답하지 않는다

    for i in range(10):
        forged = asyncio.ensure_future(client.validate(_token(_FORGER, f"forged-{i}", "x")))
        for _ in range(3):
            await asyncio.sleep(0)
        forged.cancel()
        with suppress(asyncio.CancelledError, TokenValidationError):
            await forged

    assert idp.hits == 2, "warm-up + one forced refetch for the whole window"
    idp.gate.set()
    await asyncio.sleep(0)


async def test_a_refetch_that_fails_after_its_caller_left_is_not_reported_as_unretrieved(
    ajwks: Any,
) -> None:
    """호출자가 다 떠난 뒤 실패한 fetch 는 그 실패를 누군가 거둬야 한다 — 아니면 asyncio 가 GC 때
    「Task exception was never retrieved」를 로그로 찍는다."""
    loop = asyncio.get_running_loop()
    reported: list[str] = []
    previous = loop.get_exception_handler()
    loop.set_exception_handler(lambda _loop, ctx: reported.append(str(ctx.get("message"))))
    try:
        client, idp, k2_token = await _warm_then_rotate(ajwks)
        idp.gate = asyncio.Event()
        idp.fail = KeycloakTransportError("JWKS endpoint returned HTTP 503")
        first = asyncio.ensure_future(client.validate(k2_token))
        await _until(lambda: idp.hits == 2)
        first.cancel()
        with suppress(asyncio.CancelledError):
            await first
        idp.gate.set()
        for _ in range(10):
            await asyncio.sleep(0)  # fetch 가 실패로 끝나고 완료 콜백이 돈다
        del first, client
        gc.collect()
    finally:
        loop.set_exception_handler(previous)

    assert not [m for m in reported if "never retrieved" in m], reported
