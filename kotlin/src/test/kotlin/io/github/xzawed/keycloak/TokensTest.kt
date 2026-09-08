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

    // ⚠️ **사용처 기본값은 `KeycloakConfig.clockSkew` 와 같아야 한다 — 그런데 아무도 안 봤다.**
    // 교차언어 가드(`scripts/test/test-security-defaults.sh`)의 축 1 은 **언어당 파일 하나**만 읽고,
    // kotlin 은 `config.kt` 다. 그래서 `tokens.kt`·`tokenprovider.kt`·`jwt.kt` 의 `Duration.ofSeconds(30)`
    // 셋은 어느 축에도 걸리지 않았다(실측 2026-09-08). 그 셋 중 하나가 300 이 돼도 CI 는 초록이다.
    //
    // ⚠️ **여기에 `30` 을 다시 적지 않는다** — 그러면 두 번째 정의 자리를 하나 더 만드는 것이다.
    // `KeycloakConfig` 를 인자 없이 만들어 그 값을 **파생**한다. 정책값 30 자체를 못박는 것은
    // `ConfigTest` 의 몫이고, 여기서는 「사용처가 그것과 같은가」만 본다.
    //
    // ⚠️ 기본 인자 값은 코틀린에서 **호출하지 않고는 읽을 수 없다**(합성 `$default` 브리지에 들어간다.
    // `KParameter` 는 `isOptional` 만 주고, `kotlin-reflect` 는 이 프로젝트 테스트 클래스패스에 없다).
    // 그래서 인자를 **생략해 호출하고 경계 동작을 본다** — 소스 grep 보다 강한 오라클이다.
    private fun derivedClockSkew(): Duration = KeycloakConfig(serverUrl = "http://kc.example", realm = "r", clientId = "c").clockSkew

    @Test
    fun `isExpired default skew equals KeycloakConfig clockSkew`() {
        val skew = derivedClockSkew()
        val now = Instant.parse("2026-01-01T00:00:00Z")
        val clock = Clock.fixed(now, ZoneOffset.UTC)

        // 경계 바로 위: expiresAt == now + skew → 만료로 봐야 한다(기본값이 줄면 여기서 깨진다).
        val atBoundary = TokenSet("a", null, null, "Bearer", null, now.plus(skew))
        assertTrue(
            atBoundary.isExpired(clock),
            "기본 skew 가 config.clockSkew($skew) 보다 작다 — 사용처 기본값이 갈렸다",
        )

        // 경계 바로 아래: 1ms 더 남았으면 아직 유효해야 한다(기본값이 늘면 여기서 깨진다).
        val justInside = TokenSet("a", null, null, "Bearer", null, now.plus(skew).plusMillis(1))
        assertFalse(
            justInside.isExpired(clock),
            "기본 skew 가 config.clockSkew($skew) 보다 크다 — 사용처 기본값이 갈렸다",
        )
    }
}
