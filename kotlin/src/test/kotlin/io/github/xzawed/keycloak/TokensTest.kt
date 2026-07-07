package io.github.xzawed.keycloak

import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class TokensTest {
    @Test
    fun `TokenSet toString masks accessToken`() {
        val t = TokenSet("access-value", null, null, "Bearer", null, null)
        assertTrue(t.toString().contains("accessToken=***"))
        assertFalse(t.toString().contains("access-value"))
    }

    @Test
    fun `TokenSet toString masks refreshToken when present`() {
        val t = TokenSet("a", "refresh-value", null, "Bearer", null, null)
        assertTrue(t.toString().contains("refreshToken=***"))
        assertFalse(t.toString().contains("refresh-value"))
    }

    @Test
    fun `TokenSet toString shows empty mask for null refreshToken`() {
        val t = TokenSet("a", null, null, "Bearer", null, null)
        assertTrue(t.toString().contains("refreshToken="))
        assertFalse(t.toString().contains("refreshToken=***"))
    }

    @Test
    fun `isExpired returns true when expiresAt is null`() {
        val t = TokenSet("a", null, null, "Bearer", null, null)
        assertTrue(t.isExpired())
    }

    @Test
    fun `isExpired returns false when expiresAt is well beyond skew`() {
        val fixed = Instant.parse("2026-01-01T00:00:00Z")
        val clock = Clock.fixed(fixed, ZoneOffset.UTC)
        val t = TokenSet("a", null, null, "Bearer", null, fixed.plusSeconds(120))
        assertFalse(t.isExpired(clock, Duration.ofSeconds(30)))
    }

    @Test
    fun `isExpired returns true when expiresAt is within skew of now`() {
        val fixed = Instant.parse("2026-01-01T00:00:00Z")
        val clock = Clock.fixed(fixed, ZoneOffset.UTC)
        val t = TokenSet("a", null, null, "Bearer", null, fixed.plusSeconds(10))
        assertTrue(t.isExpired(clock, Duration.ofSeconds(30)))
    }

    @Test
    fun `isExpired returns true when expiresAt already passed`() {
        val fixed = Instant.parse("2026-01-01T00:00:00Z")
        val clock = Clock.fixed(fixed, ZoneOffset.UTC)
        val t = TokenSet("a", null, null, "Bearer", null, fixed.minusSeconds(5))
        assertTrue(t.isExpired(clock, Duration.ofSeconds(30)))
    }

    @Test
    fun `isExpired boundary exactly at skew is expired`() {
        val fixed = Instant.parse("2026-01-01T00:00:00Z")
        val clock = Clock.fixed(fixed, ZoneOffset.UTC)
        val skew = Duration.ofSeconds(30)
        val t = TokenSet("a", null, null, "Bearer", null, fixed.plus(skew))
        assertTrue(t.isExpired(clock, skew))
    }

    @Test
    fun `ValidatedToken holds claims`() {
        val vt = ValidatedToken("sub", "issuer", listOf("aud1"), Instant.EPOCH, Instant.EPOCH, mapOf("k" to "v"))
        assertEquals("sub", vt.subject)
        assertEquals(listOf("aud1"), vt.audience)
        assertEquals("v", vt.claims["k"])
    }

    @Test
    fun `IntrospectionResult holds nullable fields`() {
        val active = IntrospectionResult(true, "user", "client")
        assertTrue(active.active)
        assertEquals("user", active.username)
        assertEquals("client", active.clientId)

        val inactive = IntrospectionResult(false, null, null)
        assertFalse(inactive.active)
        assertEquals(null, inactive.username)
        assertEquals(null, inactive.clientId)
    }

    @Test
    fun `AuthorizationRequest toString masks codeVerifier`() {
        val req = AuthorizationRequest("https://kc/auth?x=y", "verifier-secret-value", "state1", "nonce1")
        val s = req.toString()
        assertTrue(s.contains("codeVerifier=***"))
        assertFalse(s.contains("verifier-secret-value"))
        assertTrue(s.contains("state=state1"))
        assertTrue(s.contains("nonce=nonce1"))
    }
}
