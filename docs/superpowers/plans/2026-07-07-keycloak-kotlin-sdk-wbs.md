# Keycloak Kotlin SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폴리글랏 Keycloak SDK의 9번째 언어 = Kotlin SDK를 §4 계약 동형으로 구현 — Java SDK의 3개 JVM 기반(keycloak-admin-client·Nimbus·nimbus-jose-jwt) 재사용 + 코루틴(suspend)·data class·sealed 예외 Kotlin 관용, 자체강화 JWT, 단위 + 실 Keycloak 26.6 Testcontainers 통합테스트, Kover 커버리지 게이트·ktlint.

**Architecture:** 단일 Gradle 모듈, Kotlin 패키지로 계층 분리(config→errors→tokens→oidc→tokenprovider→jwt→auth→admin→client). 모든 네트워크 메서드 suspend(`runInterruptible(Dispatchers.IO)`). admin↔auth는 TokenProvider(suspend)로만 접착.

**Tech Stack:** Kotlin 2.2.20 · Gradle 9.5.0(wrapper) · JDK 21 · kotlinx-coroutines 1.11.0 · vanniktech maven.publish 0.37.0 · Kover 0.9.8 · ktlint 14.2.0 · JUnit 6.1.1 + kotlin.test + MockK 1.14.4 + WireMock 3.13.2 + Testcontainers 2.0.5 + dasniko testcontainers-keycloak 4.2.1.

## Global Constraints

- **정확한 코드·설정 권위 소스**: [docs/superpowers/specs/2026-07-07-keycloak-kotlin-sdk-research.md](../specs/2026-07-07-keycloak-kotlin-sdk-research.md)(리서치 부록). 각 태스크는 이 부록의 해당 절을 진실로 삼는다. 설계: [keycloak-kotlin-sdk-design.md](../specs/2026-07-07-keycloak-kotlin-sdk-design.md). 하드닝 불변식은 [Java 검증로그](../../governance/verification-log.md) 상속.
- **패키지**: 전 소스 `io.github.xzawed.keycloak`(admin은 `.admin`). `explicitApi()` — 모든 public 선언 가시성·반환타입 명시(Task 1부터).
- **코루틴 계약**: 네트워크 메서드 = `suspend`, 블로킹 Java 호출은 `runInterruptible(Dispatchers.IO){ }`로 감쌈. **`CancellationException` 최우선 재던지기**. 내부 CoroutineScope·`runBlocking` 금지(호출자/테스트/예제만). single-flight = 코루틴 `Mutex.withLock`. `close()`는 non-suspend.
- **값 좌표**: version 0.1.0 · groupId io.github.xzawed · artifactId keycloak-sdk-kotlin.
- **보안**: 시크릿/토큰 마스킹(`***`·접두 노출 없음)·TLS 기본·JWT 자체강화(RS256 핀·none 거부·iss 정확일치·aud 포함·exp 필수·클록스큐·DoS-safe JWKS)·**exactMatchClaims엔 issuer만**.
- **예외 경계변환**: 하위 오류(`jakarta.ws.rs.*`·Nimbus `ParseException`·`IOException`)는 경계에서 sealed `KeycloakException`으로 변환 — 공개 API로 누출 금지. representation(`org.keycloak.representations.idm.*`)·저수준 주입점만 노출(Java 동형).
- **커버리지 게이트**: 로직 모듈 라인≥90/브랜치≥85(Kover), 네트워크 경계 `AuthClient`/`admin.*`/`KeycloakClient` omit(통합테스트로 검증).
- **툴체인(빌드 명령·인라인 환경)**: `export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH"` 후 `gradle -p kotlin <task>`(초기) 또는 `kotlin/gradlew`(wrapper 생성 후). 단위 `gradle -p kotlin test`·커버리지 `gradle -p kotlin koverVerify`·린트 `gradle -p kotlin ktlintCheck`·통합 `gradle -p kotlin integrationTest`(Docker).
- **커밋**: 각 태스크 끝. 브랜치 `feature/kotlin-sdk`. 메시지 `feat(kotlin):`/`chore(kotlin):`/`test(kotlin):`/`docs(kotlin):`.

---

## File Structure

```
kotlin/
├─ settings.gradle.kts         # foojay-resolver 1.0.0 · rootProject keycloak-sdk-kotlin
├─ build.gradle.kts            # 부록 §build.gradle.kts 그대로
├─ gradle.properties           # org.gradle.jvmargs 등
├─ gradle/wrapper/gradle-wrapper.properties   # distributionUrl gradle-9.5.0-bin.zip
├─ gradlew · gradlew.bat · gradle/wrapper/gradle-wrapper.jar
├─ LICENSE                     # Apache-2.0
├─ src/main/kotlin/io/github/xzawed/keycloak/
│  ├─ masking.kt · errors.kt · config.kt · tokens.kt · oidc.kt · tokenprovider.kt
│  ├─ jwt.kt · auth.kt · admin/AdminClient.kt(+Users/Clients/Realms/Roles/Groups.kt) · client.kt
├─ src/test/kotlin/io/github/xzawed/keycloak/…   # 단위(runTest·MockK·WireMock)
├─ src/integrationTest/kotlin/…                  # Testcontainers E2E(별도 소스셋)
│  └─ resources/it-realm-realm.json              # Java/기타 SDK 재사용
└─ examples/quickstart.kt
```

---

## Task 1: Gradle 스캐폴딩 + 빈 빌드 GREEN

**Files:** Create `kotlin/settings.gradle.kts`·`build.gradle.kts`·`gradle.properties`·`gradle/wrapper/gradle-wrapper.properties`·`gradlew`(+.bat·wrapper.jar)·`LICENSE`·`.gitignore`·`src/main/kotlin/io/github/xzawed/keycloak/.gitkeep`.

**Interfaces:** Produces: 컴파일되는 빈 Gradle 프로젝트(플러그인·의존성·toolchain·explicitApi·Kover/ktlint 배선).

- [ ] **Step 1: build.gradle.kts + settings + wrapper** — 부록 §build.gradle.kts 그대로(plugins·group/version·`kotlin{jvmToolchain(21);explicitApi()}`·dependencies·`tasks.test{useJUnitPlatform()}`·mavenPublishing·kover). settings에 foojay-resolver 1.0.0. wrapper distributionUrl `gradle-9.5.0-bin.zip`.
- [ ] **Step 2: wrapper 생성** — Run: `export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH"; gradle -p kotlin wrapper --gradle-version 9.5.0`. `kotlin/gradlew` 생성 확인.
- [ ] **Step 3: LICENSE(Apache-2.0) + .gitignore**(`.gradle/`·`build/`·`kotlin/build/`).
- [ ] **Step 4: 빈 빌드 검증** — Run: `gradle -p kotlin build -x test`. Expected: BUILD SUCCESSFUL(빈 소스 컴파일·플러그인 해석). ktlint/kover 태스크 존재 확인 `gradle -p kotlin tasks --all | grep -E 'koverVerify|ktlintCheck'`.
- [ ] **Step 5: 커밋** — `git add kotlin && git commit -m "chore(kotlin): Gradle 스캐폴딩(2.2.20·JDK21·explicitApi·kover·ktlint) + 빈 빌드 GREEN"`.

---

## Task 2: errors + masking (sealed 계층)

**Files:** Create `src/main/kotlin/io/github/xzawed/keycloak/errors.kt`·`masking.kt`; Test `src/test/.../MaskingTest.kt`·`ErrorsTest.kt`.

**Interfaces:** Produces: `sealed KeycloakException` 계층(부록 §errors.kt 그대로) + `internal mask(CharArray?)/mask(String?)`.

- [ ] **Step 1: 실패 테스트** — `MaskingTest`: `mask(null)==""`·`mask("x".toCharArray())=="***"`·`mask("")==""`. `ErrorsTest`: `KeycloakAdminException.NotFound(404,"x")` is `KeycloakAdminException` is `KeycloakException`·status/keycloakError 보유·`Other(500,...)` 인스턴스화 가능(sealed 리프). Run(FAIL): `gradle -p kotlin test --tests "*MaskingTest" --tests "*ErrorsTest"`.
- [ ] **Step 2: 구현** — `masking.kt`·`errors.kt`(부록 §errors.kt·§masking.kt 그대로 — sealed 전부 한 파일). `explicitApi` 통과(전 public 명시).
- [ ] **Step 3: 통과** — Run: 위 테스트 GREEN.
- [ ] **Step 4: 커밋** — `feat(kotlin): errors(sealed KeycloakException 계층) + masking`.

---

## Task 3: config

**Files:** Create `config.kt`; Test `ConfigTest.kt`. **Interfaces:** `KeycloakConfig`(부록 §config 그대로 — 일반 class·named-arg·init 검증·trimEnd·CharArray 방어복사·toString 마스킹).

- [ ] **Step 1: 실패 테스트** — 빈 serverUrl/realm/clientId → `KeycloakConfigException`·`serverUrl` trailing slash 제거·`toString`에 clientSecret `***`·`clientSecret` getter가 방어복사(반환 배열 변경이 내부 미반영)·기본 타임아웃/스큐. Run(FAIL).
- [ ] **Step 2: 구현** — 부록 §config.kt 그대로.
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): KeycloakConfig(불변·검증·마스킹·CharArray 방어복사)`.

---

## Task 4: tokens + oidc

**Files:** Create `tokens.kt`·`oidc.kt`; Test `TokensTest.kt`·`OidcTest.kt`. **Interfaces:** `data class` TokenSet(isExpired)/ValidatedToken/IntrospectionResult/AuthorizationRequest(부록 §tokens 그대로·toString 마스킹) + `OidcEndpoints`(엔드포인트 조립·네트워크 없음).

- [ ] **Step 1: 실패 테스트** — TokenSet.toString에 accessToken `***`·refreshToken 마스킹·`isExpired`(null=만료·skew 경계)·AuthorizationRequest.toString codeVerifier `***`·OidcEndpoints가 serverUrl+realm으로 token/auth/introspect/logout/certs URL 조립. Run(FAIL).
- [ ] **Step 2: 구현** — 부록 §tokens.kt + oidc(Java `OidcEndpoints` 동형 — `{server}/realms/{realm}/protocol/openid-connect/{token,auth,...}`).
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): 값타입(TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest·마스킹) + OidcEndpoints`.

---

## Task 5: tokenprovider

**Files:** Create `tokenprovider.kt`; Test `TokenProviderTest.kt`(MockK·runTest). **Interfaces:** `TokenProvider`(suspend interface — ⚠️ `fun interface`+suspend 컴파일 여부 실측·불가 시 일반 interface+invoke 팩토리) + `ClientCredentialsTokenProvider`(부록 §coroutines/auth-admin 그대로·Mutex 캐시·single-flight).

- [ ] **Step 1: 실패 테스트(runTest)** — `coEvery { auth.clientCredentialsToken() } returns ...`; 첫 호출이 발급·둘째는 캐시(만료 전) `coVerify(exactly=1)`·만료 후 재발급·동시 호출 single-flight(하나만 발급). Run(FAIL): `gradle -p kotlin test --tests "*TokenProviderTest"`.
- [ ] **Step 2: 구현** — 부록 그대로. `fun interface` 컴파일 검증(불가 시 폴백·부록 게차).
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): TokenProvider(suspend) + ClientCredentialsTokenProvider(Mutex 캐시·single-flight)`.

---

## Task 6: jwt (JwtValidator — 보안 핵심)

**Files:** Create `jwt.kt`; Test `JwtValidatorTest.kt`(runTest·RSA 키픽스처·공격 프로브). **Interfaces:** `JwtValidator`(부록 §jwt 그대로 — `validate()` suspend·`forRealm()`/`withStaticJwks()`·RS256 핀·none 거부·iss 정확일치·aud 포함·exp 필수·클록스큐·DoS-safe JWKS·exactMatchClaims issuer-only).

- [ ] **Step 1: 실패 테스트(runTest·다수)** — RSA 키쌍 생성(nimbus `RSAKeyGenerator`)·정상 토큰 validate 성공(subject/issuer/audience)·**공격 프로브 전부 `assertFailsWith<TokenValidationException>`**: alg=none·HS256(대칭)·RS/HS confusion(공개키를 HMAC 비밀로)·미지 kid·malformed·exp 없음·만료(클록스큐 경계)·iss 불일치·aud 미포함. Java `JwtValidatorTest` 프로브 동형. Run(FAIL).
- [ ] **Step 2: 구현** — 부록 §jwt.kt 그대로. `withStaticJwks`(테스트 주입)·`forRealm`(실 JWKS).
- [ ] **Step 3: 통과 + 커버리지** — Run: `gradle -p kotlin test --tests "*JwtValidatorTest"` GREEN. jwt.kt 커버 라인≥90.
- [ ] **Step 4: 커밋** — `feat(kotlin): JwtValidator(nimbus 자체강화·suspend·DoS-safe JWKS·공격 프로브)`.

> ⚠️ 보안 핵심 — 완료 후 opus 어드버서리얼 리뷰(alg/confusion/JWKS DoS/클록스큐/exactMatch issuer-only) 대상.

---

## Task 7: auth (AuthClient)

**Files:** Create `auth.kt`; Test `AuthClientTest.kt`(WireMock·runTest — 네트워크 경계라 커버 omit이나 핵심 로직 검증). **Interfaces:** `AuthClient`(Nimbus 래핑 — client-credentials·PKCE authorization-code(`createAuthorizationRequest`·`exchangeCode`+nonce)·introspect·logout·refresh·`validate`). 부록 §auth 그대로(runInterruptible·경계변환·applyTimeouts·scope threading).

- [ ] **Step 1: WireMock 테스트** — token 엔드포인트 목으로 client-credentials 성공/OAuth 에러(→`KeycloakAuthException`)·연결실패(→`KeycloakTransportException`)·PKCE authorization URL에 S256 code_challenge·state/nonce·introspect active·`AuthClient : TokenProvider`(있다면). Run.
- [ ] **Step 2: 구현** — 부록 §auth. PKCE는 Java 동형(code_verifier/challenge S256 생성)·`exchangeCode`는 nonce 전달(Node HIGH 교훈).
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): AuthClient(Nimbus 래핑·PKCE S256·introspect/logout/refresh·경계변환)`.

---

## Task 8: admin (AdminClient + 5 리소스)

**Files:** Create `admin/AdminClient.kt`·`admin/Users.kt`·`Clients.kt`·`Realms.kt`·`Roles.kt`·`Groups.kt`; Test `admin/AdminBoundaryTest.kt`(경계변환 단위). **Interfaces:** `AdminClient`(keycloak-admin-client 래핑·`KeycloakBuilder.grantType(CLIENT_CREDENTIALS)`·resteasyClient 타임아웃·5리소스 CRUD suspend·`raw()`·부록 §auth-admin 경계변환).

- [ ] **Step 1: 경계변환 테스트** — `adminCall{ throw WebApplicationException(404 Response) }` → `KeycloakNotFoundException`·409→Conflict·403→Forbidden·500→Other·`ProcessingException`→Transport·`CancellationException` 재throw. (MockK로 keycloak 스텁 or WebApplicationException 직접.) Run.
- [ ] **Step 2: 구현** — 부록 §auth-admin(AdminClient·adminCall·createUser(Location→id)·deleteUser(status 검사)). 5리소스 각 CRUD + `raw()`(escape hatch). representation은 `org.keycloak.representations.idm.*` 노출.
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): AdminClient(keycloak-admin-client 래핑·5리소스 suspend·경계변환·raw)`.

---

## Task 9: client 파사드

**Files:** Create `client.kt`; Test `ClientTest.kt`. **Interfaces:** `KeycloakClient`(부록 §kotlin-idioms 파사드 — auth 즉시·admin 지연 Lazy·AutoCloseable·`create()`가 admin에 전용 ClientCredentialsTokenProvider 주입).

- [ ] **Step 1: 테스트** — `create(cfg)`가 auth 즉시·admin 미초기화(`adminLazy.isInitialized()==false`)·admin 접근 시 초기화·`close()`가 auth 정리·admin 미초기화면 강제생성 안 함·`.use{}` 동작. Run.
- [ ] **Step 2: 구현** — 부록 §파사드 그대로. admin에 무캐시 AuthClient 직접주입 금지(전용 provider — Rust 교훈).
- [ ] **Step 3: 통과 + 커밋** — `feat(kotlin): KeycloakClient 파사드(auth 즉시·admin 지연·AutoCloseable·전용 provider)`.

---

## Task 10: 통합테스트(Testcontainers E2E) + examples

**Files:** Create `src/integrationTest/kotlin/.../FullFlowIT.kt`·`src/integrationTest/resources/it-realm-realm.json`(Java 재사용)·`examples/quickstart.kt`; Modify `build.gradle.kts`(integrationTest 소스셋·태스크). **Interfaces:** E2E `full_flow`(client-credentials→validate→introspect→user/client/role/group CRUD→realm CRUD[master-admin]→raw→delete→NotFound).

- [ ] **Step 1: integrationTest 소스셋** — build.gradle.kts에 별도 소스셋·`integrationTest` 태스크(useJUnitPlatform·testcontainers). realm json은 다른 SDK testdata 재사용.
- [ ] **Step 2: FullFlowIT(runBlocking)** — dasniko KeycloakContainer(26.6)·전 흐름. Run(Docker): `gradle -p kotlin integrationTest`.
- [ ] **Step 3: examples/quickstart.kt** — client-credentials→validate→admin user 생성(runBlocking main).
- [ ] **Step 4: 통과 + 커밋** — `test(kotlin): Testcontainers E2E full_flow(실 KC 26.6) + quickstart 예제`.

---

## Task 11: 커버리지 게이트 + CI/release

**Files:** Create `.github/workflows/kotlin-release.yml`·(CI 검증은 기존 워크플로에 kotlin 잡 or 신규); Modify `build.gradle.kts`(kover excludes 최종). **Interfaces:** `kotlin-v*` 태그 → publishToMavenCentral(사람 게이트) + CI build/koverVerify/ktlintCheck.

- [ ] **Step 1: kover 게이트 검증** — Run: `gradle -p kotlin koverVerify`(로직모듈 라인≥90/브랜치≥85·경계 omit). 실측 커버리지 확인.
- [ ] **Step 2: ktlint** — Run: `gradle -p kotlin ktlintCheck`(무경고·필요시 ktlintFormat).
- [ ] **Step 3: release.yml** — 부록 §CI 시크릿(ORG_GRADLE_PROJECT_ mavenCentral*·signingInMemoryKey*)·`kotlin-v*` 트리거·`./gradlew publishToMavenCentral`(Portal 수동 release). CI 검증 잡(build+koverVerify+ktlintCheck+integrationTest).
- [ ] **Step 4: YAML 검증 + 커밋** — actionlint/yaml 파싱. `ci(kotlin): Maven Central 릴리스(kotlin-v*·in-memory GPG) + 검증 잡 + kover 게이트`.

---

## Task 12: 검증로그 문서

**Files:** Create `docs/governance/verification-log-kotlin.md`. **Interfaces:** 태스크별 게이트 통과 이력(Java/기타 검증로그 동형).

- [ ] **Step 1: 검증로그** — 테스트 수(단위 N + 통합 1 E2E)·커버리지 실측·게차(KGP↔Gradle·fun-interface·CancellationException·exactMatch issuer-only·Central Portal 소유권)·G1~G6 게이트.
- [ ] **Step 2: 커밋** — `docs(kotlin): verification-log-kotlin(게이트 이력·게차)`.

> ⚠️ CLAUDE.md/README/roadmap/DEPLOY.md 전역 문서 최신화는 **병합 후** 전역 규칙으로(이 브랜치 밖).

---

## Self-Review (작성자 체크)

- **스펙 커버리지**: 설계 §2(빌드)→T1·T11. §3(코루틴)→전 네트워크 태스크. §4(계층)→T2(errors)·T3(config)·T4(tokens/oidc)·T5(tokenprovider)·T6(jwt)·T7(auth)·T8(admin)·T9(client). §5(테스트)→각 태스크 TDD+T10. §7(CI)→T11. 커버 완료.
- **placeholder**: 각 태스크가 부록 절 참조 + 핵심 인터페이스 인라인. 부록이 정확 코드 담체.
- **타입 정합**: 신호 없음(SDK). 값타입/예외/TokenProvider 시그니처는 부록에서 고정, 전 태스크 동일 참조.
- **의존 순서**: T1(스캐폴딩)→T2(errors)→T3(config)→T4(tokens)→T5(tokenprovider)→T6(jwt)→T7(auth)→T8(admin)→T9(client)→T10(통합)→T11(CI)→T12(문서). 하위→상위 계층 순.
