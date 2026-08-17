---
paths:
  - "node/**"
  - "harness/apps/node/**"
  - "harness/install/consume/node*"
  - ".github/workflows/node-*.yml"
---

# Node 규칙

## 툴체인

시스템 설치. `engines`는 `>=22`다(문서에 "20+"라고 쓰지 않는다). 명령은 `node/`에서.

```bash
cd node && npm ci
cd node && npm test            # 단위 + 커버리지 게이트(라인 90/브랜치 85). Docker 불필요
cd node && npm run test:it     # 통합. Docker 필요(KC 26.6)
cd node && npm run typecheck   # tsc --noEmit (strict)
cd node && npm run lint
cd node && npm run build       # tsc → dist/
```

- 단일 테스트: `npx vitest run test/unit/<name>.test.ts`
- 커버리지는 `src/auth.ts`·`src/admin/**`·`src/index.ts`를 omit한다(네트워크 경계 — 통합테스트로 검증). 나머지는 라인 100%/브랜치 94%.
- 배포 검증: `npm run build && npm pack --dry-run`. ⚠️ `files:["dist"]`여도 npm은 `package.json`·`README`·`LICENSE`를 **항상** 담으므로 `node/README.md`·`node/LICENSE`가 없으면 npmjs.com 랜딩이 빈 채로 게시된다. README 링크는 전부 절대 URL로 쓴다(레지스트리 페이지에서 상대 링크는 깨진다).
- 배포는 `node-v*` 태그 → npm **Trusted Publishing**(OIDC + provenance, 저장 토큰 없음). 태그↔`package.json` 정합 가드 + 통합 E2E가 `needs:`에 있다.
- 패키지 `@xzawed/keycloak-sdk`는 ESM 전용(`"type":"module"`) + `.d.ts` 포함.
- ⚠️ **`tsconfig.json`의 `include: ["src"]`라 테스트 파일은 타입체크되지 않는다** — 제거된 타입을 계속 import해도 typecheck·eslint·vitest가 전부 놓친다(esbuild가 타입을 벗긴다). 의존성 메이저 범프 검증 시 사각지대다. `include`에 `test`를 넣으면 선행 오류가 드러나므로 별도 작업이 필요하다.

## admin

- ⚠️ **만료 시 재인증하려면 SDK provider를 `registerTokenProvider`로 배선한다 — `kc.auth()`를 호출하지 않는다.** admin-client 내장 TokenManager는 만료 시 refresh_token 그랜트만 시도하고 client_credentials 재인증 폴백이 없어, 위임하면 최초 토큰 만료(~4.5분) 뒤 모든 admin 호출이 영구 500이 된다. **9개 언어 중 node만 이 취약점을 갖는다**(JVM은 재인증 폴백 보유, go/dotnet/rust/ruby는 자체 캐싱 provider, python/php는 하위 라이브러리가 재인증). 재현: realm `accessTokenLifespan`을 낮추고 admin 호출 → 45초 대기 → 재호출.
- **admin-client 핀 `~26.7.0`은 이력의 산물이다** — 26.7.0의 `decodeToken(undefined).split()` 크래시 회귀로 `~26.6.4`까지 좁혔다가, 위 배선이 그 경로를 근본 차단함을 통합테스트로 실증하고 전진했다. **좁히기로 되돌리기 전에 배선을 먼저 볼 것.**
- ⚠️ **`findOne`류는 404에서 `null`을 반환한다**(선언 타입은 `undefined`) — `null`/`undefined` 모두 부재로 처리해야 한다. `=== undefined`만 검사하면 삭제 후 조회가 버그로 샌다.

## auth · JWT

- ⚠️ **타임아웃은 두 곳이 단위가 다르다** — `Configuration.timeout`은 **초**, admin-client `ConnectionConfig.timeout`은 **ms**. `requestOptions`로는 signal을 주입할 수 없다.
- ⚠️ **PKCE `exchangeCode`에 `nonce`를 반드시 넘긴다.** Keycloak이 id_token에 nonce를 담아 돌려주고 openid-client v6가 자동 검증하므로, 기대 nonce가 없으면 "unexpected nonce"로 전면 거부된다.
- TLS는 `serverUrl`이 `http://`일 때만 `allowInsecureRequests`가 적용된다(https는 강제 유지).
- ⚠️ **JWKS rate-limit 회귀는 대조군 없이 잡히지 않는다.** `cooldownDuration`이 개명·제거되면 JS가 조용히 무시하는데, **jose가 자체 기본값 30초로 폴백**하므로 우리 설정도 30초인 정상 케이스는 그대로 통과한다. `cooldown=0` 대조군만 실패한다 — `test/unit/jwt-jwks.test.ts`의 두 번째 케이스를 지우지 말 것.

## 의존성 범위

⚠️ **`jose`/`openid-client`의 `^6`을 `~`로 좁히지 않는다.** 이유는 "트리 중복"이 아니다(그 근거는 한 번 틀리게 적혔다 — npm은 호이스트된 루트 버전이 의존자의 범위를 만족하면 재사용하고, 더 새 버전이 있다는 이유만으로 중첩시키지 않는다). **진짜 이유는 이것이 게시되는 라이브러리라는 것이다** — 우리 범위는 우리 트리가 아니라 **소비자 트리**에서 해석된다. 좁히면 소비자가 이미 가진 jose와 충돌해 그쪽에서 중복을 강제할 확률이 올라가고, 소비자는 우리가 새 버전을 낼 때까지 손쓸 수 없다(Rust의 정확 핀 금지와 같은 논리). 재현성은 선언 범위가 아니라 `package-lock.json`에서 온다.
