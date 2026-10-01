package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.get
import com.github.tomakehurst.wiremock.client.WireMock.getRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.post
import com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo
import com.github.tomakehurst.wiremock.client.WireMock.urlPathEqualTo
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.test.runTest
import java.time.Duration
import java.util.Date
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// 코드 교환의 id_token 검증과 validate() 가 **JWKS 저장소 하나**를 쓰는가 — expectedAudience 를 재정의한 채로.
//
// 재정의 아래서는 기대 audience 가 둘이다(id_token 은 client id, 액세스 토큰은 재정의 값). 검증기가 둘이 되면서
// 키 저장소까지 갈라 가지면 JWKS 조회가 두 배가 되고, 재조회 rate-limit 창과 콜드 캐시 창도 둘이 되어 IdP 장애
// 때 상한이 두 배가 된다. 그래서 공개 진입점 `AuthClient(config)`(forRealm 경로)로 IdP 요청 수를 센다 — 주입
// 검증기(정적 JWKS)로는 조회가 일어나지 않아 이 축을 못 본다.
//
// ⚠️ 무게는 **대조군**에 있다(`.claude/rules/kotlin.md`): 같은 호출을 클라이언트 둘(= 저장소 둘)에 나눠 같은
// 프로브가 두 번째 저장소를 **볼 수 있음**을 먼저 보인다. 그것이 없으면 「1」은 공유 덕인지 프로브가 못 재는
// 것인지 갈리지 않는다. 콜드 캐시 쪽은 간격 0 대조군도 둔다(`JwksColdCacheOutageTest` 와 같은 모양).
internal class IdTokenAudienceJwksTest {
    private val certsPath = "/realms/r/protocol/openid-connect/certs"
    private val tokenPath = "/realms/r/protocol/openid-connect/token"
    private val clientId = "app"
    private val apiAudience = "api"
    private val nonce = "the-nonce"
    private val codeVerifier = "test-code-verifier-".padEnd(48, 'x')

    // 창당 상한. Nimbus 는 창을 열 때 한 건을 이미 크레딧한다 — `.claude/rules/security.md`.
    private val windowCeiling = 2

    private lateinit var server: WireMockServer
    private lateinit var key: RSAKey

    @BeforeTest
    fun setUp() {
        server = WireMockServer(wireMockConfig().dynamicPort())
        server.start()
        key = RSAKeyGenerator(2048).keyID("k1").generate()
    }

    @AfterTest
    fun tearDown() {
        server.stop()
    }

    private fun config(minRefetch: Duration? = null): KeycloakConfig =
        if (minRefetch == null) {
            KeycloakConfig(
                serverUrl = server.baseUrl(),
                realm = "r",
                clientId = clientId,
                clientSecret = "secret".toCharArray(),
                expectedAudience = apiAudience,
            )
        } else {
            KeycloakConfig(
                serverUrl = server.baseUrl(),
                realm = "r",
                clientId = clientId,
                clientSecret = "secret".toCharArray(),
                expectedAudience = apiAudience,
                jwksMinRefetch = minRefetch,
            )
        }

    private fun signed(aud: String): String {
        val claims =
            JWTClaimsSet
                .Builder()
                .issuer(OidcEndpoints.forRealm(config()).issuer)
                .audience(aud)
                .subject("user-1")
                .claim("nonce", nonce)
                .expirationTime(Date(System.currentTimeMillis() + 60_000))
                .build()
        val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(), claims)
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    // 액세스 토큰의 aud 는 재정의 값, id_token 의 aud 는 client id — 실제 Keycloak 이 내는 모양.
    private val accessToken by lazy { signed(apiAudience) }

    private fun serveTokens() {
        server.stubFor(
            post(urlEqualTo(tokenPath)).willReturn(
                aResponse()
                    .withStatus(200)
                    .withHeader("Content-Type", "application/json")
                    .withBody(
                        """{"access_token":"$accessToken","token_type":"Bearer","expires_in":300,"id_token":"${signed(clientId)}"}""",
                    ),
            ),
        )
    }

    private fun serveJwks(status: Int = 200) {
        val response =
            if (status == 200) {
                aResponse().withHeader("Content-Type", "application/json").withBody(JWKSet(key.toPublicJWK()).toString())
            } else {
                aResponse().withStatus(status)
            }
        server.stubFor(get(urlPathEqualTo(certsPath)).willReturn(response))
    }

    private fun jwksHits(): Int = server.findAll(getRequestedFor(urlPathEqualTo(certsPath))).size

    private suspend fun AuthClient.exchange(): TokenSet =
        exchangeCode("code", codeVerifier, "https://app.example.com/cb", expectedNonce = nonce)

    @Test
    fun `an exchange and validate share one JWKS fetch under an expectedAudience override`() =
        runTest {
            serveJwks()
            serveTokens()

            val exchangeFirst =
                AuthClient(config()).use { auth ->
                    val tokens = auth.exchange()
                    // A3 — 운영 경로의 validate() 는 재정의를 본다(교환이 그 검증기를 바꿔 두지 않았다).
                    assertEquals(listOf(apiAudience), auth.validate(tokens.accessToken).audience)
                    // 교환이 받은 id_token(aud = client id)은 액세스 검증을 지나지 못한다.
                    assertFailsWith<TokenValidationException> { auth.validate(assertNotNull(tokens.idToken)) }
                    jwksHits()
                }

            server.resetRequests()
            val validateFirst =
                AuthClient(config()).use { auth ->
                    auth.validate(accessToken)
                    auth.exchange()
                    jwksHits()
                }

            // 대조군 — 같은 두 호출을 클라이언트 둘에 나누면(저장소 둘) 프로브가 두 번째 조회를 본다.
            server.resetRequests()
            val twoStores =
                AuthClient(config()).use { a ->
                    AuthClient(config()).use { b ->
                        a.exchange()
                        b.validate(accessToken)
                        jwksHits()
                    }
                }

            assertEquals(2, twoStores, "대조군: 저장소가 둘이면 조회도 둘이다 — 이것을 못 보면 아래 단언은 공허하다")
            assertEquals(1, exchangeFirst, "교환 뒤 validate() 가 JWKS 를 다시 조회했다 — id_token 검증이 저장소를 따로 쓴다")
            assertEquals(1, validateFirst, "validate() 뒤 교환이 JWKS 를 다시 조회했다 — id_token 검증이 저장소를 따로 쓴다")
        }

    @Test
    fun `a cold-cache outage stays within one window across exchange and validate`() =
        runTest {
            serveJwks(status = 503)
            serveTokens()
            val attempts = 10

            suspend fun flood(
                exchanging: AuthClient,
                validating: AuthClient,
            ): Int {
                server.resetRequests()
                repeat(attempts) {
                    val refused = assertFailsWith<KeycloakAuthException> { exchanging.exchange() }
                    assertEquals("Authorization code exchange failed: invalid id_token", refused.message)
                    assertFailsWith<TokenValidationException> { validating.validate(accessToken) }
                }
                return jwksHits()
            }

            val shared = AuthClient(config()).use { auth -> flood(auth, auth) }
            // 대조군 1 — 저장소가 둘이면 창도 둘이라 상한을 넘는다.
            val twoStores = AuthClient(config()).use { a -> AuthClient(config()).use { b -> flood(a, b) } }
            // 대조군 2 — 게이트를 풀면(간격 0) 같은 프로브가 폭주를 본다.
            val ungated = AuthClient(config(Duration.ZERO)).use { auth -> flood(auth, auth) }

            assertTrue(ungated >= attempts, "대조군이 폭주를 못 보면 이 테스트는 공허하다 — 간격 0 에서 실제=$ungated")
            assertTrue(twoStores > windowCeiling, "대조군: 저장소가 둘이면 창도 둘이다 — 실제=$twoStores")
            assertTrue(
                shared <= windowCeiling,
                "교환과 validate() 가 콜드 캐시 창 하나를 나눠야 한다 — ${attempts * 2}회 검증에 IdP 요청 실제=$shared",
            )
        }
}
