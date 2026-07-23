# Keycloak Kotlin SDK — 설계 (Design)

- **작성일**: 2026-07-07
- **브랜치**: `feature/kotlin-sdk` (main 기준)
- **대상**: 폴리글랏 Keycloak SDK의 **9번째 언어 = Kotlin**(JVM·코루틴)
- **관련**: 8개 언어 SDK + 검증·스코어링 하네스(PR #20) + 설치·동작 검증 하네스(PR #21) 전부 `main` 병합 완료
- **정확한 명령·설정 권위 소스**: [keycloak-kotlin-sdk-research.md](2026-07-07-keycloak-kotlin-sdk-research.md)(리서치 부록)

---

## 1. 전략 / 정체성

9번째 언어. **Java SDK가 이미 성숙하게 래핑한 3개 JVM 기반을 그대로 재사용**하되 Kotlin 관용으로 얹는다 — "언어마다 가장 좋은 기반" 원칙의 JVM 사례(gocloak/fschmtt 같은 새 클라이언트가 아니라, 자매 Java SDK와 동일 라이브러리):

- **admin**: `org.keycloak:keycloak-admin-client` 26.0.10 (blocking RESTEasy)
- **auth**: `com.nimbusds:oauth2-oidc-sdk` 11.37.2 (blocking)
- **jwt**: `com.nimbusds:nimbus-jose-jwt` 10.9.1 (자체강화)

**Kotlin 관용화**: 모든 네트워크 메서드가 **코루틴 `suspend`**(async 계열 — Node/Rust/Python-aio 동형) · **`data class`** 값타입 · **`sealed class`** 예외 계층 · `explicitApi()`. §4 언어중립 계약(config→auth→jwt→admin→client) 동형.

JWT 검증만 자체강화(RS256 핀·`none` 거부·iss 정확일치·aud 포함·exp 필수·클록스큐·DoS-safe JWKS) — 여덟 자매 SDK와 동일하며 하드닝 불변식은 [Java 검증로그](../../governance/verification-log.md)에서 상속.

## 2. 빌드 / 구조 / 배포

- **단일 Gradle 모듈**(Kotlin DSL) → 아티팩트 `io.github.xzawed:keycloak-sdk-kotlin`. Java만 6 Maven 모듈이고 나머지 7개 SDK는 단일 패키지 → 동형. 계층(config/auth/jwt/admin/client)은 Gradle 서브프로젝트가 아니라 **Kotlin 패키지**로 분리.
- **툴체인**: Kotlin(KGP) **2.2.20**(coroutines 1.11.0 companion·보수적) · Gradle wrapper **9.5.0**(KGP 완전지원 상한) · JDK **21** toolchain(+ foojay-resolver 1.0.0) · `explicitApi()`(공개 API 엄격 — mypy/tsc strict 동형). 로컬 부트스트랩은 설치된 Gradle 9.6.1.
- **배포**: `com.vanniktech.maven.publish` 0.37.0(Central Portal 표준 — signing+sources+Dokka javadoc jar 일괄) · `publishToMavenCentral()` 무인자 · **in-memory GPG 키** · Dokka 2.2.0. 태그 `kotlin-v*` → `.github/workflows/kotlin-release.yml`(사람 게이트). io.github.xzawed 네임스페이스 Central Portal 소유권 검증은 Java 로드맵과 공유(미해결).

정확한 `build.gradle.kts`·`settings.gradle.kts`·wrapper·Kover/ktlint 설정은 부록 참조.

## 3. 코루틴 모델 (핵심 계약)

- 모든 네트워크 메서드 = `suspend`. 블로킹 Java 호출을 **`runInterruptible(Dispatchers.IO) { block() }`**로 감싸 취소-인지 변환(코루틴 취소→Thread.interrupt). SDK는 내부 `CoroutineScope`·`runBlocking` 없음 — 각 메서드는 호출자 컨텍스트에서 실행돼 구조적 동시성이 공짜로 보존된다. 호출자/테스트/예제만 `runBlocking`.
- **`CancellationException` 최우선 재던지기 필수**(broad catch에서 삼키면 구조적 동시성 파괴). Nimbus HttpURLConnection은 interrupt 미준수 → 주입 타임아웃이 실질 상한.
- single-flight = 코루틴 `Mutex.withLock`(비재진입). `close()`는 non-suspend(`AutoCloseable` + `.use{}`).

## 4. 계층 (Kotlin 패키지, `io.github.xzawed.keycloak`)

- **config** (`config.kt`): `KeycloakConfig` = **일반 class**(⚠️ data class 금지 — CharArray identity·시크릿 누출) · named-arg 주 생성자(Java Builder 불필요) · `init` 검증(빈 필드→`KeycloakConfigException`) · `trimEnd('/')` · CharArray 방어복사(in/out) · `toString` 마스킹.
- **errors** (`errors.kt`): `sealed KeycloakException` → `KeycloakConfigException`/`KeycloakAuthException`(oauthError)/`KeycloakTransportException`/`TokenValidationException`/`sealed KeycloakAdminException`(status/keycloakError → `NotFound`/`Conflict`/`Forbidden`/**`Other`**[500 등 필수 리프]). **전부 한 파일/패키지**(sealed same-module+package 요건).
- **tokens** (`tokens.kt`): `data class` `TokenSet`(isExpired)/`ValidatedToken`/`IntrospectionResult`(`String?` nullable — Optional 대체)/`AuthorizationRequest` + **toString 오버라이드 마스킹**(자동 toString이 토큰 노출). `masking.kt`(internal `mask`).
- **oidc** (`oidc.kt`): 엔드포인트 조립(네트워크 없음).
- **tokenprovider** (`tokenprovider.kt`): `TokenProvider`(suspend 인터페이스) + `ClientCredentialsTokenProvider`(코루틴 Mutex 캐시·single-flight).
- **jwt** (`jwt.kt`): `JwtValidator` — nimbus-jose-jwt 자체강화(§1). `validate()` = suspend(JWKS 조회 IO). `forRealm()` 팩토리 non-suspend. **exactMatchClaims엔 issuer만**(aud 포함검사 — Java 상속 게차). JWKS retriever도 config 타임아웃 준수.
- **auth** (`auth.kt`): `AuthClient` — Nimbus 래핑(client-credentials·PKCE authorization-code·introspect·logout·refresh·validate). OAuth 에러→`KeycloakAuthException`·send() IOException→Transport.
- **admin** (`admin/`): `AdminClient` — keycloak-admin-client 래핑(5리소스 users/clients/realms/roles/groups + raw). `KeycloakBuilder.grantType(CLIENT_CREDENTIALS)` + **resteasyClient 타임아웃 주입 필수**. 경계변환(`WebApplicationException`→404/409/403/Other·`ProcessingException`→Transport). representation은 `org.keycloak.representations.idm.*` 노출(Java 동형).
- **client** (`client.kt`): `KeycloakClient` 파사드(auth 즉시·admin 지연 `Lazy`·`AutoCloseable`). admin에 **전용 `ClientCredentialsTokenProvider` 주입**(무캐시 AuthClient 직접주입 금지 — Rust 79ecf76 교훈 선반영).

**결합 규칙**: `admin`은 `auth`를 직접 모른다 — `TokenProvider`(suspend)가 유일 접착제. 하위 오류(`jakarta.ws.rs.*`·Nimbus `ParseException`)는 경계에서 sealed `KeycloakException`으로 변환. `admin` representation·저수준 주입점만 하위 타입 노출(Java 동형·문서화된 은닉성 예외).

## 5. 테스트 / 품질

JUnit Platform(junit-bom 6.1.1) + kotlin.test + **MockK** 1.14.4(`coEvery`/`coVerify` suspend 모킹) + WireMock 3.13.2(HTTP목) + Testcontainers 2.0.5 + dasniko testcontainers-keycloak 4.2.1(실 KC 26.6 E2E) + **Kover** 0.9.8(게이트 라인≥90/브랜치≥85·네트워크 경계 `AuthClient`/`admin.*`/`KeycloakClient` omit) + **ktlint** 14.2.0. 단위=`runTest{}`, 통합=`runBlocking{}`(실 IO). JWT 보안 프로브(alg=none·HS/RS confusion·미지kid·malformed·클록스큐)는 Java 동형.

## 6. 파일 구조

```
kotlin/
├─ build.gradle.kts · settings.gradle.kts · gradle.properties · gradle/wrapper/(9.5.0) · gradlew(.bat)
├─ src/main/kotlin/io/github/xzawed/keycloak/
│  ├─ config.kt · errors.kt · masking.kt · tokens.kt · oidc.kt · tokenprovider.kt
│  ├─ jwt.kt · auth.kt · admin/(AdminClient.kt + Users/Clients/Realms/Roles/Groups.kt) · client.kt
├─ src/test/kotlin/…(단위) · src/integrationTest/kotlin/…(Testcontainers, 별도 소스셋)
├─ examples/quickstart.kt
└─ LICENSE(Apache-2.0)
```

## 7. CI / 배포

`.github/workflows/kotlin-release.yml`(태그 `kotlin-v*` → `./gradlew publishToMavenCentral`·in-memory GPG·Central Portal 토큰·사람 게이트). CI 검증 잡(`./gradlew build koverVerify ktlintCheck` + 통합 E2E). 실 배포는 사람이 태그 push + Central Portal 소유권 검증 선행(미해결·Java 공유).

## 8. 알려진 게차 (부록 상세)

KGP↔Gradle 밴드(9.5.0 핀)·coroutines core↔test 동일버전·`fun interface`+suspend(KT-40978 구현 시 검증)·`runInterruptible` 취소(Nimbus interrupt 미준수→타임아웃 상한)·CancellationException 재던지기·Central Portal 소유권 검증·in-memory GPG·Dokka v2 태스크명·MockK JDK21 self-attach·Kover 0.9.x DSL·exactMatchClaims issuer-only·explicitApi.

## 9. 범위 밖 (YAGNI)

- Kotlin Multiplatform(KMP) — JVM 단일 타깃(Java 라이브러리 재사용이 전제).
- Ktor/Spring 통합 — 순수 SDK(파사드만).
- 동기(blocking) 미러 — 코루틴 단일 모델(호출자가 `runBlocking`으로 브리지).
- 실 Maven Central 배포(사람 게이트).
