# Node SDK — 이어서 하기 (Resume Handoff)

> 세션 중단 시점의 이어가기 안내. Node/TypeScript SDK 구현이 **진행 중**이며 핵심 계층까지 완료됐다.
> **브랜치**: `feature/node-sdk` · **WBS**: [../docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md](../docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md) · **spec**: [../docs/superpowers/specs/2026-07-04-keycloak-node-sdk-design.md](../docs/superpowers/specs/2026-07-04-keycloak-node-sdk-design.md)
> (SDK 완성·PR 병합 시 이 파일은 삭제한다.)

## 이어서 하는 법

```bash
git checkout feature/node-sdk && git pull
cd node && npm ci
npm run typecheck && npm run lint && npm run test:unit   # 현재 24 GREEN, 커버 100%/93%
```

## 완료 (Task 1~6 · 커밋됨)

| WBS | 커밋 | 내용 |
|---|---|---|
| 1 | `11e7aa4` | 스캐폴딩 — ESM·tsconfig(strict)·eslint·vitest |
| 2·3 | `1ee4439` | config(defineConfig)·errors(KeycloakError 계급·mapHttpError)·tokens(TokenSet 마스킹·ValidatedToken)·masking |
| 4·5·6 | `5a20c93` | token-provider(single-flight)·oidc-metadata·**JwtValidator 강화** |

- 단위테스트 **24 GREEN**, 전역 커버리지 **100% stmts / 93% branch**(게이트 90/85), tsc·eslint 통과.
- 보안 핵심 JwtValidator: alg 핀·`none` 거부·iss 정확일치·aud 포함검사(다중 aud)·클록스큐·DoS-safe JWKS — 적대적 케이스 검증 완료.

## 남음 (Task 7~12 · WBS 참조)

- **7 `src/auth.ts`** — openid-client v6 함수형 API 래핑(PKCE·client-credentials·exchangeCode·refresh·introspect·logout·validate). 네트워크 경계 → 커버리지 omit, 매핑 로직 단위검증.
- **8 `src/admin/`** — admin-client 래핑(index+users/clients/realms/roles/groups) + `raw()` + config 타임아웃 주입 + 예외 경계 변환(404→KeycloakNotFoundError).
- **9 `src/client.ts` + `src/index.ts`** — KeycloakClient(auth 즉시·admin 지연·`close()`/`[Symbol.asyncDispose]`) + 공개 배럴.
- **10 통합테스트** — `testcontainers`(설치됨 v11) + 실제 Keycloak 26.6(`quay.io/keycloak/keycloak:26.6` `start-dev --import-realm`), realm은 `java/keycloak-sdk/src/test/resources/it-realm-realm.json` 재사용. 시나리오: client-credentials→validate(다중 aud)→introspect→user CRUD→raw()→delete후 NotFound.
- **11 CI/release** — `.github/workflows/node-ci.yml`(matrix Node 20·22, paths `node/**`)·`node-release.yml`(`node-v*` 태그 → `npm publish --provenance`, OIDC, human-gated).
- **12 문서** — getting-started Node 섹션(4블록)·README·CLAUDE 구조/명령·로드맵 매트릭스 TS/Node ✅·CHANGELOG `(Node)`·verification-log(게이트·Loops·딥리서치).
- → **PR to main**(사람 승인).

## 딥리서치로 확정된 라이브러리 API (Task 1, 재확인 불필요)

- **openid-client `6.8.4`** (함수형): `discovery(new URL(issuerUrl), clientId, undefined, ClientSecretPost(secret))` → `Configuration`; `clientCredentialsGrant(config, { scope })`, `authorizationCodeGrant(config, currentUrl, { pkceCodeVerifier })`, `randomPKCECodeVerifier()`/`calculatePKCECodeChallenge()`/`buildAuthorizationUrl(config, params)`/`randomState()`/`randomNonce()`, `refreshTokenGrant()`, `tokenIntrospection()`, `buildEndSessionUrl()`. 토큰 응답 필드 snake_case.
- **jose `5.10.0`**: `createRemoteJWKSet(url, { cooldownDuration: 30000, cacheMaxAge: 600000 })` (DoS-safe); `jwtVerify(token, keys, { algorithms, issuer, audience, clockTolerance })` — `none` 내장 거부·aud 배열 포함검사. 테스트: `generateKeyPair('RS256')`·`SignJWT`·`createLocalJWKSet`.
- **@keycloak/keycloak-admin-client `26.6.4`**: `new KcAdminClient({ baseUrl, realmName, requestOptions: { signal: AbortSignal.timeout(ms) } })` → `.auth({ grantType: 'client_credentials', clientId, clientSecret })` → `.users`(create/find/findOne/update/del) · `.clients`(create/find/update/del) · `.realms`(create/findOne/update/del) · `.roles`(create/find/findOneByName/updateByName/delByName) · `.groups`(create/find/findOne/update/del).

## 주의

- devDeps audit: **3 moderate**(dockerode/testcontainers/uuid) — dev 전용, 런타임 deps(openid-client/jose/admin-client) clean, `files:["dist"]`라 소비자 미배포.
- 커버리지 게이트에서 `src/auth.ts`·`src/admin/**`·`src/index.ts` omit(네트워크 경계) — 통합테스트로 검증.
- 실행 방식: 승인된 WBS·Workflow·G1~G6·Loops·딥리서치. 각 태스크 TDD·계층별 커밋.
