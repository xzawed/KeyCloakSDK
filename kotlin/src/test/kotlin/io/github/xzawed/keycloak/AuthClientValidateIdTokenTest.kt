package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.test.runTest
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

// 공개 id_token 검증 `AuthClient.validateIdToken` — 코드 교환이 nonce 를 대조하기 **전에** 돌리는 바로 그 검사다(교환의
// requireValidNonce 가 이 함수를 부른다): 서명(validate() 와 같은 키 원천) · alg 핀 · 길이 상한 · iss · aud 에 client id · exp ·
// skew, 그리고 id_token 자리의 종류 — 페이로드 typ 이 정확히 문자열 "ID" — 와 그다음 azp(OIDC Core §3.1.3.7 4·5). nonce 는 보지
// 않는다(교환의 몫). 등록부 `id-token-validator-not-public` · Java `AuthClientValidateIdTokenTest` 동형.
//
// 종류는 허용 목록이다(액세스 쪽 validate() 는 Bearer · DPoP 의 허용 목록): Keycloak 은 id_token 을 한 곳에서만 만들고 늘 typ "ID" 를 싣는다.
// 액세스 토큰은 typ 이 "Bearer" 이고 aud 에 client id 를, azp 에 그 client 를 담을 수 있다 — 종류를 안 보면 그 토큰이 이 길의 다른
// 검사를 전부 지난다(아래 첫 거부 시험의 대조군이 그것을 보인다). 검증기는 정적 JWKS 를 주입한다(키 원천 공유는
// `IdTokenAudienceJwksTest` 가 운영 경로 forRealm 으로 잰다).
internal class AuthClientValidateIdTokenTest {
    private val issuer = "https://kc.example.com/realms/r"
    private val clientId = "app"
    private val override = "api"

    // 종류 거부의 메시지 — 상수다. 토큰이 고른 typ 값은 싣지 않는다(azp 를 싣지 않는 것과 같은 이유).
    private val notAnIdToken = "not an id_token (typ is not \"ID\")"

    // 운영 경로의 모양 — 주입 검증기는 validate() 의 것(aud = expectedAudience, 미설정이면 client id)이고, id_token 쪽은 거기서
    // client id 로 파생된다(AuthClientTest 와 같은 시임).
    private fun client(expectedAudience: String? = null): AuthClient {
        val cfg =
            KeycloakConfig(
                serverUrl = "https://kc.example.com",
                realm = "r",
                clientId = clientId,
                clientSecret = "secret".toCharArray(),
                expectedAudience = expectedAudience,
            )
        val endpoints = OidcEndpoints.forRealm(cfg)
        return AuthClient(cfg, endpoints, JwtValidator.withStaticJwks(JWKSet(KEY.toPublicJWK()), endpoints.issuer, cfg.expectedAudience))
    }

    // iss · aud · exp(1분 뒤) · iat 가 맞는 RS256(kid k1) 토큰 — [more] 가 클레임을 더하거나 바꾼다.
    private fun signed(
        aud: List<String>,
        signer: RSAKey = KEY,
        alg: JWSAlgorithm = JWSAlgorithm.RS256,
        more: JWTClaimsSet.Builder.() -> Unit = {},
    ): String {
        val claims =
            JWTClaimsSet
                .Builder()
                .issuer(issuer)
                .audience(aud)
                .issueTime(Date())
                .expirationTime(Date(System.currentTimeMillis() + 60_000))
        claims.more()
        val jwt = SignedJWT(JWSHeader.Builder(alg).keyID("k1").build(), claims.build())
        jwt.sign(RSASSASigner(signer))
        return jwt.serialize()
    }

    // Keycloak 이 내는 id_token 의 모양(typ "ID" · aud = azp = client id) — 공개 함수는 그 클레임을 돌려준다. 같은 토큰을 같은
    // 클라이언트의 validate() 는 액세스 토큰이 아니라고 거부한다 — 두 공개 함수는 다른 길이다.
    @Test
    fun `validateIdToken accepts the id_token Keycloak issues and returns its claims`() =
        runTest {
            val auth = client()
            val idToken =
                signed(listOf(clientId)) {
                    claim("typ", "ID")
                    claim("azp", clientId)
                    subject("user-1")
                    claim("nonce", "n-1")
                }

            val validated = auth.validateIdToken(idToken)

            assertEquals("user-1", validated.subject)
            assertEquals(issuer, validated.issuer)
            assertEquals(listOf(clientId), validated.audience)
            assertEquals("ID", validated.claims["typ"])
            assertEquals(clientId, validated.claims["azp"])
            assertEquals("n-1", validated.claims["nonce"], "nonce 는 대조하지 않고 돌려준다")
            val refused = assertFailsWith<TokenValidationException> { auth.validate(idToken) }
            assertEquals("not an access token (typ \"ID\")", refused.message)
        }

    // 이 규칙이 닫는 구멍 — aud 에 client id, azp 에 그 client 를 담은 액세스 토큰(typ "Bearer"). 대조군: 같은 클라이언트의
    // validate() 가 같은 토큰을 받는다 — 서명 · iss · aud · exp 가 맞는 토큰이라, 거부의 원인은 종류 하나다(메시지까지 본다).
    @Test
    fun `validateIdToken refuses an access token that names the client`() =
        runTest {
            val auth = client()
            val accessToken =
                signed(listOf(clientId)) {
                    claim("typ", "Bearer")
                    claim("azp", clientId)
                }

            val refused = assertFailsWith<TokenValidationException> { auth.validateIdToken(accessToken) }

            assertEquals(notAnIdToken, refused.message)
            assertEquals(clientId, auth.validate(accessToken).claims["azp"], "대조군: 액세스 검증은 이 토큰을 받는다")
        }

    // typ 이 정확히 문자열 "ID" 가 아닌 것 — 부재 · 다른 대소문자 · 문자열이 아닌 값. aud · azp 는 전부 맞다.
    @Test
    fun `validateIdToken refuses a token whose typ is not exactly ID`() =
        runTest {
            val auth = client()
            val cases: Map<String, Any?> =
                mapOf(
                    "absent" to null,
                    "bearer in lower case" to "bearer",
                    "id in lower case" to "id",
                    "ID with a trailing space" to "ID ",
                    "a number" to 1L,
                    "an array holding ID" to listOf("ID"),
                    "an object holding ID" to mapOf("typ" to "ID"),
                )
            for ((case, typ) in cases) {
                val token =
                    signed(listOf(clientId)) {
                        claim("azp", clientId)
                        if (typ != null) claim("typ", typ)
                    }
                // 전제: 토큰이 정말 그 typ 을 실었다(되읽은 값) — 직렬화가 값을 바꿨다면 이 경우는 아무것도 재지 않는다.
                assertEquals(typ, SignedJWT.parse(token).jwtClaimsSet.getClaim("typ"), case)

                val refused = assertFailsWith<TokenValidationException>(case) { auth.validateIdToken(token) }
                assertEquals(notAnIdToken, refused.message, case)
            }
        }

    // JSON null 인 typ — 「있지만 문자열이 아닌」 값이다. 부재와 따로 친다(직렬화가 null 을 빼면 부재를 잰다 — 전제로 막는다).
    @Test
    fun `validateIdToken refuses a token whose typ is JSON null`() =
        runTest {
            val token =
                signed(listOf(clientId)) {
                    claim("azp", clientId)
                    serializeNullClaims(true)
                    claim("typ", null)
                }
            assertContains(SignedJWT.parse(token).payload.toString(), "\"typ\":null")

            val refused = assertFailsWith<TokenValidationException> { client().validateIdToken(token) }
            assertEquals(notAnIdToken, refused.message)
        }

    // back-channel logout 토큰의 모양(OIDC Back-Channel Logout §2.4) — Keycloak 은 typ "Logout" 을 싣고, aud 는 client id 하나라
    // azp 규칙(aud 하나 · azp 없음)은 지난다. exp 가 있어 필수 exp 도 지난다. 종류만이 그것을 id_token 자리에서 가른다.
    @Test
    fun `validateIdToken refuses a back-channel logout token`() =
        runTest {
            val logoutToken =
                signed(listOf(clientId)) {
                    claim("typ", "Logout")
                    claim("sid", "s-1")
                    claim("events", mapOf("http://schemas.openid.net/event/backchannel-logout" to emptyMap<String, Any>()))
                }
            assertNull(SignedJWT.parse(logoutToken).jwtClaimsSet.getClaim("azp"), "전제: azp 가 없다")

            val refused = assertFailsWith<TokenValidationException> { client().validateIdToken(logoutToken) }
            assertEquals(notAnIdToken, refused.message)
        }

    // 종류가 azp 보다 먼저다 — id_token 이라는 것이 azp 규칙의 전제다(아홉 언어 같은 순서). 두 규칙에 다 걸리는 토큰(typ "Bearer" ·
    // aud 둘 · azp 없음)은 종류의 상수 메시지로 거부된다 — azp 의 메시지가 아니다.
    @Test
    fun `validateIdToken checks the kind before the authorized party`() =
        runTest {
            val token = signed(listOf(clientId, "other")) { claim("typ", "Bearer") }
            assertNull(SignedJWT.parse(token).jwtClaimsSet.getClaim("azp"), "전제: azp 가 없다")

            val refused = assertFailsWith<TokenValidationException> { client().validateIdToken(token) }
            assertEquals(notAnIdToken, refused.message)
        }

    // expectedAudience 는 액세스 토큰의 값이다 — id_token 의 aud 는 client id 로 본다(OIDC Core §2 · §3.1.3.7). 재정의 값만 담은
    // id_token 은 aud 검사에서 거부된다(종류 검사보다 앞 — 메시지까지 본다). 대조군 둘: 같은 클라이언트가 client id 를 담은
    // id_token 은 받고, 그 클라이언트의 validate() 는 재정의 값을 담은 액세스 토큰을 받는다(재정의가 살아 있다).
    @Test
    fun `validateIdToken holds the audience to the client id, not the expectedAudience override`() =
        runTest {
            val auth = client(expectedAudience = override)
            val idFor: (String) -> String = { aud ->
                signed(listOf(aud)) {
                    claim("typ", "ID")
                    claim("azp", clientId)
                }
            }
            val accessForTheOverride =
                signed(listOf(override)) {
                    claim("typ", "Bearer")
                    claim("azp", clientId)
                }

            val refused = assertFailsWith<TokenValidationException> { auth.validateIdToken(idFor(override)) }
            assertEquals("JWT validation failed", refused.message)
            assertEquals(listOf(clientId), auth.validateIdToken(idFor(clientId)).audience)
            assertEquals(listOf(override), auth.validate(accessForTheOverride).audience)
        }

    // 교환의 다른 id_token 검사 — 공개 함수도 같은 것을 건다(같은 함수다). 앞의 다섯은 typ "ID" · azp = client id 라 거부는 그
    // 검사의 것이다.
    @Test
    fun `validateIdToken keeps every check of the exchange`() =
        runTest {
            val forger = RSAKeyGenerator(2048).keyID("k1").generate()
            val typed: JWTClaimsSet.Builder.() -> Unit = {
                claim("typ", "ID")
                claim("azp", clientId)
            }
            val cases =
                listOf(
                    Triple(
                        "wrong issuer",
                        signed(listOf(clientId)) {
                            typed()
                            issuer("https://evil.example.com/realms/r")
                        },
                        "JWT validation failed",
                    ),
                    Triple(
                        "algorithm outside the pin",
                        signed(listOf(clientId), alg = JWSAlgorithm.RS512, more = typed),
                        "JWT validation failed",
                    ),
                    Triple(
                        "expired beyond the skew",
                        signed(listOf(clientId)) {
                            typed()
                            expirationTime(Date(System.currentTimeMillis() - 45_000))
                        },
                        "JWT validation failed",
                    ),
                    Triple(
                        "no exp",
                        signed(listOf(clientId)) {
                            typed()
                            expirationTime(null)
                        },
                        "JWT validation failed",
                    ),
                    Triple("forged signature", signed(listOf(clientId), signer = forger, more = typed), "JWT validation failed"),
                    Triple(
                        "two audiences, no azp",
                        signed(listOf(clientId, "other")) { claim("typ", "ID") },
                        "id_token has more than one audience but no azp",
                    ),
                    Triple(
                        "azp names another client",
                        signed(listOf(clientId)) {
                            claim("typ", "ID")
                            claim("azp", "evil")
                        },
                        "id_token azp is not this client",
                    ),
                    Triple("over the length cap", "a".repeat(JWT_MAX_BYTES - 1) + "..", "token exceeds 256000 bytes"),
                )
            for ((case, token, message) in cases) {
                val refused = assertFailsWith<TokenValidationException>(case) { client().validateIdToken(token) }
                assertEquals(message, refused.message, case)
            }
        }

    private companion object {
        val KEY: RSAKey = RSAKeyGenerator(2048).keyID("k1").generate()
    }
}
