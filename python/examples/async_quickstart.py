"""Async QuickStart — `keycloak-sdk`의 `keycloak_sdk.aio` 최소 사용 예제.

sync `examples/quickstart.py`의 async 미러다. FastAPI 같은 async 프레임워크
안에서 이벤트 루프를 블로킹하지 않고 Keycloak을 호출하고 싶을 때 이 경로를 쓴다.

이 파일은 정적으로 임포트/타입체크만 되는 것을 목표로 한다(실제 Keycloak 서버 없이도
`python -c "import ast; ast.parse(...)"`와 `mypy`가 통과해야 한다). 네트워크 호출이
필요한 로직은 `main()`에 있고 `if __name__ == "__main__":` 가드 뒤에서만 실행되므로,
모듈을 임포트하는 것만으로는 아무 요청도 나가지 않는다.

실행하려면 실제 Keycloak 서버 정보로 아래 `KeycloakConfig` 값을 채우고
`python examples/async_quickstart.py`를 실행한다(서비스 계정에 필요한 권한 role 필요).
"""

from __future__ import annotations

import asyncio

from keycloak_sdk import mask
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig


async def main() -> None:
    config = KeycloakConfig(
        server_url="https://keycloak.example.com",
        realm="my-realm",
        client_id="my-client",
        client_secret="my-client-secret",  # 실제 값은 환경변수/시크릿 매니저에서 로드할 것
    )

    # AsyncKeycloakClient.create()는 auth(AsyncAuthClient)를 즉시 조립한다. admin은
    # 최초 `.admin` 접근 시 지연 생성된다(client_secret 필요 — client-credentials grant).
    async with AsyncKeycloakClient.create(config) as kc:
        # 1) client-credentials 토큰 발급 — 토큰 원문은 절대 로그에 남기지 않는다.
        #    `mask()`는 접두 노출 없이 "***"(값이 있을 때)만 돌려준다 — 존재 여부만 드러낸다.
        token = await kc.auth.client_credentials_token()
        print(f"access_token={mask(token.access_token)} token_type={token.token_type}")

        # 2) 관리 API로 사용자 목록 조회(admin이 이 시점에 지연 생성된다).
        users = await kc.admin.users.search(first=0, max=10)
        print(f"users={[u.get('username') for u in users]}")


if __name__ == "__main__":
    asyncio.run(main())
