# Keycloak Node(TypeScript) SDK — 구현 계획 (WBS)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(권장) 또는 superpowers:executing-plans로 태스크 단위 구현. 스텝은 `- [ ]` 체크박스. 사용자 승인 실행 방식: **WBS → Workflow 오케스트레이션 + AI 거버넌스(G1~G6) + Codex 이중검증 + Loops + 딥리서치**.

**Goal:** Java/Python과 §4 계약에 동형인 Keycloak Node.js SDK를 `node/`에 구현한다 — 인증(OIDC)·관리(Admin) 파사드 + 자체 강화 JWT 검증, ESM-only·Node 20+·async-only, npm 배포 준비.

**Architecture:** `openid-client`(auth)·`jose`(강화 JWT)·공식 `@keycloak/keycloak-admin-client`(admin)을 감싼 파사드. 계층 `config → errors/tokens → token-provider → oidc-metadata → jwt → auth → admin → client`. `admin`은 `auth`를 모르고 `TokenProvider`로만 결합. 하위 타입은 파사드 뒤 은닉, 예외는 경계에서 SDK 타입으로 변환.

**Tech Stack:** TypeScript(strict, NodeNext, ES2022) · Node 20+ · ESM · `openid-client` v6 · `jose` · `@keycloak/keycloak-admin-client` · vitest · testcontainers · tsc · eslint · prettier.

## Global Constraints

[스펙](../specs/2026-07-04-keycloak-node-sdk-design.md)에서 그대로 옮김. 모든 태스크에 암묵 적용.

- **배치**: 모노레포 `node/`(java/·python/과 나란히). 배포명 **`@xzawed/keycloak-sdk`** `0.1.0`.
- **런타임**: **ESM 전용**(`"type":"module"`) · **Node 20+** · **async-only**(공개 메서드 Promise; `createAuthorizationRequest`만 동기).
- **동형 계약**: [§4 언어중립계약](../specs/2026-07-02-keycloak-multilang-sdk-design.md) — 계층·예외계급·값타입·보안불변식·테스트 시나리오를 Java/Python과 일치. 참조 구현: `java/keycloak-sdk-*/src/main/java/...`, `python/src/keycloak_sdk/...`.
- **네이밍**: camelCase. 값타입 `TokenSet`/`ValidatedToken`/`IntrospectionResult`. 예외 `KeycloakError` 계급.
- **보안 불변식**: 토큰/시크릿 **완전 마스킹**(접두 노출 없음) · TLS 검증 기본 on · JWT 강화(허용 alg 핀·`none` 거부·`iss` 정확일치·`aud` 포함검사·클록스큐 기본 30s·**JWKS 재조회 DoS-safe**) · admin 타임아웃 주입.
- **결합 규칙**: `admin`은 `auth` 비의존 — `TokenProvider`가 유일 접착제. `raw()` 탈출구.
- **테스트**: 단위(vitest, 네트워크 격리) + 통합(testcontainers, 실제 Keycloak 26.6, `java/keycloak-sdk/src/test/resources/it-realm-realm.json` 재사용). 커버리지 게이트(로직 모듈 라인≥90/브랜치≥85, 네트워크 경계 omit).
- **툴체인 실행(하네스)**: Node는 시스템 설치 사용. 명령은 `node/`에서 실행: `cd node && npm ci|test|run build`.
- **커밋**: `git add -A && git commit`. 작업 브랜치 `feature/node-sdk`(실행 시 결정), PR로 main(사람 승인).
- **거버넌스**: 태스크마다 G1(빌드/타입)·G2(단위)·G3(커버리지)·G4(스펙리뷰)·G5(Codex)·G6(보안) 통과 후 커밋. 실패 시 Loops(RCA→조치→재측정). verification-log 기록.
- **⚠️ 착수 전(Task 1) 딥리서치 재검증**: `openid-client` v6 함수형 API·`jose` 옵션·`@keycloak/keycloak-admin-client` API·라이선스·최신 버전을 공식문서(context7/web)로 확인해 아래 코드의 정확한 호출 시그니처를 확정한다.

## File Structure

- `node/package.json` — ESM, deps, scripts, exports. `node/tsconfig.json`·`eslint.config.js`·`vitest.config.ts`·`.gitignore`(node_modules/dist).
- `node/src/config.ts` — `KeycloakConfig` + `defineConfig`(검증).
- `node/src/errors.ts` — `KeycloakError` 계급 + HTTP상태→예외 매핑.
- `node/src/tokens.ts` — `TokenSet`/`ValidatedToken`/`IntrospectionResult` + 마스킹.
- `node/src/masking.ts` — `mask()` 유틸.
- `node/src/token-provider.ts` — `TokenProvider` + `ClientCredentialsTokenProvider`.
- `node/src/oidc-metadata.ts` — 엔드포인트 조립(네트워크 없음).
- `node/src/jwt.ts` — `JwtValidator`(jose 강화). **보안 핵심**.
- `node/src/auth.ts` — `AuthClient`(openid-client 래핑).
- `node/src/admin/index.ts` + `users.ts`/`clients.ts`/`realms.ts`/`roles.ts`/`groups.ts` — `AdminClient` + `raw()`.
- `node/src/client.ts` — `KeycloakClient` 진입점.
- `node/src/index.ts` — 공개 배럴.
- `node/test/unit/*.test.ts` · `node/test/integration/*.it.test.ts`.
- `.github/workflows/node-ci.yml`·`node-release.yml`.

## 태스크 순서/의존

1 스캐폴딩 → 2 config → 3 errors+tokens+masking → 4 token-provider → 5 oidc-metadata → 6 jwt → 7 auth → 8 admin → 9 client+index → 10 통합테스트 → 11 CI/release → 12 문서. (2~6 상호 독립성 높아 병렬 가능; 7·8은 6·4 의존; 9는 7·8 의존.)

---

### Task 1: 스캐폴딩 (node/ 패키지)

**Files:** Create `node/package.json`, `node/tsconfig.json`, `node/eslint.config.js`, `node/vitest.config.ts`, `node/.gitignore`, `node/src/index.ts`(빈 배럴)

**Interfaces:** Produces: 빌드/테스트/린트 파이프라인. Consumes: 없음.

- [ ] **Step 1: 딥리서치 재검증** — context7/web으로 `openid-client`(최신 메이저·함수형 API 존재), `jose`, `@keycloak/keycloak-admin-client`(Keycloak 26 호환 태그), `testcontainers`, `vitest`의 현행 버전·API·라이선스 확인. 확정 버전을 아래에 반영.
- [ ] **Step 2: `node/package.json` 작성**
```json
{
  "name": "@xzawed/keycloak-sdk",
  "version": "0.1.0",
  "type": "module",
  "engines": { "node": ">=20" },
  "exports": { ".": { "types": "./dist/index.d.ts", "import": "./dist/index.js" } },
  "types": "./dist/index.d.ts",
  "files": ["dist"],
  "sideEffects": false,
  "publishConfig": { "access": "public", "provenance": true },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint": "eslint src test",
    "format:check": "prettier --check src test",
    "test": "vitest run --coverage",
    "test:unit": "vitest run --coverage test/unit",
    "test:it": "vitest run test/integration"
  },
  "dependencies": {
    "openid-client": "^6",
    "jose": "^5",
    "@keycloak/keycloak-admin-client": "^26"
  },
  "devDependencies": {
    "typescript": "^5", "vitest": "^2", "@vitest/coverage-v8": "^2",
    "testcontainers": "^10", "eslint": "^9", "prettier": "^3",
    "@types/node": "^20"
  }
}
```
> 정확한 버전은 Step 1 딥리서치로 확정(major 핀 유지).
- [ ] **Step 3: `tsconfig.json`**
```json
{
  "compilerOptions": {
    "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext",
    "strict": true, "declaration": true, "outDir": "dist", "rootDir": "src",
    "verbatimModuleSyntax": true, "skipLibCheck": true, "exactOptionalPropertyTypes": true
  },
  "include": ["src"]
}
```
- [ ] **Step 4: eslint.config.js(flat, 보안 룰 포함)·vitest.config.ts(coverage thresholds 90/85, exclude auth.ts/admin/**)·.gitignore(node_modules,dist,coverage)·src/index.ts(빈 `export {}`) 작성**
- [ ] **Step 5: 검증** — `cd node && npm install && npm run typecheck && npm run lint`
  Expected: 설치 성공, 타입/린트 통과(빈 소스).
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat(node): 스캐폴딩 — ESM 패키지·tsconfig·eslint·vitest (WBS 1)"`

---

### Task 2: config.ts (KeycloakConfig)

**Files:** Create `node/src/config.ts`, `node/test/unit/config.test.ts`
**Interfaces:** Produces: `interface KeycloakConfig`, `function defineConfig(input): KeycloakConfig`. Consumes: `KeycloakConfigError`(Task 3 — 임시로 config.ts 내 로컬 정의 후 Task 3에서 이관, 또는 Task 3 먼저). 참조: `java/keycloak-sdk-core/.../KeycloakConfig.java`, `python/src/keycloak_sdk/config.py`.

- [ ] **Step 1: 실패 테스트**
```ts
import { describe, it, expect } from 'vitest'
import { defineConfig } from '../../src/config.js'
describe('defineConfig', () => {
  it('필수값 누락 시 KeycloakConfigError', () => {
    expect(() => defineConfig({ serverUrl: '', realm: 'r', clientId: 'c' }))
      .toThrowError(/serverUrl/)
  })
  it('기본값 채움', () => {
    const c = defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: 'c' })
    expect(c.clockSkewSeconds).toBe(30)
    expect(c.connectTimeoutMs).toBe(10000)
    expect(c.scopes).toEqual([])
  })
})
```
- [ ] **Step 2: 실패 확인** — `cd node && npx vitest run test/unit/config.test.ts` → FAIL(모듈 없음)
- [ ] **Step 3: 구현**
```ts
export interface KeycloakConfig {
  readonly serverUrl: string; readonly realm: string; readonly clientId: string
  readonly clientSecret?: string; readonly scopes: readonly string[]
  readonly connectTimeoutMs: number; readonly readTimeoutMs: number; readonly clockSkewSeconds: number
}
export interface KeycloakConfigInput {
  serverUrl: string; realm: string; clientId: string; clientSecret?: string
  scopes?: string[]; connectTimeoutMs?: number; readTimeoutMs?: number; clockSkewSeconds?: number
}
export function defineConfig(input: KeycloakConfigInput): KeycloakConfig {
  for (const k of ['serverUrl', 'realm', 'clientId'] as const)
    if (!input[k]?.trim()) throw new KeycloakConfigError(`Missing required config: ${k}`)
  return {
    serverUrl: input.serverUrl.replace(/\/+$/, ''), realm: input.realm, clientId: input.clientId,
    clientSecret: input.clientSecret, scopes: input.scopes ?? [],
    connectTimeoutMs: input.connectTimeoutMs ?? 10000, readTimeoutMs: input.readTimeoutMs ?? 30000,
    clockSkewSeconds: input.clockSkewSeconds ?? 30,
  }
}
```
(Task 3 완료 전이면 `KeycloakConfigError`를 Task 3에서 import; 순서상 Task 3을 먼저 하거나 최소 stub.)
- [ ] **Step 4: 통과 확인** — 동일 명령 → PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(node): KeycloakConfig + defineConfig 검증 (WBS 2)"`

---

### Task 3: errors.ts + tokens.ts + masking.ts (핵심 타입)

**Files:** Create `node/src/masking.ts`,`errors.ts`,`tokens.ts` + `test/unit/{masking,errors,tokens}.test.ts`
**Interfaces:** Produces: `mask(v?:string):string`; `KeycloakError` 및 하위, `mapHttpError(status:number,msg:string):KeycloakError`; `TokenSet`,`ValidatedToken`,`IntrospectionResult`, `tokenSetFromResponse(json):TokenSet`. 참조: Java `Secrets`/예외계층/`TokenSet`·`ValidatedToken`, Python `_internal/secrets.py`·`exceptions.py`·`tokens.py`.

- [ ] **Step 1: 실패 테스트 (masking·errors·tokens)**
```ts
// masking.test.ts
import { mask } from '../../src/masking.js'
expect(mask('supersecret')).toBe('***')     // 완전 불투명, 접두 노출 없음
expect(mask(undefined)).toBe('***')
// errors.test.ts
import { mapHttpError, KeycloakNotFoundError } from '../../src/errors.js'
expect(mapHttpError(404, 'x')).toBeInstanceOf(KeycloakNotFoundError)
// tokens.test.ts
import { tokenSetFromResponse } from '../../src/tokens.js'
const t = tokenSetFromResponse({ access_token: 'a', token_type: 'Bearer', expires_in: 300 })
expect(t.accessToken).toBe('a'); expect(String(t)).not.toContain('a')  // toString 마스킹
```
- [ ] **Step 2: 실패 확인** → FAIL
- [ ] **Step 3: 구현**
```ts
// masking.ts
export function mask(_v?: string): string { return '***' }  // 접두 노출 없는 완전 불투명
// errors.ts
export class KeycloakError extends Error {}
export class KeycloakConfigError extends KeycloakError {}
export class KeycloakAuthError extends KeycloakError {}
export class KeycloakTokenValidationError extends KeycloakError {}
export class KeycloakAdminError extends KeycloakError {}
export class KeycloakNotFoundError extends KeycloakAdminError {}
export class KeycloakConflictError extends KeycloakAdminError {}
export class KeycloakForbiddenError extends KeycloakAdminError {}
export class KeycloakTransportError extends KeycloakError {}
export function mapHttpError(status: number, msg: string): KeycloakError {
  if (status === 404) return new KeycloakNotFoundError(msg)
  if (status === 409) return new KeycloakConflictError(msg)
  if (status === 403) return new KeycloakForbiddenError(msg)
  return new KeycloakAdminError(`HTTP ${status}: ${msg}`)
}
// tokens.ts
import { mask } from './masking.js'
export class TokenSet {
  constructor(readonly accessToken: string, readonly tokenType: string,
              readonly expiresIn: number, readonly refreshToken?: string, readonly scope?: string) {}
  toString() { return `TokenSet(tokenType=${this.tokenType}, accessToken=${mask(this.accessToken)})` }
  toJSON() { return { tokenType: this.tokenType, accessToken: mask(this.accessToken), expiresIn: this.expiresIn } }
}
export function tokenSetFromResponse(j: Record<string, unknown>): TokenSet {
  return new TokenSet(String(j.access_token), String(j.token_type ?? 'Bearer'),
    Number(j.expires_in ?? 0), j.refresh_token as string | undefined, j.scope as string | undefined)
}
export interface ValidatedToken { subject: string; audience: string[]; issuer: string; claims: Record<string, unknown> }
export interface IntrospectionResult { active: boolean; claims: Record<string, unknown> }
```
- [ ] **Step 4: 통과 확인** → PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(node): masking·예외계급·값타입(TokenSet/ValidatedToken) (WBS 3)"`

---

### Task 4: token-provider.ts

**Files:** Create `node/src/token-provider.ts`, `test/unit/token-provider.test.ts`
**Interfaces:** Produces: `interface TokenProvider { getAccessToken(): Promise<string> }`, `class ClientCredentialsTokenProvider implements TokenProvider`(생성자: `(config, authClientLike)`), single-flight 캐시+만료 갱신. Consumes: `KeycloakConfig`(T2), `AuthClient.clientCredentialsToken`(T7 — 인터페이스만 의존: `{ clientCredentialsToken(): Promise<TokenSet> }`). 참조: Java `ClientCredentialsTokenProvider`, Python 대응.

- [ ] **Step 1~5**: 실패테스트(만료 전 캐시 재사용·동시호출 single-flight·만료 시 재발급) → 구현(내부 `TokenSet`+`expiresAt`, 진행중 Promise 공유) → 통과 → 커밋 `feat(node): TokenProvider + client-credentials 기본구현(single-flight) (WBS 4)`.
  구현 핵심:
```ts
export interface TokenProvider { getAccessToken(): Promise<string> }
export class ClientCredentialsTokenProvider implements TokenProvider {
  #cached?: { token: string; expiresAt: number }; #inflight?: Promise<string>
  constructor(private readonly src: { clientCredentialsToken(): Promise<import('./tokens.js').TokenSet> },
              private readonly skewSeconds = 30) {}
  async getAccessToken(): Promise<string> {
    const now = Date.now()
    if (this.#cached && now < this.#cached.expiresAt) return this.#cached.token
    if (this.#inflight) return this.#inflight
    this.#inflight = (async () => {
      const ts = await this.src.clientCredentialsToken()
      this.#cached = { token: ts.accessToken, expiresAt: Date.now() + (ts.expiresIn - this.skewSeconds) * 1000 }
      this.#inflight = undefined; return ts.accessToken
    })().catch((e) => { this.#inflight = undefined; throw e })
    return this.#inflight
  }
}
```

---

### Task 5: oidc-metadata.ts

**Files:** Create `node/src/oidc-metadata.ts`, `test/unit/oidc-metadata.test.ts`
**Interfaces:** Produces: `function oidcEndpoints(config): { issuer; token; authorization; introspection; endSession; jwks }`(네트워크 없이 `{serverUrl}/realms/{realm}` 규약 조립). 참조: Java `OidcMetadata.forRealm`.
- [ ] 실패테스트(issuer===`${serverUrl}/realms/${realm}`, jwks===`${issuer}/protocol/openid-connect/certs`) → 구현(문자열 조립) → 통과 → 커밋 `feat(node): OIDC 엔드포인트 조립 (WBS 5)`.

---

### Task 6: jwt.ts (JwtValidator — 🔴 보안 핵심)

**Files:** Create `node/src/jwt.ts`, `test/unit/jwt.test.ts`
**Interfaces:** Produces: `class JwtValidator { constructor(opts:{ jwksUri:string; issuer:string; audience:string; allowedAlgs:string[]; clockSkewSeconds:number }); validate(token:string): Promise<ValidatedToken> }`. Consumes: `jose`, `ValidatedToken`(T3). 참조: Java `JwtValidator`(핀·iss·aud포함·클록스큐·DoS-safe JWKS), Python `jwt.py`.

- [ ] **Step 1: 실패 테스트** — jose로 테스트 키쌍 생성해 서명 토큰 발급 후:
```ts
// 정상 RS256 토큰 통과 + subject/aud 반환; alg=none 거부; 잘못된 iss 거부;
// aud가 배열 ["client","realm-management"]이고 기대 aud "client" 포함 → 통과(포함검사);
// 기대 aud 미포함 → KeycloakTokenValidationError; exp 초과(+skew 밖) → 거부.
```
(테스트는 `jose`의 `generateKeyPair('RS256')`·`SignJWT`로 로컬 발급, JWKS는 `createLocalJWKSet` 또는 목 서버로 주입.)
- [ ] **Step 2: 실패 확인** → FAIL
- [ ] **Step 3: 구현**
```ts
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose'
import { KeycloakTokenValidationError } from './errors.js'
import type { ValidatedToken } from './tokens.js'
export class JwtValidator {
  #jwks: ReturnType<typeof createRemoteJWKSet>
  constructor(private readonly opts: {
    jwksUri: string; issuer: string; audience: string; allowedAlgs: string[]; clockSkewSeconds: number
  }) {
    // createRemoteJWKSet: 내부 캐시 + 쿨다운(cooldownDuration)로 kid 미해결 시에만 재조회 rate-limit → DoS-safe.
    this.#jwks = createRemoteJWKSet(new URL(opts.jwksUri), { cooldownDuration: 30_000, cacheMaxAge: 600_000 })
  }
  async validate(token: string): Promise<ValidatedToken> {
    try {
      const { payload } = await jwtVerify(token, this.#jwks, {
        algorithms: this.opts.allowedAlgs,          // alg 핀(헤더 alg 불신), none 거부
        issuer: this.opts.issuer,                    // iss 정확일치
        audience: this.opts.audience,                // aud 포함검사(배열이면 포함 여부)
        clockTolerance: this.opts.clockSkewSeconds,  // exp/nbf ± skew
      })
      const aud = payload.aud
      return {
        subject: String(payload.sub ?? ''),
        audience: Array.isArray(aud) ? aud.map(String) : aud ? [String(aud)] : [],
        issuer: String(payload.iss ?? ''),
        claims: payload as Record<string, unknown>,
      }
    } catch (e) {
      throw new KeycloakTokenValidationError(`JWT 검증 실패: ${(e as Error).message}`)
    }
  }
}
```
> DoS-safe: `jose`의 `createRemoteJWKSet`은 kid 미해결 시에만 원격 재조회하고 `cooldownDuration`으로 rate-limit한다 — 서명 위조는 캐시된 키로 즉시 실패(재조회 유발 안 함). 이 동작을 단위테스트로 고정.
- [ ] **Step 4: 통과 확인** → PASS (모든 강화 케이스)
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(node): JwtValidator — jose 자체 강화(alg핀·iss·aud포함·클록스큐·DoS-safe JWKS) (WBS 6)"`

---

### Task 7: auth.ts (AuthClient — openid-client 래핑)

**Files:** Create `node/src/auth.ts`, `test/unit/auth.test.ts`
**Interfaces:** Produces: `class AuthClient { createAuthorizationRequest(opts?): { url:string; codeVerifier:string; state:string; nonce:string }; exchangeCode(code,verifier,state): Promise<TokenSet>; clientCredentialsToken(): Promise<TokenSet>; refresh(rt): Promise<TokenSet>; introspect(token): Promise<IntrospectionResult>; logout(rt): Promise<void>; validate(at): Promise<ValidatedToken> }`. Consumes: `openid-client`, `oidcEndpoints`(T5), `JwtValidator`(T6), `tokenSetFromResponse`(T3), `KeycloakAuthError`(T3). 참조: Java `AuthClient`, Python `auth.py`.

- [ ] **Step 1~5**: 단위테스트는 openid-client 함수를 목킹(네트워크 격리)해 매핑·PKCE·예외변환 검증 → 구현 → 통과 → 커밋.
  구현 핵심(openid-client v6 **함수형 API** — Step 1 딥리서치로 정확한 심볼 확정):
```ts
import * as oidc from 'openid-client'
import { oidcEndpoints } from './oidc-metadata.js'
import { tokenSetFromResponse, type TokenSet, type IntrospectionResult, type ValidatedToken } from './tokens.js'
import { JwtValidator } from './jwt.js'
import { KeycloakAuthError } from './errors.js'
import type { KeycloakConfig } from './config.js'
export class AuthClient {
  #config!: oidc.Configuration          // discovery 결과(지연 초기화)
  #validator: JwtValidator
  constructor(private readonly cfg: KeycloakConfig) {
    const ep = oidcEndpoints(cfg)
    this.#validator = new JwtValidator({
      jwksUri: ep.jwks, issuer: ep.issuer, audience: cfg.clientId,
      allowedAlgs: ['RS256'], clockSkewSeconds: cfg.clockSkewSeconds,
    })
  }
  async #cfgAsync(): Promise<oidc.Configuration> {
    this.#config ??= await oidc.discovery(new URL(`${this.cfg.serverUrl}/realms/${this.cfg.realm}`),
      this.cfg.clientId, this.cfg.clientSecret)
    return this.#config
  }
  createAuthorizationRequest(): { url: string; codeVerifier: string; state: string; nonce: string } {
    const codeVerifier = oidc.randomPKCECodeVerifier()
    // ... buildAuthorizationUrl(config, { code_challenge, code_challenge_method:'S256', state, nonce, scope })
    // (정확한 함수형 API는 딥리서치로 확정)
    return { url: '', codeVerifier, state: '', nonce: '' }
  }
  async clientCredentialsToken(): Promise<TokenSet> {
    try { const r = await oidc.clientCredentialsGrant(await this.#cfgAsync()); return tokenSetFromResponse(r as any) }
    catch (e) { throw new KeycloakAuthError((e as Error).message) }
  }
  async validate(accessToken: string): Promise<ValidatedToken> { return this.#validator.validate(accessToken) }
  // exchangeCode/refresh/introspect/logout — 동일 패턴(openid-client 대응 함수 + 예외 변환). 시그니처는 Interfaces 참조.
}
```
> ⚠️ openid-client v6의 정확한 함수명/시그니처는 **Task 1 딥리서치로 확정**하고 위 골격을 채운다. auth.ts는 네트워크 경계 → 커버리지 omit, 로직은 매핑 헬퍼로 분리해 단위검증, 실호출은 통합테스트(Task 10).
- [ ] **Commit**: `feat(node): AuthClient — PKCE/client-credentials/refresh/introspect/logout/validate (WBS 7)`

---

### Task 8: admin/ (AdminClient + 리소스 + raw())

**Files:** Create `node/src/admin/index.ts`,`users.ts`,`clients.ts`,`realms.ts`,`roles.ts`,`groups.ts` + `test/unit/admin.test.ts`
**Interfaces:** Produces: `class AdminClient { users: UsersResource; clients; realms; roles; groups; raw(): KcAdminClient; close(): Promise<void> }`. 각 리소스 메서드는 Java 대응과 동형(예: `UsersResource.create(rep): Promise<string>`, `get(id)`, `search(username?,first?,max?)`, `update(id,rep)`, `delete(id)`). Consumes: `@keycloak/keycloak-admin-client`, `KeycloakConfig`(T2), `mapHttpError`(T3). 참조: Java `AdminClient`+resources, Python `admin/`.

- [ ] **Step 1~5**: 단위테스트는 `@keycloak/keycloak-admin-client`를 목킹해 (a)타임아웃 주입, (b)예외 경계 변환(404→KeycloakNotFoundError), (c)리소스 위임을 검증 → 구현 → 통과 → 커밋.
  구현 핵심:
```ts
// admin/index.ts
import KcAdminClient from '@keycloak/keycloak-admin-client'
import type { KeycloakConfig } from '../config.js'
import { UsersResource } from './users.js'  // clients/realms/roles/groups 동형
import { mapHttpError } from '../errors.js'
export async function call<T>(fn: () => Promise<T>): Promise<T> {
  try { return await fn() } catch (e: any) {
    const status = e?.response?.status ?? e?.responseData?.status
    throw typeof status === 'number' ? mapHttpError(status, e?.message ?? '') : e
  }
}
export class AdminClient {
  #kc: KcAdminClient; readonly users: UsersResource /* ... */
  private constructor(kc: KcAdminClient, private readonly cfg: KeycloakConfig) {
    this.#kc = kc; this.users = new UsersResource(kc, cfg.realm) /* ...4 more */
  }
  static async create(cfg: KeycloakConfig): Promise<AdminClient> {
    // baseUrl/realm + config 타임아웃 주입(requestOptions/fetch signal) — 무한대기 방지
    const kc = new KcAdminClient({ baseUrl: cfg.serverUrl, realmName: cfg.realm,
      requestOptions: { signal: AbortSignal.timeout(cfg.readTimeoutMs) } })
    await kc.auth({ grantType: 'client_credentials', clientId: cfg.clientId, clientSecret: cfg.clientSecret! })
    return new AdminClient(kc, cfg)
  }
  raw(): KcAdminClient { return this.#kc }
  async close(): Promise<void> { /* admin-client 자원 정리(있으면) */ }
}
// admin/users.ts
export class UsersResource {
  constructor(private readonly kc: KcAdminClient, private readonly realm: string) {}
  async create(rep: Record<string, unknown>): Promise<string> {
    const r = await call(() => this.kc.users.create({ realm: this.realm, ...rep } as any)); return r.id
  }
  async search(username?: string, first = 0, max = 100): Promise<Record<string, unknown>[]> {
    return call(() => this.kc.users.find({ realm: this.realm, username, first, max } as any))
  }
  // get/update/delete — Java UsersResource와 동형
}
```
> clients/realms/roles/groups는 users.ts 패턴 + 각자의 Java 리소스 메서드(예: `RolesResource`, `GroupsResource`)를 동형 포팅. 각 파일은 단일 리소스 책임.
- [ ] **Commit**: `feat(node): AdminClient + users/clients/realms/roles/groups + raw() + 타임아웃·예외변환 (WBS 8)`

---

### Task 9: client.ts + index.ts (통합 진입점 + 배럴)

**Files:** Create `node/src/client.ts`; Modify `node/src/index.ts`; `test/unit/client.test.ts`
**Interfaces:** Produces: `class KeycloakClient { static create(input: KeycloakConfigInput): KeycloakClient; readonly auth: AuthClient; admin(): Promise<AdminClient>; close(): Promise<void>; [Symbol.asyncDispose](): Promise<void> }`. index.ts는 공개 심볼 배럴. Consumes: T2·T7·T8. 참조: Java `KeycloakClient`, Python `client.py`.

- [ ] **Step 1~5**: 테스트(auth 즉시·admin 지연 생성·clientSecret 없으면 admin() 에러·close가 admin+auth 정리) → 구현(admin 지연 캐시, `asyncDispose`) → 통과 → 커밋.
```ts
export class KeycloakClient {
  #admin?: AdminClient
  private constructor(readonly auth: AuthClient, private readonly cfg: KeycloakConfig) {}
  static create(input: KeycloakConfigInput): KeycloakClient {
    const cfg = defineConfig(input); return new KeycloakClient(new AuthClient(cfg), cfg)
  }
  async admin(): Promise<AdminClient> {
    if (!this.cfg.clientSecret) throw new KeycloakConfigError('admin requires clientSecret')
    return (this.#admin ??= await AdminClient.create(this.cfg))
  }
  async close(): Promise<void> { await this.#admin?.close() /* + auth 세션 정리 */ }
  async [Symbol.asyncDispose](): Promise<void> { await this.close() }
}
```
index.ts: `export { KeycloakClient } from './client.js'; export * from './config.js'; export * from './errors.js'; export * from './tokens.js'; export type { TokenProvider } from './token-provider.js'`
- [ ] **Commit**: `feat(node): KeycloakClient 통합 진입점 + 공개 배럴 (WBS 9)`

---

### Task 10: 통합 테스트 (testcontainers + 실제 Keycloak)

**Files:** Create `node/test/integration/e2e.it.test.ts`, `node/test/integration/support.ts`
**Interfaces:** Consumes: 전 계층. 참조: Java `AuthFlowIT`/`AdminOpsIT`/`SmokeIT`, `it-realm-realm.json`.
- [ ] **Step 1: 하네스** — `testcontainers`로 `quay.io/keycloak/keycloak:26.6` 기동(`start-dev --import-realm`), `java/keycloak-sdk/src/test/resources/it-realm-realm.json` 복사/마운트로 realm 프로비저닝.
- [ ] **Step 2: E2E 테스트(Java/Python 동일 시나리오)** — client-credentials 토큰 발급 → `validate`(다중 aud 수용) → `introspect` → user 생성/조회/삭제 → 삭제 후 조회 `KeycloakNotFoundError` → `raw()` 접근.
- [ ] **Step 3: 실행** — `cd node && npm run test:it`(Docker 필요) → 전부 GREEN.
- [ ] **Step 4: Commit** — `test(node): Testcontainers E2E(client-credentials·validate·introspect·admin CRUD·raw) (WBS 10)`

---

### Task 11: CI + release 워크플로

**Files:** Create `.github/workflows/node-ci.yml`, `.github/workflows/node-release.yml`
- [ ] **Step 1: `node-ci.yml`** — `on: {push,pull_request}: paths: ['node/**','.github/workflows/node-ci.yml']`. job `build`(matrix Node 20,22): `cd node && npm ci && npm run lint && npm run typecheck && npm run test:unit`. job `integration`(ubuntu, Docker): `npm ci && npm run test:it`.
- [ ] **Step 2: `node-release.yml`** — `on: push: tags: ['node-v*']`. `actions/setup-node`(registry-url, `id-token: write`) → `cd node && npm ci && npm run build && npm publish --provenance --access public`(OIDC Trusted Publishing, 저장 토큰 없음, human-gated).
- [ ] **Step 3: 검증** — YAML 파싱·`npm pack` dry-run(로컬 산출물 확인). **Commit** `ci(node): node-ci(20/22) + node-release(npm provenance, human-gated) (WBS 11)`.

---

### Task 12: 문서 · 거버넌스 로그

**Files:** Modify `docs/guides/getting-started.md`(Node 섹션 4블록), `README.md`, `CLAUDE.md`(구조·명령), `docs/roadmap/language-support.md`(매트릭스 TS/Node ✅ 갱신), `CHANGELOG.md`(`(Node)` Added), `docs/governance/verification-log.md`(게이트·Loops 이력)
- [ ] **Step 1**: getting-started에 Node 4블록(요구 런타임 Node 20+·로컬 설치 `cd node && npm i && npm run build`(미배포)·배포후 `npm i @xzawed/keycloak-sdk`·최소 예제 실제 API). 
- [ ] **Step 2**: 로드맵 현황 매트릭스 TS/Node 행을 ✅(설계·구현·단위·통합·CI) + 🔒 배포(human-gated)로. README/CLAUDE 구조 트리·테스트 수 갱신. CHANGELOG `(Node) keycloak-sdk 3번째 언어 추가`.
- [ ] **Step 3**: verification-log에 Node SDK 게이트 통과·Loops·딥리서치 근거 기록. 링크·일관성 스윕.
- [ ] **Step 4: Commit** — `docs(node): getting-started Node 섹션 + 로드맵·README·CLAUDE·CHANGELOG·verification-log (WBS 12)`

---

## Self-Review (계획 ↔ 스펙 대조)

- **스펙 커버리지**: §3 의존성→T1(딥리서치)·T6·T7·T8 · §4 구조→T1~T9 · §5 계층/예외/TokenProvider→T2~T9 · §6 보안불변식→T3(마스킹)·T6(JWT)·T8(타임아웃)·T11(CI가드는 T10/T6 테스트로) · §7 테스트→T3~T9 단위+T10 통합 · §8 빌드/CI/배포→T1·T11 · §9 문서→T12. 누락 없음.
- **플레이스홀더**: openid-client v6·admin-client 정확한 API 호출은 **Task 1 딥리서치로 확정** 후 골격을 채우도록 명시(라이브러리 래핑 SDK의 불가피한 부분 — 참조 구현 Java/Python + 공식문서로 검증). 그 외 스텝은 구체 코드·명령·기대값 명시.
- **타입/명칭 일관**: `KeycloakConfig`/`defineConfig`·`TokenSet`/`ValidatedToken`/`IntrospectionResult`·`Keycloak*Error`·`TokenProvider`·`AuthClient`/`AdminClient`/`KeycloakClient`·`raw()`가 전 태스크·스펙·Global Constraints와 일치.
