# Keycloak Python SDK — async 변형 설계 문서 (Design Spec)

- **작성일**: 2026-07-03
- **상태**: 승인 대기 (User Review)
- **대상**: 기존 `keycloak-sdk`(Python)에 **비동기 API 추가** — `keycloak_sdk.aio`
- **선행**: [Python SDK 설계](2026-07-03-keycloak-python-sdk-design.md) (sync 구현, main 병합됨)

---

## 1. 개요

이미 완료·병합된 sync Python SDK(`keycloak_sdk`)에 **비동기(async) 변형**을 **순수 추가**한다. sync API는 변경하지 않는다. python-keycloak이 모든 sync 메서드에 `a_*` 비동기 짝을 제공하므로, 이를 감싸 **sync와 평행한 async 클래스**를 `keycloak_sdk.aio` 서브모듈로 제공한다(예: `redis.asyncio`, `sqlalchemy.ext.asyncio`, `httpx.AsyncClient` 패턴).

**동기**: FastAPI·Starlette 등 async 웹 프레임워크에서 이벤트 루프를 블로킹하지 않고 Keycloak 인증·관리 작업을 수행.

---

## 2. 범위

### 포함
- `keycloak_sdk.aio.AsyncKeycloakClient` (async 컨텍스트 매니저, 지연 admin) + `AsyncAuthClient` + `AsyncAdminClient` + async 리소스 파사드(users/clients/realms/roles/groups).
- 인증 흐름(client-credentials·auth-code+PKCE·exchange·refresh·logout·introspect·validate)과 관리 CRUD 전체 async 미러.
- async 예외 경계 변환, async 통합테스트.

### 비목표
- sync API 변경(순수 추가). 새 값 타입/예외/설정(전부 sync와 공유·재사용).
- async 전용 신규 기능(sync에 없는 것). 완전 대칭만.

---

## 3. 아키텍처

### 3.1 구조 (신규 `aio/` 서브패키지)
```
python/src/keycloak_sdk/aio/
├─ __init__.py            # AsyncKeycloakClient 등 export
├─ client.py             # AsyncKeycloakClient
├─ auth.py               # AsyncAuthClient (KeycloakOpenID a_* 래핑)
├─ admin/
│  ├─ __init__.py        # AsyncAdminClient
│  ├─ _translate.py      # acall(awaitable) — async 예외 경계 변환
│  └─ users.py clients.py realms.py roles.py groups.py
```

### 3.2 재사용 (변경 없음, `keycloak_sdk.*`에서 import)
`KeycloakConfig`·`TokenSet`·`ValidatedToken`·`IntrospectionResult`·`AuthorizationUrl`·예외 계층(`exceptions`)·`OidcEndpoints`·PKCE 생성·`_internal.secrets.mask`·**`JwtValidator`**(JWT 검증은 CPU 바운드 sync 로직 — 그대로 재사용).

### 3.3 결합
- `aio`는 `keycloak_sdk`의 공유 모듈에 의존. sync `auth`/`admin`/`client`에는 의존하지 않음(각자 독립적으로 `KeycloakOpenID`/`KeycloakAdmin`을 async 모드로 래핑).
- `AsyncAdminClient`는 `AsyncAuthClient`에 의존하지 않음(sync와 동일 결합 규칙).

---

## 4. 공개 API (sync와 동형, async 시그니처)

```python
from keycloak_sdk import KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient

config = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="...")
async with AsyncKeycloakClient.create(config) as kc:
    tok = await kc.auth.client_credentials_token()          # TokenSet
    vt  = await kc.auth.validate(tok.access_token)          # ValidatedToken
    uid = await kc.admin.users.create({"username": "alice", "enabled": True})
    await kc.admin.users.delete(uid)
```

- **AsyncAuthClient** (KeycloakOpenID a_* 래핑): `await client_credentials_token()`·`await exchange_code(code, redirect_uri, verifier)`·`await refresh(rt)`·`await logout(rt)`·`await introspect(token)`·`await validate(token)`. `authorization_url(redirect_uri)`는 네트워크 없음 → **동기 메서드**(즉시 반환).
- **AsyncAdminClient** (KeycloakAdmin a_* 래핑, 지연): `.users/.clients/.realms/.roles/.groups`의 create/get/search/update/delete를 `async def`로. `.raw` → `KeycloakAdmin`(탈출구).
- **AsyncKeycloakClient**: `create(config)`(classmethod), `.auth`(즉시), `.admin`(지연 프로퍼티), `async with`(`__aenter__`/`__aexit__` → `aclose()`). `aclose()`는 생성된 하위 자원만 정리.

---

## 5. 횡단 관심사

### 5.1 예외 변환 (`aio/admin/_translate.py`)
- `async def acall(awaitable) -> T`: `await`한 뒤 python-keycloak 예외를 sync `_translate.translate(exc)`로 SDK 예외 변환. auth 쪽은 `AsyncAuthClient._awrap`로 `KeycloakAuthError`/`KeycloakTransportError` 변환. **sync와 동일 매핑 재사용**(404/409/403/status).
- 공개 시그니처에 python-keycloak 타입 미노출(sync와 동일).

### 5.2 JWT 검증
- `AsyncAuthClient.validate`: `await openid.a_certs()`(async JWKS fetch) → joserfc `KeySet` → **기존 sync `JwtValidator.validate(token, key_set)`**. JWKS는 인스턴스당 캐시, **키 회전 재시도**(`TokenSignatureError` 시 `a_certs()` 재조회 후 1회 재시도) — sync와 동일 정책의 async 버전.
- 알고리즘 핀닝·`none`/미서명 거부·iss 정확일치·aud 포함검사·exp/skew — `JwtValidator` 재사용으로 자동 일관.

### 5.3 보안·수명주기
- 토큰/시크릿 마스킹(공유 `mask`), TLS 검증 기본 on(python-keycloak `verify=True`). `AsyncKeycloakClient`는 async 컨텍스트 매니저.

---

## 6. 테스트 전략

| 층 | 도구 | 대상 |
|---|---|---|
| 단위 | `pytest` + `pytest-asyncio` + `unittest.mock.AsyncMock` | async 위임·매핑·예외변환·validate 배선(async certs 목) |
| 통합 | `pytest-asyncio` + `testcontainers[keycloak]`(동일 realm) | async E2E: client-credentials·다중 aud validate·introspect·user CRUD |

- `pytest-asyncio`를 dev 의존에 추가, `asyncio_mode = "auto"`(또는 마커) 설정.
- 커버리지(G3): async 리소스 파사드 + `acall` ≥90/85. 네트워크 경계 `AsyncAuthClient`/`AsyncAdminClient`(및 sync 대응)는 커버리지 omit — 통합으로 검증. `mypy --strict` 유지.
- 통합은 `@pytest.mark.integration`(기존 CI integration 잡이 자동 실행).

---

## 7. 의존성 변경
- 추가: `pytest-asyncio>=0.24`(dev). 런타임 의존 변경 없음(python-keycloak `a_*` 이미 포함, httpx 전이).
- Python 3.10+ 유지. 패키지/배포명 불변(`keycloak-sdk`, 같은 wheel에 `aio` 포함).

---

## 8. 거버넌스
[AI 거버넌스 프레임워크](../../governance/ai-governance-framework.md) 적용. `feature/python-async`에서 구현, main에 PR(사람 승인). Codex 가용 시 교차검증(현 세션은 타임아웃 → Claude 리뷰 + 실제 Keycloak async E2E 대체). sync API 무회귀 확인(기존 130 테스트 그대로 통과).

---

## 9. 참고
- python-keycloak async(`a_*`): `KeycloakOpenID.a_token/a_refresh_token/a_logout/a_introspect/a_certs`, `KeycloakAdmin.a_create_user/...` (7.1, 리서치 검증됨).
- pytest-asyncio: https://pytest-asyncio.readthedocs.io/
