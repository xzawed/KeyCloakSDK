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
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.Date
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * 200 + `{"keys":[]}` 가 이미 올라간 좋은 JWKS 캐시를 덮으면 안 된다(#520 의 JVM 절반).
 *
 * 실측 2026-09-24(수정 전): 빈 200 뒤 같은 k1 토큰도, 새로 서명한 k1 토큰도 `no matching key(s)`
 * 로 거부됐다. ⚠️ 재조회 단언이 전제다 — 두 번째 요청이 없으면 빈 응답을 본 적이 없어 k1 통과가
 * 아무것도 증명하지 않는다(판정 행렬의 「판정 불가」를 실패로 바꾼다).
 */
internal class JwksEmptyKeysetTest {
    @Test
    fun empty200DoesNotPoisonGoodCache(): Unit =
        runBlocking {
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val k2 = RSAKeyGenerator(2048).keyID("k2").generate()
            val hits = AtomicInteger()
            val body =
                AtomicReference(
                    JWKSet(k1.toPublicJWK()).toString().toByteArray(StandardCharsets.UTF_8),
                )

            val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            server.createContext("/realms/r/protocol/openid-connect/certs") { exchange ->
                hits.incrementAndGet()
                val bytes = body.get()
                exchange.responseHeaders.add("Content-Type", "application/json")
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            server.start()
            try {
                val config =
                    KeycloakConfig(
                        serverUrl = "http://127.0.0.1:${server.address.port}",
                        realm = "r",
                        clientId = "app",
                        jwksMinRefetch = Duration.ZERO,
                    )
                val endpoints = OidcEndpoints.forRealm(config)
                val validator = JwtValidator.forRealm(endpoints, config, "app")

                val good = token(endpoints, k1, "user-1")
                validator.validate(good)
                val before = hits.get()

                body.set("{\"keys\":[]}".toByteArray(StandardCharsets.UTF_8))
                val unknownKid = token(endpoints, k2, "user-1")
                assertFailsWith<TokenValidationException> { validator.validate(unknownKid) }
                assertTrue(
                    hits.get() > before,
                    "미해결 kid 가 재조회를 일으키지 않으면 빈 응답을 본 적이 없다 — 이 테스트는 공허하다",
                )

                assertEquals("user-1", validator.validate(good).subject, "빈 200 이 좋은 캐시를 덮었다")
                assertEquals(
                    "user-2",
                    validator.validate(token(endpoints, k1, "user-2")).subject,
                    "빈 200 뒤 같은 키로 새로 서명한 토큰도 통과해야 한다",
                )
            } finally {
                server.stop(0)
            }
        }

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
}
