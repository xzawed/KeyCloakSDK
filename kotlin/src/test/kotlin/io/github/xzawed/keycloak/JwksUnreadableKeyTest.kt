package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.text.ParseException
import java.time.Duration
import java.util.Date
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * 못 읽는 원소 하나가 JWKS 전체를 버리면 안 된다(RFC 7517 §5 — 이해 못 하는 kty · 빠진 필수 멤버 · 범위 밖 값의 키는 무시한다).
 *
 * Nimbus 의 `JWKSet.parse` 는 모르는 kty 만 건너뛰고, 그 밖의 못 읽는 원소 하나(지원 밖 곡선 P-192 · `n` 이 빠진 RSA · JWK 가
 * 아닌 원소)로 키셋 전체를 `ParseException` 으로 거부한다 — 같은 키셋의 정상 키로 서명한 토큰까지 거부됐다(등록부
 * jwks-unsupported-key-rejects-set · 아홉 언어 실측은 PR 본문). Java 자매 테스트와 같은 모양이다. 못 읽는 원소를 **앞**에 둔다.
 */
internal class JwksUnreadableKeyTest {
    @ParameterizedTest(name = "{0}")
    @MethodSource("unreadable")
    fun keyItCannotReadIsSkippedNotTheWholeSet(
        name: String,
        bad: String,
    ): Unit =
        runBlocking {
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val set = "{\"keys\":[$bad,${k1.toPublicJWK().toJSONString()}]}"
            // 전제 — Nimbus 자신은 이 키셋을 통째로 거부한다(아니면 이 칸은 아무것도 재지 않는다).
            assertFailsWith<ParseException>("$name 가 든 키셋을 Nimbus 가 읽는다") { JWKSet.parse(set) }

            val server = serve(AtomicReference(set.toByteArray(StandardCharsets.UTF_8)), AtomicInteger())
            try {
                val config = config(server)
                val endpoints = OidcEndpoints.forRealm(config)
                val validator = JwtValidator.forRealm(endpoints, config, "app")

                assertEquals(
                    "user-1",
                    validator.validate(token(endpoints, k1, "user-1")).subject,
                    "$name 하나가 키셋 전체를 버렸다 — 정상 키로 서명한 토큰이 거부된다",
                )
            } finally {
                server.stop(0)
            }
        }

    /**
     * 대조 — 쓸 수 있는 원소가 하나도 없는 키셋은 빈 키셋처럼 조회 실패이고 좋은 캐시를 덮지 않는다. 건너뛰기가 「다 건너뛰고 빈
     * 키셋을 올림」으로 새면 마지막 두 단언이 운다. ⚠️ 재조회 단언이 전제다(JwksEmptyKeysetTest 와 같은 이유).
     */
    @Test
    fun onlyUnreadableKeysIsRefusedAndDoesNotPoisonGoodCache(): Unit =
        runBlocking {
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val k2 = RSAKeyGenerator(2048).keyID("k2").generate()
            val hits = AtomicInteger()
            val body = AtomicReference(JWKSet(k1.toPublicJWK()).toString().toByteArray(StandardCharsets.UTF_8))
            val server = serve(body, hits)
            try {
                val config = config(server)
                val endpoints = OidcEndpoints.forRealm(config)
                val validator = JwtValidator.forRealm(endpoints, config, "app")

                val good = token(endpoints, k1, "user-1")
                validator.validate(good)
                val before = hits.get()

                val unreadableOnly = "{\"keys\":[${UNREADABLE.joinToString(",") { it.second }}]}"
                body.set(unreadableOnly.toByteArray(StandardCharsets.UTF_8))
                assertFailsWith<TokenValidationException> { validator.validate(token(endpoints, k2, "user-1")) }
                assertTrue(
                    hits.get() > before,
                    "미해결 kid 가 재조회를 일으키지 않으면 못 읽는 키셋을 본 적이 없다 — 이 테스트는 공허하다",
                )

                assertEquals("user-1", validator.validate(good).subject, "못 읽는 키만 있는 200 이 좋은 캐시를 덮었다")
                assertEquals(
                    "user-2",
                    validator.validate(token(endpoints, k1, "user-2")).subject,
                    "못 읽는 키만 있는 200 뒤 같은 키로 새로 서명한 토큰도 통과해야 한다",
                )
            } finally {
                server.stop(0)
            }
        }

    private fun serve(
        body: AtomicReference<ByteArray>,
        hits: AtomicInteger,
    ): HttpServer {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/realms/r/protocol/openid-connect/certs") { exchange ->
            hits.incrementAndGet()
            val bytes = body.get()
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        return server
    }

    private fun config(server: HttpServer) =
        KeycloakConfig(
            serverUrl = "http://127.0.0.1:${server.address.port}",
            realm = "r",
            clientId = "app",
            jwksMinRefetch = Duration.ZERO,
        )

    private fun token(
        endpoints: OidcEndpoints,
        key: RSAKey,
        sub: String,
    ): String {
        val jwt =
            SignedJWT(
                JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(),
                JWTClaimsSet
                    .Builder()
                    .issuer(endpoints.issuer)
                    .audience("app")
                    .subject(sub)
                    .expirationTime(Date(System.currentTimeMillis() + 60_000))
                    .build(),
            )
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    companion object {
        private val UNREADABLE =
            listOf(
                "EC P-192" to
                    "{\"kty\":\"EC\",\"crv\":\"P-192\",\"x\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX\"," +
                    "\"y\":\"GBkaGxwdHh8gISIjJCUmJygpKissLS4v\",\"kid\":\"p192\",\"use\":\"sig\"}",
                "RSA without n" to "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"kid\":\"missingn\",\"use\":\"sig\"}",
                "not a JWK" to "\"not-a-jwk\"",
            )

        @JvmStatic
        fun unreadable(): List<Arguments> = UNREADABLE.map { (name, bad) -> Arguments.of(name, bad) }
    }
}
