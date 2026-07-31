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
from keycloak_sdk.exceptions import KeycloakAuthError
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
