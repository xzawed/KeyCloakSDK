---
paths:
  - "node/**"
  - "harness/apps/node/**"
  - "harness/install/consume/node*"
  - ".github/workflows/node-*.yml"
---

# Node 규칙

## 툴체인 (빌드 명령)

Node는 시스템 설치(현재 v22)를 사용한다 — `package.json`의 `engines`는 `>=22`다(문서에서 "20+"라고 쓰지 말 것). 명령은 `node/`에서 실행한다:
```bash
cd node && npm ci                    # 의존성 설치(package-lock.json 기준)
cd node && npm test                  # 단위테스트 92개 + 커버리지 게이트(라인 90/브랜치 85). Docker 불필요
cd node && npm run test:unit         # 동일(단위만 명시)
cd node && npm run test:it           # 통합테스트 5개(Docker 필요 — vitest.integration.config.ts, 실제 Keycloak 26.6)
cd node && npm run typecheck         # tsc --noEmit (strict)
cd node && npm run lint              # eslint (typescript-eslint recommended)
cd node && npm run build             # tsc → dist/ (배포 산출물)
```
- 단일 테스트 파일: `cd node && npx vitest run test/unit/<name>.test.ts`
- 로컬 배포 빌드 검증(업로드 없이): `cd node && npm run build && npm pack --dry-run` → `dist/**` + `package.json` + `LICENSE` + `README.md` 포함 확인. ⚠️ `files:["dist"]`여도 npm은 `package.json`·`README`·`LICENSE`를 **항상** 담는다 — 두 파일이 `node/`에 없으면 npmjs.com 랜딩 페이지가 빈 채로 게시된다(그래서 `node/LICENSE`·`node/README.md`를 두고, README 링크는 전부 절대 URL로 쓴다 — npm 페이지에서 저장소 상대 링크는 깨진다). 레지스트리 메타데이터(`repository`+`directory`·`homepage`·`bugs`·`keywords`)도 `package.json`에 유지한다
- 실제 npm 배포는 로컬에서 실행하지 않는다 — `node-v*` 태그 push 시 `.github/workflows/node-release.yml`에서 npm Trusted Publishing(OIDC + provenance, 저장 토큰 없음)로 실행(사람 승인 게이트). 체크아웃 직후 태그↔`node/package.json` `version` 정합성 가드가 돌고(추출 실패도 실패로 취급), 발행 전 게이트로 통합 E2E 잡이 `needs:`에 들어간다
- 패키지 `@xzawed/keycloak-sdk`는 ESM 전용(`"type":"module"`)이며 `.d.ts` 타입 선언을 포함 — 소비자 측 TypeScript 타입 검사 가능
- ⚠️ 커버리지 게이트에서 `src/auth.ts`·`src/admin/**`·`src/index.ts` omit(네트워크 경계) — 통합테스트로 검증. 나머지 로직 모듈은 라인 100%/브랜치 94% 실측

## 게차

- ⚠️ **(Node) `jose`/`openid-client`의 `^6`을 `~`로 좁히지 말 것 — 다만 이유는 "트리 중복"이 아니다(그 근거는 한 번 틀리게 적혔다).** "0.1.0 라이브러리가 검증하지 않은 마이너를 소비자가 해석하게 두는 건 위험하니 `~`로 좁히자"는 제안이 릴리스 감사에서 나왔다. 결론은 기각이 맞지만, 처음 적었던 근거 — "`~6.2`면 jose 6.3.0이 나오는 순간 두 벌이 설치된다" — 는 **npm의 동작이 아니다**. `npm install --package-lock-only`로 재현: 루트가 `jose@6.2.2`(openid-client의 `^6.2.2`를 만족)면 `node_modules/jose` **1개**, 루트가 `jose@6.1.3`(하한 미달)이면 `node_modules/jose`+`node_modules/openid-client/node_modules/jose` **2개**. npm은 호이스트된 루트 버전이 의존자의 범위를 만족하면 재사용하고, 단지 더 새 버전이 존재한다는 이유로 중첩시키지 않는다. 즉 중복은 **우리 범위가 openid-client의 하한 아래로 내려갈 때** 생기며 그건 jose가 아니라 openid-client가 릴리스해야 일어난다. **진짜 이유는 이게 게시되는 라이브러리라는 것이다** — 우리 범위는 우리 트리가 아니라 **소비자 트리**에서 해석된다. 라이브러리에서 범위를 좁히면 소비자가 이미 가진 jose와 충돌해 **그쪽에서** 중복을 강제할 확률이 올라가고, 소비자는 우리가 새 버전을 낼 때까지 손쓸 수 없다(`keycloak` 크레이트에 `=26.6.2`를 쓰면 안 되는 것과 같은 논리 — CLAUDE.md Rust 절). 재현성은 선언 범위가 아니라 `package-lock.json`에서 온다.

- ⚠️ **(Node) admin-client `findOne`류는 404에서 `null` 반환(선언 타입은 `undefined`)** — `null`/`undefined` 모두 부재로 처리해 `KeycloakNotFoundError`로 변환. `=== undefined`만 검사하면 삭제 후 조회가 버그로 샌다. 근거: `admin/call.ts`의 `requireFound`.
- ⚠️ **(Node) 타임아웃은 `Configuration.timeout`(초), admin-client는 `ConnectionConfig.timeout`(ms)로 주입** — `requestOptions`는 signal 주입 불가. TLS는 `serverUrl`이 `http://`일 때만 `allowInsecureRequests` 적용(https는 강제 유지).
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce` 필수 전달.** authorization request가 실은 nonce를 Keycloak이 id_token에 담아 돌려주고 openid-client v6가 자동검증 — 기대 nonce 누락 시 "unexpected nonce"로 전면 거부(리뷰 HIGH). `TokenSet`/`KeycloakConfig`는 toString/JSON/inspect에서 마스킹. JWKS는 `cooldownDuration`으로 DoS-안전.
- ⚠️ **(Node) admin은 만료 시 재인증하려면 SDK provider를 `registerTokenProvider`로 배선한다 — `kc.auth()`는 호출하지 않는다(PR #63).** admin-client 내장 TokenManager는 만료 시 refresh_token 그랜트만 시도하고 client_credentials 재인증 폴백이 없어, 위임하면 최초 토큰 만료(~4.5분) 후 모든 admin 호출이 영구 500 실패한다. 파사드가 `ClientCredentialsTokenProvider`를 `AdminClient.create(config, provider)`로 주입해 admin이 만료 시 재인증하게 한다. **⚠️ 9언어 중 node만 취약**: JVM(Java/Kotlin)은 TokenManager가 refresh 부재 시 재인증 폴백 보유, go/dotnet/rust/ruby는 자체 캐싱 provider, python/php는 하위 라이브러리가 재인증 — 전부 SAFE. 재현: realm `accessTokenLifespan`을 낮춰 admin op → 45s 대기 → op 관찰.
- ⚠️ **(Node) `tsconfig.json`의 `include: ["src"]`라 테스트 파일은 타입체크 안 됨** — jose v6가 제거한 `KeyLike`를 계속 import해도 typecheck·eslint·vitest 전부 못 잡음(esbuild가 타입 벗김). `include`에 `test`를 추가하면 `token-provider.test.ts`의 선행 `TS2554` 5건이 드러나므로 별도 작업이 필요하다 — 의존성 메이저 bump 검증 시 사각지대. 근거: `test/unit/jwt.test.ts`.
- ⚠️ **(Node) JWKS rate-limit 회귀는 대조군 없이는 안 잡힌다.** `cooldownDuration`이 개명·제거되면 JS가 조용히 무시해 하드닝이 사라지는데, **jose가 그 경우 자체 기본값 30초로 폴백**하므로 우리 설정값도 30초인 정상 케이스는 그대로 통과한다(변이검증 실측) — `cooldown=0` 대조군만 히트 7→1로 떨어져 실패. `test/unit/jwt-jwks.test.ts`의 두번째 케이스를 지우지 말 것.
