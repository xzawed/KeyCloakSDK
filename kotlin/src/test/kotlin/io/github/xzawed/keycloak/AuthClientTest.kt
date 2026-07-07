package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.containing
import com.github.tomakehurst.wiremock.client.WireMock.post
import com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo
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
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// AuthClientTest — WireMock으로 Keycloak token/introspect/logout 엔드포인트를 목킹해 AuthClient의 경계변환
// (OAuth 에러→KeycloakAuthException·send() 실패→KeycloakTransportException)·PKCE S256 조립·exchangeCode의
// nonce threading(Node SDK HIGH 결함 회귀 방지)을 검증한다. 네트워크 경계라 Kover 커버리지 게이트에서
// 제외되지만(build.gradle.kts), 이 스위트가 로직을 실증한다 — 전 메서드 전수 커버가 목표는 아니다.
internal class AuthClientTest {
    private lateinit var server: WireMockServer

    @BeforeTest
    fun setUp() {
        server = WireMockServer(wireMockConfig().dynamicPort())
        server.start()
    }

    @AfterTest
    fun tearDown() {
        server.stop()
    }

    private fun config(
        readTimeout: Duration = Duration.ofSeconds(30),
        serverUrl: String = server.baseUrl(),
    ): KeycloakConfig =
        KeycloakConfig(
            serverUrl = serverUrl,
            realm = "r",
            clientId = "app",
            clientSecret = "secret".toCharArray(),
            scopes = listOf("openid", "profile"),
            readTimeout = readTimeout,
        )

    private val tokenPath = "/realms/r/protocol/openid-connect/token"
    private val introspectPath = "/realms/r/protocol/openid-connect/token/introspect"
    private val logoutPath = "/realms/r/protocol/openid-connect/logout"

    @Test
    fun `clientCredentialsToken returns TokenSet on success and threads grant_type`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .withRequestBody(containing("grant_type=client_credentials"))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody(
                                """{"access_token":"AT","token_type":"Bearer","expires_in":300,"scope":"openid profile"}""",
                            ),
                    ),
            )
            val auth = AuthClient(config())

            val tokenSet = auth.clientCredentialsToken()

            assertEquals("AT", tokenSet.accessToken)
            assertEquals("Bearer", tokenSet.tokenType)
            assertNotNull(tokenSet.expiresAt)
            auth.close()
        }

    @Test
    fun `clientCredentialsToken maps OAuth error response to KeycloakAuthException with error code`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .willReturn(
                        aResponse()
                            .withStatus(401)
                            .withHeader("Content-Type", "application/json")
                            .withBody("""{"error":"invalid_client","error_description":"bad credentials"}"""),
                    ),
            )
            val auth = AuthClient(config())

            val ex = assertFailsWith<KeycloakAuthException> { auth.clientCredentialsToken() }

            assertEquals("invalid_client", ex.oauthError)
            auth.close()
        }

    @Test
    fun `clientCredentialsToken maps connection failure to KeycloakTransportException`() =
        runTest {
            val transientServer = WireMockServer(wireMockConfig().dynamicPort())
            transientServer.start()
            val cfg = config(serverUrl = transientServer.baseUrl())
            transientServer.stop() // nothing listens on this port anymore -> connection refused
            val auth = AuthClient(cfg)

            assertFailsWith<KeycloakTransportException> { auth.clientCredentialsToken() }
            auth.close()
        }

    @Test
    fun `clientCredentialsToken maps read timeout to KeycloakTransportException`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withFixedDelay(1500)
                            .withBody("""{"access_token":"AT","token_type":"Bearer","expires_in":300}"""),
                    ),
            )
            val auth = AuthClient(config(readTimeout = Duration.ofMillis(200)))

            assertFailsWith<KeycloakTransportException> { auth.clientCredentialsToken() }
            auth.close()
        }

    @Test
    fun `createAuthorizationRequest builds S256 PKCE url with state and nonce`() {
        val auth = AuthClient(config())

        val req = auth.createAuthorizationRequest("https://app.example.com/callback")

        assertContains(req.authorizationUrl, "response_type=code")
        assertContains(req.authorizationUrl, "code_challenge_method=S256")
        assertContains(req.authorizationUrl, "code_challenge=")
        assertContains(req.authorizationUrl, "state=${req.state}")
        assertContains(req.authorizationUrl, "nonce=${req.nonce}")
        assertTrue(req.codeVerifier.isNotBlank())
        auth.close()
    }

    @Test
    fun `createAuthorizationRequest values differ across calls`() {
        val auth = AuthClient(config())

        val a = auth.createAuthorizationRequest("https://app.example.com/cb")
        val b = auth.createAuthorizationRequest("https://app.example.com/cb")

        assertNotEquals(a.codeVerifier, b.codeVerifier)
        assertNotEquals(a.state, b.state)
        assertNotEquals(a.nonce, b.nonce)
        auth.close()
    }

    @Test
    fun `introspect maps active token fields`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(introspectPath))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody("""{"active":true,"username":"alice","client_id":"app"}"""),
                    ),
            )
            val auth = AuthClient(config())

            val result = auth.introspect("some-token")

            assertTrue(result.active)
            assertEquals("alice", result.username)
            assertEquals("app", result.clientId)
            auth.close()
        }

    @Test
    fun `introspect maps inactive token`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(introspectPath))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody("""{"active":false}"""),
                    ),
            )
            val auth = AuthClient(config())

            val result = auth.introspect("some-token")

            assertEquals(false, result.active)
            auth.close()
        }

    @Test
    fun `refresh returns new TokenSet`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .withRequestBody(containing("grant_type=refresh_token"))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody(
                                """{"access_token":"AT2","refresh_token":"RT2","token_type":"Bearer","expires_in":60}""",
                            ),
                    ),
            )
            val auth = AuthClient(config())

            val tokenSet = auth.refresh("old-refresh-token")

            assertEquals("AT2", tokenSet.accessToken)
            assertEquals("RT2", tokenSet.refreshToken)
            auth.close()
        }

    @Test
    fun `logout posts refresh token and succeeds on 2xx`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(logoutPath))
                    .withRequestBody(containing("refresh_token=some-refresh-token"))
                    .willReturn(aResponse().withStatus(204)),
            )
            val auth = AuthClient(config())

            auth.logout("some-refresh-token")
            auth.close()
        }

    @Test
    fun `logout throws KeycloakAuthException on non-2xx`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(logoutPath))
                    .willReturn(aResponse().withStatus(400)),
            )
            val auth = AuthClient(config())

            assertFailsWith<KeycloakAuthException> { auth.logout("rt") }
            auth.close()
        }

    // exchangeCode + nonce threading (Node SDK HIGH 결함의 회귀 방지) ------------------------------------

    // Nimbus CodeVerifier는 RFC 7636을 강제해 43~128자를 요구한다 — 짧은 임의 문자열은 구성 단계에서
    // IllegalArgumentException으로 거부되므로 테스트 전용 verifier는 최소 길이를 만족시킨다.
    private val testCodeVerifier = "test-code-verifier-".padEnd(48, 'x')

    private fun rsaKey(kid: String = "k1"): RSAKey = RSAKeyGenerator(2048).keyID(kid).generate()

    private fun signedIdToken(
        key: RSAKey,
        issuer: String,
        audience: String,
        nonce: String,
    ): String {
        val claims =
            JWTClaimsSet
                .Builder()
                .issuer(issuer)
                .audience(audience)
                .subject("user-1")
                .claim("nonce", nonce)
                .expirationTime(Date(System.currentTimeMillis() + 60_000))
                .build()
        val header = JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build()
        val jwt = SignedJWT(header, claims)
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    @Test
    fun `exchangeCode with matching nonce returns TokenSet including id_token`() =
        runTest {
            val key = rsaKey()
            val cfg = config()
            val endpoints = OidcEndpoints.forRealm(cfg)
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), endpoints.issuer, cfg.clientId)
            val idToken = signedIdToken(key, endpoints.issuer, cfg.clientId, "the-nonce")
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .withRequestBody(containing("code_verifier=$testCodeVerifier"))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody(
                                """{"access_token":"AT","token_type":"Bearer","expires_in":300,"id_token":"$idToken"}""",
                            ),
                    ),
            )
            val auth = AuthClient(cfg, endpoints, validator)

            val tokenSet =
                auth.exchangeCode(
                    "code",
                    testCodeVerifier,
                    "https://app.example.com/cb",
                    expectedNonce = "the-nonce",
                )

            assertEquals("AT", tokenSet.accessToken)
            assertEquals(idToken, tokenSet.idToken)
            auth.close()
        }

    @Test
    fun `exchangeCode with mismatched nonce throws KeycloakAuthException`() =
        runTest {
            val key = rsaKey()
            val cfg = config()
            val endpoints = OidcEndpoints.forRealm(cfg)
            val validator = JwtValidator.withStaticJwks(JWKSet(key.toPublicJWK()), endpoints.issuer, cfg.clientId)
            val idToken = signedIdToken(key, endpoints.issuer, cfg.clientId, "server-nonce")
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody(
                                """{"access_token":"AT","token_type":"Bearer","expires_in":300,"id_token":"$idToken"}""",
                            ),
                    ),
            )
            val auth = AuthClient(cfg, endpoints, validator)

            assertFailsWith<KeycloakAuthException> {
                auth.exchangeCode(
                    "code",
                    testCodeVerifier,
                    "https://app.example.com/cb",
                    expectedNonce = "expected-nonce",
                )
            }
            auth.close()
        }

    @Test
    fun `exchangeCode without expectedNonce skips id_token validation`() =
        runTest {
            val cfg = config()
            server.stubFor(
                post(urlEqualTo(tokenPath))
                    .willReturn(
                        aResponse()
                            .withStatus(200)
                            .withHeader("Content-Type", "application/json")
                            .withBody("""{"access_token":"AT","token_type":"Bearer","expires_in":300}"""),
                    ),
            )
            val auth = AuthClient(cfg)

            val tokenSet = auth.exchangeCode("code", testCodeVerifier, "https://app.example.com/cb")

            assertEquals("AT", tokenSet.accessToken)
            auth.close()
        }
}
