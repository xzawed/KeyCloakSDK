# keycloak-sdk (Python)

Keycloak SDK for Python — 인증(OIDC/OAuth2) + 관리 API. [`python-keycloak`](https://github.com/marcospereirampj/python-keycloak)의 `KeycloakOpenID`/`KeycloakAdmin`을 감싸고, JWT 검증만 [`joserfc`](https://jose.authlib.org/)로 자체 강화 구현한다. [Java SDK](https://github.com/xzawed/KeyCloakSDK/tree/main/java/)와 개념·계층·명명이 동형(isomorphic)이다.

[English](https://github.com/xzawed/KeyCloakSDK/blob/main/python/README.md) · 한국어

> **사전 릴리스** — PyPI에 아직 게시되지 않았다.

## 설치

```bash
pip install keycloak-sdk
```

배포명은 `keycloak-sdk`, 임포트 패키지명은 `keycloak_sdk`다.

## QuickStart

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig

config = KeycloakConfig(
    server_url="https://keycloak.example.com",
    realm="my-realm",
    client_id="my-client",
    client_secret="my-client-secret",  # 실제 값은 환경변수/시크릿 매니저에서 로드할 것
)

with KeycloakClient.create(config) as kc:
    # 1) 인증(auth)은 즉시 사용 가능. repr(TokenSet)은 토큰 값을 전부 마스킹한다.
    token = kc.auth.client_credentials_token()

    # 2) 자체 강화 검증(알고리즘 핀·iss 정확일치·aud 포함검사·exp 필수·클록 스큐)
    validated = kc.auth.validate(token.access_token)
    print(f"subject={validated.subject} aud={validated.audience}")

    # 3) 관리(admin)는 최초 접근 시 지연 생성(client_secret 필요)
    users = kc.admin.users.search(first=0, max=10)
    print([u.get("username") for u in users])
```

전체 예제: [`examples/quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/quickstart.py).

## Async

`keycloak_sdk.aio`는 sync API와 완전히 동형(같은 메서드명·값타입·예외)인 async
미러다. python-keycloak의 `a_*` 메서드를 감싸 이벤트 루프를 블로킹하지 않는다 —
FastAPI 등 async 프레임워크 안에서 쓰기에 적합하다.

```python
from keycloak_sdk import KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient


async def handler(config: KeycloakConfig) -> None:
    async with AsyncKeycloakClient.create(config) as kc:
        token = await kc.auth.client_credentials_token()
        validated = await kc.auth.validate(token.access_token)
        print(f"subject={validated.subject}")

        users = await kc.admin.users.search(first=0, max=10)
        print([u.get("username") for u in users])
```

`authorization_url`만 네트워크가 필요 없어 동기 메서드로 남아 있다(`await` 불필요).
나머지 `auth`/`admin` 메서드는 모두 `async def`다. 전체 예제:
[`examples/async_quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/async_quickstart.py).

## 보안 기본값

- **알고리즘 핀닝**: 헤더의 `alg`를 신뢰하지 않아 `alg: none`·HS/RS 혼동을 구조적으로 거부한다.
- **클레임 강제**: `iss` 정확일치 · `aud` 포함검사 · `exp` 필수 · `nbf` · 제한된 클록 스큐.
- **DoS-safe JWKS**: 미해결 kid에만 재조회하고 그 재조회도 rate-limit되어 위조 토큰이 IdP 트래픽을 증폭시키지 못한다.
- **마스킹·TLS**: 시크릿·토큰은 완전 마스킹(`***`, 접두 노출 없음)되고 TLS 검증은 기본 on이다.

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

## 문서

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#python)
- [Keycloak 서버 배포 가이드](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [보안 정책](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- 개발/빌드 명령: [CONTRIBUTING.md](https://github.com/xzawed/KeyCloakSDK/blob/main/CONTRIBUTING.md)

## 라이선스

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/python/LICENSE)
