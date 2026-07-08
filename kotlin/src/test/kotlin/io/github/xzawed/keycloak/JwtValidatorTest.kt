package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.MACSigner
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.OctetSequenceKey
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.PlainJWT
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.test.runTest
import java.time.Duration
import java.util.Base64
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// JwtValidator 공격 프로브 스위트 — Java `JwtValidatorTest`(keycloak-sdk-auth)와 동형 + 브리프가 요구하는
// 전 프로브(미지 kid·malformed·exp 없음·만료·iss 불일치·클록스큐 경계)를 추가로 포함한다. 정적 JWKS만
// 사용(withStaticJwks) — 네트워크 없이 alg/서명/클레임 하드닝만 검증한다.
internal class JwtValidatorTest {
    private val issuer = "https://kc.example.com/realms/r"
    private val audience = "app"

    private fun rsaKey(kid: String = "k1"): RSAKey = RSAKeyGenerator(2048).keyID(kid).generate()

    private fun claims(
        iss: String = issuer,
        aud: List<String> = listOf(audience),
        expiresInMillis: Long? = 60_000,
        subject: String = "user-1",
        notBeforeInMillis: Long? = null,
    ): JWTClaimsSet {
        val builder =
            JWTClaimsSet
                .Builder()
                .issuer(iss)
                .audience(aud)
                .subject(subject)
        if (expiresInMillis != null) {
            builder.expirationTime(Date(System.currentTimeMillis() + expiresInMillis))
        }
        if (notBeforeInMillis != null) {
            builder.notBeforeTime(Date(System.currentTimeMillis() + notBeforeInMillis))
        }
        return builder.build()
    }

    private fun signedRs256(
        key: RSAKey,
        claimsSet: JWTClaimsSet,
        kid: String = key.keyID,
    ): String {
        val header = JWSHeader.Builder(JWSAlgorithm.RS256).keyID(kid).build()
        val jwt = SignedJWT(header, claimsSet)
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    @Test
    fun `valid RS256 token validates and exposes claims`() =
        runTest {
            val key = rsaKey()
            val token = signedRs256(key, claims())
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)

            val result = validator.validate(token)

            assertEquals(issuer, result.issuer)
            assertEquals("user-1", result.subject)
            assertTrue(result.audience.contains(audience))
        }

    @Test
    fun `alg-none token is rejected`() =
        runTest {
            val validator = JwtValidator.withStaticJwks(JWKSet(), issuer, audience)
            // 헤더 {"alg":"none"} — base64url(header) + "." + base64url(payload) + "."
            val noneJwt = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJpc3MifQ."

            assertFailsWith<TokenValidationException> { validator.validate(noneJwt) }
        }

    @Test
    fun `unsigned PlainJWT with otherwise-valid claims is rejected for being unsigned`() =
        runTest {
            // 실증 검증(non-vacuous): claim(issuer/audience/exp)은 모두 유효하게 만들어 서명 부재만이
            // 거부 사유임을 증명한다 — 이 토큰이 수락된다면 그 자체가 취약점이다.
            val validator = JwtValidator.withStaticJwks(JWKSet(), issuer, audience)
            val plain = PlainJWT(claims())

            assertFailsWith<TokenValidationException> { validator.validate(plain.serialize()) }
        }

    @Test
    fun `HS256-signed token is rejected when validator is pinned to RS256`() =
        runTest {
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val header = JWSHeader.Builder(JWSAlgorithm.HS256).build()
            val jwt = SignedJWT(header, claims())
            jwt.sign(MACSigner("0123456789abcdef0123456789abcdef".toByteArray()))

            assertFailsWith<TokenValidationException> { validator.validate(jwt.serialize()) }
        }

    @Test
    fun `HS256-signed token is rejected by the alg pin alone, even with a matching HMAC key registered`() =
        runTest {
            // 위 프로브와 달리 JWKS에 HS256(kty=oct) 키를 kid까지 일치시켜 "정상적으로" 등록해,
            // Nimbus의 키타입 불일치(kty mismatch)가 아니라 allowedAlgs=RS256 고정 자체가 거부 사유임을
            // 격리해서 증명한다 — kty가 우연히 안 맞아서가 아니라 alg 핀이 실제로 일하고 있다는 회귀 방지.
            val secret = "0123456789abcdef0123456789abcdef".toByteArray()
            val hmacJwk =
                OctetSequenceKey
                    .Builder(secret)
                    .keyID("hmac-1")
                    .algorithm(JWSAlgorithm.HS256)
                    .build()
            val validator = JwtValidator.withStaticJwks(JWKSet(hmacJwk), issuer, audience)
            val header = JWSHeader.Builder(JWSAlgorithm.HS256).keyID("hmac-1").build()
            val jwt = SignedJWT(header, claims())
            jwt.sign(MACSigner(secret))

            assertFailsWith<TokenValidationException> { validator.validate(jwt.serialize()) }
        }

    @Test
    fun `RS-HS confusion — HS256 token signed with the RSA public key bytes is rejected`() =
        runTest {
            // 고전적 alg-confusion 공격: 공격자가 검증기가 신뢰하는 RSA 공개키(X.509 인코딩) 바이트를
            // 그대로 HMAC 비밀키로 재사용해 HS256으로 서명한다. claim은 모두 유효하지만 alg가 허용
            // 집합(RS256)에 없으므로 반드시 거부되어야 한다.
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val secret = key.toRSAPublicKey().encoded
            val header = JWSHeader.Builder(JWSAlgorithm.HS256).build()
            val jwt = SignedJWT(header, claims())
            jwt.sign(MACSigner(secret))

            assertFailsWith<TokenValidationException> { validator.validate(jwt.serialize()) }
        }

    @Test
    fun `unknown kid is rejected`() =
        runTest {
            val signingKey = rsaKey("kid-attacker")
            val trustedKey = rsaKey("kid-trusted")
            val validator = JwtValidator.withStaticJwks(JWKSet(trustedKey.toPublicJWK()), issuer, audience)
            val token = signedRs256(signingKey, claims())

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `tampered payload under a trusted kid is rejected by signature verification`() =
        runTest {
            // 위 `unknown kid` 프로브는 키 SELECTION 단계에서 이미 실패해 서명검증 코드에 결코 도달하지
            // 못한다 — 그래서 RSASSA 서명검증 자체가 일하고 있다는 증거가 되지 못한다. 여기서는 신뢰된
            // kid로 유효하게 서명(키 선택 성공)한 뒤 payload 세그먼트만 재인코딩해 원본 서명과 불일치시킨다.
            // 서명이 실제로 페이로드를 바인딩하고 있다면 이 변조 토큰은 반드시 거부되어야 한다.
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val token = signedRs256(key, claims(subject = "user-1"))
            val parts = token.split(".")
            check(parts.size == 3) { "expected header.payload.signature, got ${parts.size} segments" }
            val decoder = Base64.getUrlDecoder()
            val encoder = Base64.getUrlEncoder().withoutPadding()
            val tamperedPayload = String(decoder.decode(parts[1]), Charsets.UTF_8).replace("user-1", "user-2")
            val tamperedToken = "${parts[0]}.${encoder.encodeToString(tamperedPayload.toByteArray(Charsets.UTF_8))}.${parts[2]}"

            assertFailsWith<TokenValidationException> { validator.validate(tamperedToken) }
        }

    @Test
    fun `malformed token is rejected`() =
        runTest {
            val validator = JwtValidator.withStaticJwks(JWKSet(), issuer, audience)

            assertFailsWith<TokenValidationException> { validator.validate("not-a-jwt-at-all") }
        }

    @Test
    fun `missing exp claim is rejected`() =
        runTest {
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val token = signedRs256(key, claims(expiresInMillis = null))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `expired token beyond clock skew is rejected`() =
        runTest {
            val key = rsaKey()
            val validator =
                JwtValidator.withStaticJwks(
                    JWKSet(key.toPublicJWK()),
                    issuer,
                    audience,
                    skew = Duration.ofSeconds(30),
                )
            val token = signedRs256(key, claims(expiresInMillis = -120_000))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `wrong issuer is rejected`() =
        runTest {
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val token = signedRs256(key, claims(iss = "https://attacker.example.com/realms/evil"))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `audience not containing expected is rejected`() =
        runTest {
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val token = signedRs256(key, claims(aud = listOf("someone-else")))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `multi-valued audience containing expected is accepted`() =
        runTest {
            // 회귀: 실 Keycloak client-credentials 토큰은 aud가 다중값이다(예: ["app","realm-management"]).
            // exactMatchClaims에 issuer만 두는 설계가 지켜지지 않으면 이 정상 토큰이 오탐 거부된다.
            val key = rsaKey()
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), issuer, audience)
            val token = signedRs256(key, claims(aud = listOf(audience, "realm-management")))

            val result = validator.validate(token)

            assertTrue(result.audience.containsAll(listOf(audience, "realm-management")))
        }

    @Test
    fun `token expired by less than clock skew is accepted`() =
        runTest {
            val key = rsaKey()
            val validator =
                JwtValidator.withStaticJwks(
                    JWKSet(key.toPublicJWK()),
                    issuer,
                    audience,
                    skew = Duration.ofSeconds(30),
                )
            val token = signedRs256(key, claims(expiresInMillis = -10_000))

            val result = validator.validate(token)

            assertEquals(issuer, result.issuer)
        }

    @Test
    fun `token expired by more than clock skew is rejected`() =
        runTest {
            val key = rsaKey()
            val validator =
                JwtValidator.withStaticJwks(
                    JWKSet(key.toPublicJWK()),
                    issuer,
                    audience,
                    skew = Duration.ofSeconds(30),
                )
            val token = signedRs256(key, claims(expiresInMillis = -50_000))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `future nbf beyond clock skew is rejected`() =
        runTest {
            // Nimbus의 DefaultJWTClaimsVerifier는 nbf가 존재하면 기본적으로 강제한다(클록스큐 내는 허용).
            // 이 프로브는 그 동작을 명시적으로 회귀-고정한다: nbf가 스큐(30초)를 훌쩍 넘는 미래(2분 뒤)면
            // 거부되어야 한다.
            val key = rsaKey()
            val validator =
                JwtValidator.withStaticJwks(
                    JWKSet(key.toPublicJWK()),
                    issuer,
                    audience,
                    skew = Duration.ofSeconds(30),
                )
            val token = signedRs256(key, claims(notBeforeInMillis = 120_000))

            assertFailsWith<TokenValidationException> { validator.validate(token) }
        }

    @Test
    fun `forRealm builds a validator without performing network IO`() {
        // JWKSourceBuilder.build()는 지연 조회다 — forRealm() 자체는 네트워크를 타지 않는다(non-suspend
        // 팩토리인 이유). 첫 validate() 호출 시점에야 JWKS 블로킹 조회가 발생한다.
        val config = KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app")
        val endpoints = OidcEndpoints.forRealm(config)

        val validator = JwtValidator.forRealm(endpoints, config, audience)

        assertNotNull(validator)
    }

    @Test
    fun `forRealm wraps an invalid JWKS URI as TokenValidationException`() {
        val config = KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app")
        val badEndpoints =
            OidcEndpoints(
                issuer = issuer,
                token = "$issuer/protocol/openid-connect/token",
                authorization = "$issuer/protocol/openid-connect/auth",
                introspection = "$issuer/protocol/openid-connect/token/introspect",
                logout = "$issuer/protocol/openid-connect/logout",
                userinfo = "$issuer/protocol/openid-connect/userinfo",
                jwks = "no-such-protocol-handler://bad-host/certs",
            )

        assertFailsWith<TokenValidationException> { JwtValidator.forRealm(badEndpoints, config, audience) }
    }
}
