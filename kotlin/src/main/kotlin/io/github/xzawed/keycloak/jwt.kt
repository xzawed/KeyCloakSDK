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
import kotlinx.coroutines.runInterruptible
import java.net.MalformedURLException
import java.net.URI
import java.time.Duration

// jwt.kt — JwtValidator: Java SDK의 JwtValidator(io.github.xzawed.keycloak.auth.JwtValidator)와 100%
// 동형인 하드닝 불변식(§jwt)을 지킨다: RS256 alg 핀 · alg=none/미서명 명시 거부 · iss 정확일치
// (exactMatchClaims엔 issuer만 — aud를 넣으면 다중값 정상 토큰이 오탐 거부된다) · aud 포함검사 ·
// exp 필수 · 클록스큐 · DoS-safe JWKS(JWKSourceBuilder 기본값 = cache+rateLimited만 활성 —
// refreshAhead/retrying/outageTolerant는 기본 비활성. 위조 서명은 재조회 유발 안 함·미해결 kid만 rate-limited 재조회).
public class JwtValidator private constructor(
    jwkSource: JWKSource<SecurityContext>,
    issuer: String,
    audience: String,
    allowedAlgs: Set<JWSAlgorithm>,
    skew: Duration,
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
     * accessToken을 검증하고 SDK 소유 [ValidatedToken]을 반환한다 — 어떤 실패 경로에서도 Nimbus 타입은
     * 공개 API에 노출하지 않는다. JWKS 조회는 블로킹 I/O일 수 있어 [runInterruptible]로 감싼다.
     */
    public suspend fun validate(accessToken: String): ValidatedToken =
        try {
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

    public companion object {
        /** 실 JWKS 엔드포인트를 지연 조회하는 운영용 팩토리(non-suspend — 조회는 첫 [validate] 호출 시점). */
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
            // JWKSourceBuilder 기본값 중 DoS 방지에 실제로 기여하는 것은 cache + rateLimited(둘 다 기본
            // true)뿐이다 — 위조 kid를 연속 주입해도 JWKS 재조회가 무제한으로 증폭되지 않는다.
            // retrying/outageTolerant는 기본 false(비활성)이므로 이 체인에 포함되지 않는다. rateLimited
            // 간격은 config로 설정 가능하게 한다(기본 30초 = Nimbus DEFAULT_RATE_LIMIT_MIN_INTERVAL 동형).
            // ⚠️ Nimbus는 rate-limit 간격이 캐시 TTL(기본 5분) 이상이면 build()에서
            // IllegalStateException을 던진다(캐시가 만료돼도 rate-limit이 재조회를 막아 JWKS를 영영
            // 갱신할 수 없는 구성이므로 정당한 거부다). 그대로 두면 이 foreign 예외가 공개 API로
            // 새어나가므로(§4 위반) 경계에서 sealed KeycloakException 계급으로 바꾼다 — Java 동형.
            val source: JWKSource<SecurityContext> =
                try {
                    JWKSourceBuilder
                        .create<SecurityContext>(jwksUrl, retriever)
                        .rateLimited(config.jwksMinRefetch.toMillis())
                        .build()
                } catch (e: IllegalStateException) {
                    throw KeycloakConfigException(
                        "jwksMinRefetch (${config.jwksMinRefetch.toSeconds()}s) must be shorter than " +
                            "the JWKS cache time-to-live " +
                            "(${JWKSourceBuilder.DEFAULT_CACHE_TIME_TO_LIVE / 1000}s)",
                        e,
                    )
                }
            return JwtValidator(source, endpoints.issuer, audience, allowedAlgs, config.clockSkew)
        }

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

// 코루틴 취소를 Thread.interrupt로 전파하는 블로킹 호출 래퍼(§코루틴 래핑 핵심 계약). Nimbus의
// HttpURLConnection 기반 JWKS 조회는 interrupt를 완전히 준수하지 않으므로, 주입된 connect/read
// 타임아웃이 실질 상한이다.
internal suspend fun <T> onIo(block: () -> T): T = runInterruptible(Dispatchers.IO, block)
