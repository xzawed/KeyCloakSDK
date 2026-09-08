package io.github.xzawed.keycloak

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals

internal class TokenProviderTest {
    private fun tokenSet(
        accessToken: String,
        expiresAt: Instant?,
    ) = TokenSet(accessToken, null, null, "Bearer", null, expiresAt)

    @Test
    fun `first accessToken call fetches once and returns its accessToken`() =
        runTest {
            val fixed = Instant.parse("2026-01-01T00:00:00Z")
            val clock = Clock.fixed(fixed, ZoneOffset.UTC)
            val calls = AtomicInteger(0)
            val provider =
                ClientCredentialsTokenProvider(
                    fetch = {
                        calls.incrementAndGet()
                        tokenSet("token-1", fixed.plusSeconds(300))
                    },
                    clock = clock,
                )

            val result = provider.accessToken()

            assertEquals("token-1", result)
            assertEquals(1, calls.get())
        }

    @Test
    fun `second call within validity returns cached token without refetching`() =
        runTest {
            val fixed = Instant.parse("2026-01-01T00:00:00Z")
            val clock = Clock.fixed(fixed, ZoneOffset.UTC)
            val calls = AtomicInteger(0)
            val provider =
                ClientCredentialsTokenProvider(
                    fetch = {
                        calls.incrementAndGet()
                        tokenSet("token-1", fixed.plusSeconds(300))
                    },
                    clock = clock,
                )

            provider.accessToken()
            val second = provider.accessToken()

            assertEquals("token-1", second)
            assertEquals(1, calls.get())
        }

    @Test
    fun `fetch is called again after the cached token expires`() =
        runTest {
            val start = Instant.parse("2026-01-01T00:00:00Z")
            var now = start
            val mutableClock =
                object : Clock() {
                    override fun getZone() = ZoneOffset.UTC

                    override fun withZone(zone: java.time.ZoneId?) = this

                    override fun instant() = now
                }
            val calls = AtomicInteger(0)
            val provider =
                ClientCredentialsTokenProvider(
                    fetch = {
                        val n = calls.incrementAndGet()
                        tokenSet("token-$n", now.plusSeconds(60))
                    },
                    clock = mutableClock,
                    skew = Duration.ofSeconds(30),
                )

            val first = provider.accessToken()
            assertEquals("token-1", first)
            assertEquals(1, calls.get())

            // advance clock well past expiry (60s validity, 30s skew)
            now = start.plusSeconds(120)

            val second = provider.accessToken()
            assertEquals("token-2", second)
            assertEquals(2, calls.get())
        }

    @Test
    fun `concurrent callers single-flight to exactly one fetch`() =
        runTest {
            val fixed = Instant.parse("2026-01-01T00:00:00Z")
            val clock = Clock.fixed(fixed, ZoneOffset.UTC)
            val calls = AtomicInteger(0)
            val provider =
                ClientCredentialsTokenProvider(
                    fetch = {
                        calls.incrementAndGet()
                        delay(100)
                        tokenSet("token-1", fixed.plusSeconds(300))
                    },
                    clock = clock,
                )

            val results =
                (1..10)
                    .map { async { provider.accessToken() } }
                    .awaitAll()

            assertEquals(1, calls.get())
            assertEquals(List(10) { "token-1" }, results)
        }

    // ⚠️ 이 생성자의 `skew` 기본값은 `TokenSet.isExpired` 의 기본값과 **별개의 사본**이다 —
    // provider 는 자기 필드를 `isExpired(clock, skew)` 로 항상 넘기므로 `TokensTest` 의 핀이
    // 여기를 덮지 않는다. 그래서 같은 계약을 여기서 따로 잰다(둘 다 어느 가드도 안 보던 자리다).
    //
    // ⚠️ **`30` 을 다시 적지 않는다** — `KeycloakConfig` 를 인자 없이 만들어 파생한다.
    private fun derivedClockSkew(): Duration = KeycloakConfig(serverUrl = "http://kc.example", realm = "r", clientId = "c").clockSkew

    @Test
    fun `constructor default skew equals KeycloakConfig clockSkew`() =
        runTest {
            val skew = derivedClockSkew()
            val start = Instant.parse("2026-01-01T00:00:00Z")
            var now = start
            val movingClock =
                object : Clock() {
                    override fun getZone() = ZoneOffset.UTC

                    override fun withZone(zone: java.time.ZoneId?): Clock = this

                    override fun instant(): Instant = now
                }

            // (1) 기본값이 **커지면** 잡는다 — 만료까지 skew+1ms 남은 토큰은 아직 캐시여야 한다.
            val tightCalls = AtomicInteger(0)
            val tight =
                ClientCredentialsTokenProvider(
                    fetch = {
                        tightCalls.incrementAndGet()
                        tokenSet("tight", start.plus(skew).plusMillis(1))
                    },
                    clock = movingClock,
                )
            tight.accessToken()
            tight.accessToken()
            assertEquals(1, tightCalls.get(), "기본 skew 가 config.clockSkew($skew) 보다 크다 — 너무 일찍 재발급한다")

            // (2) 기본값이 **작아지면** 잡는다 — skew+1ms 를 지나면 재발급이어야 한다.
            val wideCalls = AtomicInteger(0)
            val wide =
                ClientCredentialsTokenProvider(
                    fetch = {
                        wideCalls.incrementAndGet()
                        tokenSet("wide", start.plus(skew).plus(skew))
                    },
                    clock = movingClock,
                )
            now = start
            wide.accessToken()
            now = start.plus(skew).plusMillis(1)
            wide.accessToken()
            assertEquals(2, wideCalls.get(), "기본 skew 가 config.clockSkew($skew) 보다 작다 — 만료 직전 토큰을 계속 쓴다")
        }
}
