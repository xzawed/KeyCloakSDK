package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.MACSigner
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jose.util.Base64URL
import com.nimbusds.jose.util.Resource
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.time.Duration
import java.util.Base64
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
     * 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 RS→HS 혼동은 거부된다(Nimbus 는 HS 에 oct 키만 고른다). oct 를
     * 버리는 것만으로 충분하다는 판정의 근거라, 라이브러리 갱신이 이것을 바꾸면 여기서 운다.
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
    ): String {
        val header = JWSHeader.Builder(JWSAlgorithm.HS256).apply { kid?.let { keyID(it) } }.build()
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
