# 검증 로그 — Kotlin SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Kotlin SDK(`io.github.xzawed:keycloak-sdk-kotlin`, Maven Central) 태스크별 정량 검증 기록. 브랜치 `feature/kotlin-sdk`(아직 `main` 미병합, PR 예정). 9번째 언어 — JVM 자매 언어인 Java SDK의 검증된 라이브러리 스택을 **코루틴 관용**으로 재래핑한다.

**툴체인**: JDK 21(Eclipse Temurin `jdk-21.0.8.9-hotspot`) + 포터블 Gradle `9.6.1`(로컬) / 래퍼 핀 `9.5.0`(CI·재현성). 명령은 `kotlin/`에서 `./gradlew`(래퍼) 또는 로컬 `gradle -p kotlin <task>`:
- 빌드: `gradle -p kotlin build` · 단위테스트: `gradle -p kotlin test`(Docker 불필요) · 통합 E2E: `gradle -p kotlin integrationTest`(Docker 필요 — Testcontainers, 실 Keycloak 26.6)
- 커버리지 게이트: `gradle -p kotlin koverVerify`(로직 모듈 라인≥90%/브랜치≥85%·네트워크 경계 omit) · 린트: `gradle -p kotlin ktlintCheck`(무경고·필요시 `ktlintFormat`)
- 빌드 프리픽스: `export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="/c/Users/dirtc/.gradle"`

**게이트**: G1 정적분석/스타일(`ktlintCheck` 무경고·`explicitApi()` public API 엄격) · G2 단위테스트(`gradle test`) · G3 커버리지(Kover — 네트워크 경계 `AuthClient*`/`admin.*`/`KeycloakClient*` omit, 로직 모듈 라인≥90%/브랜치≥85%) · G4 스펙리뷰(§4 언어중립 계약과의 동형성·특히 Java SDK와의 동형) · G5 교차검증(태스크별 리뷰 루프 + Task 6 보안 어드버서리얼 리뷰 + 최종 whole-branch 리뷰) · G6 보안(JWT 강화·JWKS DoS-safe·마스킹·경계 예외변환·구조적 동시성 CancellationException 재던지기).

> **실행 방식**: brainstorming(설계 승인) → 딥리서치(6 에이전트·high) → 스펙+부록 커밋 → 승인된 WBS(12태스크: scaffold → errors → config → tokens/oidc → tokenprovider → jwt → auth → admin → client → integration → CI → docs) → subagent-driven(구현자+리뷰어 per task) TDD + 계층별 커밋 + 태스크 직후 리뷰 루프. Task 6(JwtValidator, 보안핵심)은 19개 공격 프로브 + opus 어드버서리얼 리뷰(SECURE 판정), Task 8+9는 묶음 리뷰, Task 11은 릴리스 보안 리뷰.

---

## 딥리서치 (착수 전) — 라이브러리 API 확정

설계 스펙([2026-07-07-keycloak-kotlin-sdk-design.md](../superpowers/specs/2026-07-07-keycloak-kotlin-sdk-design.md))·리서치 부록([2026-07-07-keycloak-kotlin-sdk-research.md](../superpowers/specs/2026-07-07-keycloak-kotlin-sdk-research.md)) 단계에서 6개 병렬 에이전트로 아래를 **확정**(구현 중 재확인 불필요):

- **JVM 라이브러리 재사용**(Java SDK 검증 스택 그대로): `org.keycloak:keycloak-admin-client` **26.0.10**(admin·representation 노출 → `api`; 현재 **26.0.11** — PR #84에서 JacksonProvider 등록 정정과 함께 전진) · `com.nimbusds:oauth2-oidc-sdk` **11.37.2**(auth) · `com.nimbusds:nimbus-jose-jwt` **10.9.1**(JWT 검증 프리미티브). Java SDK가 이미 실 Keycloak으로 필드까지 검증한 스택이라 신규 라이브러리 리스크 0 — 차이는 **코루틴 관용 래핑**뿐.
- **코루틴 경계**: 모든 네트워크 메서드는 `suspend`, 블로킹 라이브러리 호출은 `runInterruptible(Dispatchers.IO) { … }`(= `onIo` 헬퍼)로 옮겨 취소 협조(cancellation)를 보장한다. `kotlinx-coroutines-core` **1.11.0**(공개 `suspend` 노출 → `api`).
- **⚠️ `fun interface` + `suspend` 컴파일 여부**(KT-40978): 과거 Kotlin은 SAM 변환 함수형 인터페이스의 추상 멤버가 `suspend`면 컴파일 거부했으나 **2.2.20에서 해소됨을 실증** — `TokenProvider`를 `public fun interface TokenProvider { public suspend fun accessToken(): String }`로 선언 가능.
- **빌드 스택**: Kotlin **2.2.20** · vanniktech maven.publish **0.37.0**(Central Portal 표준 — signing+sources+Dokka javadoc jar·in-memory GPG) · Kover **0.9.8**(커버리지 게이트) · ktlint gradle plugin **14.2.0** · Dokka **2.2.0**. ⚠️ KGP↔Gradle 호환 밴드를 위해 래퍼는 9.5.0 핀(2.2.20 KGP 지원 범위).
- **JWT 강화 불변식**([Java 검증로그](verification-log.md) 상속): RS256 핀·`none` 거부(헤더 alg 불신)·iss 정확일치(`exactMatchClaims` issuer만)·aud 포함검사·`exp` 필수·클록 스큐(기본 30초)·DoS-safe JWKS(Nimbus `JWKSourceBuilder` 캐시+RateLimited). Nimbus는 building block만 제공하고 안전한 기본값을 주지 않으므로 전부 명시 재정의.

---

## 계층별 구현 (Task 1~12)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. subagent-driven(구현자+리뷰어). G1(ktlint/explicitApi)·G2(테스트)·G3(커버) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 0 | `2c95617`·`6a579b1` | 설계 스펙 + 리서치 부록 + WBS(12태스크) | — | — | — |
| 1 | `bf38670`·`021e4cf` | Gradle 스캐폴딩(2.2.20·JDK21·`explicitApi()`·kover·ktlint·vanniktech·빈 빌드 GREEN) | ✅ | — | — |
| 2 | `ed385ed`·`5e1af99` | errors(sealed `KeycloakException` 계층) + masking + `.editorconfig`(ktlint filename 규칙 비활성) | ✅ | ✅ | ✅ |
| 3 | `a239117` | `KeycloakConfig`(불변·검증·후행슬래시 제거·`CharArray` 방어복사·`toString` 마스킹) | ✅ | ✅ | ✅ |
| 4 | `163fc8c` | 값타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`·마스킹) + `OidcEndpoints`(네트워크 없음) | ✅ | ✅ | ✅ |
| 5 | `b66d316` | `TokenProvider`(`fun interface`·suspend) + `ClientCredentialsTokenProvider`(@Volatile 캐시·Mutex single-flight·fetch 디커플) | ✅ | ✅ | ✅ |
| 6 | `4771cca`·`138bfec` | `JwtValidator`(Nimbus 자체강화·suspend·DoS-safe JWKS·19 공격 프로브) — **opus 어드버서리얼 리뷰 SECURE** | ✅ | ✅ | ✅ |
| 7 | `a88564b` | `AuthClient`(Nimbus 래핑·PKCE S256·client-credentials/exchangeCode/introspect/logout/refresh/validate·경계변환) | ✅ | ✅ | ✅ |
| 8 | `1976abb`·`378af3d` | `AdminClient`(keycloak-admin-client 래핑·`KeycloakBuilder` client-credentials·resteasy 타임아웃·5리소스 suspend CRUD·`raw`·`adminCall` 경계변환) | ✅ | ✅ | ✅ |
| 9 | `44f27fa` | `KeycloakClient` 파사드(auth 즉시·admin 지연 `Lazy` SYNCHRONIZED·`AutoCloseable`·전용 provider seam) — **T8+T9 묶음 리뷰 Approved** | ✅ | ✅ | ✅ |
| 10 | `e38c08b`·`4b4c0cd` | Testcontainers E2E `FullFlowIT`(실 KC 26.6·전 흐름) + `examples/quickstart.kt` — **실행가능화 4대 fix**(아래 게차) | ✅ | ✅ | ✅ |
| 11 | `6727597` | CI/release(`kotlin-ci.yml` build-test+integration · `kotlin-release.yml` `kotlin-v*`→verify→publish·in-memory GPG) — 리뷰 Approved | ✅ | ✅ | ✅ |
| 12 | (이 문서) | verification-log-kotlin | — | — | — |

## 테스트·커버리지 실측

- **단위테스트 100개**(10 클래스: `ConfigTest`·`ErrorsTest`·`MaskingTest`·`TokensTest`·`OidcTest`·`TokenProviderTest`·`JwtValidatorTest`·`AuthClientTest`·`admin.AdminBoundaryTest`·`ClientTest`) + **통합 E2E 1개**(`FullFlowIT` — client-credentials→validate→introspect→user/client/role/group CRUD→NotFound→realm get→403 forbidden→raw→master-admin realm CRUD) = **총 101개 GREEN**.
- **커버리지(Kover, 네트워크 경계 omit)**: **라인 131/132 = 99.24%** · **브랜치 36/42 = 85.71%** · 명령 764/774 = 98.71%. 게이트(라인≥90%/브랜치≥85%) **통과**. omit 대상은 `AuthClient*`·`admin.*`·`KeycloakClient*`(네트워크 경계 — 통합 E2E로 검증).
- **린트**: `ktlintCheck` 무경고. `explicitApi()`로 public API 가시성 엄격 강제.

---

## 핵심 게차 (Gotchas) — Kotlin 고유

Java SDK의 게차(admin-client 버전 ≠ 서버 버전·JWT 강화 필수·admin 타임아웃 주입 등)를 상속하되, Kotlin/Gradle 툴체인 고유 이슈가 추가됐다:

- ⚠️ **`fun interface` + `suspend`는 Kotlin 2.2.20에서 컴파일된다(KT-40978 해소).** `TokenProvider`를 SAM 변환 가능한 함수형 인터페이스로 선언(`public fun interface TokenProvider { public suspend fun accessToken(): String }`) — 과거 버전에서 거부됐던 조합이 실증적으로 통과.
- ⚠️ **ktlint filename 규칙은 이 모노레포와 충돌한다.** 언어 공통으로 소문자 다중선언 파일(`errors.kt`·`masking.kt`·`tokens.kt`·`client.kt` 등)을 쓰는데 ktlint의 "단일/다중 선언 파일은 PascalCase" 요구는 자동수정 불가라 `kotlin/.editorconfig`의 `ktlint_standard_filename = disabled`로 비활성한다. 나머지 포매팅은 `ktlintFormat`이 자동정렬(커밋 전 실행) + `ktlintCheck`로 게이트.
- ⚠️ **`gradle --stop`을 빌드 인플라이트 중에 실행하면 진행 중 빌드를 죽인다.** `--no-daemon`도 jvmargs(-Xmx2g) 때문에 단일-사용 데몬을 fork하므로 `--stop`이 그 데몬을 죽여 "stop command received"로 실패한다(테스트 실패로 오인). **빌드 중 `--stop` 금지·동일 프로젝트에 gradle 2개 동시실행 금지**(락 경합). kill 후 stale build 상태는 `NoClassDefFoundError`(람다 `$1` 클래스)를 유발 → `gradle -p kotlin clean`으로 복구.
- ⚠️ **MockK로 JAX-RS 추상 클래스(`jakarta.ws.rs.core.Response`·`WebApplicationException`)를 모킹하면 JDK 21에서 무기한 hang한다(Task 8).** byte-buddy가 RESTEasy 구현 클래스 그래프를 계측하다 멈춘다(단일 테스트도 2.5분 타임아웃 실측 — "non-final이라 서브클래싱 안전"은 오판). `AdminBoundaryTest`는 **실객체**로 재작성한다: `WebApplicationException(message, status)`(내부에서 `Response.status().build()` 생성)·`Response.status(500).entity("body").build()`(outbound String entity는 `readEntity`가 그대로 반환 — entity-read 성공 경로)·`object : WebApplicationException(){ override fun getResponse()=null }`(익명 서브클래스로 null-response 재현). `UsersResource` 등 **인터페이스**는 MockK 프록시가 가벼워 안전(계측 hang 무관).
- ⚠️ **코루틴 스택트레이스 복구가 예외 identity를 보존하지 않는다(Task 8).** `kotlinx.coroutines`는 suspend 경계를 넘는 예외를 (동일 정보의) 새 인스턴스로 복사하므로 `ProcessingException` 원인 검증에 `assertSame`이 아니라 `assertIs<ProcessingException>` + message 비교를 쓴다.
- ⚠️ **Kover 0.9.x는 와일드카드 없는 정확 클래스명 exclude를 적용하지 않는다(Task 8).** `"AuthClient"` 정확명은 무시돼 브랜치 집계에 섞였다(브랜치 81.25%로 하락) → 네트워크 경계 클래스는 전부 `*` 접미(`AuthClient*`/`KeycloakClient*`/`admin.*`)로 지정한다. `…*`는 클래스 본체 + 파일-레벨 top-level 함수 클래스(`…Kt`)까지 포함.
- ⚠️ **jvm-test-suite 없이 수동 `creating` 소스셋으로 integrationTest를 만들면 "no tests discovered"로 실패한다(Task 10).** 수동 소스셋의 `compileClasspath +=`/`runtimeClasspath +=` 오버라이드가 Kotlin 컴파일 출력을 소스셋 `output.classesDirs`에 등록하지 못해, 컴파일된 `FullFlowIT.class`가 Test 태스크의 `testClassesDirs`에 안 잡힌다. Gradle 표준 **`jvm-test-suite`**(`testing { suites { register<JvmTestSuite> } }`)로 전환하면 소스셋·Kotlin 컴파일·Test 태스크·JUnit Platform·resources를 정합 배선한다. 스위트 `dependencies` 블록엔 `kotlin("test")` 헬퍼가 없어 `kotlin.test.Test` typealias(→`org.junit.jupiter.api.Test`)를 제공하는 **`kotlin-test-junit5`** 좌표를 명시해야 한다(plain `kotlin-test`는 assertions만 — 단위 `test`는 Kotlin 플러그인의 variant-aware 해석이 junit5 변형을 자동 선택하나 스위트엔 그 해석이 없음).
- ⚠️ **`= runBlocking { … }` 표현식-본문 @Test 메서드는 JUnit Jupiter가 발견하지 못한다(Task 10).** `runBlocking`은 블록의 **결과 타입 T**를 반환하므로, 블록 마지막 식이 non-Unit이면 메서드가 non-void가 되고 Jupiter는 non-void 메서드를 `@Test`로 인식하지 않는다. **`: Unit` 반환 타입을 명시**해 블록을 `-> Unit`으로 만들고 void 바이트코드로 컴파일한다. (단위테스트가 `= runTest { … }`로 무사한 건 JVM에서 `runTest`가 이미 Unit을 반환하기 때문.)
- ⚠️ **Kover 0.9.x는 jvm-test-suite로 등록된 integrationTest를 자동 계측 대상에 포함한다(Task 10).** 그 결과 (1) 테스트 클래스 `FullFlowIT`가 커버리지 subject로 집계되고 태스크 미실행 시 0% covered로 잡혀 총계가 붕괴(라인 51%/브랜치 69% 실측), (2) `koverVerify`가 `integrationTest`를 태스크 그래프로 끌어들여 Docker 없는 단위 CI 게이트가 파손된다. **두 조치 모두 필요**: `currentProject.instrumentation.disabledForTestTasks.add("integrationTest")`(계측 끄고 Kover 리포트가 이 태스크를 트리거하는 것도 방지) + `currentProject.sources.excludedSourceSets.add("integrationTest")`(소스셋을 subject 집합에서 제외). 이전 수동 소스셋은 Kover가 몰라 이 조정이 불필요했다.
- ⚠️ **exchangeCode는 id_token을 nonce 비교 전에 완전 서명 검증한다(Java보다 강함).** `AuthClient.exchangeCode`는 SDK의 강화 `JwtValidator`로 id_token 서명을 먼저 검증한 뒤 nonce를 대조한다(Java는 nonce 파스온리였음).
- ⚠️ **admin 파사드는 auth를 직접 알지 못한다(§4·Java 동형).** `KeycloakClient`는 admin에 provider를 배선하지 않고, `AdminClient`가 `KeycloakBuilder` 내장 client-credentials 그랜트로 토큰을 자체 소유한다(내부 `TokenManager`가 자동 획득·갱신). `ClientCredentialsTokenProvider`(Task 5)는 §4 접착 유틸이자 파사드 레벨 시임일 뿐 admin이 실사용하지는 않는다 — Java SDK가 커스텀 RESTEasy 필터 충돌로 내린 동일 결정을 상속.
- ⚠️ **로컬 Windows 빌드는 포터블 Gradle 9.6.1을 쓰나 CI 래퍼는 9.5.0 핀이다.** KGP 2.2.20 지원 밴드 내 재현성을 위해 래퍼(`gradle/wrapper/gradle-wrapper.properties`)를 9.5.0으로 고정 — CI의 `gradle/actions/setup-gradle@v4`가 이 래퍼를 캐시·실행한다.

## 보안 (G6) — Task 6 JwtValidator 어드버서리얼 리뷰

Task 6(JwtValidator, 보안핵심)은 **19개 공격 프로브** + opus 어드버서리얼 보안리뷰로 **SECURE 판정(악용 가능 0)**:
- alg-confusion(HS256 위조·RS256-spoofed-HMAC)·`alg:"none"` 거부·iss superstring/substring 거부·aud 미포함 거부·`exp` 부재 거부·미래 `nbf` 거부(회귀 프로브 `138bfec`)·변조 서명(known kid) 거부·클록 스큐 경계·악성 JWKS(모듈러스 이상) 경계 예외변환.
- `jwt.kt` 커버리지 100%·alg-pin은 mutation-tested. DoS-safe JWKS는 Nimbus `JWKSourceBuilder`(캐시+RateLimited)로 위조 Bearer 토큰당 IdP 폭주 차단.
- 마스킹: `TokenSet`(access/refresh)·`KeycloakConfig`(clientSecret)를 `toString`에서 완전 불투명 `***`(접두 노출 없음). 시크릿은 `CharArray` 방어복사(심층방어 — 하위 Nimbus/admin-client가 `String`을 요구해 end-to-end 소거 보장은 아님·다른 언어와 동일 근본 한계).

---

## 남은 게이트

- **최종 whole-branch 리뷰**(opus·4차원 어드버서리얼) → 확정 결함 수정 → PR.
- **병합 후**(전역 규칙): `CLAUDE.md`/`README.md`/`docs/roadmap`/`DEPLOY.md` 전역 문서 최신화(9번째 언어 반영) + 툴체인 섹션 추가.
- **실배포**(사람 게이트): Maven Central `io.github.xzawed:keycloak-sdk-kotlin` — `kotlin-v*` 태그 push 시 `kotlin-release.yml`이 `publishToMavenCentral`(Central Portal 스테이징) 실행, 사람이 Portal 콘솔에서 수동 release. Central Portal 네임스페이스 소유권 검증(Java 로드맵 공유 미해결) + in-memory GPG 키/토큰 시크릿 등록 선행.
