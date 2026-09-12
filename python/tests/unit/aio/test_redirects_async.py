"""async 경로의 리다이렉트 핀 테스트.

python-keycloak의 async 전송(`httpx.AsyncClient`)은 **오늘은** 안전하다 —
httpx의 `follow_redirects` 기본값이 False다. 우리가 켜서 안전한 게 아니라 남의
기본값에 얹혀 있다는 뜻이므로, 그 기본값이 바뀌거나 python-keycloak이
`follow_redirects=True`를 넘기기 시작하면 **조용히** 취약해진다.

그래서 속성(`async_s.follow_redirects is False`)이 아니라 **행동**을 고정한다 —
속성 단언은 라이브러리 기본값을 되풀이할 뿐이고 python-keycloak이 플래그를 넘기는
변화만 잡지만, 행동 단언은 스택 어느 층에서 바뀌든 잡는다.
"""

from __future__ import annotations

import httpx
import pytest
from keycloak import KeycloakOpenID

from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError
from keycloak_sdk.oidc import OidcEndpoints
from tests.unit.conftest import ACCESS_TOKEN, CLIENT_SECRET, Trap


def _config(trap: Trap) -> KeycloakConfig:
    return KeycloakConfig(
        server_url=trap.idp_url,
        realm="t",
        client_id="app",
        client_secret=CLIENT_SECRET,
        read_timeout=5.0,
    )


async def test_async_backchannel_does_not_follow_redirects(trap: Trap) -> None:
    """대조군: 같은 덫에서 `follow_redirects=True`인 httpx는 따라가고 거짓 성공을 만든다."""
    leaky = KeycloakOpenID(
        server_url=trap.idp_url,
        realm_name="t",
        client_id="app",
        client_secret_key=CLIENT_SECRET,
        verify=False,
        timeout=5,
    )
    # python-keycloak이 언젠가 넘길 수 있는 바로 그 한 줄을 시뮬레이션한다.
    leaky.connection.async_s = httpx.AsyncClient(follow_redirects=True)
    assert await leaky.a_introspect(ACCESS_TOKEN) == {"active": True, "username": "victim"}
    assert len(trap.hits) == 1, "대조군이 리다이렉트를 따라가지 않았다 — 덫 고장"
    assert CLIENT_SECRET in trap.hits[0].body
    await leaky.connection.aclose()
    trap.reset()

    # 대상: SDK의 async 경로는 따라가지 않고 성공을 반환하지도 않는다.
    config = _config(trap)
    client = AsyncAuthClient(config, OidcEndpoints.for_realm(config))
    with pytest.raises(KeycloakAuthError) as exc_info:
        await client.introspect(ACCESS_TOKEN)

    assert trap.hits == []
    assert "307" in str(exc_info.value)
    await client.aclose()


async def test_async_jwks_is_not_poisoned_by_a_redirect(trap: Trap) -> None:
    """aio 의 **JWKS 레인**도 3xx 를 따라가지 않는다.

    ⚠️ 이 테스트는 **변이 프로브가 찾아내서** 생겼다: `afetch_jwks` 의
    `follow_redirects=False` 를 `True` 로 바꿔도 스위트 전체가 초록이었다. 위 introspect
    테스트는 상류 `a_introspect` 경로를 재는데, JWKS 는 바이트 상한을 걸려고 상류를
    우회해 **직접 GET** 하므로 그 보장이 이쪽에 자동으로 오지 않는다.

    따라가면 무엇을 잃는가: 공격자가 돌려준 JWKS 가 **검증 키로 캐시된다**(인증 전면 우회).
    """
    certs_url = f"{trap.idp_url}/realms/t/protocol/openid-connect/certs"

    # 대조군: 따라가는 클라이언트는 공격자 JWKS 를 받아온다 — 덫이 무장돼 있음을 증명한다.
    async with httpx.AsyncClient(follow_redirects=True) as leaky:
        stolen = await leaky.get(certs_url)
    assert stolen.json() == {"keys": [{"kid": "ATTACKER-KEY", "kty": "oct"}]}
    assert len(trap.hits) == 1, "덫이 무장되지 않았다"
    trap.reset()

    # 대상: SDK 는 따라가지 않고, 성공을 반환하지도 않으며, 캐시도 채우지 않는다.
    config = _config(trap)
    client = AsyncAuthClient(config, OidcEndpoints.for_realm(config))
    with pytest.raises(KeycloakTransportError) as exc_info:
        await client.validate("not.a.real.token")

    assert trap.hits == [], "SDK 가 리다이렉트 대상으로 요청을 보냈다"
    assert client._jwks_cache is None, "공격자 JWKS 가 캐시됐다"
    assert "307" in str(exc_info.value)
    await client.aclose()
