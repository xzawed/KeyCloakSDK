# Keycloak Node(TypeScript) SDK — 설계 문서 (Design Spec)

- **작성일**: 2026-07-04
- **상태**: 승인 대기 (User Review)
- **대상**: 3번째 언어 — TypeScript/Node.js (`node/`)
- **진실 원천**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) · 절차: [add-a-language 플레이북](../../guides/add-a-language-playbook.md)
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

Keycloak을 위한 **Node.js용 SDK**를 만든다. Java(`keycloak-admin-client`+Nimbus)·Python(`python-keycloak`+joserfc)에 이어 세 번째 언어로, **§4 언어 중립 계약에 동형(isomorphic)**이다 — 같은 계층(`config → auth → jwt → admin → client`)·같은 예외 계급·같은 보안 불변식·같은 테스트 시나리오. 관용은 언어를 따른다(camelCase, Promise 기반 async).

두 API 표면을 각 언어 최고의 성숙 클라이언트로 감싼다 — **인증(OIDC/OAuth2)은 `openid-client`, 관리(Admin REST)는 공식 `@keycloak/keycloak-admin-client`** — 그 위에 일관된 파사드를 얹는다. **JWT 검증만은 라이브러리 기본값을 신뢰하지 않고 `jose`로 자체 강화 구현**한다.

### 핵심 결정 (브레인스토밍 승인)
- **배치**: 모노레포 — 이 저장소 최상위 `node/`(java/·python/과 나란히). §4 계약·거버넌스·docs·CHANGELOG 공유.
- **런타임**: **ESM 전용 · Node 20+**. 권장 클라이언트(`openid-client` v6·native fetch/WebCrypto)와 정렬. CommonJS `require` 소비자는 dynamic import로만 가능(명문화).
- **동시성**: **async-only**(모든 공개 메서드 Promise 반환) — JS 관용. Java sync·Python sync+async와의 자연스러운 언어차.

---

## 2. 범위 (Scope) & 비목표

### 범위
- **인증 흐름**: Authorization Code + PKCE(S256), Client Credentials, Refresh, Logout, Introspection, JWT 검증.
- **관리 파사드**: `users`/`clients`/`realms`/`roles`/`groups` + 원시 접근 `raw()`.
- **횡단**: 통합 예외 계급, 시크릿·토큰 마스킹, TLS 검증 기본 on, 수명주기(`close()`), 타임아웃.
- **품질/배포**: 단위 + Testcontainers 통합테스트, npm 배포(태그 드리븐, human-gated), CI.

### 비목표
- 브라우저/SPA 인증(그건 `keycloak-js`/`oidc-client-ts` 영역) — 이 SDK는 **서버측(Node)** 파사드.
- CommonJS 듀얼 빌드(ESM 전용).
- 별도 sync API(async-only).

---

## 3. 의존성 (래핑 대상)

| 계층 | 래핑 라이브러리 | 근거 · 주의 |
|---|---|---|
| **auth** | `openid-client` v6 (panva) | OIDF 인증 RP. ESM·Node 20+·native fetch. 함수형 API. 메이저 핀. |
| **jwt** | `jose` (panva) | `createRemoteJWKSet`(JWKS 캐시+쿨다운)·`jwtVerify`(algorithms·issuer·audience·clockTolerance). 안전 기본값은 우리가 얹는다. |
| **admin** | `@keycloak/keycloak-admin-client` (공식) | 서버 버전을 npm 트랙으로 추종 → **버전 핀** + CI `npm install` 확인. representation 타입은 문서화된 은닉성 예외로 통과(Java admin과 동일 정책). |

> ⚠️ **착수 시 딥리서치로 재검증**(플레이북 1단계): 유지보수 상태·최신 메이저·라이선스(Apache-2.0 호환)·`keycloak-connect` deprecated 확인. `keycloak-js`/`oidc-client-ts`는 브라우저용이라 **부적합**. 후보가 바뀌면 이 표를 갱신 후 구현.

---

## 4. 디렉터리 구조 (`node/`)

```
node/
├─ package.json          # "type":"module", exports 맵, 배포명 @xzawed/keycloak-sdk
├─ tsconfig.json         # strict, moduleResolution NodeNext, target ES2022, declaration
├─ eslint.config.js      # 보안 룰셋 포함
├─ vitest.config.ts      # 커버리지 게이트(로직 모듈, 경계 omit)
├─ src/
│  ├─ index.ts           # 공개 export 배럴
│  ├─ config.ts          # KeycloakConfig(불변) + 검증
│  ├─ errors.ts          # KeycloakError 계급
│  ├─ tokens.ts          # TokenSet / ValidatedToken / IntrospectionResult
│  ├─ token-provider.ts  # TokenProvider + client-credentials 기본구현
│  ├─ oidc-metadata.ts   # {serverUrl}/realms/{realm} 엔드포인트 조립
│  ├─ auth.ts            # AuthClient — openid-client 래핑
│  ├─ jwt.ts             # JwtValidator — jose 자체 강화
│  ├─ admin/
│  │  ├─ index.ts        # AdminClient + raw()
│  │  ├─ users.ts  clients.ts  realms.ts  roles.ts  groups.ts
│  └─ client.ts          # KeycloakClient 통합 진입점
└─ test/
   ├─ unit/              # 목/스텁, 네트워크 격리
   └─ integration/       # testcontainers, 실제 Keycloak
```

각 파일은 단일 책임. 파사드(`client.ts`·`admin/index.ts`) 뒤에 하위 타입 은닉.

---

## 5. 계층 설계 (동형 + async)

### 5.1 공개 API (camelCase, 모두 async 별도 표기 외 Promise)
- **`KeycloakClient.create(config)`** → 인스턴스. `client.auth`(즉시)·`client.admin`(지연, clientSecret 필요)·`client.close()`/`[Symbol.asyncDispose]`.
- **AuthClient**: `createAuthorizationRequest()`(동기 — 네트워크 없음: `{ url, codeVerifier, state, nonce }`) · `exchangeCode(code, verifier, state)` · `clientCredentialsToken()` · `refresh(refreshToken)` · `introspect(token)` · `logout(refreshToken)` · `validate(accessToken)` → `ValidatedToken`.
- **AdminClient**: `users` · `clients` · `realms` · `roles` · `groups` 리소스 접근자 + `raw()`(공식 `KeycloakAdminClient` 노출). 각 리소스는 `create/get/search/update/delete` 등.

### 5.2 값 타입 (`tokens.ts`)
- `TokenSet { accessToken; refreshToken?; tokenType; expiresIn; scope? }`
- `ValidatedToken { subject; audience: string[]; issuer; claims }`
- `IntrospectionResult { active; ...claims }`

### 5.3 결합 규칙
`admin`은 `auth`를 직접 모른다 — `core`의 `TokenProvider` 인터페이스로만 연결. 기본 `TokenProvider`는 client-credentials 자동 획득·갱신(single-flight). 소비자는 자체 `TokenProvider`를 주입 가능.

### 5.4 예외 계급 (`errors.ts`)
`KeycloakError`(base) → `KeycloakConfigError` · `KeycloakAuthError` · `KeycloakTokenValidationError` · `KeycloakAdminError` · `KeycloakNotFoundError`(404) · `KeycloakConflictError`(409) · `KeycloakForbiddenError`(403) · `KeycloakTransportError`. **경계에서 하위 라이브러리 에러를 이 타입들로 변환** — `openid-client`/`@keycloak/*` 에러가 공개 API로 새지 않는다.

---

## 6. 보안 불변식 (§4 · 게차 준수)

- **마스킹**: 토큰/시크릿은 로그·`toString`/직렬화·에러 메시지에 **완전 불투명 `***`**(접두 노출 없음). 값 타입의 `toJSON`/커스텀 inspect에서 강제.
- **TLS 검증 기본 on**: no-op 옵션 금지.
- **JWT 강화(`jwt.ts`)**: 허용 알고리즘 핀(`RS256` 등, 헤더 `alg` 불신)·`none`/미서명 거부·`iss` 정확일치·`aud` **포함검사**(다중 aud 수용)·`exp`/`nbf` + 클록 스큐(기본 30s)·**JWKS 재조회 DoS-안전**(서명 위조는 재조회 유발 안 함, kid 미해결만 재조회, 최소 간격 rate-limit — `jose` `createRemoteJWKSet`의 쿨다운 활용 + 검증 순서 설계).
- **admin 타임아웃 주입**: config 타임아웃을 admin-client HTTP에 전달(무한대기 방지).
- **CI 회귀 가드**: 마스킹·TLS·JWKS DoS-safe 단위 테스트를 머지 차단 잡으로.

---

## 7. 테스트 (Java/Python 패리티)

| 층위 | 도구 | 대상 |
|---|---|---|
| **단위** | `vitest`(ESM 네이티브) + 목/스텁 | PKCE 생성, 설정 검증·기본값, 토큰 응답 파싱, JWT 강화(alg 핀·none·iss·aud·exp/nbf), 예외 경계 매핑, 마스킹 |
| **통합** | `testcontainers`(npm) + 실제 **Keycloak 26.6** | client-credentials→`validate`(다중 aud)→introspect→user/client CRUD→`raw()`→delete 후 `KeycloakNotFoundError`. **Java/Python `it-realm-realm.json` 재사용** |
| **커버리지** | `vitest --coverage`(c8) | 로직 모듈 임계값(예: 라인≥90/브랜치≥85), 네트워크 경계(`auth`/`admin` 생성) omit |

시나리오 집합은 Java/Python과 **동형**(개수는 언어차 허용). 통합은 Docker 필요.

---

## 8. 빌드 · CI · 배포

- **빌드**: `tsc`(ESM + `.d.ts` 생성). `package.json` `exports`·`types`·`"type":"module"`. `sideEffects:false`.
- **품질**: `eslint`(보안 룰 포함)·`prettier`·`tsc --noEmit`(strict).
- **CI (`.github/workflows/node-ci.yml`)**: matrix Node **20·22** — lint+typecheck+unit+coverage 잡, integration 잡(Docker) 별도. paths `node/**`.
- **배포 (`.github/workflows/node-release.yml`)**: `node-v*` 태그 → `npm publish --provenance`(OIDC Trusted Publishing, 저장 토큰 없음), human-gated. 로컬 사전검증 `npm pack`/`npm publish --dry-run`.
- **패키지**: `@xzawed/keycloak-sdk` `0.1.0`(scoped — npm 선점 회피, `io.github.xzawed` 네임스페이스와 정합). `publishConfig.access:public`.

---

## 9. 문서 · 거버넌스

- getting-started에 **Node 섹션(4블록)** 추가 · README·CLAUDE 구조 트리·로드맵 현황 매트릭스 갱신 · CHANGELOG `(Node)` 태그.
- 언어별 **verification-log**(게이트 통과·Loops 이력) 기록.
- **G1~G6 게이트 + Codex 이중검증 + Loops** 준수. 실행은 **WBS → Workflow 오케스트레이션**(플레이북 6단계 매핑), 딥리서치·다이나믹 워크플로우 승인됨.

---

## 10. 결정 · 열린 항목

- **결정됨**: 모노레포 `node/` · ESM-only Node 20+ · async-only · 전체 §4 계약 동형 · 래핑(openid-client/jose/admin-client) · vitest · 패키지 `@xzawed/keycloak-sdk`.
- **착수 시 확정**: §3 클라이언트 후보의 딥리서치 재검증(유지보수·라이선스·최신 메이저) · npm 패키지명 가용성 확인(선점 시 대안) · 커버리지 임계값 수치 확정.
- **비목표 재확인**: 브라우저 지원·CJS 듀얼·sync API는 범위 밖.
