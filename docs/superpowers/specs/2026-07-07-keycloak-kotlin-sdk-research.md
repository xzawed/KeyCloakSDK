# Kotlin SDK — 리서치 부록 (권위 명령·설정 소스)

> Kotlin SDK(9번째 언어)의 Kotlin 고유 관심사를 병렬 딥리서치(2026-07-07, 6 에이전트·web 검증, 전 영역 confidence high)로 확정. WBS 태스크·구현자가 참조하는 **권위 소스**. 설계는 [keycloak-kotlin-sdk-design.md](2026-07-07-keycloak-kotlin-sdk-design.md).
>
> 핵심: Java SDK의 3개 JVM 기반(keycloak-admin-client 26.0.10·oauth2-oidc-sdk 11.37.2·nimbus-jose-jwt 10.9.1)을 재사용하되 **코루틴 suspend·data class·sealed 예외**로 Kotlin 관용화. JwtValidator/AuthClient/AdminClient의 하드닝 불변식은 [Java SDK 검증로그](../../governance/verification-log.md)에서 상속.

## 확정 스택 (버전)
| 요소 | 버전 | 비고 |
|---|---|---|
| Kotlin(KGP) | **2.2.20** | coroutines 1.11.0의 정확한 companion — 보안 핵심이라 보수적. (2.4.0도 forward-호환이나 metadata skew 여지) |
| Gradle wrapper | **9.5.0** | KGP 2.2.20/2.4.0 완전지원 상한(현 stable 9.6.1은 untested 경고). 부트스트랩은 로컬 Gradle 9.6.1 |
| kotlinx-coroutines-core / -test | **1.11.0** | core와 test **동일 버전 필수**(불일치 시 TestCoroutineScheduler 링킹 오류). 공개 suspend 시그니처 노출 → `api(...)` |
| JDK toolchain | **21** | `kotlin { jvmToolchain(21) }` + settings의 foojay-resolver-convention 1.0.0 |
| 배포 | vanniktech maven.publish **0.37.0** | Central Portal 표준(signing+sources+Dokka javadoc jar). `publishToMavenCentral()` 무인자·`signAllPublications()`·in-memory GPG |
| Dokka | **2.2.0** | DGP v2(javadoc jar). 미적용 시 빈 javadoc jar |
| 재사용 JVM 라이브러리 | keycloak-admin-client 26.0.10 · oauth2-oidc-sdk 11.37.2 · nimbus-jose-jwt 10.9.1 | Java SDK BOM과 동일 좌표 |
| 테스트 | JUnit-bom 6.1.1 + kotlin.test · MockK 1.14.4(coEvery/coVerify) · WireMock 3.13.2 · Testcontainers 2.0.5 + dasniko testcontainers-keycloak 4.2.1 | |
| 커버리지/린트 | Kover 0.9.8(라인90/브랜치85) · ktlint-gradle 14.2.0 | |
| 좌표 | `io.github.xzawed:keycloak-sdk-kotlin` | Java 5개 아티팩트와 구분 |

## build.gradle.kts (핵심)
```kotlin
plugins {
    kotlin("jvm") version "2.2.20"
    `java-library`
    id("org.jetbrains.dokka") version "2.2.0"
    id("com.vanniktech.maven.publish") version "0.37.0"
    id("org.jetbrains.kotlinx.kover") version "0.9.8"
    id("org.jlleitschuh.gradle.ktlint") version "14.2.0"
}
group = "io.github.xzawed"; version = "0.1.0"
kotlin { jvmToolchain(21); explicitApi() }   // JDK21 + public API 엄격
dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")   // 공개 suspend → api
    api("org.keycloak:keycloak-admin-client:26.0.10")             // representation 노출 → api
    implementation("com.nimbusds:oauth2-oidc-sdk:11.37.2")
    implementation("com.nimbusds:nimbus-jose-jwt:10.9.1")
    testImplementation(kotlin("test"))
    testImplementation(platform("org.junit:junit-bom:6.1.1"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.4")
    testImplementation("org.wiremock:wiremock:3.13.2")
    testImplementation("org.testcontainers:testcontainers:2.0.5")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter:2.0.5")
    testImplementation("com.github.dasniko:testcontainers-keycloak:4.2.1")
}
tasks.test { useJUnitPlatform() }
// settings.gradle.kts: plugins { id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0" }
// gradle/wrapper/gradle-wrapper.properties: distributionUrl=...gradle-9.5.0-bin.zip
// mavenPublishing { publishToMavenCentral(); signAllPublications(); coordinates("io.github.xzawed","keycloak-sdk-kotlin",version.toString()); pom { ... Apache-2.0 ... } }
```
Kover 게이트: `kover { reports { filters { excludes { classes("io.github.xzawed.keycloak.AuthClient","io.github.xzawed.keycloak.admin.*","io.github.xzawed.keycloak.KeycloakClient") } } verify { rule { bound { minValue=90; coverageUnits=LINE } } rule { bound { minValue=85; coverageUnits=BRANCH } } } } }` + `tasks.named("check"){ dependsOn("koverVerify") }`.
CI 시크릿(ORG_GRADLE_PROJECT_ 접두): `mavenCentralUsername`/`mavenCentralPassword`(Central Portal 토큰)·`signingInMemoryKey`(ASCII-armored 전체 개인키)·`signingInMemoryKeyPassword`. 배포 태스크 `./gradlew publishToMavenCentral`(업로드→Portal 수동 release·사람 게이트).

## 코루틴 래핑 (핵심 계약)
- 모든 네트워크 메서드 = `suspend`, 블로킹 Java 호출을 **`runInterruptible(Dispatchers.IO) { block() }`**로 감싼다(코루틴 취소→Thread.interrupt 전파, `withContext`보다 취소 정확). 단 Nimbus HttpURLConnection은 interrupt 미준수 → 주입 타임아웃이 실질 상한.
- SDK는 내부 `CoroutineScope`·`runBlocking` 없음(호출자/테스트/예제만). **`CancellationException` 최우선 재던지기 필수**(삼키면 구조적 동시성 파괴).
- single-flight = 코루틴 `Mutex.withLock`(비재진입 — 자기 재획득 데드락). JVM `synchronized`를 suspend 넘어 유지 금지.
- `close()`는 non-suspend(`AutoCloseable` + `.use{}`).
```kotlin
internal suspend fun <T> onIo(block: () -> T): T = runInterruptible(Dispatchers.IO, block)
public suspend fun clientCredentialsToken(): TokenSet {
    val issuedAt = Instant.now().epochSecond
    val tr = TokenRequest.Builder(md.tokenEndpoint, clientAuth(), ClientCredentialsGrant())
        .scope(Scope(*config.scopes.toTypedArray())).build()
    val resp = try { onIo { TokenResponse.parse(applyTimeouts(tr.toHTTPRequest()).send()) } }
        catch (e: CancellationException) { throw e }
        catch (e: IOException) { throw KeycloakTransportException("auth request failed", e) }
        catch (e: ParseException) { throw KeycloakAuthException("malformed auth response", cause = e) }
    if (!resp.indicatesSuccess()) { val err = resp.toErrorResponse().errorObject
        throw KeycloakAuthException("client credentials failed: ${err.description}", err.code) }
    return toTokenSet(resp.toSuccessResponse().tokens, issuedAt)
}
private fun applyTimeouts(req: HTTPRequest) = req.apply {
    connectTimeout = config.connectTimeout.toMillis().toInt(); readTimeout = config.readTimeout.toMillis().toInt() }
```

## JWT 자체강화 (Java와 100% 동형)
`validate()` = suspend(JWKS 블로킹 조회 → `onIo`). `forRealm()` 팩토리는 non-suspend(지연 조회). RS256 alg 핀·`none`/PlainJWT 명시 거부·iss 정확일치(**exactMatchClaims엔 issuer만** — aud는 다중값 정상토큰 오탐 방지 위해 포함검사)·aud 포함·exp 필수·클록스큐·`JWKSourceBuilder.create(url, retriever).build()` 기본값(cache+rateLimited 30s+refreshAhead+retrying=DoS-safe)·JWKS retriever도 config 타임아웃 준수.
```kotlin
suspend fun validate(accessToken: String): ValidatedToken = onIo {
    val jwt = JWTParser.parse(accessToken)                       // CPU만
    if (jwt !is SignedJWT) throw TokenValidationException("Unsecured/non-signed JWT rejected") // alg=none 거부
    ValidatedToken.from(processor.process(jwt, null))            // process()가 JWKS 블로킹 조회 가능
}   // catch: TokenValidationException·CancellationException 재throw, else → TokenValidationException(e)
// forRealm: JWSVerificationKeySelector(allowedAlgs=setOf(RS256), source) + DefaultJWTClaimsVerifier(audience, exactIssuerOnly, setOf("exp")).setMaxClockSkew(skew)
```

## auth / admin
- **auth**=Nimbus(client-credentials·PKCE authorization-code·introspect·logout·refresh). OAuth 에러응답→`KeycloakAuthException`(Transport 아님)·send() IOException→Transport.
- **admin**=keycloak-admin-client(`KeycloakBuilder.grantType(CLIENT_CREDENTIALS)`·**resteasyClient 타임아웃 주입 필수**[미주입=스레드고갈 DoS]·내부 TokenManager가 admin 토큰 소유). 경계변환: `WebApplicationException`(status→404/409/403/Other)·`ProcessingException`("RESTEASY004655" 소켓/타임아웃/TLS)→Transport. `create()`는 Location→id·`delete()`는 status 수동검사. representation은 `org.keycloak.representations.idm.*` 노출(Java 동형).
- **접착**: `TokenProvider`(suspend). admin에는 **전용 `ClientCredentialsTokenProvider` 주입**(무캐시 AuthClient 직접주입 금지 — Rust 79ecf76 교훈 선반영). ⚠️ keycloak-admin-client 래핑 시 provider는 내부 TokenManager가 토큰을 소유해 실사용 안 되나 §4 계약·시임 위해 유지.

## Kotlin 관용 (값타입·config·예외·파사드)
```kotlin
// masking.kt — internal, 접두 노출 없음
internal fun mask(v: CharArray?) = if (v.isNullOrEmpty()) "" else "***"
internal fun mask(v: String?) = if (v.isNullOrEmpty()) "" else "***"

// 값타입 = data class + toString 오버라이드(자동 toString이 토큰/시크릿 전량 노출 → 필수)
public data class TokenSet(val accessToken: String, val refreshToken: String?, val idToken: String?,
    val tokenType: String, val scope: String?, val expiresAt: Instant?) {
    fun isExpired(clock: Clock = Clock.systemUTC(), skew: Duration = Duration.ofSeconds(30)) =
        expiresAt == null || !Instant.now(clock).plus(skew).isBefore(expiresAt)
    override fun toString() = "TokenSet(tokenType=$tokenType, scope=$scope, accessToken=***, refreshToken=${mask(refreshToken)}, expiresAt=$expiresAt)" }
public data class ValidatedToken(val subject: String?, val issuer: String?, val audience: List<String>,
    val expiresAt: Instant?, val issuedAt: Instant?, val claims: Map<String, Any?>)
public data class IntrospectionResult(val active: Boolean, val username: String?, val clientId: String?)  // Optional→nullable
public data class AuthorizationRequest(val authorizationUrl: String, val codeVerifier: String, val state: String, val nonce: String) {
    override fun toString() = "AuthorizationRequest(authorizationUrl=$authorizationUrl, codeVerifier=***, state=$state, nonce=$nonce)" }

// config = 일반 class(⚠️ data class 금지: CharArray identity + 시크릿 누출)·named-arg·init 검증·trimEnd·방어복사
public class KeycloakConfig(serverUrl: String, public val realm: String, public val clientId: String,
    clientSecret: CharArray? = null, public val scopes: List<String> = emptyList(),
    public val connectTimeout: Duration = Duration.ofSeconds(10), public val readTimeout: Duration = Duration.ofSeconds(30),
    public val clockSkew: Duration = Duration.ofSeconds(30)) {
    public val serverUrl: String = serverUrl.trimEnd('/')
    private val secret: CharArray? = clientSecret?.copyOf()
    public val clientSecret: CharArray? get() = secret?.copyOf()
    init { if (this.serverUrl.isBlank()) throw KeycloakConfigException("Missing required config: serverUrl")
           if (realm.isBlank()) throw KeycloakConfigException("Missing required config: realm")
           if (clientId.isBlank()) throw KeycloakConfigException("Missing required config: clientId") }
    override fun toString() = "KeycloakConfig(serverUrl=$serverUrl, realm=$realm, clientId=$clientId, clientSecret=${mask(secret)})" }

// errors.kt — sealed 계층 전체를 한 패키지/파일에(sealed same-module+package 요건)
public sealed class KeycloakException(message: String, cause: Throwable? = null) : Exception(message, cause)
public class KeycloakConfigException(m: String, c: Throwable? = null) : KeycloakException(m, c)
public class KeycloakAuthException(m: String, public val oauthError: String? = null, c: Throwable? = null) : KeycloakException(m, c)
public class KeycloakTransportException(m: String, c: Throwable? = null) : KeycloakException(m, c)
public class TokenValidationException(m: String, c: Throwable? = null) : KeycloakException(m, c)
public sealed class KeycloakAdminException(public val status: Int, public val keycloakError: String?, c: Throwable? = null)
    : KeycloakException("Keycloak admin error (HTTP $status)", c) {
    public class NotFound(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)
    public class Conflict(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)
    public class Forbidden(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)
    public class Other(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c) }  // 500 등 필수 리프

// 파사드 = auth 즉시 + admin 지연(Lazy SYNCHRONIZED) + AutoCloseable
public class KeycloakClient private constructor(public val config: KeycloakConfig, public val auth: AuthClient,
    private val adminLazy: Lazy<AdminClient>) : AutoCloseable {
    public val admin: AdminClient get() = adminLazy.value
    override fun close() { auth.close(); if (adminLazy.isInitialized()) adminLazy.value.close() }
    public companion object { public fun create(config: KeycloakConfig): KeycloakClient =
        KeycloakClient(config, AuthClient(config), lazy { AdminClient(config, ClientCredentialsTokenProvider(config)) }) } }
```

## 테스트
단위=`runTest {}`(suspend·delay 가상시간)·suspend 모킹은 `coEvery`/`coVerify`. 통합=`runBlocking {}`(실 IO엔 가상시간 무의미). 커맨드 `./gradlew test`·`koverVerify`·`ktlintCheck`, 단일 `./gradlew test --tests "…JwtValidatorTest"`.

## 게차 (구현 시 검증·주의)
- **KGP↔Gradle 밴드**: wrapper 9.5.0 핀(9.6.1은 untested 경고).
- **coroutines core↔test 동일 버전**(libs.versions.toml 단일 정의 권장).
- **`fun interface` + suspend(KT-40978)**: 구현 시 `suspend fun interface TokenProvider` 컴파일 여부 검증 — 불가하면 일반 `interface` + `invoke` 팩토리 폴백. (kotlin-idioms 에이전트는 가능하다 보고·coroutines-wrap/auth-admin은 불가라 보고 — 상충, 실측 확정.)
- **`runInterruptible` 취소**: 코루틴 취소가 Thread.interrupt 전파하나 Nimbus HttpURLConnection·일부 RESTEasy 경로는 미준수 → 타임아웃이 실질 상한.
- **CancellationException 재던지기**를 모든 broad catch 최상단에.
- **Central Portal 소유권 검증**(io.github.xzawed — Java 로드맵 공유 미해결)·**in-memory GPG 키**(secring 파일 아님).
- **Dokka v2 태스크명** `dokkaGeneratePublicationHtml`(v1 dokkaHtml 아님).
- **MockK JDK21 self-attach 경고**(기능 정상·필요시 `-XX:+EnableDynamicAgentLoading`)·suspend는 반드시 `coEvery`/`coVerify`.
- **Kover 0.9.x DSL**(`kover{reports{...}}`·excludes.classes FQN/와일드카드) — 0.7/0.8과 다름.
- **exactMatchClaims엔 issuer만**(aud 넣으면 client-credentials 다중 aud 오탐 — Java 상속 게차).
- **explicitApi()**로 모든 public 선언 가시성·반환타입 명시(Task 1부터).
