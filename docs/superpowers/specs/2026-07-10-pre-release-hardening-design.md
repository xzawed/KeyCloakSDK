# 배포 전 하드닝 (Pre-Release Hardening) — 설계

- **작성일**: 2026-07-10
- **상태**: 승인됨 (구현 계획 수립 대기)
- **적용 대상**: 9개 언어 SDK 전체 + 검증 하네스 + CI
- **선행 조건**: 없음 (main 클린, 열린 이슈·PR 0건)

## 1. 배경

9개 언어 SDK가 모두 `main`에 병합됐고 CI는 초록이다. 그러나 정밀 감사 결과 두 가지가 드러났다.

**첫째, 검증 인프라가 자기 자신을 검증하지 못한다.** `harness/suites/*.sh` 9개 전부가 단위테스트 종료코드를 로그에만 찍고 버리며, JSON 계약에 "테스트가 통과했는가"를 담는 필드 자체가 없다. `report/score.mjs`의 커버리지 크레딧은 오직 `su.ran`에만 걸려 있는데 suite 스크립트가 그 값을 `true` 리터럴로 박아 넣는다. `security/probe.mjs`는 200이 아닌 **모든** 응답을 "방어 성공"으로 세므로 `/validate`가 500으로 크래시해도 보안 만점이다. `install-verify.sh`는 무조건 `exit 0`으로 끝나고, `verify.sh`는 실행비트가 없어 CI에서 `exit 126`으로 즉사한다. 즉 이 프로젝트가 광고하는 "4차원 검증·A등급 스코어카드"는 상당 부분 아무것도 거부하지 못하는 상태다.

**둘째, 동형성이 실제로는 깨져 있다.** 이 리포는 9개 언어가 동일한 §4 계약을 구현한다고 전제한다. 그러나 Rust가 JWKS rate-limit stamp 순서를 고치고 회귀테스트까지 붙였음에도 PHP는 여전히 틀렸고, Kotlin이 `ProcessingException`을 잡는 반면 **같은 라이브러리를 쓰는** Java는 잡지 않는다. Node는 9개 언어 중 유일하게 `exp` 클레임을 강제하지 않는다. 한 언어에서 얻은 교훈이 나머지로 역전파되지 않는 것이 이 프로젝트의 실제 실패 양상이다.

**태그 0개, 배포 0회, 소비자 0명.** 파괴적 API 변경이 무료인 유일한 시점이다. 첫 배포 이후에는 전부 semver 메이저 이슈가 된다.

## 2. 감사 신뢰도 — 이 스펙이 근거로 삼는 것과 삼지 않는 것

작업 집합은 **두 차례 감사 실행의 합집합 70건**이다(run1 확정 38 + run2 확정 48, 위치 기준 병합). 단일 실행을 진실로 삼지 않는 이유는 아래와 같다.

적대적 반증자(refuter)가 **최소 3건의 거짓 음성**을 냈다. `install-verify.sh`의 무조건 `exit 0`을 "오탐"으로 기각했고(실제로는 파일 마지막 줄에 그대로 있다), Node의 `allowedAlgs: ['RS256']` 하드코딩을 기각하면서 **완전히 동일한 결함인 Java `AuthClient.java:39`는 확정**했으며, Python `timeout=int(self._config.read_timeout)`를 기각했다. 또한 Rust 콜드캐시 이중 fetch는 확정 목록과 반증 목록에 **동시에** 올라 있다.

따라서 이 스펙은 다음 규칙을 따른다.

- 확정 목록은 합집합으로 취한다 (부록 A).
- 반증 목록은 **기각이 아니라 미판정**으로 취급한다 (부록 B). 해당 클래스 PR 착수 시 각각 코드로 재확인한다.
- 검증 에이전트가 죽어 판정 자체가 없는 9건도 미판정으로 남긴다 (부록 B).
- 사람이 코드로 직접 재판정해 확정한 항목은 별도로 기록한다 (부록 C).

### 작업 집합의 출처

각 PR의 실제 작업 항목은 **부록 A ∪ 부록 C ∪ CI 실측 항목**이다. 셋의 출처가 다르므로 구분한다.

| 출처 | 건수 | 성격 |
|---|---|---|
| 부록 A | 70 (고유 65) | 두 감사 실행이 확정한 것. ⚠️ 병합 키가 `언어\|파일:라인`이라 같은 근본원인을 두 렌즈가 다른 라인으로 보고하면 중복 계수된다 — 사람이 판정한 확정 중복 쌍 5개를 빼면 고유 결함은 65건이다(예: `php/src/Jwks/JwksStore.php`의 `:47`과 `:51`은 같은 stamp-after-fetch 결함). 반대로 같은 파일의 여러 건이 모두 중복인 것은 아니다 — `go/jwt.go`의 4건은 서로 다른 진짜 결함이다. 상세는 [2026-07-10-audit-findings.json](2026-07-10-audit-findings.json)의 `meta.duplicate_clusters` |
| 부록 C | 11 | 사람이 코드/실행으로 직접 재판정한 것. 이 중 node `auth.ts:60`(RS256 하드코딩), node `users.ts:31`(조용한 절삭), 하네스 `exit 0`은 **감사가 잘못 기각했거나 아예 생성하지 않아** 부록 A에 없다 |
| CI 실측 | 2 | PR 0의 `0-a`(java·php install publish 실패). 야간 CI 아티팩트에서만 재현되므로 정적 감사가 볼 수 없었다 |

정직한 한계: 감사는 정적 분석 + 라이브러리 1차 소스 대조였고, 전체 빌드/테스트를 실행하지 않았다. 예외적으로 Node의 `exp` 결함만 실제 `jose 5.10.0`을 설치해 실행으로 재현했다.

## 3. 세 가지 불변식

이 작업 전체가 다음 세 문장으로 요약된다.

**I1 — 게이트는 반증 가능해야 한다.** 모든 검증 게이트는 "고의로 깨뜨리면 실제로 빨개진다"를 변이 테스트로 증명한 뒤에만 신뢰한다. 현재 SCORECARD가 A/97인 이유가 코드 품질 때문인지 게이트 무력화 때문인지 지금은 구별할 수단이 없다.

**I2 — 결함은 언어가 아니라 클래스 단위로 닫는다.** 한 언어에서 발견된 결함은 9언어 매트릭스를 다 채우기 전에는 닫지 않는다. 각 PR 본문에 9언어 체크리스트를 포함한다.

**I3 — 수정에는 실패하는 테스트가 선행한다.** 회귀테스트를 먼저 넣어 RED를 확인하고, 그다음 고쳐 GREEN을 만든다. 감사에서 test-quality 결함이 최다(29%)였던 이유는 테스트가 정상 경로만 밟았기 때문이다.

## 4. PR 0 — 게이트를 진짜로 만들기

PR 0 내부에도 순서 의존이 있다. **0-a를 먼저 고치지 않고 0-e를 적용하면 CI가 즉시 빨개진다.**

### 0-a. java/php install publish의 CI 전용 실패 수정 (선행 필수)

야간 CI 아티팩트(`INSTALL-MATRIX.md`, 2026-07-08·07-09 동일)에서 java·php가 publish 단계에서 실패한다. 로컬(Windows Docker Desktop)은 바인드마운트 소유권을 마스킹해 통과하므로 드러나지 않았다.

- **java**: 컨테이너 내부 `mvn -Prelease install`은 `BUILD SUCCESS`. 산출물 추출 단계에서 `mkdir …/publish/out/java/staging-m2/com: permission denied` → 필수 아티팩트 8종 누락. 원인은 앞선 `docker run`이 root 소유로 만든 디렉터리에 runner(uid 1001)가 쓰지 못하는 것. 추출 전 소유권을 정정하거나, 컨테이너 내부에서 tar를 stdout으로 스트림해 호스트 uid로 풀어낸다.
- **php**: `composer/satis` 컨테이너에서 `fatal: detected dubious ownership in repository at '/build/php-src'`. satis 컨테이너에 `GIT_CONFIG_COUNT=1 / GIT_CONFIG_KEY_0=safe.directory / GIT_CONFIG_VALUE_0=/build/php-src`를 주입한다.

### 0-b. suite JSON 계약에 "테스트가 통과했는가"를 추가

`harness/suites/*.sh` 9개가 `___TESTEXIT`(python은 `___INSTALLEXIT`도)를 emit하지만 리포 어디에서도 파싱되지 않는다(grep 0건). 마지막 줄은 `"ran":true`를 리터럴로 출력한다.

- 9개 suite 스크립트: 종료코드를 파싱해 `"testsPassed": true|false` 필드를 추가한다.
- `harness/report/score.mjs:20`: `su.ran` → `su.ran && su.testsPassed`. 테스트 실패 시 커버리지 차원 0점.
- suite JSON 계약 문서를 갱신한다.

### 0-c. security 프로브 판정 강화

`harness/security/probe.mjs:27`의 `expectReject`가 `r.status !== 200`으로 판정한다. 주석마저 "200이 아니면 방어 성공"이라고 적혀 있다.

- 명시 허용목록(`401`, `400`)으로 바꾼다. 5xx는 방어 실패로 집계하고 별도 `crashes` 카운터를 남긴다.

### 0-d. 실행비트 14개 부여 + CI 회귀 가드

`git ls-files -s -- '*.sh'`에서 모드 `100644`인 파일이 14개다. 영향:

| 파일 | 호출 형태 | 결과 |
|---|---|---|
| `harness/verify.sh` | `./verify.sh` | exit 126 — score-all 즉사 |
| `harness/install/publish/kotlin.sh` | `./publish/kotlin.sh` | kotlin publish 실패 |
| `harness/suites/kotlin.sh` | `[ -x … ]` 테스트 | **조용히 스킵** (`ran:false`) |
| `scripts/release-readiness.sh` · `release-trigger.sh` | `./scripts/…` (DEPLOY.md 안내) | Linux/macOS에서 exit 126 |

- `git update-index --chmod=+x`로 14개에 실행비트를 부여한다.
- CI 회귀 가드: `git ls-files -s -- '*.sh' | awk '$1=="100644"'`가 비어있지 않으면 실패.

`consume/kotlin-run.sh`는 Dockerfile이 `CMD ["sh", "/work/run.sh"]`로 호출하므로 무해하나 일관성을 위해 함께 부여한다. `install/lib.sh`는 `.`로 source되므로 무관하다.

### 0-e. 조용한 초록 제거

- `harness/install/install-verify.sh` 마지막 줄의 무조건 `exit 0` → 매트릭스에 `✗`가 있으면 `exit 1`. 부분실패 격리(다른 언어 계속 진행)는 유지하고 종료코드에만 반영한다.
- `harness/verify.sh`: conformance·security·k6·`run-suite.sh`를 감싼 `|| true`와 healthz 타임아웃의 `continue`가 실패를 삼킨다. 언어별 실패를 누적해 마지막에 종료코드로 반영한다.
- `.github/workflows/php-ci.yml:32`: `$p = $t ? $c/$t*100 : 100;` — `statements`가 0이면 커버리지 100%로 fail-open. `$t == 0`이면 실패로 바꾼다.

### 0-f. 변이 증명 (I1)

각 게이트를 고의로 깨뜨려 빨개지는지 확인하고 되돌린다.

- Node 단위테스트 1개를 실패시켜 → `verify.sh node`의 커버리지 차원이 0점, 등급이 하락하는지
- 샘플앱 `/validate`가 500을 반환하게 하고 → 보안 점수가 하락하는지
- `.sh` 하나에서 실행비트를 제거하고 → CI 가드가 잡는지
- `install-verify.sh`에서 한 언어를 강제 실패시키고 → 잡이 exit 1인지

## 5. PR 1~6 — 결함 클래스

각 PR은 하나의 불변식을 9개 언어 전부에 대해 닫는다. PR 본문에 9언어 체크리스트를 포함하고, 위반이 없는 언어도 "확인함"으로 명시한다.

### PR 1 — `exp` 부재 토큰은 거부한다

- **위반**: node (`src/jwt.ts:36` — `jwtVerify`에 `requiredClaims` 미전달)
- **레퍼런스**: 나머지 8개 언어 전부. java `Set.of("exp")` · kotlin `setOf("exp")` · go `claims.Expiry == nil` · rust `set_required_spec_claims` · dotnet `RequireExpirationTime=true` · ruby `required_claims` · php `throw 'exp claim is required'` · python `raise TokenValidationError("Missing exp claim")`
- **실증**: `jose 5.10.0`을 설치해 `node/src/jwt.ts:36`의 옵션 그대로 실행한 결과, exp 없는 유효서명 토큰이 통과하고 `requiredClaims`를 추가하면 거부된다. 대조군(만료 토큰 거부, 정상 토큰 통과) 정상.
- **수정**: `requiredClaims: ['exp','iss','aud']` 추가. `jwt.ts:47`의 `expiresAt: … : undefined` 삼항은 exp가 항상 존재하므로 제거한다.
- **회귀테스트**: 9개 언어 전부에 "exp 없는 유효서명 토큰 → 거부" 부정 테스트를 추가한다. 현재 node·java에 없다.

### PR 2 — JWKS 재조회 rate-limit은 결정 시점에 stamp하고, cold-start도 single-flight를 거친다

- **불변식 A**: 재조회를 하기로 결정한 순간 stamp한다. fetch가 실패해도 게이트는 소모된다.
- **불변식 B**: cold-start 초기 로드도 single-flight/rate-limit을 거친다.
- **불변식 C**: 키 회전 시 rate-limit이 single-flight보다 먼저 걸려 새 키로 서명된 **유효** 토큰을 거짓 거부해서는 안 된다.
- **위반**: php(A, `src/Jwks/JwksStore.php:50-51`이 `fetch()` 후 stamp) · rust(B, `src/jwks.rs:61`) · go(C, `jwt.go:132`)
- **레퍼런스**: rust `src/jwks.rs:83-86`("fetch가 실패해도 gate는 이미 소모") · ruby `lib/keycloak_sdk/jwks_store.rb:26-27`
- **파생**: go `jwt.go:172`의 JWKS fetch가 HTTP 상태를 검사하지 않아 비-200 응답을 빈 keyset으로 캐시한다(이후 검증이 fail-closed로 막힘). 가용성 사고이므로 이 PR에서 함께 닫는다.
- **회귀테스트**: rust의 `fetch_failure_still_stamps_gate`(certs 히트 수를 카운트) 동형을 php·go·python(sync/async 양쪽)·ruby·node·java·kotlin·dotnet에 확산한다. python async 미러에는 rate-limit 부정 테스트가 아예 없다.

### PR 3 — 하위 라이브러리 예외는 공개 API를 넘지 않는다 (§4 경계)

- **위반**:
  - java `AdminExceptions.java:17` — `catch (WebApplicationException)`만. `ProcessingException`은 형제 클래스(둘 다 `RuntimeException` 직계)라 잡히지 않는다. JAX-RS는 연결거부·읽기타임아웃을 이 예외로 감싼다. Java 프로덕션 코드 전체에 `ProcessingException` 문자열이 0건이다.
  - node `src/admin/call.ts` · `src/admin/index.ts:59` · `src/auth.ts:89`(discovery)
  - dotnet `AuthClient.cs:185`·`:59`(전송 실패를 `KeycloakAuthException`으로 오분류) · `Admin/AdminClient.cs:61`(비-JSON 에러 바디 → raw `JsonException` 누출)
  - rust `src/admin.rs:35`(토큰 획득 실패를 `Admin(Other{status:401})`로 오분류, `oauth_error` 소실)
  - ruby `lib/keycloak_sdk/admin/roles.rb:18`(URL 경로 미인코딩 → 공백 포함 name이 `URI::InvalidURIError` 누출, `#`/`?` 포함 name은 조용한 오라우팅)
- **레퍼런스**: kotlin `admin/AdminClient.kt:96-100` — **Java와 같은 `keycloak-admin-client 26.0.10`을 쓰면서** `WebApplicationException`과 `ProcessingException`을 모두 잡는다. go `TransportError` · dotnet `HttpRequestException`+타임아웃 분기 · ruby `Faraday::Error`.
- **회귀테스트**: 각 언어에 "연결거부/타임아웃 → TransportError" 부정 테스트. node `test/unit/admin.test.ts:113`은 "상태 없는 에러는 raw 전파"를 **기대값으로 박아** 결함을 고착시키고 있으므로 교정한다.

### PR 4 — `exchangeCode`는 id_token을 서명검증 후 nonce와 대조해 반환한다 (파괴적 API 변경)

- **위반**:
  - java `AuthClient.java:210-211` — `new TokenSet(at.getValue(), refresh, null, "Bearer", …)`. `idToken`이 null 리터럴, `tokenType`이 "Bearer" 리터럴. `getIdToken()`이 항상 null을 반환해 OIDC 로그인에서 사용자 신원을 읽을 수 없고 nonce 재생 방어를 구현할 수 없다.
  - go `auth.go:91` · rust `src/auth.rs:122` · ruby `lib/keycloak_sdk/auth_client.rb:35` — nonce를 생성만 하고 검증·반환하지 않는다.
- **레퍼런스**: kotlin `auth.kt` — id_token을 nonce 비교 **전에** 완전 서명검증한다(Java보다 엄격).
- **API 변경**: `exchangeCode(code, redirectUri, codeVerifier)` → `exchangeCode(code, redirectUri, codeVerifier, expectedNonce)`. `TokenSet.idToken`을 실제 값으로 채우고 `tokenType`을 응답값에서 읽는다.
- **연쇄 수정**: `examples/`와 `harness/apps/` 9개 샘플앱을 함께 고친다.
- **재판정 필요**: dotnet `ExchangeCodeAsync`의 nonce 처리(부록 B). 착수 시 확인한다.

### PR 5 — 공개 설정 필드는 반드시 배선된다 (무음 no-op 금지) + 효율성

- **하드코딩 노브**:
  - java `AuthClient.java:39` `Set.of(JWSAlgorithm.RS256)` · node `src/auth.ts:60` `allowedAlgs: ['RS256']` · python `src/keycloak_sdk/auth.py:203`(`allowed_algs` 미전달) — ES256/PS256 서명 realm의 정상 토큰이 전부 거부된다. `KeycloakConfig`에 서명 알고리즘 필드를 추가한다(기본 RS256, 다중값).
  - go `config.go`·node `src/config.ts:49` — `connectTimeout`을 받아 기본값·검증까지 하고 어떤 HTTP 클라이언트에도 배선하지 않는다.
  - go `config.go` — 음수 timeout을 조용히 통과시킨다.
  - php `JwksStore.php:28`(60초) · go `jwt.go:46`(60초) — JWKS 재조회 간격이 소스에 박혀 config로 흐르지 않는다.
  - ruby `lib/keycloak_sdk.rb:35` — rack-oauth2 타임아웃이 require 시점에 **프로세스 전역** 10초로 박혀 Config를 무시하고 다른 rack-oauth2 소비자와 충돌한다.
  - python `admin/__init__.py:49` — `timeout=int(self._config.read_timeout)`. `read_timeout=0.5` → `timeout=0` → urllib3가 `ValueError`로 거부해 admin 전체가 매 호출 실패한다.
  - node `src/admin/users.ts:31` · dotnet `Users.SearchAsync` — `max = 100` 기본값이 무인자 호출 시 결과를 조용히 잘라낸다.
- **효율성**: ruby `http.rb:17`(keep-alive 없음, 매 요청 새 TCP+TLS) · rust `jwt.rs:68`(매 검증마다 JWK clone + `DecodingKey` 재파싱) · rust `jwks.rs:86`(콜드캐시에서 동일 JWKS 2회 GET) · python `auth.py:147`(매 `authorization_url()` 호출마다 discovery 왕복) · node `auth.ts:229`(discovery가 설정 타임아웃 대신 라이브러리 기본 30초)

### PR 6 — 보안 핵심 경로는 부정 테스트를 갖는다

감사에서 test-quality 결함이 14건으로 최다였다. 코드가 "올바르게 보이는" 이유가 테스트가 그 부분을 건드리지 않기 때문인 경우가 반복된다.

- java `JwtValidatorTest.java` — 만료·발급자 불일치·서명 변조 거부 테스트가 하나도 없다. `DefaultJWTClaimsVerifier`의 required set을 `Set.of()`로 바꿔도 기존 7개 테스트가 전부 통과한다. (missing-exp 테스트는 PR 1에서 추가하므로 이 PR에서는 나머지 3종을 다룬다.)
- java `AdminExceptionsTest.java` · dotnet `AdminClientTests.cs`·`AuthClientTests.cs` — 전송 실패 경계 테스트 부재/불충분. (PR 3과 겹치므로 PR 3에서 처리하고 여기서는 잔여분만.)
- kotlin `FullFlowIT.kt:204` — "realm CRUD 완주 증명"이 SDK가 아니라 컨테이너의 raw master 클라이언트로 수행되어 `RealmsResource.delete/create` 성공 경로가 어떤 테스트로도 실행되지 않는다.
- kotlin `JwtValidatorTest.kt:151` — DoS-safe JWKS 불변식이 주석으로만 단언되고, 모든 JWKS 부정 테스트가 재조회 없는 정적 `ImmutableJWKSet`을 써서 실제 `forRealm`의 `JWKSourceBuilder` 구성이 전혀 검증되지 않는다.
- ruby `spec/unit/auth_client_spec.rb` — PKCE S256 챌린지 파생의 정확성을 검증하는 테스트가 없다.
- rust `error.rs:73` — 방금 생성한 값을 그대로 재확인하는 vacuous 테스트. `token_provider.rs:176` — 오류 변형만 확인하고 내용을 검증하지 않는다.
- go `tokens.go:49` — `ExpiresIn` 파생 분기가 어떤 단위테스트로도 실행되지 않는다.
- **커버리지 omit 재검토**: `auth`/`admin`/`client` omit 뒤에 순수 로직(분기·검증)이 숨어 있는지 언어별로 확인한다. 숨어 있다면 그 로직을 omit되지 않는 모듈로 옮기거나 omit 범위를 좁힌다.

## 6. PR 7~8 — 인프라와 문서

### PR 7 — 배포 필수 인프라

- `SECURITY.md` 작성(리포에 취약점 신고 경로가 전무하다) + GitHub Private Vulnerability Reporting 활성화(사람, 1클릭).
- 의존성 CVE 감사 CI 5개 언어: rust `cargo audit`(RUSTSEC-2023-0071은 dev-dependency `rsa`에 대한 것으로 런타임 무영향 — 문서화된 예외로 `--ignore`) · python `pip-audit` · node `npm audit --audit-level=high --omit=dev` · dotnet `dotnet list package --vulnerable` + grep 게이트 · java OWASP dependency-check. 현재 php(`composer audit`)·ruby(`bundler-audit`)만 존재한다.
- `.github/dependabot.yml` — 9개 생태계(maven, gradle, pip, npm, gomod, nuget, composer, cargo, bundler) + github-actions.

### PR 8 — 문서 일괄 최신화

- `CLAUDE.md`의 사실 오류 2건: Rust `CARGO_REGISTRY_TOKEN`을 "등록됨"으로 기술하나 `gh secret list` 결과 리포 시크릿은 `CODECOV_TOKEN`·`SONAR_TOKEN` 둘뿐이다. jackson을 "2.21.4 고정 / fix 미출시"로 기술하나 pom은 이미 2.21.5다(PR #25).
- `CHANGELOG.md`에 Kotlin(9번째 언어)이 전면 누락(`grep -ic kotlin` = 0). PR #21·#24·#25·#26·#30도 미반영.
- 게차(Gotchas) 섹션에 이번 감사의 교훈을 추가: 동형성은 자동으로 전파되지 않는다 · 커버리지 omit이 미검증 로직을 가린다 · `|| true`와 `exit 0`이 게이트를 무력화한다.
- `docs/guides/getting-started.md`(Kotlin 누락, 8/9 자기모순) · `add-a-language-playbook.md`(Kotlin을 "상호운용 검증 트랙"으로 오기) · `ai-governance-framework.md`("Java MVP" 전용 스코프) · `harness/README.md`(k6 미연동 서술, 8언어 라벨).

## 7. 검증 전략

9개 언어 툴체인이 전부 로컬에 있으므로(`CLAUDE.md` 툴체인 섹션) 각 PR은 커밋 전에 실제로 빌드·테스트한다. PR 0이 먼저 병합되면 이후 모든 PR의 CI가 진짜로 강제된다.

- **I3 준수**: 각 결함마다 회귀테스트를 먼저 추가해 RED를 확인하고, 그다음 수정해 GREEN을 만든다.
- **변이 증명**: PR 0의 각 게이트에 대해 고의 파손 → 빨개짐 확인 → 되돌림.
- **재판정**: 부록 B의 항목은 해당 클래스 PR 착수 시 코드로 재확인한다. 확정되면 그 PR에 편입하고, 오탐이면 스펙에 기록한다.

구현 계획은 **PR 단위로 나눠 작성**한다. 9개 PR을 하나의 계획서에 담으면 검토 불가능한 크기가 되고, 무엇보다 PR 0이 게이트를 진짜로 만들기 전에는 이후 PR의 "검증됨"이 아무것도 의미하지 않는다. 따라서 PR 0의 계획을 먼저 확정·완결하고, 그 결과(변이 증명 로그)를 확인한 뒤 PR 1~6의 계획을 쓴다.

### 구조적 한계

PR 0-a(java/php install publish 수정)는 **Linux CI에서만 재현**된다. Windows Docker Desktop이 바인드마운트 소유권을 마스킹하므로 로컬에서는 이미 통과한다. 이 항목만은 `workflow_dispatch`로 실제 CI를 돌려 확인해야 하고, 잡 1회에 약 18분이 걸린다.

## 8. 범위 제외 (의도적)

배포를 막지 않으며 배포 후에 판단해도 늦지 않는 항목이다.

- **TokenStore SPI** — 스펙 §6.2가 약속했으나 Java에서는 dead(소비 모듈 참조 0건)이고 나머지 8개 언어엔 부재하다. 제거할지, 9언어에 구현할지, 스펙에서 뺄지는 별도 결정이다.
- **SonarCloud 8언어 커버리지 배선** — 규모 L. 현재 Kotlin만 배선되어 나머지 8개 언어 src를 건드리는 PR은 new-code 커버리지가 0%로 집계된다(현재는 old-code라 게이트 미발동).
- **하네스 `wait_healthy` 크래시 조기감지** — 앱 부팅 실패 시 전체 타임아웃(rust는 2400초)까지 대기한다. 각 `run.sh`가 실패 시 `sleep 3600`으로 컨테이너를 살려두므로 이득이 제한적이다.
- **main 브랜치 보호 규칙 · protected Environment** — GitHub 서버측 설정(사람).
- **CODECOV_TOKEN 처리** — 소비하는 워크플로가 0개인 죽은 시크릿. 배선할지 제거할지 결정 필요.

## 9. 성공 기준

1. PR 0 병합 후, 고의로 깨뜨린 테스트/프로브/실행비트/install 실패가 **전부 CI를 빨갛게 만든다**(변이 증명 로그 첨부).
2. 야간 `harness` 워크플로의 `score-all`·`install-all`·`all-langs` 세 잡이 모두 초록이고, `INSTALL-MATRIX.md`가 9/9 `✓`이며, `SCORECARD.md`가 CI 아티팩트로 실제 생성된다.
3. PR 1~6 각각에 대해, 9언어 체크리스트가 PR 본문에 채워지고 위반 언어에는 회귀테스트가 동반된다.
4. 전 언어 단위·통합 테스트와 커버리지 게이트가 초록이며, 그 초록이 I1에 의해 반증 가능함이 증명되어 있다.

---

## 부록 A — 확정 결함 전체 목록 (두 감사 실행의 합집합, 70건)

> run1(38건)·run2(48건)을 위치 기준으로 병합. 심각도는 해당 발견을 낸 실행의 판정을 따른다.
>
> **이 목록이 작업 집합의 전부가 아니다.** 각 PR의 실제 범위는 여기에 부록 C(사람이 재판정한 11건)와 CI 실측 2건을 더한 것이다(§2 "작업 집합의 출처" 참조).

### PR0 (9건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| HIGH | ci-scripts | bug | `.github/workflows/harness.yml:58` | harness/verify.sh가 실행비트 없이(100644) 커밋돼 나이틀 score-all CI 잡이 ./verify.sh에서 exit 126으로 즉시 죽는다 |
| HIGH | harness | test-quality | `harness/suites/go.sh:69` | suite 스크립트가 테스트 종료코드(___TESTEXIT/___INSTALLEXIT)를 캡처만 하고 버려 — 단위테스트 실패에도 coverage 만점 부여 |
| HIGH | harness | test-quality | `harness/suites/node.sh:54` | 스코어링 하네스의 전 9개 suite 스크립트가 단위테스트 종료코드를 무조건 버려 — go/python만이 아니라 모든 언어의 테스트 실패가 SCORECARD에 무음 통과된다(확정 go.sh 발견의 과소범위) |
| MEDIUM | ci-scripts | bug | `harness/install/install-verify.sh:800` | harness/install/publish/kotlin.sh 실행비트 부재(100644)로 install-verify가 ./publish/kotlin.sh를 exit 126으로 실패시켜 kotlin 설치검증이 항상 조용히 실패로 격리된다 |
| MEDIUM | ci-scripts | bug | `harness/suites/run-suite.sh:30` | harness/suites/kotlin.sh 실행비트 부재(100644)로 run-suite.sh의 [ -x ] 게이트가 거짓이 되어 kotlin 단위테스트/커버리지/린트 차원이 조용히 ran:false로 조작된다 |
| MEDIUM | ci-scripts | bug | `scripts/release-readiness.sh:1` | scripts/release-readiness.sh·release-trigger.sh 실행비트 부재(100644)로 DEPLOY.md가 안내하는 ./scripts/… 호출이 fresh Linux 클론에서 exit 126이 된다(테스트는 sh로 우회해 은폐) |
| MEDIUM | harness | validation-bypass | `harness/security/probe.mjs:27` | security 프로브 expectReject가 200이 아닌 모든 응답을 '방어 성공'으로 처리 — /validate가 500 크래시해도 보안 100점 |
| LOW | ci-scripts | validation-bypass | `.github/workflows/php-ci.yml:32` | php-ci 커버리지 게이트가 clover 통계 부재/0일 때 100%로 fail-open한다 |
| LOW | harness | efficiency | `harness/install/lib.sh:84` | wait_healthy·verify.sh healthz 폴링이 컨테이너 크래시를 감지 못해 전체 타임아웃(rust는 2400s)까지 대기 |

### PR1 (2건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| HIGH | node | validation-bypass | `node/src/jwt.ts:36` | JwtValidator가 exp 클레임을 필수로 강제하지 않아 무만료 토큰이 검증을 통과한다 |
| HIGH | node | test-quality | `node/test/unit/jwt.test.ts:72` | jwt.test.ts가 'exp 없는 토큰 거부'를 검증하지 않아, jose가 exp 미포함 토큰을 통과시키는 실제 결함을 은폐한다 |

### PR2 (10건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| HIGH | php | bug | `php/src/Jwks/JwksStore.php:47` | JwksStore의 재조회 rate-limit이 fetch 성공 후에만 stamp되어 IdP 장애 중 위조 kid 폭주가 무제한 재조회를 유발한다(미인증 DoS 증폭) |
| HIGH | php | test-quality | `php/tests/Unit/Jwks/JwksStoreTest.php:43` | JWKS DoS 레이트리밋 테스트가 성공 경로만 검증해 IdP 장애 시 무제한 재조회(미인증 증폭) 결함을 은폐한다 |
| HIGH | python | test-quality | `python/tests/unit/aio/test_auth.py:365` | async JWKS 강제 재조회 rate-limit 게이트(DoS 증폭 방어 핵심)에 대한 부정 테스트가 async 스위트에 아예 없다 — 게이트를 제거해도 CI가 통과한다 |
| MEDIUM | go | concurrency | `go/jwt.go:132` | 키 회전 시 동시 요청에서 미해결 kid의 rate-limit 게이트가 single-flight보다 먼저 걸려, 새 키로 서명된 유효 토큰들이 하나만 통과하고 나머지는 거짓 거부된다 |
| MEDIUM | go | test-quality | `go/jwt_test.go:156` | JWKS 재조회 rate-limit 게이트가 '조회 실패 시에도 스탬프된다'는 DoS 불변식을 검증하는 부정 테스트가 없어, 스탬프 시점을 옮기는 회귀가 모든 테스트를 통과한다 |
| MEDIUM | go | efficiency | `go/jwt.go:120` | JWKS 콜드스타트/장애 구간에서 재조회 rate-limit이 미적용되어 위조 토큰 홍수가 IdP로 무제한 증폭된다 |
| MEDIUM | php | efficiency | `php/src/Jwks/JwksStore.php:51` | JwksStore 재조회 rate-limit이 fetch 성공 후에만 stamp돼 IdP 장애 중 위조 kid 스팸이 무제한 재조회를 유발한다 |
| MEDIUM | rust | concurrency | `rust/src/jwks.rs:61` | JWKS 콜드-스타트 초기 로드가 single-flight/rate-limit 없이 실행되어 시작 시 thundering herd(및 미인증 DoS 증폭)가 발생한다 |
| LOW | php | hardcode | `php/src/Jwks/JwksStore.php:28` | JWKS 재조회 rate-limit 간격이 60초로 하드코딩돼 KeycloakConfig로 흐르지 않는다 |
| LOW | rust | efficiency | `rust/src/jwks.rs:86` | 콜드 캐시 상태에서 미해결 kid 조회 시 동일한 JWKS를 두 번 연속 GET한다(중복 왕복) |

### PR3 (14건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| HIGH | java | bug | `java/keycloak-sdk-admin/src/main/java/io/github/xzawed/keycloak/admin/AdminExceptions.java:17` | admin 호출의 전송 오류(jakarta.ws.rs.ProcessingException)가 SDK 예외로 변환되지 않고 공개 API로 누출된다 |
| MEDIUM | dotnet | bug | `dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs:185` | 토큰/인트로스펙션 엔드포인트의 전송 실패(연결거부·DNS·TLS)가 KeycloakTransportException이 아니라 KeycloakAuthException으로 오분류된다 |
| MEDIUM | dotnet | bug | `dotnet/src/Xzawed.Keycloak.Sdk/Admin/AdminClient.cs:61` | 타입드 admin 호출에서 에러 바디가 JSON이 아니면 raw System.Text.Json.JsonException이 SDK 공개 API로 누출된다 |
| MEDIUM | dotnet | test-quality | `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/AuthClientTests.cs:86` | transport 실패 부정 테스트가 timeout만 커버 — connect/DNS/TLS 오분류를 아무 테스트도 잡지 못한다 |
| MEDIUM | dotnet | test-quality | `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/AdminClientTests.cs:47` | typed admin 에러 경계는 단위테스트 전무 — 비-JSON 에러 바디의 미변환 JsonException 누출을 아무 테스트도 잡지 못한다 |
| MEDIUM | java | test-quality | `java/keycloak-sdk-admin/src/test/java/io/github/xzawed/keycloak/admin/AdminExceptionsTest.java:12` | admin 경계는 WebApplicationException만 변환 — 전송 실패(ProcessingException) 미변환 누출 경로에 대한 부정 테스트가 없고, 커버리지 omit이 이 미검증 경로를 가린다 |
| MEDIUM | node | bug | `node/src/admin/call.ts:14` | admin 전송계층 오류(타임아웃/연결실패/TLS)가 SDK 타입으로 변환되지 않고 raw로 공개 API에 누출된다 |
| MEDIUM | node | bug | `node/src/auth.ts:89` | Node AuthClient의 clientCredentialsToken/exchangeCode/refresh/introspect가 OIDC discovery(.well-known) 조회의 원시 전송오류를 KeycloakError 경계 밖으로 누출한다 |
| MEDIUM | node | bug | `node/src/admin/index.ts:59` | AdminClient.create의 초기 client-credentials 인증(kc.auth)이 call()로 감싸지지 않아 401·전송오류가 raw NetworkError로 누출된다 |
| MEDIUM | node | bug | `node/src/admin/call.ts:18` | admin/call.ts가 전송계층 오류(connection refused/DNS/TLS/read-timeout)를 하위 라이브러리 raw 오류 그대로 재전파한다 — KeycloakTransportError로 변환하지 않는다 |
| MEDIUM | node | test-quality | `node/test/unit/admin.test.ts:113` | admin 테스트가 '상태 없는 에러는 raw 전파'를 기대값으로 박아 실제 전송실패(타임아웃/DNS)의 하위타입 누출을 고착시킨다 |
| MEDIUM | ruby | bug | `ruby/lib/keycloak_sdk/admin/roles.rb:18` | admin 리소스가 name/id를 URL 경로에 인코딩 없이 삽입 — 공백 포함 role name은 URI::InvalidURIError를 공개 API로 누출하고 '#'/'?' 포함 name은 요청을 조용히 오라우팅한다 |
| LOW | dotnet | bug | `dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs:59` | AuthClient 토큰/인트로스펙션 메서드가 네트워크 실패(연결거부/DNS/TLS)를 KeycloakTransportException이 아니라 KeycloakAuthException으로 오분류한다 |
| LOW | rust | bug | `rust/src/admin.rs:35` | admin 토큰 획득 실패(잘못된 client_secret 등)가 Auth가 아니라 Admin(Other{status:401})로 분류되어 oauth_error가 소실된다 |

### PR4 (4건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| MEDIUM | java | bug | `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:211` | exchangeCode가 id_token을 항상 버려(null) OIDC 로그인에서 id_token·nonce를 얻거나 검증할 수 없다 |
| MEDIUM | ruby | validation-bypass | `ruby/lib/keycloak_sdk/auth_client.rb:35` | exchange_code가 생성해둔 nonce를 무시하고 id_token을 서명·nonce 검증 없이 그대로 반환한다 |
| LOW | go | validation-bypass | `go/auth.go:91` | CreateAuthorizationRequest가 생성한 nonce가 ExchangeCode에서 전혀 검증되지 않고 id_token 자체도 검증되지 않아 OIDC nonce 재생 방지가 무효다 |
| LOW | rust | validation-bypass | `rust/src/auth.rs:122` | authorization 요청의 nonce가 생성되기만 하고 검증도 반환도 안 되어 id_token 재생(replay) 바인딩이 소비자에게 제공되지 않음 |

### PR5 (18건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| MEDIUM | go | hardcode | `go/config.go:16` | Config.ConnectTimeout를 받아 기본값(10000ms)까지 채우지만 어떤 HTTP 클라이언트에도 연결(dial) 타임아웃으로 배선되지 않아 조용히 무시된다 |
| MEDIUM | java | hardcode | `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:39` | AuthClient.validate가 서명 알고리즘을 RS256으로 하드코딩 — ES256/PS256/RS512 서명 realm의 정상 토큰을 전부 거부 |
| MEDIUM | node | hardcode | `node/src/config.ts:49` | config.connectTimeoutMs는 공개 설정 필드지만 프로덕션 코드 어디에서도 사용되지 않는다(무음 no-op) |
| MEDIUM | python | efficiency | `python/src/keycloak_sdk/auth.py:147` | 동기 authorization_url()이 매 호출마다 불필요한 OIDC discovery(well-known) 네트워크 왕복을 발생시킨다 |
| MEDIUM | python | test-quality | `python/src/keycloak_sdk/admin/__init__.py:49` | admin 타임아웃 int() 절삭 결함이 커버리지 omit 파일에 숨어 있고 이를 검증하는 테스트가 없다 — read_timeout<1이면 admin이 timeout=0으로 즉시 실패 |
| MEDIUM | python | hardcode | `python/src/keycloak_sdk/auth.py:203` | AuthClient.validate가 JwtValidator에 allowed_algs를 전달하지 않아 RS256으로 고정되고, config에 알고리즘 설정 필드가 없어 ES256/PS256 서명 realm은 전면 검증 실패 |
| MEDIUM | ruby | hardcode | `lib/keycloak_sdk.rb:35` | rack-oauth2 인증 호출 타임아웃이 require 시점 프로세스 전역에 10초로 박혀 Config 타임아웃을 무시하고 다른 rack-oauth2 소비자와 충돌한다 |
| MEDIUM | ruby | efficiency | `ruby/lib/keycloak_sdk/http.rb:17` | 모든 HTTP 요청이 Faraday :net_http 어댑터를 통해 매번 새 TCP+TLS 연결을 열고 닫는다 — keep-alive/커넥션 풀 없음 |
| LOW | go | bug | `go/config.go:34` | Config.ConnectTimeout가 어디에도 배선되지 않아 연결 단계 타임아웃이 무시된다 |
| LOW | go | validation-bypass | `go/config.go:32` | 음수 ReadTimeout/ConnectTimeout를 config 검증이 조용히 통과시켜 문서화된 hung-IdP 타임아웃 보호가 무력화된다 |
| LOW | go | hardcode | `go/jwt.go:46` | JWKS 강제 재조회 rate-limit 간격(minRefetch 60s)이 소스에 박혀 있고 형제 타임아웃 노브와 달리 Config로 흐르지 않는다 |
| LOW | node | efficiency | `node/src/auth.ts:229` | discovery() 요청이 설정된 readTimeoutMs 대신 라이브러리 기본 30초 타임아웃을 사용해, 짧은 타임아웃으로 fast-fail을 의도한 소비자의 첫 auth 호출이 최대 30초까지 리소스를 붙잡는다 |
| LOW | ruby | efficiency | `ruby/lib/keycloak_sdk/jwt_validator.rb:55` | 매 토큰 검증마다 캐시된 JWKS 원본 해시로부터 OpenSSL RSA 공개키를 재구성한다(파싱된 키 미캐시) |
| LOW | rust | validation-bypass | `rust/src/token_provider.rs:78` | 토큰 응답에 expires_in이 없으면 캐시된 토큰이 만료되지 않는 것으로 취급되어 영구 재사용된다 |
| LOW | rust | validation-bypass | `rust/src/token_provider.rs:68` | 200 응답의 access_token이 문자열이 아니면(null/숫자) 존재검사만 통과해 빈 문자열 토큰이 성공으로 반환된다 |
| LOW | rust | bug | `rust/src/token_provider.rs:115` | 토큰 응답에 expires_in이 없으면 access_token이 만료 없음으로 캐시되어 영구 재사용(자가치유 불가) |
| LOW | rust | efficiency | `rust/src/jwt.rs:68` | validate()가 매 호출마다 캐시된 JWK를 clone하고 DecodingKey를 JWK에서 재파싱해, 고빈도 토큰 검증에서 반복 역직렬화 오버헤드가 누적된다 |
| LOW | rust | test-quality | `rust/src/token_provider.rs:176` | token_provider의 oauth_error_mapped 테스트가 오류 변형만 확인하고 oauth_error 내용을 검증하지 않아 error 필드 추출 버그를 놓친다 |

### PR6 (13건)

| 심각도 | 언어 | 분류 | 위치 | 결함 |
|---|---|---|---|---|
| MEDIUM | java | bug | `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:200` | 공개(public) 클라이언트에서 refresh/logout/introspect 호출 시 clientAuth()가 raw NullPointerException을 던진다 |
| MEDIUM | java | test-quality | `java/keycloak-sdk-auth/src/test/java/io/github/xzawed/keycloak/auth/JwtValidatorTest.java:10` | JWT 검증기 핵심 부정 테스트 누락 — 만료·발급자불일치·서명변조·missing-exp 거부가 단 하나도 검증되지 않아 claim-verifier 배선 회귀가 그린으로 통과한다 |
| MEDIUM | kotlin | resource-leak | `kotlin/src/main/kotlin/io/github/xzawed/keycloak/jwt.kt:95` | forRealm()이 만든 JWKSource가 nimbus refreshAhead 논-데몬 스레드를 누출해 JVM 종료를 무기한 지연시킨다 |
| MEDIUM | kotlin | test-quality | `kotlin/src/integrationTest/kotlin/io/github/xzawed/keycloak/FullFlowIT.kt:204` | FullFlowIT의 'realm CRUD 완주 증명'은 SDK가 아니라 컨테이너의 raw master 클라이언트로 수행되어 RealmsResource.delete/create-성공 경로가 어떤 테스트로도 실행되지 않는다 |
| MEDIUM | ruby | test-quality | `ruby/spec/unit/auth_client_spec.rb:26` | PKCE S256 챌린지 파생의 정확성을 검증하는 테스트가 어디에도 없다 — 잘못된 code_challenge가 그린으로 배포된다 |
| MEDIUM | rust | test-quality | `rust/src/auth.rs:97` | create_authorization_request의 scope 스레딩이 어떤 테스트에서도 검증되지 않고 커버리지에서도 omit되어, 하드코딩 'openid'로의 회귀가 무탐지된다 |
| MEDIUM | rust | test-quality | `rust/src/auth.rs:229` | map_token_err의 에러 분기(ServerResponse→Auth, Request→Transport)가 어떤 테스트에서도 실행되지 않고 auth.rs 커버리지 omit 뒤에 숨어 있다 |
| LOW | go | bug | `go/jwt.go:172` | JWKS fetch가 HTTP 상태 코드를 검사하지 않아 200 이외/keys 없는 JSON 응답을 빈 keyset으로 캐시해 이후 검증이 fail-closed로 막힌다 |
| LOW | go | test-quality | `go/tokens.go:49` | tokens.go의 ExpiresIn 파생 분기(Expiry→상대수명)가 어떤 단위테스트로도 실행되지 않음 — 커버리지 집계 로직 모듈의 미검증 분기 |
| LOW | java | test-quality | `java/keycloak-sdk-auth/src/test/java/io/github/xzawed/keycloak/auth/AuthClientRefreshTest.java:5` | AuthClientRefreshTest는 이름과 달리 refresh()를 전혀 테스트하지 않고 logout(null)만 검증 — refresh() null 가드가 미테스트 |
| LOW | kotlin | test-quality | `kotlin/src/main/kotlin/io/github/xzawed/keycloak/auth.kt:152` | coverage exclude된 auth.kt의 introspect-실패·clientAuth-null시크릿·refresh-오류 분기가 단위/통합 어디서도 실행되지 않는다 |
| LOW | node | test-quality | `node/test/unit/jwt.test.ts:91` | DoS-safe JWKS 재조회 클레임을 검증하는 테스트가 instanceof 확인뿐이라 cooldown/rate-limit 회귀를 잡지 못한다 |
| LOW | rust | test-quality | `rust/src/error.rs:73` | error.rs의 auth_carries_oauth_error는 방금 생성한 값을 그대로 재확인하는 vacuous 테스트로 프로덕션 로직을 전혀 실행하지 않는다 |

### PR7·PR8

인프라·문서 항목은 본문 §6 참조(감사 결함 목록과 별개 출처: 직전 인프라 감사 26건).

---

## 부록 B — 재판정 필요 (반증 처리됐으나 신뢰 불가)

적대적 반증자가 오탐으로 기각한 항목이다. 그러나 이 중 최소 3건이 **거짓 음성**임을 직접 코드 확인으로 입증했다(부록 C). 따라서 아래는 **기각이 아니라 미판정**으로 취급하고, 해당 클래스 PR 착수 시 각각 재확인한다.

| 언어 | 반증된 주장 |
|---|---|
| java | AuthClient 커버리지 omit이 미검증 에러-응답 매핑 분기를 가림 — 통합테스트는 성공 경로만 assert해 '네트워크 경계는 IT로 검증' 정당화가 부분적으로만 성립 |
| python | AdminClient가 read_timeout을 int()로 잘라 sub-second 설정에서 timeout=0이 되고, 그로 인해 발생한 raw ValueError가 SDK 경계를 그대로 누출한다 |
| node | AuthClient가 JWT 검증 알고리즘을 ['RS256']으로 하드코딩 — config에 오버라이드 표면이 없어 ES256/PS256 realm 토큰을 전부 거부 |
| node | users.search/groups.list의 max=100 하드코딩이 무인자 호출 시 결과를 조용히 잘라낸다(silent truncation) |
| node | 보안 핵심 JwtValidator 단위 테스트에 alg=none·서명 위조(변조) 거부 부정 테스트가 없다 |
| go | auth.go의 scope() 커스텀 스코프 분기가 어떤 테스트에서도 실행되지 않는데 auth.go는 커버리지 게이트에서 omit되어 미검증 분기가 이중으로 은폐된다 |
| dotnet | JwtValidator.ValidateAsync가 전달받은 CancellationToken을 ValidateTokenAsync에 넘기지 않아 JWKS 조회 중 취소가 무시된다 |
| dotnet | ExchangeCodeAsync가 id_token이 없으면 nonce 검증을 조용히 건너뛴다 — 주석은 'fail-closed'라고 명시하지만 실제로는 fail-open이다 |
| dotnet | JWT 검증 대상 audience를 ClientId로 하드코딩 — 소비자가 기대 audience를 설정할 수 없어 기본 Keycloak 토큰 검증이 실패한다 |
| dotnet | Users.SearchAsync의 max 기본값 100이 결과를 조용히 잘라낸다(silent truncation) |
| dotnet | 커버리지 게이트가 AuthClient를 omit해 미테스트 순수-로직 분기를 은폐한다 |
| rust | 콜드 캐시에서 미해결 kid 1건이 즉시 두 번 fetch를 유발해 첫 요청의 rate-limit 보호를 약화한다 |
| rust | JWKS 재조회 rate-limit 창(60초)이 client.rs에 하드코딩되어 config로 조정 불가 — 키회전+플러딩 겹칠 때 정상 토큰이 거부됨 |
| kotlin | admin create/delete가 adminCall 경계에서 예외를 읽기 전에 Response를 close해 Keycloak 서버 에러 본문이 유실된다 |
| harness | verify.sh와 install-verify.sh가 어떤 언어 실패에도 종료코드 0을 반환 — CI 스코어링/설치 잡이 항상 초록 |

검증 에이전트가 API 오류로 죽어 **판정 자체가 없는** 항목:

| 심각도 | 언어 | 위치 | 결함 |
|---|---|---|---|
| HIGH | java | `java/keycloak-sdk-admin/src/main/java/io/github/xzawed/keycloak/admin/AdminExceptions.java:17` | admin 호출의 전송 오류(jakarta.ws.rs.ProcessingException)가 SDK 예외로 변환되지 않고 공개 API로 누출된다 |
| MEDIUM | node | `node/src/admin/call.ts:14` | admin 전송계층 오류(타임아웃/연결실패/TLS)가 SDK 타입으로 변환되지 않고 raw로 공개 API에 누출된다 |
| HIGH | node | `node/test/unit/jwt.test.ts:72` | jwt.test.ts가 'exp 없는 토큰 거부'를 검증하지 않아, jose가 exp 미포함 토큰을 통과시키는 실제 결함을 은폐한다 |
| MEDIUM | node | `node/test/unit/admin.test.ts:113` | admin.test.ts의 '상태 없는 에러 그대로 전파' 테스트가 전송계층 실패의 원시 오류 누출(§4 위반)을 정답으로 고착시킨다 |
| LOW | php | `php/src/Jwks/JwksStore.php:28` | JWKS 재조회 rate-limit 간격이 60초로 하드코딩돼 KeycloakConfig로 흐르지 않는다 |
| MEDIUM | kotlin | `kotlin/src/integrationTest/kotlin/io/github/xzawed/keycloak/FullFlowIT.kt:204` | FullFlowIT의 'realm CRUD 완주 증명'은 SDK가 아니라 컨테이너의 raw master 클라이언트로 수행되어 RealmsResource.delete/create-성공 경로가 어떤 테스트로도 실행되지 않는다 |
| MEDIUM | kotlin | `kotlin/src/test/kotlin/io/github/xzawed/keycloak/JwtValidatorTest.kt:151` | DoS-safe JWKS 불변식(위조 서명은 재조회 안 함·미해결 kid만 rate-limited 재조회)이 주석으로만 단언되고 모든 JWKS 부정 테스트가 재조회 없는 정적 ImmutableJWKSet를 써서 실제 forRealm JWKSourceBuilder 구성이 전혀 검증되지 않는다 |
| LOW | kotlin | `kotlin/src/main/kotlin/io/github/xzawed/keycloak/auth.kt:152` | coverage exclude된 auth.kt의 introspect-실패·clientAuth-null시크릿·refresh-오류 분기가 단위/통합 어디서도 실행되지 않는다 |
| LOW | harness | `harness/install/lib.sh:84` | wait_healthy·verify.sh healthz 폴링이 컨테이너 크래시를 감지 못해 전체 타임아웃(rust는 2400s)까지 대기 |

---

## 부록 C — 사람이 코드로 직접 재판정한 항목

감사 에이전트의 판정과 무관하게, 아래는 실제 파일을 읽거나 코드를 실행해 확인했다. 부록 B의 반증 목록을 신뢰할 수 없다고 판단한 근거다.

| 항목 | 판정 | 근거 |
|---|---|---|
| node `exp` 미강제 | **확정** | `jose 5.10.0` 설치 후 `jwt.ts:36`의 옵션 그대로 실행 — exp 없는 유효서명 토큰 통과, `requiredClaims` 추가 시 거부. 대조군(만료 토큰 거부·정상 토큰 통과) 정상 |
| 9언어 `exp` 강제 매트릭스 | **node만 이탈** | java `Set.of("exp")` · kotlin `setOf("exp")` · go `claims.Expiry == nil` · rust `set_required_spec_claims` · dotnet `RequireExpirationTime=true` · ruby `required_claims` · php `throw 'exp claim is required'` · python `raise TokenValidationError("Missing exp claim")` |
| php JWKS stamp 순서 | **확정** | `JwksStore.php:50-51`이 `fetch()` → `lastRefetchAt = $now` 순서. rust `jwks.rs:83-86`과 ruby `jwks_store.rb:26-27`은 stamp → fetch 순서 |
| java `ProcessingException` 누출 | **확정** | `AdminExceptions.java:17`이 `WebApplicationException`만 catch. java 프로덕션 코드에 `ProcessingException` 0건. kotlin `AdminClient.kt:96-100`은 같은 라이브러리로 둘 다 catch |
| java `exchangeCode` id_token 폐기 | **확정** | `AuthClient.java:210-211` — `new TokenSet(at.getValue(), refresh, null, "Bearer", …)`. run2가 이 발견을 생성하지 않았을 뿐 |
| node RS256 하드코딩 | **확정 (반증 오류)** | `auth.ts:60` `allowedAlgs: ['RS256']`. run2는 이를 오탐 기각하면서 동일한 java `AuthClient.java:39`는 확정했다 — 판정 모순 |
| python `int(read_timeout)` | **확정 (반증 오류)** | `admin/__init__.py:49` `timeout=int(self._config.read_timeout)`. run1 확정, run2 반증 |
| 하네스 `exit 0` 조용한 초록 | **확정 (반증 오류)** | `install-verify.sh` 마지막 줄 무조건 `exit 0` + `install-matrix.mjs \|\| true`. `verify.sh`는 conformance·security·k6·run-suite를 전부 `\|\| true`로 감싸고 healthz 타임아웃을 `continue`로 넘긴다 |
| node `users.search` 조용한 절삭 | **확정** | `src/admin/users.ts:31` `max = 100` 기본값 |
| CI install-all의 java/php 실패 | **확정** | 2026-07-08·07-09 야간 CI 아티팩트 `INSTALL-MATRIX.md` 두 건 모두 java `✗`(publish) · php `✗`(publish). 잡은 설계상 `exit 0`이라 초록으로 표시됨 |
| CI score-all 즉사 | **확정** | 야간 CI 로그: `./verify.sh: Permission denied` / `Process completed with exit code 126`. 3회 연속(07-08·07-09·07-10) |
