# keycloak-sdk (Python)

Keycloak SDK for Python — 인증(OIDC/OAuth2) + 관리 API. [`python-keycloak`](https://github.com/marcospereirampj/python-keycloak)의 `KeycloakOpenID`/`KeycloakAdmin`을 감싸고, JWT 검증만 [`joserfc`](https://jose.authlib.org/)로 자체 강화 구현한다. [Java SDK](../java/)와 개념·계층·명명이 동형(isomorphic)이다.

## 설치

```bash
pip install keycloak-sdk
```

## QuickStart

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.secrets import mask

config = KeycloakConfig(
    server_url="https://keycloak.example.com",
    realm="my-realm",
    client_id="my-client",
    client_secret="my-client-secret",
)

with KeycloakClient.create(config) as kc:
    # 인증(auth)은 즉시 사용 가능
    token = kc.auth.client_credentials_token()
    print(f"access_token={mask(token.access_token)}")

    # 관리(admin)는 최초 접근 시 지연 생성(client_secret 필요)
    users = kc.admin.users.search(first=0, max=10)
    print([u.get("username") for u in users])
```

전체 예제: [`examples/quickstart.py`](examples/quickstart.py).

## Async

`keycloak_sdk.aio`는 sync API와 완전히 동형(같은 메서드명·값타입·예외)인 async
미러다. python-keycloak의 `a_*` 메서드를 감싸 이벤트 루프를 블로킹하지 않는다 —
FastAPI 등 async 프레임워크 안에서 쓰기에 적합하다.

```python
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk._internal.secrets import mask

config = KeycloakConfig(
    server_url="https://keycloak.example.com",
    realm="my-realm",
    client_id="my-client",
    client_secret="my-client-secret",
)

async def handler() -> None:
    async with AsyncKeycloakClient.create(config) as kc:
        token = await kc.auth.client_credentials_token()
        print(f"access_token={mask(token.access_token)}")

        users = await kc.admin.users.search(first=0, max=10)
        print([u.get("username") for u in users])
```

`authorization_url`만 네트워크가 필요 없어 동기 메서드로 남아 있다(`await` 불필요).
나머지 `auth`/`admin` 메서드는 모두 `async def`다. 전체 예제:
[`examples/async_quickstart.py`](examples/async_quickstart.py).

## Java ↔ Python API 매핑

두 SDK는 언어 중립 계약을 공유한다 — Java `camelCase` ↔ Python `snake_case`, 개념·흐름은 동일하다.

| 개념 | Java | Python |
|---|---|---|
| 설정 | `KeycloakConfig.builder()...build()` | `KeycloakConfig(server_url=..., realm=..., client_id=...)` |
| 진입점 생성 | `KeycloakClient.create(config)` | `KeycloakClient.create(config)` |
| client-credentials 토큰 | `client.auth().clientCredentialsToken()` | `kc.auth.client_credentials_token()` |
| 토큰 검증 | `client.auth().validate(token)` | `kc.auth.validate(token)` |
| 사용자 생성 | `client.admin().users().create(rep)` | `kc.admin.users.create(rep)` |
| 사용자 조회 | `client.admin().users().get(id)` | `kc.admin.users.get(id)` |
| 예외 계층 | `KeycloakSdkException` | `KeycloakSdkError` |
| 리소스 없음 | `KeycloakNotFoundException` | `KeycloakNotFoundError` |

## 호환성

| 구성요소 | 버전 |
|---|---|
| Keycloak 서버 | 26.6.x (통합테스트 검증 대상) |
| `python-keycloak` | `>=7.1,<8` |
| `joserfc` | `>=1.7` |
| Python | `>=3.10` (3.10 / 3.11 / 3.12 / 3.13 CI 매트릭스) |

## 개발

```bash
cd python
python -m pip install -e ".[dev]"
pytest -m "not integration"   # 단위 테스트
pytest -m integration          # 통합 테스트 (Docker 필요, testcontainers)
mypy src                       # 정적 타입 검사 (strict)
```

## 라이선스

Apache-2.0
