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
}
