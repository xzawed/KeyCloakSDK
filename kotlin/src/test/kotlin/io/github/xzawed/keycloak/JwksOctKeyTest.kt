package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.MACSigner
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jose.jwk.source.JWKSource
import com.nimbusds.jose.proc.SecurityContext
import com.nimbusds.jose.util.Base64URL
import com.nimbusds.jose.util.Resource
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.assertAll
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import org.junit.jupiter.params.provider.ValueSource
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.time.Duration
import java.util.Base64
import java.util.Date
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * ⚠️ JWKS 의 대칭(`oct`) 키는 검증 키가 아니다 — JWKS 는 공개 문서라 그 안의 대칭 키는 비밀이 아니다. HS256 을 허용한 설정에서
 * 그 키로 서명한 위조 토큰이 통과했다 — Nimbus 의 `JWSVerificationKeySelector` 는 HS 에 `OctetSequenceKey` 를 고르고, kid 가 없는
 * 토큰도 그렇다(등록부 jwks-oct-key-usable-with-hs · 아홉 언어 실측은 PR 본문). Keycloak 은 oct 를 내지 않는다. Java 자매 시험과 같은
 * 모양이다.
 */
internal class JwksOctKeyTest {
    @ParameterizedTest(name = "{0}")
    @MethodSource("octShapes")
    fun octKeyIsNeverAVerificationKey(
        name: String,
        members: String,
        kid: String?,
    ): Unit =
        runBlocking {
            val secret = ByteArray(32).also { RANDOM.nextBytes(it) }
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val oct = "{\"kty\":\"oct\",\"k\":\"${Base64URL.encode(secret)}\",$members}"
            val server = serve("{\"keys\":[$oct,${k1.toPublicJWK().toJSONString()}]}")
            try {
                val config = hsAllowed(server)
                val endpoints = OidcEndpoints.forRealm(config)
                val validator = JwtValidator.forRealm(endpoints, config, "app")

                assertFailsWith<TokenValidationException>("$name: JWKS 의 oct 키로 서명한 위조 토큰이 통과했다") {
                    validator.validate(hsToken(endpoints, secret, kid))
                }
                // 대조 — 같은 키셋의 RSA 토큰은 통과한다(oct 를 버리는 것이 키셋 전체를 버리지 않는다).
                assertEquals("user-1", validator.validate(rsToken(endpoints, k1)).subject)
            } finally {
                server.stop(0)
            }
        }

    /** oct 만 있는 키셋은 쓸 수 있는 키가 없는 키셋이다 — 빈 키셋처럼 조회 실패로 닫는다(Nimbus 에 빈 집합을 넘기지 않는다). */
    @Test
    fun onlyAnOctKeyHasNoUsableKeys() {
        val res =
            Resource(
                "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k1\",\"k\":\"c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA\"}]}",
                "application/json",
            )
        val e = assertFailsWith<IOException> { NoRedirectResourceRetriever.usableKeysOnly(res) }
        assertTrue(e.message!!.contains("no usable keys (1 skipped)"), e.message)
    }

    /**
     * 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 RS→HS 혼동은 거부된다. 이제 검증기가 키 조회 전에 HS 를 거부해
     * (등록부 hs-refusal-rests-on-libraries) 이 칸은 Nimbus 의 키 선택(HS 에 oct 키만 고른다)까지 가지 않는다 — 라이브러리 갱신과 무관하다.
     */
    @Test
    fun rsaPublicKeyBytesAsHmacSecretAreRejectedEvenWithHsAllowed(): Unit =
        runBlocking {
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val server = serve("{\"keys\":[${k1.toPublicJWK().toJSONString()}]}")
            try {
                val config = hsAllowed(server)
                val endpoints = OidcEndpoints.forRealm(config)
                val validator = JwtValidator.forRealm(endpoints, config, "app")
                val der = k1.toRSAPublicKey().encoded
                val pem =
                    (
                        "-----BEGIN PUBLIC KEY-----\n" +
                            Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(der) +
                            "\n-----END PUBLIC KEY-----\n"
                    ).toByteArray(StandardCharsets.US_ASCII)
                for (secret in listOf(der, pem)) {
                    assertFailsWith<TokenValidationException> { validator.validate(hsToken(endpoints, secret, "k1")) }
                }
            } finally {
                server.stop(0)
            }
        }

    /**
     * HS(대칭) 서명은 설정이 허용해도 키를 찾기 전에 거부한다(등록부 hs-refusal-rests-on-libraries) — 검증 키는 JWKS(공개 문서)에서만
     * 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다. 그 거부가 oct 를 버리는 키 저장소와 Nimbus 의 키·alg 결합에만 기대지 않는다는
     * 증거가 키 조회 0 이다. kid 는 원천에 있는 RSA 키를 가리킨다. 코드 교환의 id_token 경로([JwtValidator.withAudience] —
     * `AuthClient.requireValidNonce`)도 같은 거부다. Java 자매 시험과 같은 모양이다.
     */
    @ParameterizedTest
    @ValueSource(strings = ["HS256", "HS384", "HS512"])
    fun hsSignatureIsRefusedBeforeAnyKeyLookupEvenWhenAllowed(name: String): Unit =
        runBlocking {
            val hs = JWSAlgorithm.parse(name)
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val set = JWKSet(k1.toPublicJWK())
            val lookups = AtomicInteger()
            val counting =
                JWKSource<SecurityContext> { selector, _ ->
                    lookups.incrementAndGet()
                    selector.select(set)
                }
            val endpoints = OidcEndpoints.forRealm(KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app"))
            val validator =
                JwtValidator.withJwkSource(counting, endpoints.issuer, "app", setOf(JWSAlgorithm.RS256, hs), Duration.ofSeconds(30))
            val secret = ByteArray(64).also { RANDOM.nextBytes(it) }
            val forged = hsToken(endpoints, secret, "k1", hs)

            for (path in listOf(validator, validator.withAudience("app"))) {
                val e = assertFailsWith<TokenValidationException> { path.validate(forged) }
                assertAll(
                    { assertEquals("algorithm not allowed: $name (a JWKS holds public keys only)", e.message) },
                    { assertNull(e.cause, "원인이 달렸다 — 라이브러리의 거부를 감싼 것이다") },
                    { assertEquals(0, lookups.get(), "HS 토큰이 키를 찾았다") },
                )
            }
            // 대조 — 같은 검증기의 RS256 토큰은 통과하고, 계수기는 그 조회를 본다(위의 0 이 죽은 계수기의 0 이 아니다).
            assertEquals("user-1", validator.validate(rsToken(endpoints, k1)).subject)
            assertTrue(lookups.get() > 0, "계수기가 키 조회를 보지 못한다")
        }

    /**
     * 길이 상한이 HS 거부보다 먼저다 — HS256 을 허용한 설정에서 상한을 넘은 HS256 토큰은 HS 의 문구가 아니라 상한의 문구로, 분해 · 키
     * 조회 전에 거부된다. 토큰은 분해할 수 있는 진짜 HS256 토큰이라 HS 거부가 상한보다 앞에 오면 그 문구가 나온다. Java 자매 시험과 같다.
     */
    @Test
    fun hsTokenOverTheCapIsRefusedByTheCapBeforeTheHsRefusal(): Unit =
        runBlocking {
            val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
            val set = JWKSet(k1.toPublicJWK())
            val lookups = AtomicInteger()
            val counting =
                JWKSource<SecurityContext> { selector, _ ->
                    lookups.incrementAndGet()
                    selector.select(set)
                }
            val endpoints = OidcEndpoints.forRealm(KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app"))
            val validator =
                JwtValidator.withJwkSource(
                    counting,
                    endpoints.issuer,
                    "app",
                    setOf(JWSAlgorithm.RS256, JWSAlgorithm.HS256),
                    Duration.ofSeconds(30),
                )
            val secret = ByteArray(64).also { RANDOM.nextBytes(it) }
            val padded =
                JWTClaimsSet
                    .Builder(claims(endpoints, "attacker"))
                    .claim("pad", "x".repeat(JWT_MAX_BYTES * 3 / 4))
                    .build()
            val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.HS256).keyID("k1").build(), padded)
            jwt.sign(MACSigner(secret))
            val over = jwt.serialize()
            assertTrue(over.length > JWT_MAX_BYTES, "fixture: ${over.length}")

            for (path in listOf(validator, validator.withAudience("app"))) {
                val e = assertFailsWith<TokenValidationException> { path.validate(over) }
                assertAll(
                    { assertEquals("token exceeds 256000 bytes", e.message) },
                    { assertNull(e.cause) },
                    { assertEquals(0, lookups.get(), "상한을 넘은 HS 토큰이 키를 찾았다") },
                )
            }
        }

    private fun serve(set: String): HttpServer {
        val bytes = set.toByteArray(StandardCharsets.UTF_8)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/realms/r/protocol/openid-connect/certs") { exchange ->
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        return server
    }

    private fun hsAllowed(server: HttpServer) =
        KeycloakConfig(
            serverUrl = "http://127.0.0.1:${server.address.port}",
            realm = "r",
            clientId = "app",
            signatureAlgorithms = listOf("RS256", "HS256"),
            jwksMinRefetch = Duration.ZERO,
        )

    private fun claims(
        endpoints: OidcEndpoints,
        sub: String,
    ): JWTClaimsSet =
        JWTClaimsSet
            .Builder()
            .issuer(endpoints.issuer)
            .audience("app")
            .subject(sub)
            .expirationTime(Date(System.currentTimeMillis() + 60_000))
            .build()

    private fun rsToken(
        endpoints: OidcEndpoints,
        key: RSAKey,
    ): String {
        val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(), claims(endpoints, "user-1"))
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    private fun hsToken(
        endpoints: OidcEndpoints,
        secret: ByteArray,
        kid: String?,
        alg: JWSAlgorithm = JWSAlgorithm.HS256,
    ): String {
        val header = JWSHeader.Builder(alg).apply { kid?.let { keyID(it) } }.build()
        val jwt = SignedJWT(header, claims(endpoints, "attacker"))
        jwt.sign(MACSigner(secret))
        return jwt.serialize()
    }

    companion object {
        private val RANDOM = SecureRandom()

        @JvmStatic
        fun octShapes(): List<Arguments> =
            listOf(
                Arguments.of("kid · alg", "\"kid\":\"hk\",\"alg\":\"HS256\",\"use\":\"sig\"", "hk"),
                Arguments.of("alg 없음", "\"kid\":\"hk\"", "hk"),
                Arguments.of("kid 없음", "\"alg\":\"HS256\",\"use\":\"sig\"", null),
            )
    }
}
