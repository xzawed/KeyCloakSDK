package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWK
import com.nimbusds.jose.jwk.JWKSelector
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jose.jwk.source.CachingJWKSetSource
import com.nimbusds.jose.jwk.source.JWKSetBasedJWKSource
import com.nimbusds.jose.jwk.source.JWKSetCacheRefreshEvaluator
import com.nimbusds.jose.jwk.source.JWKSetSource
import com.nimbusds.jose.jwk.source.JWKSetSourceWrapper
import com.nimbusds.jose.jwk.source.JWKSource
import com.nimbusds.jose.jwk.source.OutageTolerantJWKSetSource
import com.nimbusds.jose.proc.SecurityContext
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.test.runTest
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.Date
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

// JWKS 키 집합의 수명 300초 — 지나면 콜드 캐시처럼 다시 가져오고, 낡은 집합으로 물러서지 않는다(등록부
// jwks-cache-lifetime-divergent, 판정 2026-10-29 — 아홉 언어가 같은 규칙). Java `JwksMaxAgeTest` 와 동형이다.
//
// 시계: Nimbus 는 시각을 JWKSetBasedJWKSource.get 한 자리에서만 System.currentTimeMillis() 로 읽어 체인 아래로
// 넘긴다 — 캐시 만료 · rate-limit 창 · refresh-ahead 가 모두 그 값을 쓴다. 그래서 forRealm 이 만든 체인(jwkSource())은
// 그대로 두고 맨 위 어댑터만 가짜 시계로 바꾼다. FakeClockJwkSource 는 JWKSetBasedJWKSource.get 을 줄 단위로 옮긴
// 것이다(시각을 읽는 자리만 다르다).
//
// ⚠️ 시각은 리터럴(299 · 301 · 350초)이다 — 상수에서 파생하면 상수를 바꾼 변이를 따라가 초록으로 남는다.
//
// ⚠️ JVM 이 다른 둘(규칙은 같다 — 300초가 지난 집합은 쓰지 않는다)과 잔여(벽시계 · 시작 시각부터 셈)는 Java
// `JwksMaxAgeTest` 머리 주석이 소유한다: 실패 백오프 대신 Nimbus rate-limit(30초 창 · 창당 2회)이고, refresh-ahead 가
// 마지막 30초의 검증을 캐시로 통과시키며 백그라운드로 미리 가져온다 — 그래서 T1 의 「조회 없음」은 269초에서 잰다.
internal class JwksMaxAgeTest {
    private val second = 1_000L

    @Test
    fun `T1 the key set is reused without a fetch and fetched exactly once after 300 s`() =
        runTest {
            val k1 = key("k1")
            Idp(k1).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                val token = rig.token(k1)
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(1, idp.hits.get())

                now.addAndGet(269 * second) // refresh-ahead 창(마지막 30초) 바로 앞
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(1, settle(idp.hits), "269초 된 집합은 조회 없이 써야 한다")

                now.addAndGet(32 * second) // t0 + 301
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(2, settle(idp.hits), "300초가 지나면 다음 검증이 정확히 한 번 조회한다")
            }
        }

    // T1 의 299초 — refresh-ahead: 캐시로 통과하고 백그라운드로 한 번 가져온다. 그 집합이 나이를 다시 센다.
    @Test
    fun `refresh-ahead serves a validation at 299 s from the cache and refreshes once in the background`() =
        runTest {
            val k1 = key("k1")
            Idp(k1).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                val token = rig.token(k1)
                rig.validator.validate(token)

                now.addAndGet(299 * second)
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(2, settle(idp.hits), "마지막 30초의 검증은 백그라운드로 정확히 한 번 미리 가져온다")

                now.addAndGet(2 * second) // t0 + 301 — 299초에 받은 집합으로는 2초다
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(2, settle(idp.hits))
            }
        }

    // refresh-ahead 는 장애 중에 나이를 늘리지 않는다 — 299초의 백그라운드 조회가 503 이면 301초의 검증은 거부된다.
    @Test
    fun `refresh-ahead during an outage does not extend the age`() =
        runTest {
            val k1 = key("k1")
            Idp(k1).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                val token = rig.token(k1)
                rig.validator.validate(token)
                idp.status = 503

                now.addAndGet(299 * second)
                assertEquals("k1", rig.validator.validate(token).subject, "299초 — 아직 나이 안이다")
                assertEquals(2, settle(idp.hits), "백그라운드 조회 한 번(실패)")

                now.addAndGet(2 * second) // t0 + 301
                assertFailsWith<TokenValidationException>("300초가 지난 집합으로 물러서면 안 된다") {
                    rig.validator.validate(token)
                }
                assertEquals(3, idp.hits.get(), "299초가 연 창의 크레딧 한 번")
            }
        }

    // 체인의 모양 — 캐시 TTL 300초 · outage tolerance(장애 중 낡은 집합) 가 어디에도 없다. T2 가 행동으로 같은 것을 잰다.
    @Test
    fun `the chain caches for 300 s and has no outage fallback`() {
        val config = KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app")
        val src = JwtValidator.forRealm(OidcEndpoints.forRealm(config), config, "app").jwkSource()
        val top = assertIs<JWKSetBasedJWKSource<*>>(src).getJWKSetSource()
        val ttl = assertIs<CachingJWKSetSource<*>>(top).getTimeToLive()
        assertEquals(300_000L, ttl)
        // ⚠️ Nimbus 기본값도 300초라 `.cache(...)` 를 지워도 위 단언은 초록이다 — 상수가 실제로 배선됐는지는 이 줄이 본다.
        assertEquals(JWKS_MAX_AGE_SECONDS * 1000L, ttl, "캐시 TTL 이 JWKS_MAX_AGE_SECONDS 에서 오지 않는다")
        var depth = 0
        var s: JWKSetSource<*>? = top
        while (s is JWKSetSourceWrapper<*>) {
            assertFalse(s is OutageTolerantJWKSetSource<*>, "outage tolerance 가 체인에 있다 — 장애 중 낡은 집합을 돌려준다")
            depth++
            s = s.getSource()
        }
        assertTrue(depth >= 2, "체인을 걷지 못했다(refresh-ahead 캐시 → rate-limit) — 이 단언은 공허하다")
    }

    @Test
    fun `T2 after expiry an outage rejects, is bounded by the window and recovers`() =
        runTest {
            val k1 = key("k1")
            Idp(k1).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                val token = rig.token(k1)
                rig.validator.validate(token)
                idp.status = 503

                now.addAndGet(301 * second)
                assertFailsWith<TokenValidationException> { rig.validator.validate(token) }
                assertEquals(2, idp.hits.get(), "정확히 한 번 시도하고, 낡은 키로 물러서지 않는다")
                repeat(5) { assertFailsWith<TokenValidationException> { rig.validator.validate(token) } }
                // 창(jwksMinRefetch 30초) 안: Nimbus 는 창을 열 때 한 번을 크레딧해 창당 두 번이다(.claude/rules/security.md).
                assertEquals(3, idp.hits.get(), "창 안의 추가 검증은 크레딧된 한 번 말고는 IdP 로 나가지 않는다")

                idp.status = 200
                now.addAndGet(31 * second)
                assertEquals("k1", rig.validator.validate(token).subject)
                assertEquals(4, idp.hits.get(), "창이 지나면 한 번 가져와 성공한다")
            }
        }

    @Test
    fun `T3 a key the IdP removed is rejected after 300 s`() =
        runTest {
            val k1 = key("k1")
            val k2 = key("k2")
            Idp(k1, k2).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                rig.validator.validate(rig.token(k1))
                idp.serve(k2)

                now.addAndGet(301 * second)
                assertFailsWith<TokenValidationException> { rig.validator.validate(rig.token(k1)) }
                // 나이로 다시 가져온 것 하나 + 미해결 kid 의 재조회 하나(같은 창의 크레딧).
                assertEquals(3, idp.hits.get())
                assertEquals("k2", rig.validator.validate(rig.token(k2)).subject)
                assertEquals(3, idp.hits.get())
            }
        }

    @Test
    fun `T4 a forced refetch restarts the age`() =
        runTest {
            val k1 = key("k1")
            val k2 = key("k2")
            Idp(k1).use { idp ->
                val now = AtomicLong(System.currentTimeMillis())
                val rig = rig(idp, now)
                rig.validator.validate(rig.token(k1))
                idp.serve(k1, k2)

                now.addAndGet(100 * second)
                assertEquals("k2", rig.validator.validate(rig.token(k2)).subject) // 미해결 kid → 재조회
                assertEquals(2, idp.hits.get())

                now.addAndGet(250 * second) // t0 + 350 — 재조회로부터는 250초
                assertEquals("k1", rig.validator.validate(rig.token(k1)).subject)
                assertEquals(2, settle(idp.hits), "재조회가 300초를 다시 세야 한다")
            }
        }

    // ── 도구 ──

    // forRealm 이 만든 검증기 그대로 — 키 원천의 맨 위 어댑터만 가짜 시계로 바꾼다.
    private fun rig(
        idp: Idp,
        now: AtomicLong,
    ): Rig {
        val config = KeycloakConfig(serverUrl = idp.baseUrl(), realm = "r", clientId = "app")
        val endpoints = OidcEndpoints.forRealm(config)
        val production = JwtValidator.forRealm(endpoints, config, "app")
        val clocked =
            JwtValidator.withJwkSource(
                FakeClockJwkSource(production.jwkSource(), now),
                endpoints.issuer,
                "app",
                setOf(JWSAlgorithm.RS256),
                config.clockSkew,
            )
        return Rig(clocked, endpoints.issuer)
    }

    private class Rig(
        val validator: JwtValidator,
        private val issuer: String,
    ) {
        fun token(key: RSAKey): String {
            val jwt =
                SignedJWT(
                    JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(),
                    JWTClaimsSet
                        .Builder()
                        .issuer(issuer)
                        .audience("app")
                        .subject(key.keyID)
                        .expirationTime(Date(System.currentTimeMillis() + 600_000))
                        .build(),
                )
            jwt.sign(RSASSASigner(key))
            return jwt.serialize()
        }
    }

    // JWKSetBasedJWKSource.get 을 줄 단위로 옮겼다 — 시각만 now 에서 읽는다.
    private class FakeClockJwkSource(
        production: JWKSource<SecurityContext>,
        private val now: AtomicLong,
    ) : JWKSource<SecurityContext> {
        @Suppress("UNCHECKED_CAST")
        private val chain: JWKSetSource<SecurityContext> =
            assertIs<JWKSetBasedJWKSource<*>>(
                production,
                "forRealm 의 키 원천이 JWKSetBasedJWKSource 가 아니다 — 이 어댑터가 옮긴 get() 이 더는 운영 경로가 아니다",
            ).getJWKSetSource() as JWKSetSource<SecurityContext>

        override fun get(
            jwkSelector: JWKSelector,
            context: SecurityContext?,
        ): List<JWK> {
            val currentTime = now.get()
            val jwkSet = chain.getJWKSet(JWKSetCacheRefreshEvaluator.noRefresh(), currentTime, context)
            var select = jwkSelector.select(jwkSet)
            if (select.isEmpty()) {
                val recentJwkSet =
                    chain.getJWKSet(JWKSetCacheRefreshEvaluator.referenceComparison(jwkSet), currentTime, context)
                select = jwkSelector.select(recentJwkSet)
            }
            return select
        }
    }

    // 백그라운드(refresh-ahead) 조회가 끝날 틈을 준다 — 그동안 hits 가 늘면 그것까지 센다.
    private fun settle(hits: AtomicInteger): Int {
        var seen: Int
        do {
            seen = hits.get()
            Thread.sleep(300)
        } while (hits.get() != seen)
        return seen
    }

    private fun key(kid: String): RSAKey = RSAKeyGenerator(2048).keyID(kid).generate()

    // /certs 하나를 내는 IdP. status·본문은 시험 도중 바꾼다. hits 는 모든 요청을 센다.
    private class Idp(
        vararg keys: RSAKey,
    ) : Closeable {
        val hits = AtomicInteger()

        @Volatile
        var status = 200

        @Volatile
        private var body: ByteArray = jwks(keys.toList())

        private val server: HttpServer =
            HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
                createContext(CERTS) { ex ->
                    hits.incrementAndGet()
                    if (status != 200) {
                        ex.sendResponseHeaders(status, -1)
                        ex.close()
                        return@createContext
                    }
                    val b = body
                    ex.responseHeaders.add("Content-Type", "application/json")
                    ex.sendResponseHeaders(200, b.size.toLong())
                    ex.responseBody.use { it.write(b) }
                }
                start()
            }

        fun serve(vararg keys: RSAKey) {
            body = jwks(keys.toList())
        }

        fun baseUrl(): String = "http://127.0.0.1:${server.address.port}"

        override fun close() = server.stop(0)

        private fun jwks(keys: List<RSAKey>): ByteArray = JWKSet(keys.map { it.toPublicJWK() }).toString().toByteArray()
    }

    private companion object {
        const val CERTS = "/realms/r/protocol/openid-connect/certs"
    }
}
