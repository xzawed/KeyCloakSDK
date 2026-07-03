# Keycloak Python SDK — 설계 문서 (Design Spec)

- **작성일**: 2026-07-03
- **상태**: 승인 대기 (User Review)
- **패키지**: `keycloak-sdk` (import `keycloak_sdk`)
- **라이선스**: Apache-2.0
- **선행**: [Java SDK 설계](2026-07-02-keycloak-multilang-sdk-design.md) (§10 다국어 확장) — 본 문서가 그 Python 후속

---

## 1. 개요 (Overview)

다국어 Keycloak SDK의 **Python 구현**. Java SDK와 **동일한 언어 중립 계약**(개념·계층·흐름)을 따르되 Pythonic하게 구현한다. 인증(OIDC/OAuth2)과 관리 REST API를 함께 다룬다.

### 전략 변경 — 코드생성 대신 python-keycloak 래핑

Java 설계 §10은 "Python엔 공식 클라이언트가 없으니 OpenAPI 코드생성"을 가정했으나, **성숙한 `python-keycloak` 라이브러리(7.1.1, 2026-02-15)** 가 존재하며 **admin과 OIDC를 모두** 커버함이 리서치로 확인됐다. 따라서 **"언어별 최선 기반 사용"** 원칙에 따라, Java가 공식 admin-client를 감쌌듯 Python은 **`python-keycloak`을 감싼다**.

- **장점**: 지저분한 Keycloak OpenAPI 명세(operationId 0개·securitySchemes 없음·무타입 필드·"not planned" 방치 버그) 회피, 성숙한 라이브러리(106M 다운로드, Keycloak 22~26 지원), 작업량 대폭 감소.
- **주의(감싸서 방어)**: python-keycloak은 PyPI 분류가 "Alpha"이고 최근 머지 속도가 둔화됨. 우리 파사드/예외/타입 계층이 이 라이브러리 변동을 소비자로부터 격리한다.

---

## 2. 범위 (Scope)

### MVP 범위
- **인증 흐름**: Authorization Code + PKCE(`authorization_url` + `exchange_code`), Client Credentials, 토큰 검증/갱신(자체 강화 JWT 검증·introspection·refresh·logout).
- **관리 파사드**: `users`/`clients`/`realms`/`roles`/`groups` (create/get/search/update/delete) + `raw` 탈출구.
- **횡단**: 통합 예외 계층, 자체 강화 JWT 검증, 시크릿 마스킹, 지연 admin 초기화.
- **품질/배포**: pytest 단위 + `testcontainers[keycloak]` 통합, PyPI 배포(hatchling), CI.

### 비목표 (Non-goals)
- **async API**: python-keycloak이 `a_*` 비동기 메서드를 제공하나, MVP는 **sync 우선**(Java 동형 공통 계약). async는 향후 병행 변형으로 미룸.
- OpenAPI 코드생성 (`spec/` 디렉터리 불필요 — 래핑 방식).
- Resource Owner Password grant(보안상 비권장), 프레임워크 특화 통합(FastAPI 등).
- OIDF 인증(certification): 완성 제품 필요 시 별도.

---

## 3. 아키텍처 (Architecture)

### 3.1 구조 (단일 패키지 + 서브모듈, Python 관용)

```
python/                                  # 모노레포 내 java/ 형제
├─ pyproject.toml                        # [build-system] hatchling; deps: python-keycloak>=7.1, joserfc>=1.7
├─ src/keycloak_sdk/
│  ├─ __init__.py                        # 공개 export
│  ├─ config.py                          # KeycloakConfig (frozen dataclass + 검증)
│  ├─ client.py                          # KeycloakClient (파사드)
│  ├─ auth.py                            # AuthClient (KeycloakOpenID 래핑)
│  ├─ admin/
│  │  ├─ __init__.py                     # AdminClient (KeycloakAdmin 래핑)
│  │  ├─ users.py  clients.py  realms.py  roles.py  groups.py
│  ├─ tokens.py                          # TokenSet · ValidatedToken · IntrospectionResult (dataclass)
│  ├─ jwt.py                             # JwtValidator (joserfc 자체 강화 검증)
│  ├─ exceptions.py                      # 예외 계층
│  └─ _internal/
│     ├─ secrets.py                      # 마스킹 유틸
│     └─ oidc.py                         # realm 엔드포인트 URL 구성
├─ tests/
│  ├─ unit/                              # python-keycloak 목 기반
│  └─ integration/                       # testcontainers[keycloak]
├─ README.md
└─ (루트) LICENSE 공유
```

### 3.2 계층 & 결합
- **config**: 불변 설정 + 검증. 타 모듈 독립.
- **auth**: `KeycloakOpenID`를 감싸고, JWT 검증은 자체 `jwt.JwtValidator` 사용(라이브러리 decode_token에 의존하지 않음).
- **admin**: `KeycloakAdmin`을 감싸고, 리소스 파사드로 노출. auth에 의존하지 않음.
- **client**: `KeycloakClient`가 auth+admin 조립(admin 지연 초기화).

---

## 4. 언어 중립 계약 (Java ↔ Python 매핑)

| 개념 | Java | Python |
|---|---|---|
| 설정 | `KeycloakConfig.builder()....build()` | `KeycloakConfig(server_url=..., realm=..., ...)` (dataclass) |
| 진입점 | `KeycloakClient.create(config)` | `KeycloakClient.create(config)` (컨텍스트 매니저) |
| 인증 | `kc.auth().clientCredentialsToken()` | `kc.auth.client_credentials_token()` |
| 검증 | `kc.auth().validate(t)` → `ValidatedToken` | `kc.auth.validate(t)` → `ValidatedToken` |
| 관리 | `kc.admin().users().create(rep)` | `kc.admin.users.create(rep)` |
| 예외 | `KeycloakNotFoundException` | `KeycloakNotFoundError` |

명명 규칙만 언어 관용(camelCase↔snake_case), 개념·계층·흐름·예외 분류는 동형. 문서에 이 매핑표를 유지한다.

---

## 5. 공개 API 설계

### 5.1 설정 & 진입점
```python
config = KeycloakConfig(
    server_url="https://kc.example.com",
    realm="myrealm",
    client_id="my-app",
    client_secret="...",          # Optional (공개 클라이언트는 None)
    scopes=("openid", "profile"),
    connect_timeout=10.0, read_timeout=30.0, clock_skew=30.0,
)  # __post_init__에서 server_url/realm/client_id 검증 → KeycloakConfigError

with KeycloakClient.create(config) as kc:   # __enter__/__exit__ → close
    ...
```

### 5.2 인증 (`kc.auth`, `AuthClient`)
- **Authorization Code + PKCE**: `authorization_url(redirect_uri) -> AuthorizationUrl(url, code_verifier, state, nonce)`; `exchange_code(code, redirect_uri, code_verifier) -> TokenSet`.
- **Client Credentials**: `client_credentials_token() -> TokenSet`.
- **검증/갱신**: `validate(access_token) -> ValidatedToken`(자체 강화 §6.2), `introspect(token) -> IntrospectionResult`, `refresh(refresh_token) -> TokenSet`, `logout(refresh_token) -> None`.

### 5.3 관리 (`kc.admin`, `AdminClient` — 지연 초기화)
- `users`/`clients`/`realms`/`roles`/`groups`: 각각 `create(rep) -> str(id)`, `get(id) -> Optional[dict]`, `search(...) -> list[dict]`, `update(id, rep) -> None`, `delete(id) -> None`.
- `raw -> keycloak.KeycloakAdmin` (파사드 미커버 엔드포인트 탈출구).
- **표현형(representation)**: python-keycloak가 **plain `dict`** 반환/수신 → 라이브러리 타입 미노출이라 `dict[str, Any]` 그대로 통과(Pythonic).
- **지연 초기화**: `admin` 최초 접근 시 `KeycloakAdmin` 생성(secret 필요). 공개 클라이언트는 `auth`만으로 동작.

### 5.4 값 타입 (`tokens.py`, dataclass)
- `TokenSet(access_token, refresh_token, id_token, token_type, scope, expires_at)` + `is_expired(now, skew)`, 마스킹 `__repr__`.
- `ValidatedToken(subject, issuer, audience: list[str], expires_at, issued_at, claims: dict)`.
- `IntrospectionResult(active, username, client_id)`.

---

## 6. 횡단 관심사

### 6.1 통합 예외 계층 (`exceptions.py`)
```
KeycloakSdkError (base)
├─ KeycloakConfigError
├─ KeycloakAuthError            # OAuth error/description 보존
├─ TokenValidationError
├─ KeycloakAdminError           # status_code + keycloak_error 보존
│  ├─ KeycloakNotFoundError     # 404
│  ├─ KeycloakConflictError     # 409
│  └─ KeycloakForbiddenError    # 403
└─ KeycloakTransportError
```
python-keycloak의 `KeycloakError`/`KeycloakAuthenticationError`/`KeycloakGetError`(`.response_code`) 등을 경계에서 SDK 예외로 변환. 공개 API에 python-keycloak 예외 타입 노출 금지. Java와 동일 분류(이름만 `*Error`).

### 6.2 JWT 검증 강화 (`jwt.py`, joserfc) 🔴
python-keycloak `decode_token`에 의존하지 않고 **자체 검증**:
- **허용 알고리즘 핀닝**(RS256), 토큰 헤더 `alg` 불신, `none`/미서명 거부.
- **issuer 정확일치**(`{server_url}/realms/{realm}`), **audience 포함검사**(⚠️ Java 통합에서 발견한 다중 aud `["client","realm-management"]` 대응).
- `exp`/`nbf` + 설정 가능한 클록 스큐.
- **JWKS**: realm `certs` 엔드포인트에서 키셋을 issuer당 캐시. 실패 시 `TokenValidationError`. CVE-2026-11800(알고리즘 혼동) 방어 Java와 일관.

### 6.3 보안
- `TokenSet`/`ValidatedToken`/config의 `__repr__`·로그에서 토큰·시크릿 마스킹.
- `client_secret`은 Python `str`(불변, zero화 불가) — 로깅 금지·마스킹으로 방어, 한계 문서화.
- TLS 검증 기본 on (python-keycloak `verify=True` 기본).

### 6.4 수명주기 & 스레드
- `KeycloakClient`는 컨텍스트 매니저(`close()`가 하위 자원 정리). `admin` 지연 생성.
- JWKS 캐시는 issuer당 프로세스 공유. (async 미도입이므로 단순.)

---

## 7. 의존성 & 버전 (2026-07-03 검증)

| 의존성 | 버전 | 용도 |
|---|---|---|
| `python-keycloak` | `>=7.1,<8` | admin(KeycloakAdmin) + auth(KeycloakOpenID) 기반 |
| `joserfc` | `>=1.7` | 자체 강화 JWT/JOSE 검증 (Authlib 후속, 타입 우선) |
| Python | `>=3.10` | python-keycloak 최소 |
| 대상 Keycloak | `26.6.x` | 통합테스트: 실제 26.6.4 |
| 빌드 | hatchling `>=1.30` | pyproject 백엔드 |
| 테스트 | pytest `9.x` · `testcontainers[keycloak]` `4.14+` · pytest-cov | 단위 + 통합 |
| 타입 | mypy `2.x` (CI) | 정적 타입 검사 |

> ⚠️ `testcontainers[keycloak]`는 자체적으로 `python-keycloak>=6`에 의존 — 버전 정합 확인. Keycloak OpenAPI 명세는 사용하지 않음(래핑 방식).

---

## 8. 테스트 전략
| 층 | 도구 | 대상 |
|---|---|---|
| 단위 | pytest + unittest.mock(python-keycloak `KeycloakOpenID`/`KeycloakAdmin` 목) | PKCE·URL·토큰 매핑·JWT 검증(정적 JWKS)·예외 변환·설정 검증 |
| 통합 | `testcontainers[keycloak]` (실제 KC 26.6, realm import) | 인증 흐름(client-credentials·검증·introspect)·관리 CRUD end-to-end |

- 커버리지(pytest-cov): 로직 라인 ≥90% / 브랜치 ≥85%. 네트워크 경계(auth/admin 래핑)는 통합으로 검증(단위 커버리지 제외).
- JWT 검증은 보안 핵심 — 다중 aud 수용·불일치 거부·`none`/알고리즘 혼동 거부 회귀 테스트(Java 동형).

---

## 9. 빌드 · 배포 · CI
- **패키징**: `pyproject.toml` + hatchling. `src/` 레이아웃. 버전 `0.1.0`.
- **PyPI**: `keycloak-sdk`. **Trusted Publisher(GitHub OIDC)** 태그 드리븐 릴리스 — 저장 자격증명 없이 배포. **human-gated**(`v*` 태그 push).
- **CI**: PR에서 `pytest`(단위 + testcontainers 통합, Python 3.10~3.13 매트릭스) + `mypy`. 태그: PyPI 배포.
- **SemVer**: SDK 자체 버전은 Keycloak/python-keycloak 버전과 분리. 호환 매트릭스로 안내.

---

## 10. 거버넌스 (Java와 동일)
[AI 거버넌스 프레임워크](../../governance/ai-governance-framework.md) 적용: TDD 서브에이전트 → Claude 리뷰 → Codex 교차검증(가용 시) → G1~G6 게이트 → 미달 시 루프. `feature/python-sdk`에서 구현, main에 PR(사람 승인). PyPI 배포는 human-gated.

---

## 11. 배포 전 확인 항목
- [ ] PyPI `keycloak-sdk` 이름 예약(placeholder 0.0.0) — 선착순.
- [ ] PyPI Trusted Publisher(GitHub Actions) 설정.
- [ ] `python-keycloak`/`testcontainers[keycloak]` 버전 정합 최종 확인.

## 12. 참고 (검증 출처, 2026-07-03)
- python-keycloak: https://pypi.org/project/python-keycloak/ (7.1.1) · https://github.com/marcospereirampj/python-keycloak
- joserfc: https://pypi.org/project/joserfc/ (1.7.2) · Authlib jose deprecation: https://docs.authlib.org/en/latest/upgrades/jose.html
- testcontainers[keycloak]: https://testcontainers-python.readthedocs.io/ (4.14.2)
- Keycloak OpenAPI 품질 이슈(래핑으로 회피): keycloak/keycloak#36903, #40400
- 패키징: https://packaging.python.org/en/latest/guides/writing-pyproject-toml/ (hatchling)
