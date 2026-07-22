# 검증 로그 — Node.js/TypeScript SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Node SDK(`@xzawed/keycloak-sdk`) 태스크별 정량 검증 기록. 브랜치 `feature/node-sdk`.

**툴체인**: 시스템 Node v22(요구 20+) · npm. 명령은 `node/`에서: `npm ci|test|run typecheck|run lint|run build|run test:it`.

**게이트**: G1 빌드/타입(`tsc`) · G2 단위테스트(`vitest`) · G3 커버리지(v8, 로직 라인≥90/브랜치≥85; 네트워크 경계 `auth.ts`/`admin/**`/`index.ts` omit) · G4 스펙리뷰 · G5 교차검증(다중에이전트 어드버서리얼) · G6 보안.

> **실행 방식**: 승인된 WBS → Workflow 오케스트레이션 + G1~G6 + Loops + 딥리서치. 각 태스크 TDD·계층별 커밋. Codex 대신 이번 사이클은 **4-차원 다중에이전트 어드버서리얼 리뷰**(정확성·보안·동형성·테스트)로 G5 교차검증을 수행했다.

---

## 딥리서치 (착수 전, Task 1) — 라이브러리 API 확정

공식 타입 정의(`node_modules`)·context7·web으로 현행 버전·시그니처·라이선스를 확인해 아래를 **확정**(구현 중 재확인 불필요):

- **openid-client `6.8.4`**(함수형·ESM): `discovery(url, clientId, secret?, clientAuth?, {execute})` → `Configuration`; `clientCredentialsGrant`/`authorizationCodeGrant(config, currentUrl, checks)`/`refreshTokenGrant`/`tokenIntrospection`/`buildEndSessionUrl`. 타임아웃은 `Configuration.timeout`(**초**) 내장 프로퍼티. http 로컬은 `allowInsecureRequests`를 `execute`에. 토큰 응답은 snake_case(oauth4webapi `TokenEndpointResponse`).
- **jose `5.10.0`**(현재 `^6` — PR #80에서 6.2.x로 전진, 7개 API/옵션의 이름·의미가 v6에서 동일함을 published `.d.ts`로 확인하고 cooldown 동작을 히트 수로 실측): `createRemoteJWKSet(url, {cooldownDuration, cacheMaxAge})` → DoS-안전(kid 미해결 시에만 재조회). `jwtVerify(token, keys, {algorithms, issuer, audience, clockTolerance})` — `none` 내장 거부·aud 배열 포함검사.
- **@keycloak/keycloak-admin-client `26.6.4`**(ESM): `new KcAdminClient({baseUrl, realmName, timeout})`(timeout **ms** — `requestOptions`는 `Omit<RequestInit,"signal">`) → `.auth({grantType:'client_credentials', clientId, clientSecret})` → `.users/clients/realms/roles/groups`(create/find/findOne/update/del, roles는 findOneByName/delByName). 실패는 `NetworkError`(`.response.status`), `findOne`은 404에서 **`null`** 반환(선언 타입 `undefined`).

## Phase 1~9 — 계층별 구현 (Task 1~12)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. 게이트 G1(tsc)·G2(vitest)·G3(커버리지)·G4(스펙 대조) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 1 | `11e7aa4` | 스캐폴딩(ESM·tsconfig strict·eslint·vitest) | ✅ | ✅ | — |
| 2·3 | `1ee4439` | config·errors·tokens·masking | ✅ | ✅ | ✅ 100/100 |
| 4·5·6 | `5a20c93` | token-provider(single-flight)·oidc-metadata·JwtValidator | ✅ | ✅ 24 | ✅ 100/93 |
| 7 | `320705f` | AuthClient(openid-client v6) | ✅ | ✅ 38 | ✅(omit) |
| 8 | `9b68e29` | AdminClient + 리소스 5종 + 예외 경계변환 | ✅ | ✅ 55 | ✅(omit) |
| 9 | `1c3896b` | KeycloakClient + 공개 배럴 | ✅ | ✅ 65 | ✅ 100/94 |
| 10 | `91b8140` | Testcontainers E2E(실제 Keycloak 26.6) | ✅ | ✅ +5 | — |
| 11 | `84b8dbd` | node-ci(20/22) + node-release(npm provenance) | ✅ | — | — |
| 12 | (문서) | getting-started·README·CLAUDE·로드맵·CHANGELOG | — | — | — |

### Loop 1 (Task 10, G2 실패 → RCA → 조치 → 재측정)
- **증상**: E2E "삭제 후 조회 NotFound"가 예외 대신 `null` resolve.
- **RCA**: admin-client `findOne`이 404 + catchNotFound에서 `undefined`가 아니라 **`null`**을 반환(선언 타입은 `undefined`). `get()`의 `=== undefined` 검사가 `null`을 놓침.
- **조치**: `admin/call.ts`에 `requireFound`(null/undefined 통일 → `KeycloakNotFoundError`) 헬퍼 추가, 5개 리소스 `get`에 적용. 단위테스트도 실제 `null` 동작 반영.
- **재측정**: ✅ E2E 5개 전부 GREEN. (통합테스트가 목킹 단위테스트가 놓친 실환경 버그를 포착한 사례.)

## G5 — 다중에이전트 어드버서리얼 리뷰 (Task 12 직전)

4-차원(정확성·보안·동형성·테스트) 병렬 리뷰 + 각 findings에 대한 독립 어드버서리얼 검증(REFUTE 시도). **12건 제기 → 7건 CONFIRMED · 5건 REFUTED**. 확정 7건 전부 조치(커밋 `8bdb31b`):

| # | 심각도 | 결함 | 조치 |
|---|---|---|---|
| 1 | 🔴 HIGH | `exchangeCode`가 `expectedNonce` 미전달 → openid-client가 id_token nonce를 "unexpected"로 거부 → 기본 openid 스코프 인가코드 로그인 전면 실패 | `exchangeCode(…, nonce?)` 추가 → `expectedNonce`로 전달 + 테스트 |
| 2 | LOW | `client.admin()`·`AuthClient.#discover()` check-then-set 경합(동시 최초 호출 중복 인증/discovery) | single-flight(진행중 Promise 공유, 실패 미캐시) |
| 3 | MED | `TokenSet`이 OIDC `id_token` 유실·상대 `expiresIn`만 노출 | `idToken`·`expiresAt`(절대·epoch초)·`isExpired` 추가(Python 동형) |
| 4 | MED | `IntrospectionResult`가 `username`/`clientId` 대신 generic claims만 | `username`·`clientId` 추가(claims는 상위집합 유지) |
| 5 | MED | `defineConfig` 반환 config가 `clientSecret` 평문 노출 | `toJSON`/`util.inspect` 마스킹(속성 접근·스프레드 유지, Python `__repr__` 동형) |
| 6 | LOW | `ValidatedToken`이 `expiresAt`/`issuedAt` 미노출 | `exp`/`iat`을 첫급 필드로 추가(Java/Python 동형) |
| 7 | LOW | vitest `include`가 통합테스트까지 매칭 → `npm test`가 Docker 기동 시도 | 기본 설정 `test/unit`로 한정 + `vitest.integration.config.ts` 분리 |

**REFUTED 5건(반증 근거 기록)**: 예외 네이밍 차이(`KeycloakError` vs `KeycloakSdkError`)는 동작 결함 아님(Java `KeycloakTransportException`도 정의만·미인스턴스화) · 네이밍 이형 무해 · alg:none 테스트 미커버는 jose가 이중 방어라 실버그 없음 · DoS-safe JWKS 재조회 미테스트는 jose 위임이라 실버그 없음 · TokenSet refresh 마스킹 미테스트는 현행 렌더 경로가 이미 마스킹.

## 최종 상태 (G1~G6 종합)

- **G1**: ✅ `tsc`(strict, NodeNext, noUncheckedIndexedAccess, verbatimModuleSyntax) · `eslint` 통과.
- **G2**: ✅ 단위 **71** GREEN(config 5·masking 2·errors 3·tokens 6·oidc-metadata 1·token-provider 4·jwt 7·auth 15·admin 17·client 11).
- **G3**: ✅ 로직 모듈 라인 **100%**/브랜치 **94%**(게이트 90/85), 네트워크 경계 omit.
- **통합**: ✅ Testcontainers E2E **5** GREEN(실제 Keycloak 26.6 — client-credentials→validate 다중aud→introspect→user CRUD→삭제 후 NotFound→raw()).
- **G4**: ✅ §4 언어중립 계약·Java/Python 참조와 동형(계층·예외계급·값타입·보안불변식). 리뷰로 동형성 편차 4건 보강.
- **G5**: ✅ 4-차원 다중에이전트 어드버서리얼 리뷰(12제기→7확정 조치·5반증).
- **G6**: ✅ JWT 강화(alg 핀·`none` 거부·iss 정확일치·aud 포함검사·클록 스큐·DoS-안전 JWKS) · 완전 마스킹(토큰·시크릿·config) · TLS 기본 강제(http만 완화) · admin 타임아웃 주입(무한대기 차단).
- **배포**: 🔒 npm Trusted Publishing(OIDC + provenance) 준비, `node-v*` 태그 push 대기(human-gated, 미실행).
