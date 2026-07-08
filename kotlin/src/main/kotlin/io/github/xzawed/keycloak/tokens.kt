package io.github.xzawed.keycloak

import java.time.Clock
import java.time.Duration
import java.time.Instant

// 값타입 = data class + toString 오버라이드(자동 toString이 토큰/시크릿 전량 노출 → 필수)
public data class TokenSet(
    public val accessToken: String,
    public val refreshToken: String?,
    public val idToken: String?,
    public val tokenType: String,
    public val scope: String?,
    public val expiresAt: Instant?,
) {
    public fun isExpired(
        clock: Clock = Clock.systemUTC(),
        skew: Duration = Duration.ofSeconds(30),
    ): Boolean = expiresAt == null || !Instant.now(clock).plus(skew).isBefore(expiresAt)

    override fun toString(): String =
        "TokenSet(tokenType=$tokenType, scope=$scope, accessToken=***, refreshToken=${mask(refreshToken)}, expiresAt=$expiresAt)"
}

public data class ValidatedToken(
    public val subject: String?,
    public val issuer: String?,
    public val audience: List<String>,
    public val expiresAt: Instant?,
    public val issuedAt: Instant?,
    public val claims: Map<String, Any?>,
)

public data class IntrospectionResult(
    public val active: Boolean,
    public val username: String?,
    public val clientId: String?,
)

public data class AuthorizationRequest(
    public val authorizationUrl: String,
    public val codeVerifier: String,
    public val state: String,
    public val nonce: String,
) {
    override fun toString(): String =
        "AuthorizationRequest(authorizationUrl=$authorizationUrl, codeVerifier=***, state=$state, nonce=$nonce)"
}
