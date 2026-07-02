# Keycloak 다국어 SDK — 설계 문서 (Design Spec)

- **작성일**: 2026-07-02
- **상태**: 승인 대기 (User Review)
- **대상 언어(MVP)**: Java (기준 언어) · **향후**: Python
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

Keycloak을 위한 **다국어(multi-language) SDK**를 만든다. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다루며, 언어마다 관용적이면서도 **개념·계층·흐름은 동형(isomorphic)** 인 SDK를 제공하는 것이 목표다.

첫 구현(MVP)은 **Java**를 기준 언어로 삼아 전체 파이프라인(설계→구현→테스트→Maven Central 배포)을 끝까지 증명한다. 그 다음 **Python** SDK를 동일한 언어 중립 계약(§4)에 맞춰 확장한다.

### 핵심 전략

> 언어마다 **가장 좋은 기반**을 사용한다 — 공식 클라이언트가 있으면 감싸고(Java), 없으면 OpenAPI 명세에서 코드 생성한다(Python) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다.

- **Admin API**: Java는 공식 `org.keycloak:keycloak-admin-client`를 감싼다. Python은 Keycloak 공식 OpenAPI 명세에서 저수준 클라이언트를 코드 생성하고, 그 위에 손수 작성한 파사드를 얹는다.
- **인증 흐름**: 프로토콜을 재구현하지 않는다. Java는 Nimbus OAuth2/OIDC SDK를, Python은 Authlib를 얇게 감싼다.

---

## 2. 범위 (Scope)

### MVP 범위 (Java)

- **인증 흐름**: Authorization Code + PKCE, Client Credentials, 토큰 검증/갱신(JWT 서명 검증·introspection·refresh·logout).
- **관리 파사드**: 공식 admin-client 래핑 위에 관용적 표면 — `users()`, `clients()`, `realms()`, `roles()`, `groups()`. 원시 접근용 탈출구 `raw()` 제공.
- **횡단 관심사**: 통합 예외 계층, 비밀·토큰 보안 정책, JWT 검증 강화, 스레드 안전·수명주기, 회복탄력성(타임아웃·재시도).
- **품질/배포**: 단위 + 통합 테스트(Testcontainers), Maven Central 공개 배포, CI.

### 향후 범위 (Python — 이번 스펙에서는 설계 원칙만, 구현은 별도 스펙)

- 동일한 언어 중립 계약(§4)을 구현. Keycloak OpenAPI에서 관리 클라이언트 생성 + Authlib 인증 래퍼.

### 비목표 (Non-goals)

- Keycloak 서버/확장(SPI, custom provider)의 개발.
- 프레임워크 특화 통합(Spring Boot starter 등)은 MVP 비목표 — 프레임워크 무관(framework-agnostic) 코어를 우선한다.
- Resource Owner Password grant(보안상 비권장)는 MVP 제외.
- OIDF 인증(certification): 라이브러리 자체는 인증 대상이 아니며(§6.2), 완성 제품을 필요 시 별도 인증한다.

---

## 3. 아키텍처 (Architecture)

### 3.1 리포지토리 구조 (폴리글랏 모노레포)

```
KeyCloakSDK/
├─ spec/                         # 버전 고정된 Keycloak Admin OpenAPI 명세 (Python 코드생성 소스, MVP엔 참조/보관)
├─ java/                         # ← MVP 구현 영역 (Maven 멀티모듈 reactor)
│  ├─ pom.xml                    # 부모 POM (버전·의존성 관리)
│  ├─ keycloak-sdk-bom/          # 의존성 버전 고정용 BOM (배포)
│  ├─ keycloak-sdk-core/         # 공통: KeycloakConfig, TokenProvider, 예외 계층, HTTP·보안 정책
│  ├─ keycloak-sdk-auth/         # 인증 래퍼 (Nimbus OAuth2/OIDC SDK 감쌈)
│  ├─ keycloak-sdk-admin/        # 관리 파사드 (공식 keycloak-admin-client 감쌈)
│  ├─ keycloak-sdk/              # 통합 진입점 KeycloakClient (auth+admin 조립, 배포 집합)
│  └─ keycloak-sdk-examples/     # 실행 예제 (배포 제외)
├─ docs/                         # 설계·가이드 문서 (본 문서 포함)
├─ LICENSE                       # Apache-2.0
├─ NOTICE                        # 감싼 Apache-2.0 저작물 고지
└─ CLAUDE.md
```

### 3.2 모듈 경계와 의존 방향

각 모듈은 "무엇을 하고, 어떻게 쓰며, 무엇에 의존하는가"가 한 문장으로 답해지도록 좁게 잡는다.

| 모듈 | 역할 | 의존 |
|---|---|---|
| `core` | 설정·토큰 추상화·예외·보안 정책. 다른 모듈에 의존하지 않음 | (외부만) |
| `auth` | Nimbus를 감싼 인증 흐름. 프로토콜 재구현 없음 | `core` |
| `admin` | 공식 admin-client를 감싼 관리 파사드. 토큰은 `TokenProvider`로 주입 | `core` |
| `keycloak-sdk` | `auth`+`admin`을 엮는 편의 파사드 `KeycloakClient` | `core`, `auth`, `admin` |
| `keycloak-sdk-bom` | 위 모듈 + 외부 의존 버전을 고정 | — |

- **핵심 결합 규칙**: `admin`은 `auth`를 직접 알지 못한다. 둘을 잇는 접착제는 `core`의 `TokenProvider` 인터페이스뿐이다 → auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리 교체가 소비자에게 파급되지 않는다.

---

## 4. 언어 중립 API 계약 (Cross-Language Contract) 🔴

**다국어 일관성의 핵심.** Java(손수 래핑)와 Python(OpenAPI 생성 + 파사드)이 근본적으로 다른 출발점을 갖기 때문에, **언어 중립 계약을 진실 원천으로 먼저 정의**하고 각 언어가 이를 구현한다. Python은 **생성된 저수준 클라이언트를 파사드 뒤에 숨기고**, 생성 코드를 공개 API로 노출하지 않는다.

계약이 규정하는 것:

- **리소스 그룹핑**: `auth`, `admin.users`, `admin.clients`, `admin.realms`, `admin.roles`, `admin.groups`.
- **메서드 이름**: 개념 동일, 표기만 언어 관용 (Java `getUser`/`createUser` ↔ Python `get_user`/`create_user`).
- **모델(대표 필드) 이름**: 동일 개념명 유지.
- **예외 분류(taxonomy)**: §6.1의 계층을 언어별로 동일한 이름으로 미러링.
- **설정 형태**: `KeycloakConfig`의 필드·의미 동일.
- **동기/비동기 자세**: **Sync를 공통 계약**으로 한다. Python은 추후 병렬적이고 명확히 이름 붙은 async 변형을 *추가* 제공할 수 있으나, sync 표면은 항상 존재한다.
- **페이지네이션·에러 페이로드 보존 규칙**: 동일.

문서에 **"언어 추가 체크리스트"** 를 남겨 Python 착수 시 그대로 따르도록 한다. Java ↔ Python 명명 규칙 매핑 표를 유지한다.

---

## 5. 공개 API 설계 (Java)

### 5.1 진입점 & 설정

```java
KeycloakConfig config = KeycloakConfig.builder()
    .serverUrl("https://kc.example.com")
    .realm("myrealm")
    .clientId("my-app")
    .clientSecret("...")              // confidential client일 때 (char[] 권장, §6.2)
    .scopes("openid", "profile")
    .build();                         // 빌드 시점 검증 → 실패 시 KeycloakConfigException

KeycloakClient kc = KeycloakClient.create(config);   // AutoCloseable, 스레드 안전, 재사용 (§6.4)
```

### 5.2 인증 흐름 (auth) — `kc.auth()`

- **Authorization Code + PKCE**: `createAuthorizationRequest()` → 로그인 URL + `code_verifier`(+state/nonce) 반환 → 콜백에서 `exchangeCode(code, verifier, state)` → `TokenSet`.
- **Client Credentials**: `clientCredentialsToken()` → `TokenSet` (M2M · admin 토큰 공급에도 사용).
- **토큰 검증/갱신**: `validate(accessToken)`(JWKS 서명 검증, §6.3), `introspect(token)`, `refresh(refreshToken)`, `logout(refreshToken)`.

### 5.3 관리 흐름 (admin) — `kc.admin()`

- 내부적으로 공식 `org.keycloak.admin.client.Keycloak` 인스턴스를 보유·재사용(§6.4).
- 토큰은 `core`의 `TokenProvider`로 주입. 기본 구현은 client-credentials로 자동 획득·갱신(single-flight, §6.4).
- 관용 표면(우선순위): `users()`, `clients()`, `realms()`, `roles()`, `groups()` — 각 리소스에 CRUD + 자주 쓰는 조회/검색.
- **탈출구**: `admin().raw()`로 공식 `Keycloak` 노출 (파사드가 아직 감싸지 않은 엔드포인트 접근용).

### 5.4 데이터 흐름

`auth`는 토큰을 *발급*, `admin`은 토큰을 *소비*. 접착제는 `core`의 `TokenProvider` 인터페이스뿐. 소비자는 자체 `TokenProvider`를 꽂아 토큰 출처를 대체할 수 있다.

---

## 6. 횡단 관심사 (Cross-Cutting Concerns)

### 6.1 통합 예외 모델

감싼 라이브러리 예외(`jakarta.ws.rs.WebApplicationException`, Nimbus `ParseException`/`GeneralException`)를 **경계에서 SDK 예외로 변환**하며, 공개 API 시그니처에 내부 타입을 노출하지 않는다.

```
KeycloakSdkException (RuntimeException, base)
├─ KeycloakConfigException        # 잘못된 설정 (빌드 시점)
├─ KeycloakAuthException          # 인증/토큰 교환 실패 (OAuth error/error_description 보존)
├─ TokenValidationException       # 서명·만료·issuer·audience 검증 실패
├─ KeycloakAdminException          # 관리 API 오류 (HTTP status + Keycloak error payload 보존)
│  ├─ KeycloakNotFoundException    # 404
│  ├─ KeycloakConflictException    # 409
│  └─ KeycloakForbiddenException   # 403
└─ KeycloakTransportException      # 네트워크/타임아웃
```

동일한 분류를 Python에서도 같은 이름으로 미러링(§4).

### 6.2 비밀·토큰 보안 정책 🔴

- 시크릿/토큰을 **로그에 남기지 않음**. `toString()`·예외 메시지에서 `Authorization` 헤더·토큰·시크릿을 마스킹.
- 클라이언트 시크릿은 가능하면 `char[]`/`byte[]`로 보관하고 사용 후 소거.
- 토큰 저장은 **기본 인메모리**, 교체 가능한 `TokenStore` SPI 제공(디스크/키체인은 소비자가 opt-in).
- **TLS 검증 기본 on**. 개발용 비활성화는 명시적·요란하게 문서화된 옵션으로만.
- PKCE `state`/`nonce` 생성·검증 필수.

### 6.3 JWT 검증 강화 🔴 (CVE-2026-11800 알고리즘 혼동 방지)

- **허용 알고리즘 핀닝**: discovery/설정에서 기대 알고리즘을 고정하고, 토큰 헤더의 `alg`를 신뢰하지 않음. `none` 거부.
- **issuer/audience 검증** 필수.
- `exp`/`nbf` 검증 + 설정 가능한 소량 클록 스큐(기본 30~60s).
- **JWKS 캐시 TTL + 키 회전** 처리. JWKS 소스는 issuer당 프로세스 싱글턴(§6.4).

### 6.4 스레드 안전 · 수명주기

- `KeycloakClient` / `admin`의 `Keycloak` 인스턴스는 **재사용 가능·스레드 안전·`AutoCloseable`**. 생성 비용이 크므로 싱글턴/풀 사용 모델을 문서화. 미종료 시 커넥션/스레드 누수.
- JWKS `JWKSource`는 issuer당 하나를 캐시(싱글턴)로 유지 — 아니면 캐시 무력화 + JWKS 엔드포인트 폭주.
- 만료 시점 토큰 갱신은 **single-flight**로 중복 제거(thundering-herd 방지).

### 6.5 회복탄력성 (Resilience)

- 기본 connect/read 타임아웃 설정.
- 멱등 작업에 한해 지수 백오프 + 지터 재시도(전이적 5xx/네트워크).
- Keycloak `429` 시 `Retry-After` 준수.
- JWKS 갱신/타임아웃 설정 가능.

---

## 7. 의존성 & 버전 (2026-07-02 검증)

> ⚠️ **버전 함정**: Keycloak **서버**(26.6.4)와 **admin-client**(26.0.x 트랙)는 버전 체계가 다르다. admin-client는 여러 서버 버전을 지원하도록 독립 배포되며 "26.6.x admin-client"는 존재하지 않는다. SDK 자체 버전도 Keycloak 버전과 분리한다(§9).

| 의존성 | 좌표 | 버전 | 비고 |
|---|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | `26.0.10` | Jakarta 네임스페이스. RESTEasy 6.2.15.Final + Jackson 2.21.2 전이 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | `11.37.2` | PKCE·client credentials·introspection 지원 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | `10.9.1` | JWKS 검증. 명시적 핀닝(전이 버전은 10.9) |
| 대상 Keycloak 서버 | quay.io/keycloak/keycloak | `26.6.x` | 호환 매트릭스로 관리 |
| Java 베이스라인 | — | **17** | `maven.compiler.release=17`. record/sealed 사용 |

**의존성 충돌 관리**: BOM(`keycloak-sdk-bom`)으로 admin-client/Nimbus/Jackson/RESTEasy 버전 고정. 전체 의존성 트리 문서화. `maven-enforcer-plugin`으로 CI에서 dependency convergence 검사. (shade는 Jakarta JAX-RS provider 리스크로 MVP에서는 보류, 문서화 우선.)

---

## 8. 테스트 전략

| 층 | 도구 | 대상 |
|---|---|---|
| 단위 | JUnit `6.1.1` (Java 17 베이스라인) + Mockito `5.23.0` | PKCE 생성, 설정 검증, 토큰 파싱, 예외 매핑 등 순수 로직 |
| 통합 | `com.github.dasniko:testcontainers-keycloak:4.2.1` (KC 26.6 기본) + `org.testcontainers:testcontainers-junit-jupiter:2.0.5` | 실제 Keycloak 컨테이너에 realm/client 프로비저닝 후 인증 흐름·관리 작업 end-to-end |

> ⚠️ JUnit 모듈은 `org.testcontainers:testcontainers-junit-jupiter`(2.0에서 접두어 변경, 구 `junit-jupiter`는 2.0.5 없음). Java 17 베이스라인이므로 JUnit 6.1.1 사용(Java 11로 낮출 경우에만 JUnit 5.14.4로 고정). `KeycloakContainer`는 이미지명 필수(무인자 생성자 deprecated), `withRealmImportFile(...)`로 프로비저닝, `getKeycloakAdminClient()`/`getClientCredentialsToken(...)` 등 헬퍼 활용.

- **대표 필드 드리프트 테스트**: admin-client의 representation 필드가 서버와 완전히 일치하지 않을 수 있으므로, 의존하는 필드/엔드포인트를 실제 서버 대상으로 단언한다.
- **계약 테스트(향후)**: 언어 간 동작 일관성 검증 스위트를 `spec/`와 연계해 Python 추가 시 재사용.

---

## 9. 빌드 · 버전 · 배포

### 9.1 버전 정책 (SemVer)

- SDK 자체 공개 API에 **엄격한 SemVer** 적용, **Keycloak 버전과 분리**. 지원 서버는 호환 매트릭스로 안내(SDK 버전에 서버 버전을 인코딩하지 않음).
- Java ↔ Python 릴리스 번호 정렬 정책(또는 명시적 독립 + 매핑)을 문서화.

### 9.2 Maven Central 배포 (Central Portal)

> ⚠️ 구 OSSRH는 **2025-06-30 종료**. 반드시 Central Portal(central.sonatype.com) 경로 사용.

- **네임스페이스/groupId**: `io.github.xzawed` (GitHub 계정 `xzawed`, 로그인으로 자동 검증).
- **플러그인**: `org.sonatype.central:central-publishing-maven-plugin:0.11.0` (`<extensions>true</extensions>`, `<publishingServerId>central</publishingServerId>`). 공식 문서 예제의 0.9.0은 낡음 → 0.11.0 사용.
- **필수 산출물**: `maven-source-plugin`(sources jar), `maven-javadoc-plugin`(javadoc jar), `maven-gpg-plugin`(.asc 서명, 공개키를 키서버 배포).
- **필수 POM 메타데이터**: `name`, `description`, `url`, `licenses`(Apache-2.0), `developers`, `scm`.

### 9.3 라이선스

- **Apache-2.0** (Keycloak·Nimbus·Jackson·RESTEasy 등 감싼 스택과 일치, 명시적 특허 부여 유리).
- 최상위 `LICENSE`, SPDX 헤더, POM `<licenses>`, 감싼 Apache-2.0 저작물 고지용 `NOTICE`. Python 패키지도 동일.

### 9.4 CI/CD (GitHub Actions)

- PR: `mvn verify` (단위 + Testcontainers 통합, JDK 17/21 매트릭스), enforcer convergence 검사.
- 태그 릴리스: 서명 후 Central Portal 배포. GPG 개인키·Portal 토큰은 암호화된 CI 시크릿, 키 회전/만료 절차 문서화.

---

## 10. 다국어 확장성 (Python — 향후)

- `spec/`에 **버전 고정된 Keycloak Admin OpenAPI 명세** 보관: `https://www.keycloak.org/docs-api/<KC_VERSION>/rest-api/openapi.json` (버전은 URL로만 판별 — 문서 내 `info.version`은 하드코딩된 `1.0`).
- **명세 정규화(patch) 단계 필수**: 공식 명세에 알려진 결함이 있음 — `securitySchemes` 부재(인증 헤더 미표기), 불리언/정수 필드가 `object`로 뭉개짐, 일부 잘못된 201/204 응답, 타입 없는 배열(`clientProfiles`/`clientPolicies`). 코드생성 전 보정.
- **코드 생성기**: 지저분한 입력에 견고한 `openapi-generator`(v7.23.0)를 기본, `openapi-python-client`(0.29.0)는 프로토타입 옵션.
- **인증 래퍼**: Authlib(1.7.2). JOSE는 `authlib.jose`가 deprecation 경로이므로 `joserfc`로 계획하거나 내부 인터페이스 뒤로 격리.
- **공개 API는 §4 계약을 따르는 손수 작성 파사드** — 생성된 저수준 클라이언트는 내부 구현으로만.
- Java/Python 모두 OIDC 라이브러리 자체는 인증(certified) 아님을 문서에 명시.

---

## 11. 배포 전 확인 항목 (Pre-publish Action Items)

- [x] **GitHub 사용자명 확정** → `xzawed`. groupId `io.github.xzawed`. Private 저장소 `KeyCloakSDK` 생성.
- [ ] **PyPI 패키지명 선점**: PyPI는 역-DNS 네임스페이스가 없고 선착순 → Python SDK 착수 전 코히런트한 이름을 조기 예약(플레이스홀더 0.0.0). Maven groupId:artifactId ↔ PyPI dist name ↔ import package 매핑 문서화.
- [ ] GPG 서명 키 생성 및 키서버 배포, CI 시크릿 등록.
- [ ] Central Portal 계정 생성 및 Portal 토큰 발급.

---

## 12. 참고 (검증 출처)

주요 사실은 2026-07-02 기준 1차 출처(Maven Central metadata/POM, keycloak.org, connect2id.com, central.sonatype.org, GitHub)에 대해 적대적 교차 검증됨.

- Keycloak admin-client: https://www.keycloak.org/securing-apps/admin-client
- Nimbus OAuth2/OIDC SDK: https://connect2id.com/products/nimbus-oauth-openid-connect-sdk
- Maven Central Portal: https://central.sonatype.org/publish/publish-portal-maven/ · OSSRH 종료: https://central.sonatype.org/news/20250326_ossrh_sunset/
- Keycloak OpenAPI: https://www.keycloak.org/docs-api/26.6.4/rest-api/openapi.json
- Testcontainers Keycloak: https://github.com/dasniko/testcontainers-keycloak
