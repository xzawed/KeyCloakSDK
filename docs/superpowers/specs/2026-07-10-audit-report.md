<!--
  출처: 2026-07-10 정밀 코드 감사(run2, task wxli8myl6)의 종합 에이전트 산출물 원문.
  ⚠️ 이 리포트는 run2 단독 결과다. run1이 확정했으나 run2가 생성하지 않은 결함(예: Java
  exchangeCode의 id_token 폐기)은 여기에 없다. 권위 있는 작업 집합은 다음 둘이다:
    - docs/superpowers/specs/2026-07-10-pre-release-hardening-design.md (설계·부록 A/B/C)
    - docs/superpowers/specs/2026-07-10-audit-findings.json (병합 70건, 기계 판독용)
  또한 이 리포트가 "오탐"이라 부른 15건은 기각이 아니라 미판정이다(스펙 §2).
-->

# Keycloak 다국어 SDK — 최종 종합 감사 보고서

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

## 핵심 요약

9개 언어 SDK + 하네스 + CI 스크립트에 걸쳐 **확정 결함 48건**(CRITICAL 0 · HIGH 9 · MEDIUM 28 · LOW 11)을 보고한다. 오탐 15건, 재현불가 1건은 별도로 짧게 정리했다.

**가장 위험한 것**은 두 부류다. 첫째, **보안 회귀를 감지하지 못하는 검증 인프라** — 9개 언어 전부의 스코어링 suite가 단위테스트 종료코드를 버려(7·9), 어떤 SDK의 테스트가 깨져도 커버리지 만점을 부여하고, security 프로브는 500 크래시를 "방어 성공"으로 집계하며(33), verify.sh·kotlin suite·publish 스크립트의 실행비트 누락(8·34·35)으로 나이틀 스코어카드 파이프라인이 CI에서 항상 죽거나 kotlin 검증을 조용히 스킵한다. 즉 이 프로젝트가 광고하는 "4차원 검증·A등급 스코어카드"는 상당 부분 자기 자신을 검증하지 못하는 상태다. 둘째, **JWT 하드닝 불변식의 실제 누수** — Node는 `exp` 클레임을 필수로 강제하지 않아 무만료 토큰을 통과시키고(3·4), PHP는 JWKS 재조회 rate-limit을 fetch 성공 후에만 stamp해 IdP 장애창에서 미인증 DoS 증폭이 부활한다(5·6·25).

**정직한 판정**: 코어 SDK 로직(설정·토큰·JWT 검증 본체)은 대체로 견고하고, 9개 언어에 걸쳐 동형 설계가 일관되게 지켜진 것은 실제로 인상적이다. 그러나 (a) **전송 계층 오류 처리**가 여러 언어에서 §4 경계 은닉 불변식을 위반하며(Java·Node·.NET), (b) **테스트가 정상 경로만 검증하고 부정·실패·동시성 경로를 비워둔** 채 커버리지 omit으로 그 공백을 가리는 패턴이 광범위하다(test-quality 14건이 전체의 29%). 코드가 "올바르게 보이는" 이유가 테스트가 그 부분을 건드리지 않기 때문인 경우가 반복된다. 배포 전 반드시 전송오류 변환과 JWT `exp` 강제를 실제 실행으로 재현·수정할 것을 권한다.

---

## 카테고리별 통계

| 카테고리 | 건수 | 대표 결함 |
|---|---|---|
| 테스트품질 | 14 | 2,4,6,7,9,12,13,15,20,23,24,30,32,46 |
| 잠재버그 | 15 | 1,5,8,10,16,21,22,27,34,35,36,37,39,40,42 |
| 암묵적 검증무시 | 6 | 3,33,38,43,44,48 |
| 하드코딩 | 5 | 11,17,19,28,41 |
| 효율성 | 5 | 14,25,29,45,47 |
| 동시성 | 2 | 18,26 |
| 자원누수 | 1 | 31 |
| **합계** | **48** | |

CI-스크립트 결함(8·34·35·36·48)은 잠재버그/검증무시로 분류했다. test-quality가 최다인 것은 이 감사의 핵심 발견을 압축한다 — 결함의 상당수가 "코드가 틀렸다"가 아니라 "틀려도 아무도 모른다"이다.

---

## 언어간 전파 매트릭스

같은 결함 클래스가 여러 언어에 반복된다. 각 클래스가 어느 언어에서 발현/미발현인지:

| 결함 클래스 | Java | Python | Node | Go | .NET | PHP | Rust | Ruby | Kotlin | 하네스/CI |
|---|---|---|---|---|---|---|---|---|---|---|
| 전송오류 미변환(§4 누출) | ●1,13 | 안전(broad-catch) | ●16,37 | 수정됨 | ●21,23,40 | 안전 | ○42 | ○27(URI) | — | — |
| JWKS rate-limit stamp-on-success | 안전 | 테스트공백2 | — | 테스트공백20 | — | ●5,6,25 | 안전 | 안전 | — | — |
| `exp` 필수 미강제 | 강제 | 강제 | ●3,4 | 강제 | 강제 | 강제 | 강제 | 강제 | 강제 | — |
| ConnectTimeout 미배선(무음 노브) | — | — | ●17 | ●19 | — | — | — | — | — |
| 콜드/회전 동시성 thundering herd | — | — | — | ●18 | — | — | ●26 | — | — |
| JWKS refetch 간격 하드코딩 | — | — | — | — | — | ●41 | 문서화된설계 | — | — |
| 실행비트 누락(exit 126/스킵) | — | — | — | — | — | — | — | — | — | ●8,34,35,36 |
| suite 테스트 종료코드 폐기 | — | ●9 | ●9 | ●7,9 | ●9 | ●9 | ●9 | ●9 | 부분9 | ●7,9 |
| introspect/토큰 실패경로 미검증 | ○12 | — | — | — | ●23,24 | — | ○46(kotlin) | ○30 | ○46 | — |

●=확정 결함 · ○=관련 저severity/테스트공백 · "안전/강제"=해당 언어는 올바르게 처리(반례로 유용). 전송오류 미변환과 suite-종료코드-폐기가 가장 넓게 퍼진 두 클래스다.

---

## HIGH (9건)

### 1. [Java] admin 전송오류(ProcessingException)가 SDK 예외로 변환 안 됨
`java/keycloak-sdk-admin/.../AdminExceptions.java:17` — `catch (WebApplicationException)`만 잡는다. RESTEasy는 연결거부·타임아웃·TLS 실패를 형제 타입 `jakarta.ws.rs.ProcessingException`으로 던지므로 변환되지 않고 누출된다. AdminClient는 타임아웃을 실제 주입(60-65)하므로 이 경로가 확실히 발동한다.
- **실패**: 서버 다운 상태에서 `client.admin().users().get(id)` → read timeout → raw `ProcessingException`이 `KeycloakTransportException` 대신 호출자에게 누출(§4 위반). Go SDK가 명시적으로 고친 것과 동일 클래스.
- **수정**: `call()`에 `catch (ProcessingException e){ throw new KeycloakTransportException(...); }` 추가.

### 2. [Python] async JWKS 강제재조회 rate-limit 부정 테스트 부재
`python/tests/unit/aio/test_auth.py:365` — sync에는 `test_forced_jwks_refetch_is_rate_limited`(certs.call_count==2)가 있으나 async 미러에 없다. 존재하는 async 보안 테스트는 `TokenSignatureError` 경로라 `force=True` 게이트 분기를 한 줄도 실행하지 않는다.
- **실패**: 누군가 `aio/auth.py`의 rate-limit 게이트를 제거하면 kid를 매번 바꾼 위조 토큰마다 IdP 재조회가 부활하는데, aio/auth.py가 커버리지 omit이라 89개 async 테스트가 전부 GREEN으로 통과 — 보안 회귀가 무음.
- **수정**: sync 테스트의 async 이식(a_certs.await_count==2 + 클레임 실패 시 await_count==1) 추가.

### 3. [Node] JwtValidator가 `exp` 미강제 → 무만료 토큰 통과 (검증무시)
`node/src/jwt.ts:36` — `jwtVerify`에 `requiredClaims`/`maxTokenAge`를 넘기지 않는다. jose 5.10.0은 `requiredClaims` 기본이 `[]`이고 exp는 존재할 때만 검증하므로, exp 없는 토큰은 만료 검사를 건너뛴다.
- **실패**: realm 키로 서명됐으나 exp 없는 access token을 `client.auth.validate()`에 넘기면 검증 성공 + `expiresAt: undefined` 반환. 나머지 8개 언어(Go `Expiry==nil` 거부·Rust `required_spec_claims(['exp'])`·C# `RequireExpirationTime=true`)는 모두 거부 — 9언어 공통 하드닝 불변식 위반.
- **수정**: `requiredClaims: ['exp','iss','aud']` 추가.

### 4. [Node] jwt.test.ts가 'exp 없는 토큰 거부'를 미검증 → 3번 결함 은폐
`node/test/unit/jwt.test.ts:72` — 모든 `sign()` 헬퍼(32-38)와 만료 테스트가 항상 `setExpirationTime`을 호출한다. no-exp 케이스가 전무해 3번의 실제 결함이 GREEN 스위트에서 드러나지 않는다. `jwt.ts:47`의 `expiresAt` 삼항도 exp 부재를 거부가 아니라 `undefined`로 조용히 수용한다.
- **실패**: exp 생략 토큰이 통과하는데 부정 테스트 4종(aud/issuer/만료/alg)에 no-exp가 없어 위조 무만료 토큰 수용을 아무도 못 잡는다.
- **수정**: 'exp 없는 유효서명 토큰 → 거부' 회귀 테스트 추가(3번 코드 수정과 동반).

### 5. [PHP] JwksStore rate-limit이 fetch 성공 후에만 stamp → 위조 kid 무제한 재조회
`php/src/Jwks/JwksStore.php:47` — `lastRefetchAt = $now`(51)가 `fetch()`(50) *뒤에* 실행되는데 fetch는 네트워크 실패에서 예외를 던져 stamp에 도달하지 못한다. 게이트 조건이 `lastRefetchAt !== null`이라 null인 동안 절대 발동 안 함.
- **실패**: IdP 다운 중 서로 다른 위조 kid Bearer 토큰 연속 전송 → 매번 게이트 우회 → 매번 다운된 IdP를 재타격. 형제 SDK(Rust/Go/Python/Ruby)가 결정시점 stamp로 닫은 미인증 DoS 증폭이 PHP에서만, 보호가 가장 필요한 장애창에서 부활(장수명 워커 배포 한정).
- **수정**: fetch() 호출 직전으로 stamp 이동(결정시점 소모).

### 6. [PHP] JWKS DoS 테스트가 성공 경로만 검증 → 5번 결함 은폐
`php/tests/Unit/Jwks/JwksStoreTest.php:43` — 유일한 DoS 테스트가 항상 200 반환하는 더블을 써서 rate-limit이 fetch 성공 경로에서만 행사된다. `testNetworkFailureMappedToTransportError`는 예외 타입만 확인하고 후속 스로틀을 검증 안 함.
- **실패**: 5번의 무제한 재조회가 GREEN이라 'DoS-safe' 불변식에 거짓 확신을 준다.
- **수정**: 첫 조회 후 IdP가 실패하는 응답 시퀀스 더블로 fetch 히트 상한을 assert(Rust `fetch_failure_still_stamps_gate` 동형).

### 7 & 9. [하네스] 9개 suite가 단위테스트 종료코드를 폐기 → 테스트 실패에도 커버리지 만점
`harness/suites/go.sh:69`(7) · `harness/suites/node.sh:54`(9, 전 언어 확장) — 모든 suite가 `echo "___TESTEXIT=$?"`로 종료코드를 로그에만 찍고 파싱하지 않은 채 `"ran":true`를 하드코딩한다. `score.mjs`의 coverage 차원은 `coverageLine`/`lintClean`만 보고 pass/fail도 unit 카운트도 참조하지 않는다. go/node/python/dotnet/php/rust/ruby 7개는 완전 무음, java/kotlin은 mvn/gradle 종료코드가 lintClean에 소비돼 부분 검출.
- **실패**: 임의 언어 단위테스트 1개가 회귀로 실패해도 커버리지 표는 계속 출력되므로 `<lang>.suite.json`이 `ran:true, coverageLine:97`로 기록 → 스코어카드 등급 무변화. python.sh는 `pip install` 실패(`___INSTALLEXIT`)까지 무시.
- **수정**: TESTEXIT/INSTALLEXIT를 파싱해 0이 아니면 `ran:false`(또는 `testsPassed:false`)로 emit, score.mjs가 커버리지 크레딧 차단.

### 8. [CI] harness/verify.sh 실행비트 부재(100644) → 나이틀 score-all 잡이 exit 126
`.github/workflows/harness.yml:58` — `./verify.sh ...`로 상대경로 직접 실행하는데 트리 모드가 100644(형제 run.sh는 100755). 리눅스 러너 fresh checkout은 rw-r--r--로 풀어 실행권한이 없다.
- **실패**: nightly/manual score-all이 즉시 exit 126 → conformance/security/suites/스코어링이 하나도 안 돌고 SCORECARD.md 미생성. 광고된 9언어 스코어카드 파이프라인이 CI에서 항상 죽어 있음.
- **수정**: `git update-index --chmod=+x harness/verify.sh` 또는 `bash verify.sh`.

---

## MEDIUM (28건)

### 10. [Java] 공개 클라이언트 refresh/logout/introspect가 raw NPE
`AuthClient.java:200` — `clientAuth()`가 `new String((char[])null)`을 무조건 실행. secret이 nullable인데 exchangeCode만 null 분기를 처리하고 refresh/logout/introspect의 catch는 `IOException|ParseException`만 잡아 NPE 누출.
- **실패**: PKCE 공개 클라이언트로 `refresh(token)` 호출 → NPE가 KeycloakAuthException으로 변환되지 않고 누출. Keycloak은 공개 클라이언트 refresh를 지원하는데 전면 실패.
- **수정**: secret==null이면 client_id 본문 인증으로 분기(exchangeCode 동형).

### 11. [Java] validate가 RS256 하드코딩 → ES256/PS256 realm 토큰 전부 거부 (하드코딩)
`AuthClient.java:39` — `Set.of(JWSAlgorithm.RS256)`을 소스에 고정. `JwtValidator.forRealm`은 이미 allowedAlgs를 파라미터로 받도록 설계됐고 KeycloakConfig엔 알고리즘 필드가 없다.
- **실패**: realm 서명을 ES256으로 바꾸면 정상(비위조) 토큰이 매 호출 `TokenValidationException`으로 거부되어 인증 전면 불가. 재컴파일 없이 우회 불가.
- **수정**: KeycloakConfig에 signatureAlgorithms(기본 RS256, 다중값) 추가해 config에서 읽어 전달.

### 12. [Java] JwtValidator 핵심 부정 테스트 누락 (만료·iss불일치·서명변조·no-exp)
`JwtValidatorTest.java:10` — 부정 테스트가 alg=none/HS256혼동/aud미포함만. `Set.of("exp")`를 `Set.of()`로, `.issuer(issuer)`를 드롭해도 8개 테스트 전부 GREEN. catch-all 래퍼 타입만 확인해 '올바른 이유로 거부됐는지'도 미구분.
- **실패**: exp 강제/issuer 검증 배선을 제거하는 회귀가 CI를 통과해 위조 무만료·타 realm 토큰이 프로덕션에서 수락.
- **수정**: 과거exp/no-exp/iss불일치/변조-재서명 각각 거부 assert 추가.

### 13. [Java] admin 전송실패 부정 테스트 부재 + 커버리지 omit이 은폐
`AdminExceptionsTest.java:12` — 1번 결함(ProcessingException 미변환)의 테스트 짝. ProcessingException 케이스가 없고 AdminClient.class가 jacoco 제외라 '네트워크 경계는 IT로 검증' 정당화가 성공 경로에만 해당.
- **수정**: ProcessingException 주입 → KeycloakTransportException 변환 부정 테스트 추가(1번과 동반).

### 14. [Python] sync authorization_url()이 매 호출 discovery 왕복 (효율성)
`python/src/keycloak_sdk/auth.py:147` — 로컬 `self._endpoints.authorization`이 있는데도 `self._openid.auth_url()`에 위임하고, python-keycloak `auth_url`은 캐싱 없이 매번 `.well-known` GET을 한다. async 미러는 로컬 조립(왕복 0회).
- **실패**: 초당 500 로그인 시작 → 초당 500 불필요한 well-known GET. async 소비자는 0회, sync만 부담하는 비대칭.
- **수정**: async 미러처럼 `urlencode` + `self._endpoints.authorization` 로컬 조립.

### 15. [Python] admin timeout int() 절삭 결함 + 테스트 부재
`python/src/keycloak_sdk/admin/__init__.py:49` — `timeout=int(read_timeout)`로 `int(0.5)==0`. 자매 AuthClient는 `max(1,round())`로 가드하나 admin(sync/async)은 안 함. 두 파일 모두 커버리지 omit이고 테스트가 timeout 인자를 assert하지 않음.
- **실패**: `read_timeout=0.5` 설정 시 admin이 timeout=0(urllib3 ValueError→KeycloakConnectionError)으로 도달 가능한 서버에도 전 admin 호출 실패. auth는 정상이라 진단 난해.
- **수정**: `max(1, round(read_timeout))`로 통일 + 테스트 추가.

### 16. [Node] admin 전송오류(타임아웃/연결실패/TLS)가 raw 누출
`node/src/admin/call.ts:14` — status 없는 오류를 `throw err`로 재전파. admin-client는 `!response.ok`에서만 `.response`를 붙이고, fetch 자체 실패(`TypeError: fetch failed`)·타임아웃(`DOMException[TimeoutError]`)은 `.response`가 없어 변환 안 됨. `KeycloakTransportError`가 admin 경로에서 미사용.
- **실패**: 서버 무응답 시 `admin.users.get(id)`가 raw DOMException/TypeError를 던져 `catch(e instanceof KeycloakError)`가 매칭 실패. admin.test.ts:113-118이 이 무변환 전파를 현재 동작으로 assert.
- **수정**: status undefined일 때 Error를 `KeycloakTransportError`로 감쌈.

### 17. [Node] connectTimeoutMs가 무음 no-op (하드코딩)
`node/src/config.ts:49` — 공개 필드로 기본값 10_000까지 채우나 src 어디서도 소비 안 함. 실제 타임아웃은 전부 readTimeoutMs.
- **실패**: `defineConfig({connectTimeoutMs: 2000, readTimeoutMs: 60000})` 설정 시 도달불가 호스트 연결이 2초가 아니라 최대 60초 블록. 받아들이는 척하고 조용히 버려지는 API.
- **수정**: 배선하거나(라이브러리 미지원 시 불가) 필드 제거, 최소한 무시됨을 문서화.

### 18. [Go] 키 회전 시 rate-limit 게이트가 single-flight보다 앞서 정상 토큰 거짓 거부 (동시성)
`go/jwt.go:132` — 강제재조회 경로에서 rate-limit 게이트(132-138)가 `singleFetch`(140) 앞. 첫 goroutine이 `forcedAt`을 stamp하면 같은 미해결 kid의 동시 goroutine들은 게이트에서 rate-limited로 반환된다.
- **실패**: kid k1→k2 회전 직후 k2 토큰 N개 동시 도착 → G1만 통과, G2..GN은 `refetch rate-limited`로 거짓 거부(fetch 지연창 동안). singleflight가 게이트 뒤라 합류 못 함.
- **수정**: 게이트에 막힌 goroutine이 진행 중 fetch 결과를 기다리도록 double-check lookup 또는 singleflight.Do 합류.

### 19. [Go] ConnectTimeout이 dial 타임아웃에 미배선 (하드코딩)
`go/config.go:16` — 기본값 10000까지 채우나 auth/admin/validator 3곳 모두 `ReadTimeout`만 쓰고 `net.Dialer`/커스텀 Transport가 전무.
- **실패**: `ConnectTimeout:2000, ReadTimeout:60000`으로 블랙홀 호스트 fail-fast를 의도해도 연결이 최대 60초 블록. ConnectTimeout=1로 낮춰도 무효.
- **수정**: `Transport.DialContext`에 `net.Dialer{Timeout: ConnectTimeout}` 주입 또는 필드 제거.

### 20. [Go] JWKS rate-limit '실패 시에도 stamp' 불변식 부정 테스트 부재
`go/jwt_test.go:156` — resolveKey는 결정시점 stamp(올바름)이나, 이를 고정하는 테스트가 없다. rate-limit 테스트는 항상 성공하는 fixture를, fetch-error 테스트는 초기 로드 경로만 탄다.
- **실패**: stamp를 fetch 성공 후로 옮기는 리팩터가 전 테스트 GREEN을 유지하지만, IdP 장애 중 랜덤 kid 폭주가 무제한 재조회를 재개(Rust는 회귀테스트로 고정).
- **수정**: 초기성공→이후fetch실패→다음요청 rate-limited를 atomic 카운터로 검증하는 테스트 추가.

### 21. [.NET] 토큰/introspect 전송실패가 KeycloakAuthException으로 오분류
`dotnet/.../AuthClient.cs:185` — `resp.IsError`면 무조건 KeycloakAuthException. Duende가 HttpRequestException을 `FromException`으로 삼켜 `IsError=true`(ErrorType=Exception)로 반환하므로 진짜 전송실패가 timeout catch에 도달 못 함. 문서는 TransportException이 connect/DNS/TLS를 담당한다 선언하나 timeout만 매핑.
- **실패**: 서버 다운 시 `ClientCredentialsTokenAsync()`가 KeycloakAuthException("grant failed")을 던짐. `catch(KeycloakTransportException)` 재시도 로직이 못 잡고 일시장애를 자격증명 오류로 오인.
- **수정**: `ErrorType==Exception`/`Exception is HttpRequestException`을 먼저 TransportException으로 분기.

### 22. [.NET] typed admin 비-JSON 에러 바디가 raw JsonException 누출
`dotnet/.../Admin/AdminClient.cs:61` — `CallTypedAsync` catch가 `KeycloakHttpClientException`/`HttpRequestException`/timeout 셋뿐. 라이브러리 `EnsureResponseAsync`가 에러 바디를 `Deserialize<ErrorResponse>`하다 비-JSON에서 `JsonException`을 던지면 미변환 누출. raw REST 경로(GetJsonAsync)는 이미 잡음.
- **실패**: 프록시가 502를 HTML 바디로 반환 → `admin.Users.GetAsync(id)`가 raw `JsonException` → `catch(KeycloakException)`가 놓쳐 앱 크래시(§4 위반).
- **수정**: `catch (JsonException ex){ throw new KeycloakAdminException(500,...,ex); }` 추가.

### 23. [.NET] transport 부정 테스트가 timeout만 커버
`dotnet/.../AuthClientTests.cs:86` — 유일한 transport 테스트가 HttpClient.Timeout 경로만. connect/DNS/TLS 부정 테스트 부재로 21번 오분류가 조용히 통과.
- **수정**: 닫힌 포트로 호출해 TransportException을 기대하는 부정 테스트 추가(21 수정과 동반).

### 24. [.NET] typed admin 에러 경계 단위테스트 전무
`dotnet/.../AdminClientTests.cs:47` — 테스트가 전부 raw REST 경로(Clients/Roles)만. Users/Groups/Realms가 쓰는 `CallTypedAsync` 에러 변환은 단위테스트 0개, E2E는 정상 JSON 404만.
- **수정**: WireMock으로 typed 경로에 500+HTML 바디 stub, KeycloakAdminException 기대 테스트 추가(22 수정과 동반).

### 25. [PHP] JwksStore rate-limit stamp-on-success (5번과 동일 코드)
`php/src/Jwks/JwksStore.php:51` — 5번의 재기술(다른 라인 앵커). 재조회를 결정한 순간이 아니라 fetch 성공 후 stamp.
- **수정**: 5번과 동일 — fetch 호출 직전 stamp + 회귀테스트.

### 26. [Rust] JWKS 콜드-스타트 초기로드가 single-flight 없이 thundering herd (동시성)
`rust/src/jwks.rs:61` — 초기 로드 분기가 락 없이 각 태스크가 독립 `fetch()`. docstring의 single-flight 불변식은 재조회 경로에만 적용.
- **실패**: 기동 직후 동일 kid 토큰 50개 동시 validate → `/certs`로 50개 동시 GET(기대 1+49캐시). 콜드창에 서로 다른 미해결 kid를 주입하면 rate-limit도 우회(기동창 한정). Go/Python은 초기로드도 singleflight로 수렴.
- **수정**: 초기 로드도 gate 획득 후 이중검사 fetch로 수렴.

### 27. [Ruby] admin이 name/id를 URL 경로에 인코딩 없이 삽입
`ruby/lib/keycloak_sdk/admin/roles.rb:18` — `roles/#{name}` 문자열 보간. Faraday가 `URI.parse`하므로 공백 포함 name은 `URI::InvalidURIError`(Faraday::Error 아님)를 던져 `rescue Faraday::Error`가 못 잡고 raw 누출. '#' 포함 name은 fragment로 파싱돼 조용히 오라우팅.
- **실패**: `roles.get('app admin')`(KC 허용 role명) → raw `URI::InvalidURIError` 누출(§4 위반), 유효 role 조회/삭제 불가. `roles.get('C#-dev')` → GET이 `.../roles/C`로 조용히 오라우팅.
- **수정**: 세그먼트 percent-encode(`ERB::Util.url_encode`) + rescue를 `Faraday::Error, URI::Error`로 확장.

### 28. [Ruby] rack-oauth2 타임아웃이 require 시점 프로세스 전역 10초 하드코딩 (하드코딩)
`lib/keycloak_sdk.rb:35` — require 시점 `Rack::OAuth2.http_config`로 10초 고정. exchange_code/refresh/client_credentials_token이 Config 타임아웃을 무시하고 항상 10초. `@@http_config ||= block`은 write-once라 소비자/타 gem과 충돌.
- **실패**: 소비자가 `read_timeout:60`으로 느린 IdP 대비해도 grant 3경로가 10초에 끊김. SDK require 후 소비자의 `http_config` 호출은 no-op → 소비자의 다른 IdP 토큰 요청까지 10초로 오염.
- **수정**: per-call `local_http_config`로 config 값 주입 + write-once 충돌 문서화.

### 29. [Ruby] 모든 HTTP가 net_http로 매번 새 TCP+TLS (효율성)
`ruby/lib/keycloak_sdk/http.rb:17` — `f.adapter :net_http`는 요청마다 `Net::HTTP.new` + `http.start`로 소켓을 열고 닫는다(keep-alive/풀 없음). 다른 언어(Go/.NET/reqwest 풀)와 비대칭.
- **실패**: HTTPS Keycloak에 500명 사용자 루프 생성 시 500회 완전 TLS 핸드셰이크(keep-alive면 1회). 50ms RTT에서 요청당 수십~수백ms 추가.
- **수정**: `faraday-net_http_persistent` 어댑터로 교체.

### 30. [Ruby] PKCE S256 챌린지 파생 정확성 테스트 부재
`ruby/spec/unit/auth_client_spec.rb:26` — `code_challenge=`/`S256` 문자열 포함만 확인하고 `challenge==BASE64URL(SHA256(verifier))` 등식을 검증 안 함. exchange_code 테스트도 body 매처 없이 stub.
- **실패**: `hexdigest`/padding누락/SHA1 리팩터가 규격 이탈 challenge를 만들어 실 KC가 `invalid_grant`로 거부하는데, 단위테스트 GREEN + full_flow는 client_credentials만 돌려 미검출.
- **수정**: challenge 파라미터를 파싱해 SHA256 재계산 대조 + `body: hash_including("code_verifier")` 검증.

### 31. [Kotlin] forRealm()의 JWKSource가 논-데몬 refreshAhead 스레드 누출 (자원누수)
`kotlin/.../jwt.kt:95` — 코드 주석은 'refreshAhead 기본 비활성'이라 단언하나 nimbus 10.9.1은 `refreshAhead=true` 기본값. build()가 `newSingleThreadExecutor`(논-데몬)를 만들고 RefreshAheadCachingJWKSetSource로 감싸는데 JwtValidator에 close 경로가 없고 AuthClient.close()는 no-op.
- **실패**: CLI 배치가 캐시 TTL(5분)을 넘겨 동작, 캐시 만료 30초 이내에 validate가 도착하면 비동기 갱신 태스크가 논-데몬 워커를 기동. `client.close()` 후 main 리턴해도 JVM이 무기한 매달림.
- **수정**: JwtValidator를 AutoCloseable로 만들어 JWKSource 종료 배선, 또는 `.refreshAheadCache(false)`로 명시 비활성.

### 32. [Kotlin] realm CRUD가 SDK 파사드가 아닌 raw master 클라이언트로 수행
`kotlin/.../FullFlowIT.kt:204` — 실제 realm create/delete를 `container.keycloakAdminClient`로 하고, SDK `realms()`는 get(조회)과 create(403 실패)만 호출. `RealmsResource.delete()`와 create 성공 경로가 단위(admin.* omit)·통합 어디서도 미실행.
- **실패**: `RealmsResource.delete()`에 `.remove()` 누락 회귀를 넣어도 101 단위 + E2E 전부 GREEN(실제 삭제는 raw 클라이언트가 하므로).
- **수정**: E2E를 SDK 파사드로 재작성하거나 delegate mock 단위테스트로 커버.

### 33. [하네스] security 프로브가 200 아닌 모든 응답을 '방어 성공' 처리 (검증무시)
`harness/security/probe.mjs:27` — `rec(name, r.status !== 200, ...)`. 계약상 올바른 거부는 401인데 400/404/500/502 전부 defended로 집계. flood 프로브도 500을 'no crash'로 오판. score.mjs가 그대로 점수화.
- **실패**: 어떤 앱이 alg=none/미해결-kid 토큰에 처리안된 예외로 HTTP 500(하드닝 결함·정보노출)을 반환해도 8개 expectReject가 전부 defended → 보안 차원 100/100. 크래시와 올바른 거부를 구분 못 함.
- **수정**: `r.status === 401`로 좁히고 flood도 5xx를 '방어 실패'로 카운트.

### 34. [CI] harness/install/publish/kotlin.sh 실행비트 부재 → kotlin 설치검증 항상 실패-격리
`harness/install/install-verify.sh:800` — `./publish/kotlin.sh`가 100644라 리눅스에서 exit 126 → `fail_lang kotlin publish`. fail_lang이 잡을 GREEN 유지하므로 kotlin이 INSTALL-MATRIX에 영구 'publish 실패'로 기록되지만 CI는 초록.
- **수정**: `git update-index --chmod=+x harness/install/publish/kotlin.sh`.

### 35. [CI] harness/suites/kotlin.sh 실행비트 부재 → `[ -x ]` 게이트가 kotlin을 ran:false 조작
`harness/suites/run-suite.sh:30` — `[ -x "suites/$L.sh" ]`가 100644 kotlin.sh에서 거짓 → 'no suites/kotlin.sh'로 ran:false. run-suite가 `bash`로 실행하므로 exec-bit는 불필요한데 -x 게이트가 권한을 검사하는 설계 결함.
- **실패**: kotlin의 단위테스트+Kover+ktlint 스위트가 한 번도 안 돌고 커버리지 차원이 0/누락 처리.
- **수정**: `chmod +x` + `[ -x ]`를 `[ -f ]`로 변경.

### 36. [CI] scripts/release-readiness.sh·release-trigger.sh 실행비트 부재 → DEPLOY.md 안내가 fresh Linux에서 exit 126
`scripts/release-readiness.sh:1` — 두 파일 모두 100644. DEPLOY.md와 release-trigger.sh 출력이 `./scripts/...`로 직접 실행 안내. 테스트는 `sh "$SH"`로 우회해 은폐.
- **실패**: 배포 담당자가 리눅스에 새 클론 후 `./scripts/release-readiness.sh` → 'Permission denied' exit 126, 준비상태 리포트 못 얻음.
- **수정**: `git update-index --chmod=+x scripts/release-readiness.sh scripts/release-trigger.sh`.

### 37. [Node] auth의 4개 메서드가 discovery 전송오류를 KeycloakError 밖으로 누출
`node/src/auth.ts:89` — clientCredentialsToken/exchangeCode/refresh/introspect가 `#discover()`를 KeycloakAuthError 매핑 경계 밖에서 호출. `#discover`의 try/finally에 catch가 없고 `#runDiscovery`의 `oidc.discovery`도 무try. logout(fetch를 try/catch로 감쌈)과 비대칭.
- **실패**: 서버 다운 시 최초 `clientCredentialsToken()`이 `oidc.discovery`에서 raw `TypeError: fetch failed`를 던져 KeycloakError 미변환 누출. 재시도 분기가 매칭 실패(§4 위반). 8개 언어는 네트워크 없는 규약 조립이라 이 왕복 자체가 없음.
- **수정**: `#discover()`/`oidc.discovery`를 try/catch로 감싸 KeycloakTransportError로 변환.

---

## LOW (11건)

### 38. [Go] ExchangeCode가 nonce·id_token을 전혀 검증 안 함 (검증무시)
`go/auth.go:91` — CreateAuthorizationRequest가 nonce를 생성·전송하나 ExchangeCode는 nonce 인자를 받지 않고 id_token 서명·nonce를 검증 없이 원문 반환. Validate는 access token만 검증. nonce가 死값.
- **실패**: 다른 세션 id_token 재생을 감지 못 함. Node는 nonce 불일치를 'unexpected nonce'로 거부하나 Go는 보호 없음(PKCE+state 1차 방어는 작동).
- **수정**: ExchangeCode에 expectedNonce 추가해 id_token 서명검증 후 nonce 상수시간 비교.

### 39. [Go] JWKS fetch가 HTTP 상태 미검사 → 빈 keyset 캐시로 fail-closed
`go/jwt.go:172` — `Do` 후 `StatusCode`를 확인 않고 unmarshal. 4xx/5xx + keyless JSON(`{}`)이 성공 파싱되면 빈 keyset이 캐시(auth.go:171은 StatusCode≥400 검사하는데 jwt.go엔 없음).
- **실패**: 콜드 로드 순간 프록시가 `{}`를 반환하면 빈 keyset 캐시 → 이후 모든 kid 조회 실패, forcedAt stamp로 minRefetch(60s) 동안 정상 토큰까지 거부(엔드포인트 복구 후에도).
- **수정**: `StatusCode != 200`이면 TransportError, `len(Keys)==0`이면 캐시 안 함.

### 40. [.NET] AuthClient 네트워크 실패가 KeycloakAuthException으로 오분류 (21번 재기술)
`dotnet/.../AuthClient.cs:59` — 21번과 동일 클래스, 다른 앵커. timeout catch만 transport 처리, connect/DNS/TLS는 IsError로 흘러 AuthException.
- **수정**: 21번과 동일.

### 41. [PHP] JWKS 재조회 간격 60초 하드코딩 (하드코딩)
`php/src/Jwks/JwksStore.php:28` — 생성자 기본 60초가 KeycloakClient::create()에서 4번째 인자 미전달로 고정. KeycloakConfig에 필드 없음.
- **실패**: 60초 내 2회 키 회전 시 새 kid 정상 토큰이 최대 60초 거부(기본 KC 회전은 느려 발현 드묾).
- **수정**: KeycloakConfig에 jwksMinRefetchSeconds 추가.

### 42. [Rust] admin 토큰 획득 실패가 Auth가 아닌 Admin(Other{401})로 분류
`rust/src/admin.rs:35` — `SdkTokenSupplier::get`이 TokenProvider 오류를 `HttpFailure{401}`로 변환, map_admin이 `AdminError::Other{401}`로 매핑. oauth_error("invalid_client")가 구조적 소실.
- **실패**: 틀린 client_secret으로 `get_user(id)` → `AdminError::Other{401}`. `match { Auth => reconfigure() }`가 Admin 브랜치로 오라우팅.
- **수정**: admin 경계에서 401 특별 취급 또는 토큰 실패를 별도 채널로 표면화.

### 43. [Rust] expires_in 부재 시 토큰이 영구 유효로 캐시 (검증무시)
`rust/src/token_provider.rs:78` — `unwrap_or(0)` → `expires_at: None`. `is_expired`가 `None => false`라 무만료 판정.
- **실패**: `{"access_token":"AT"}`(expires_in 없음/문자열) 수신 → 서버측 AT 만료(~5분) 후에도 재발급 안 함 → 후속 admin 호출이 401, provider가 만료 신호를 인식 못 해 영구 미복구.
- **수정**: expires_in 부재 시 `Some(now)`(즉시 만료) 또는 보수적 기본 수명.

### 44. [Rust] 200 응답 access_token이 비-문자열이면 빈 토큰 성공 반환 (검증무시)
`rust/src/token_provider.rs:68` — 가드가 존재만 확인. `Some(Value::Null)`이 `.is_none()==false`라 통과, `as_str().unwrap_or_default()`가 `""` 생성.
- **실패**: `{"access_token":null,"expires_in":300}` 수신 → `Ok("")` 빈 베어러를 300초 캐시 → admin이 `Bearer `로 401, 근본원인 미표면화.
- **수정**: `and_then(as_str).filter(!empty).is_none()`로 강화, 실패를 명시 오류.

### 45. [Rust] 콜드 캐시 미해결 kid가 동일 JWKS를 2회 GET (효율성)
`rust/src/jwks.rs:86` — 초기 로드(L62)가 kid 미발견 시 fall-through해 gate 통과 후 L86에서 재 fetch. 마이크로초 차이라 동일 keyset.
- **실패**: 기동 직후 stale-kid/위조-kid 첫 요청이 `/certs`에 2회 GET(프로세스 수명당 콜드스타트 1회 한정).
- **수정**: 초기 fetch 후 kid 미발견 시 즉시 `unknown kid` 반환(L86 스킵).

### 46. [Kotlin] coverage omit된 auth.kt introspect-실패·null시크릿 분기 미실행
`kotlin/.../auth.kt:152` — AuthClient* Kover 제외. introspect 실패 분기(152-155)와 clientAuth null-시크릿 throw(276-280)가 단위·통합 미실행(refresh 실패 경로 주장은 부정확 — mapTokenResponse 공유로 커버됨).
- **수정**: introspect 오류응답 stub + clientSecret=null config 부정 테스트 추가.

### 47. [하네스] wait_healthy가 컨테이너 크래시 미감지 → 전체 타임아웃 대기 (효율성)
`harness/install/lib.sh:84` — curl 200만 폴링하고 컨테이너 State 미확인. rust는 2400s, kotlin 420s, java 300s.
- **실패**: consume 컨테이너가 app-boot 크래시로 exit해도 wait_healthy가 healthz를 40분(rust) 폴링 후 timeout(주장의 cargo-build-실패 예시는 run.sh가 sleep 3600으로 살려둬 부정확 — app-boot 종료 경로에서만 발현).
- **수정**: 폴링 루프에 `docker inspect .State.Running` false면 즉시 return.

### 48. [CI] php-ci 커버리지 게이트가 clover 통계 0일 때 100%로 fail-open (검증무시)
`.github/workflows/php-ci.yml:32` — `$p=$t? $c/$t*100:100`. clover statements=0(pcov 미로드·소스경로 드리프트)이면 100%로 통과. go-ci는 `awk exit(p<90)`로 fail-closed.
- **실패**: 커버리지가 측정조차 안 됐는데 'line coverage: 100.00%' exit 0. 90% 안전망 무력화.
- **수정**: `$t<=0`이면 exit 1(fail-closed).

---

## 강조 섹션 1 — 암묵적 검증무시 (6건)

사용자가 특별히 요청한 항목이다. "검사를 하는 척하지만 실제로는 통과시키는" 패턴:

| # | 위치 | 무엇을 무시하나 |
|---|---|---|
| 3 | node/jwt.ts:36 | `exp` 클레임 필수성 — 무만료 토큰 통과 |
| 33 | harness/security/probe.mjs:27 | 200≠응답을 전부 '방어'로 — 500 크래시가 보안 100점 |
| 38 | go/auth.go:91 | id_token nonce/서명 — OIDC 재생 방지 무효 |
| 43 | rust/token_provider.rs:78 | expires_in 부재 → 무만료 캐시 |
| 44 | rust/token_provider.rs:68 | access_token 타입 — 빈 토큰 성공 반환 |
| 48 | php-ci.yml:32 | 커버리지 통계 부재 → 100% fail-open |

가장 심각한 것은 3번(실제 인증 우회 표면)과 33·48(검증 인프라 자체가 fail-open이라 다른 결함을 은폐). 33번은 특히 위험하다 — 보안을 측정하는 도구가 크래시를 만점으로 세면 하드닝 회귀 전체가 보이지 않는다.

## 강조 섹션 2 — 하드코딩 (5건)

| # | 위치 | 하드코딩된 값 | 영향 |
|---|---|---|---|
| 11 | java AuthClient.java:39 | 알고리즘 RS256 | ES256/PS256 realm 토큰 전면 거부, 우회 불가 |
| 17 | node config.ts:49 | connectTimeoutMs 무배선 | 설정 수용하는 척, 조용히 무시 |
| 19 | go config.go:16 | ConnectTimeout 무배선 | 동일 — fail-fast 의도 무효 |
| 28 | ruby keycloak_sdk.rb:35 | 전역 타임아웃 10초 | Config 무시 + 프로세스 전역 오염 |
| 41 | php JwksStore.php:28 | 재조회 간격 60초 | 빠른 키회전 시 정상 토큰 거부 |

11번은 실제 인증 실패를 유발하는 유일한 correctness 결함이고, 17·19는 "받아들이는 척하는 no-op 노브"라는 동일 클래스(config 필드가 코드에 흐르지 않음). 28은 하드코딩 + 전역 상태 오염이 겹쳐 가장 파급이 크다.

---

## 오탐/재현불가 (16건)

전문 리뷰에서 반증되어 기각. 요점만:

- **오탐 15건**: (java) AuthClient omit 메타논증 — 현재 NPE 없음, '회귀 시' 가정법. (python) admin int() timeout — raw ValueError는 python-keycloak broad-catch가 KeycloakConnectionError로 흡수해 §4 유지. (node) RS256 핀 — index.ts가 AuthClient+JwtValidator를 공개 export해 오버라이드 가능, 9언어 동형 의도 설계. (node) users.search max=100 — Keycloak 서버 기본값 미러, 표준 페이지네이션. (node) alg=none 테스트 — 기존 ES256 핀 테스트가 동일 코드경로 커버. (go) scope() 분기 — 추적상 정확, 가정적 버그. (dotnet) ct 미전파 — 안정 API에 CancellationToken 오버로드가 애초에 없음. (dotnet) nonce fail-open — id_token 부재 시 nonce가 보호할 대상 자체가 없음(의미상 올바른 null-check). (dotnet) audience=clientId — 9언어 동형·스펙 §6.3·audience-confusion 방어. (dotnet) SearchAsync max=100 — 표준 페이징 동형. (dotnet) AuthClient omit — 현재 코드 정확, 가정적 회귀. (rust) 콜드 미해결-kid 2회 fetch — fetch#1은 rate-limit 면제 부트스트랩, one-shot. (rust) 60초 하드코딩 — config화해도 동일 거부창, 의도적 fail-closed 설계. (kotlin) admin close 순서 — 라이브러리가 close 전 readEntity로 서버 상세 보존. (harness) verify/install exit 0 — 비게이트 리포트 잡, PR 게이트는 mvp-go/run.sh가 정상 처리.

- **재현불가 1건**: (ruby) AuthClient#refresh 미검증 — 반증되지도 확정되지도 못함.

---

## 감사의 한계 (정직한 명시)

이 감사는 **전체 빌드·테스트를 실행하지 않은 정적 소스 + 라이브러리 소스 + 문서 기반 감사**다. 구체적으로:

- **확정 결함 48건도 실제 실행으로 재현하지 않았다.** 코드 경로 추적, 라이브러리 소스 직접 확인(`php/vendor/`, `.venv/`, `node_modules/`, nimbus/faraday/rack-oauth2 gem 소스), 테스트 본문 읽기로 논증했으나, 런타임에서 해당 예외가 실제로 그 타입으로 던져지는지·타이밍 창이 실제로 열리는지는 검증하지 않았다.
- **동시성 결함(18·26)**과 **rate-limit stamp 결함(5·6·20·25)**은 타이밍·경합에 의존하므로 실제 발현 빈도는 부하·배포모델에 따라 다르다.
- **CI 실행비트 결함(8·34·35·36)**은 `git ls-files -s` 트리 모드로 확인했으나 실제 러너 로그로 exit 126을 관측하지 못했다. Windows 로컬 워킹트리는 실행가능으로 보여 로컬 GREEN과 CI 실패가 갈릴 수 있다.
- **라이브러리 동작 단정**(Duende `FromException`, jose `requiredClaims`, RESTEasy `ProcessingException` 등)은 소스/디컴파일/공식 문서 근거이나 정확한 마이너 버전 거동은 실서버 왕복으로 재확인해야 한다.

따라서 각 결함은 **수정 착수 전 해당 실패 시나리오를 재현하는 실패 테스트를 먼저 작성**해 확정할 것을 권한다(특히 HIGH).

---

## 수정 착수 권장 순서

1. **검증 인프라 먼저 고친다 (7·8·9·33·34·35·48).** 나머지 46건을 고쳐도 회귀를 잡을 파이프라인이 죽어 있으면 무의미하다. suite 종료코드 반영 + security 프로브를 401로 좁히기 + 실행비트 4개 + php fail-closed. 이걸 먼저 해야 이후 수정의 테스트가 실제로 게이트한다.

2. **JWT 하드닝 실누수를 막는다 (3·4·5·6·25).** Node `exp` 필수 강제 + PHP JWKS stamp 결정시점 이동. 둘 다 인증 우회/DoS 증폭이라 실제 공격 표면이며 부정 테스트를 동반해 회귀 고정.

3. **전송오류 §4 경계를 언어 전반에서 통일한다 (1·13·16·37·21·23·40·22·24·39).** Java `ProcessingException`, Node admin+discovery, .NET IsError/JsonException 분기. 이미 Go가 문서화한 패턴을 나머지에 이식하고, 각 언어에 "서버 다운 → TransportException" 부정 테스트를 추가한다.

4. **하드코딩된 config 노브를 배선하거나 제거한다 (11·17·19·28·41).** 특히 Java RS256(실제 인증 실패)과 Ruby 전역 타임아웃(전역 상태 오염)을 우선. 배선 불가한 노브(node/go connectTimeout)는 필드를 제거해 "무시되는 API"라는 오해를 없앤다.

5. **동시성·자원누수·나머지 테스트 공백 (18·26·31·12·20·30·32·46).** Go 회전 경합·Rust 콜드스타트 herd·Kotlin 논-데몬 스레드 누수는 발현 조건이 좁으나 프로덕션 장기 실행에서 드러난다. 남은 test-quality 결함은 커버리지 omit 뒤에 숨은 부정 경로를 채워, 이미 올바른 코드가 회귀로 깨질 때 실제로 잡히도록 한다.