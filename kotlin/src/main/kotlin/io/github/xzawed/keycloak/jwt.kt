package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.source.ImmutableJWKSet
import com.nimbusds.jose.jwk.source.JWKSource
import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import com.nimbusds.jose.proc.JWSVerificationKeySelector
import com.nimbusds.jose.proc.SecurityContext
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.JWTParser
import com.nimbusds.jwt.SignedJWT
import com.nimbusds.jwt.proc.ConfigurableJWTProcessor
import com.nimbusds.jwt.proc.DefaultJWTClaimsVerifier
import com.nimbusds.jwt.proc.DefaultJWTProcessor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import java.io.InterruptedIOException
import java.net.MalformedURLException
import java.net.URI
import java.time.Duration

// 받는 토큰의 길이 상한 — 넘으면 분해·base64/JSON 디코드·JWKS 적재보다 먼저 거부한다(아홉 언어가 함께 움직인다).
// Nimbus 는 서명을 보기 전에 헤더(JWTParser)와 클레임(DefaultJWTProcessor)을 JSON 으로 풀어, 위조 토큰이 거부되기 전에
// 입력 바이트당 최대 약 38 B 를 할당했다(2026-10-27 측정, 등록부 inbound-token-cap-divergent). 256000 은
// Microsoft.IdentityModel 의 DefaultMaximumTokenSizeInBytes 와 같고 Keycloak 26.6 이 기본 설정으로 받는 가장 긴
// Bearer(65,459 B)의 약 3.9 배라, 서버가 받는 토큰은 거부하지 않는다. Java 자매(`JwtValidator.JWT_MAX_BYTES`)와 같은 값이다.
// 단위는 String.length(UTF-16 단위)다 — 정상 JWT 는 ASCII 라 바이트 수와 같다.
internal const val JWT_MAX_BYTES: Int = 256_000

// JWKS 키 집합의 수명(초) — 아홉 언어가 함께 움직인다(등록부 jwks-cache-lifetime-divergent, 판정 2026-10-29). 이 나이에
// 닿은 집합은 콜드 캐시처럼 다시 가져오고, 그 조회가 실패하면 검증이 실패한다 — 낡은 집합으로 물러서지 않는다(outage
// tolerance 를 명시적으로 끈다). Nimbus 캐시 TTL 로 넣는다(remoteJwkSource). ⚠️ Nimbus 는 그 나이를 조회가 끝난 때가
// 아니라 그 조회를 부른 검증이 **시작한** 때부터(그만큼 짧다), monotonic 이 아니라 벽시계(System.currentTimeMillis)로
// 센다 — 시계를 뒤로 돌리면 그만큼 길어진다(JwksMaxAgeTest 머리 주석). Java 자매(`JwtValidator.JWKS_MAX_AGE_SECONDS`)와 같다.
internal const val JWKS_MAX_AGE_SECONDS: Int = 300

// jwt.kt — JwtValidator: Java SDK의 JwtValidator(io.github.xzawed.keycloak.auth.JwtValidator)와 100%
// 동형인 하드닝 불변식(§jwt)을 지킨다: RS256 alg 핀 · alg=none/미서명 명시 거부 · iss 정확일치
// (exactMatchClaims엔 issuer만 — aud를 넣으면 다중값 정상 토큰이 오탐 거부된다) · aud 포함검사 ·
// exp 필수 · 클록스큐 · DoS-safe JWKS(cache TTL = JWKS_MAX_AGE_SECONDS · refreshAhead · rateLimited —
// outageTolerant 는 명시적으로 끈다 · retrying 은 기본 비활성. 위조 서명은 재조회 유발 안 함·미해결 kid만 rate-limited 재조회).
// ⚠️ 생성자 인자 목록을 바꾸지 말 것 — 게시본의 합성 public 생성자(끝에 DefaultConstructorMarker)가 이 모양이다.
public class JwtValidator private constructor(
    private val jwkSource: JWKSource<SecurityContext>,
    private val issuer: String,
    audience: String,
    private val allowedAlgs: Set<JWSAlgorithm>,
    private val skew: Duration,
) {
    private val processor: ConfigurableJWTProcessor<SecurityContext> =
        DefaultJWTProcessor<SecurityContext>().also { p ->
            // 허용 alg만 통과(JWSVerificationKeySelector) → none/HS256/기타 미허용 alg는 여기서 거부된다.
            p.setJWSKeySelector(JWSVerificationKeySelector(allowedAlgs, jwkSource))
            // exactMatchClaims에는 issuer만 둔다: audience까지 넣으면 Nimbus가 aud를 [audience]와
            // "완전 일치"로 요구하게 되어, 실제 Keycloak처럼 aud가 다중값(예: ["it-client","realm-management"])인
            // 정상 토큰이 오탐 거부된다. audience는 requiredAudience(첫 인자)로만 넘겨 "포함 검사"로 검증한다.
            val exact = JWTClaimsSet.Builder().issuer(issuer).build()
            val verifier = DefaultJWTClaimsVerifier<SecurityContext>(audience, exact, setOf("exp"))
            verifier.setMaxClockSkew(skew.seconds.toInt())
            p.setJWTClaimsSetVerifier(verifier)
        }

    /**
     * Validates accessToken and returns the SDK-owned [ValidatedToken] — no failure path exposes a Nimbus type in the
     * public API. A JWKS fetch can be blocking I/O, so it is wrapped in [runInterruptible].
     * The code exchange's id_token validation (`AuthClient.requireValidNonce` → [withAudience]'s validate) is this
     * function too, so the cap check is here and only here.
     */
    public suspend fun validate(accessToken: String): ValidatedToken {
        // 상한이 먼저다 — 분해·디코드·JWKS 적재 전에, IO 디스패처로 넘기기도 전에([JWT_MAX_BYTES]).
        if (accessToken.length > JWT_MAX_BYTES) {
            throw TokenValidationException("token exceeds $JWT_MAX_BYTES bytes")
        }
        return try {
            onIo {
                // alg=none / 미서명 JWT를 Nimbus의 암묵적 기본 동작에 의존하지 않고 명시적으로 거부한다.
                val jwt = JWTParser.parse(accessToken)
                if (jwt !is SignedJWT) {
                    throw TokenValidationException("Unsecured or non-signed JWT rejected")
                }
                validatedTokenFrom(processor.process(jwt, null))
            }
        } catch (e: TokenValidationException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw TokenValidationException("JWT validation failed", e)
        }
    }

    // 기대 audience 만 바꾼 검증기. 코드 교환의 id_token 검증이 쓴다 — OIDC Core §2 · §3.1.3.7 대로 id_token 의
    // aud 는 client id 이고, `expectedAudience` 재정의는 액세스 토큰 전용이다. iss · alg 핀 · skew 는 그대로다.
    // ⚠️ 같은 [jwkSource] 객체를 넘긴다 — 새 저장소를 만들면 JWKS 캐시·재조회 rate-limit 창·콜드 캐시 창이 둘로
    // 갈려 IdP 요청 상한이 두 배가 된다(`IdTokenAudienceJwksTest`). 조회도 suspension point 도 없다.
    internal fun withAudience(audience: String): JwtValidator = JwtValidator(jwkSource, issuer, audience, allowedAlgs, skew)

    // 이 검증기의 키 원천 — 시험이 forRealm 이 만든 체인을 꺼내 가짜 시계로 돌린다(JwksMaxAgeTest).
    internal fun jwkSource(): JWKSource<SecurityContext> = jwkSource

    public companion object {
        /** Production factory that queries the real JWKS endpoint lazily (non-suspend — the query happens at the first [validate] call). */
        public fun forRealm(
            endpoints: OidcEndpoints,
            config: KeycloakConfig,
            audience: String,
            // §4: config는 String으로 서명 알고리즘을 보유하고(Nimbus 타입 미노출) 경계에서만 변환한다.
            allowedAlgs: Set<JWSAlgorithm> = config.signatureAlgorithms.map { JWSAlgorithm.parse(it) }.toSet(),
        ): JwtValidator {
            // JWKS fetch도 KeycloakConfig의 connect/read 타임아웃을 따른다: 기본 DefaultResourceRetriever는
            // 자체 기본 타임아웃을 쓰므로 그대로 두면 설정이 무시된다.
            // ⚠️ 기본 DefaultResourceRetriever는 HttpURLConnection의 기본 동작(리다이렉트 추종)을
            // 그대로 쓴다 — JWKS가 예상 밖 3xx를 주면 공격자가 고른 URL의 응답을 **서명 검증용 키
            // 집합으로 사용**하게 된다. auth 경로보다 결과가 나쁘다. Java 자매 SDK와 동형으로 막는다.
            val retriever =
                NoRedirectResourceRetriever(
                    config.connectTimeout.toMillis().toInt(),
                    config.readTimeout.toMillis().toInt(),
                )
            val jwksUrl =
                try {
                    URI(endpoints.jwks).toURL()
                } catch (e: MalformedURLException) {
                    throw TokenValidationException("Invalid JWKS URI", e)
                }
            // rateLimited 간격은 config로 설정 가능하게 한다(기본 30초 = Nimbus DEFAULT_RATE_LIMIT_MIN_INTERVAL 동형) —
            // 위조 kid를 연속 주입해도 JWKS 재조회가 무제한으로 증폭되지 않는다.
            // ⚠️ Nimbus는 rate-limit 간격이 캐시 TTL(JWKS_MAX_AGE_SECONDS) 이상이면 build()에서
            // IllegalStateException을 던진다(캐시가 만료돼도 rate-limit이 재조회를 막아 JWKS를 영영
            // 갱신할 수 없는 구성이므로 정당한 거부다). 그대로 두면 이 foreign 예외가 공개 API로
            // 새어나가므로(§4 위반) 경계에서 sealed KeycloakException 계급으로 바꾼다 — Java 동형.
            val source: JWKSource<SecurityContext> =
                try {
                    remoteJwkSource(jwksUrl, retriever, config.jwksMinRefetch)
                } catch (e: IllegalStateException) {
                    throw KeycloakConfigException(
                        "jwksMinRefetch (${config.jwksMinRefetch.toSeconds()}s) must be shorter than " +
                            "the JWKS cache time-to-live (${JWKS_MAX_AGE_SECONDS}s)",
                        e,
                    )
                }
            return JwtValidator(source, endpoints.issuer, audience, allowedAlgs, config.clockSkew)
        }

        // forRealm 의 JWKS 체인(Java `JwtValidator.remoteJwkSource` 동형). 캐시 TTL 은 JWKS_MAX_AGE_SECONDS · outage
        // tolerance 는 끈다(켜면 장애 중 낡은 집합을 돌려준다). refresh-ahead(기본 켜짐 — TTL 의 마지막 30초에 온 검증이
        // 백그라운드로 미리 가져온다)는 그대로다: 나이를 줄일 뿐 늘리지 않는다. retrying 은 기본 비활성.
        private fun remoteJwkSource(
            jwksUrl: java.net.URL,
            retriever: com.nimbusds.jose.util.ResourceRetriever,
            minRefetch: Duration,
        ): JWKSource<SecurityContext> =
            JWKSourceBuilder
                .create<SecurityContext>(jwksUrl, retriever)
                .cache(JWKS_MAX_AGE_SECONDS * 1000L, JWKSourceBuilder.DEFAULT_CACHE_REFRESH_TIMEOUT)
                .outageTolerant(false)
                .rateLimited(minRefetch.toMillis())
                .build()

        /** 테스트 전용: 주어진 키 원천으로 검증기를 만든다(Java `JwtValidator.withJwkSource` 동형). */
        internal fun withJwkSource(
            jwkSource: JWKSource<SecurityContext>,
            issuer: String,
            audience: String,
            allowedAlgs: Set<JWSAlgorithm>,
            skew: Duration,
        ): JwtValidator = JwtValidator(jwkSource, issuer, audience, allowedAlgs, skew)

        /** 테스트 전용: 네트워크 없이 정적 JWKS를 주입한다(Java `JwtValidator.withStaticJwks` 동형). */
        internal fun withStaticJwks(
            jwks: JWKSet,
            issuer: String,
            audience: String,
            allowedAlgs: Set<JWSAlgorithm> = setOf(JWSAlgorithm.RS256),
            skew: Duration = Duration.ofSeconds(30),
        ): JwtValidator = JwtValidator(ImmutableJWKSet<SecurityContext>(jwks), issuer, audience, allowedAlgs, skew)
    }
}

// Nimbus JWTClaimsSet → SDK 소유 ValidatedToken 매핑(I.1 동형). ValidatedToken data class(tokens.kt)는
// 그대로 두고, 이 모듈에서만 필요한 internal 변환 헬퍼를 jwt.kt에 둔다.
internal fun validatedTokenFrom(claimsSet: JWTClaimsSet): ValidatedToken {
    val audience = claimsSet.audience?.toList() ?: emptyList()
    val expiresAt = claimsSet.expirationTime?.toInstant()
    val issuedAt = claimsSet.issueTime?.toInstant()
    val claims = claimsSet.claims?.toMap() ?: emptyMap()
    return ValidatedToken(claimsSet.subject, claimsSet.issuer, audience, expiresAt, issuedAt, claims)
}

// 코루틴 취소를 Thread.interrupt로 전파하는 블로킹 호출 래퍼(§코루틴 래핑 핵심 계약). 플랫폼 스레드의 소켓
// 읽기는 interrupt를 무시하므로, 주입된 connect/read 타임아웃이 실질 상한이다.
// ⚠️ auth 운송(BoundedTransport)에는 인터럽트에 끝나는 자리가 하나 있다 — 경로의 연결이 모두 쓰이는 동안의 풀의
// 기다림. 그 끝은 InterruptedException 이 아니라 InterruptedIOException 이라 runInterruptible 이 취소로 알아보지
// 못하고, 코루틴은 취소된 뒤에도 그 예외(→ KeycloakTransportException)를 그대로 내보낸다(취소 뒤의 정상 반환만 취소가
// 된다). 취소된 코루틴에서 온 것이면 취소로 돌린다 — 취소되지 않았으면(읽기 타임아웃 SocketTimeoutException 등)
// 그대로다(`ConnectionReuseTest` 의 취소 사례).
internal suspend fun <T> onIo(block: () -> T): T =
    try {
        runInterruptible(Dispatchers.IO, block)
    } catch (e: InterruptedIOException) {
        currentCoroutineContext().ensureActive()
        throw e
    }
