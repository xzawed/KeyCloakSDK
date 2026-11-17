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
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// 교차언어 가드 토큰 타입 축(test-security-defaults.sh 1c)의 kotlin 앵커 테스트가 거부를 단언하는 access_token 값들.
// 파일 수준에 두는 것은 `HostilePathMatrixTest` 가 **같은 목록**을 모든 TOKEN_GRANT·CODE_EXCHANGE 행에 붙이기 때문이다
// (사본을 만들지 않는다 — 여기에 값을 더하면 행렬이 따라온다).
internal val CC_NON_STRING_ACCESS_TOKENS: List<String> = listOf("12345", """{"a":1}""", "[]", "true", "null", "\"\"")

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
        expectedAudience: String? = null,
    ): KeycloakConfig =
        KeycloakConfig(
            serverUrl = serverUrl,
            realm = "r",
            clientId = "app",
            clientSecret = "secret".toCharArray(),
            scopes = listOf("openid", "profile"),
            readTimeout = readTimeout,
            expectedAudience = expectedAudience,
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

    // 비문자열·빈 access_token 거절은 우리 코드가 아니라 **Nimbus `TokenResponse.parse`** 가 한다. 교차언어
    // 가드는 그 호출의 존재만 봤다 — 라이브러리가 관용해지면(.NET 의 Duende 가 실제로 강제변환했다) 쓸 수
    // 없는 토큰이 성공으로 나가도 아무도 모른다. 그 행동을 고정한다(양성 대조는 위 성공 테스트).
    @Test
    fun `clientCredentialsToken rejects non-string or empty access_token`() =
        runTest {
            for (raw in CC_NON_STRING_ACCESS_TOKENS) {
                server.resetAll()
                server.stubFor(
                    post(urlEqualTo(tokenPath))
                        .willReturn(
                            aResponse()
                                .withStatus(200)
                                .withHeader("Content-Type", "application/json")
                                .withBody("""{"access_token":$raw,"token_type":"Bearer","expires_in":300}"""),
                        ),
                )
                val auth = AuthClient(config())
                val ex = assertFailsWith<KeycloakAuthException>("access_token $raw") { auth.clientCredentialsToken() }
                assertEquals("Malformed auth response", ex.message, "access_token $raw")
                // 원인은 Nimbus 예외의 가린 사본이다(응답을 인용하므로 — `AuthMalformedResponseTest`) — 타입 이름이 거절한 쪽을 말한다.
                assertEquals("com.nimbusds.oauth2.sdk.ParseException", (ex.cause as RedactedCause).originalType, "access_token $raw")
                auth.close()
            }
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

    @Test
    fun `logout maps connection failure to KeycloakTransportException`() =
        runTest {
            // 응답이 없는 실패(연결 거부)의 갈래 — 단위 커버리지 밖(AuthClient*)의 손으로 쓴 변환이라 아무 시험도 밟지
            // 않았다(등록부 coverage-exclusion-hides-untested-branches). 원시 IOException 이 공개 API 로 새면 §4 위반이다.
            val transientServer = WireMockServer(wireMockConfig().dynamicPort())
            transientServer.start()
            val cfg = config(serverUrl = transientServer.baseUrl())
            transientServer.stop() // nothing listens on this port anymore -> connection refused
            val auth = AuthClient(cfg)

            val refused = assertFailsWith<KeycloakTransportException> { auth.logout("rt") }

            assertEquals("Logout request failed", refused.message)
            auth.close()
        }

    // exchangeCode + nonce threading (Node SDK HIGH 결함의 회귀 방지) ------------------------------------

    // Nimbus CodeVerifier는 RFC 7636을 강제해 43~128자를 요구한다 — 짧은 임의 문자열은 구성 단계에서
    // IllegalArgumentException으로 거부되므로 테스트 전용 verifier는 최소 길이를 만족시킨다.
    private val testCodeVerifier = "test-code-verifier-".padEnd(48, 'x')

    private fun rsaKey(kid: String = "k1"): RSAKey = RSAKeyGenerator(2048).keyID(kid).generate()

    // typ "ID" — Keycloak 의 id_token 이 싣는 값(id_token 검증기는 그 밖의 typ 을 거부한다 — nonce 거부 시험이 종류 거부로 공허하게
    // 통과하지 않게 여기서 싣는다).
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
                .claim("typ", "ID")
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

    // 위조 RS256 id_token — iss·aud·exp 는 전부 맞고 서명 키만 realm JWKS 밖이다. 실서버는 이것을 만들 수
    // 없어(자기 키로만 서명한다) 통합 스위트(CodeExchangeIT)가 못 덮는 자리다. nonce 대조만 남기고 서명 검증을
    // 건너뛰는 변이는 이것이 잡는다 — 같은 kid(서명 불일치)와 모르는 kid(키 없음) 두 길 다.
    // nonce 까지 틀린 위조도 「unexpected nonce」가 아니라 「invalid id_token」이다 — 서명을 **먼저** 본다(검증 전
    // 페이로드의 nonce 를 먼저 대조하는 변이가 이 한 쌍 없이는 초록이었다, 독립 레그 Grok 실측). 거부 오류의 어느
    // 꼴에도 위조 토큰이 실리지 않는다.
    @Test
    fun `exchangeCode refuses a forged RS256 id_token whose nonce matches`() =
        runTest {
            val realmKey = rsaKey("k1")
            val cfg = config()
            val endpoints = OidcEndpoints.forRealm(cfg)
            for (forger in listOf(rsaKey("k1"), rsaKey("attacker"))) {
                for (expectedNonce in listOf("the-nonce", "another-nonce")) {
                    val case = "kid=${forger.keyID} expectedNonce=$expectedNonce"
                    val validator = JwtValidator.withStaticJwks(JWKSet(realmKey.toPublicJWK()), endpoints.issuer, cfg.clientId)
                    val forged = signedIdToken(forger, endpoints.issuer, cfg.clientId, "the-nonce")
                    server.stubFor(
                        post(urlEqualTo(tokenPath))
                            .willReturn(
                                aResponse()
                                    .withStatus(200)
                                    .withHeader("Content-Type", "application/json")
                                    .withBody("""{"access_token":"AT","token_type":"Bearer","expires_in":300,"id_token":"$forged"}"""),
                            ),
                    )
                    val auth = AuthClient(cfg, endpoints, validator)

                    val refused =
                        assertFailsWith<KeycloakAuthException>(case) {
                            auth.exchangeCode("code", testCodeVerifier, "https://app.example.com/cb", expectedNonce = expectedNonce)
                        }
                    assertEquals("Authorization code exchange failed: invalid id_token", refused.message, case)
                    assertTrue(refused.cause is TokenValidationException, "$case: ${refused.cause}")
                    val printed = refused.stackTraceToString()
                    assertTrue(forged !in printed && forged.substringBefore('.') !in printed, "$case: the forged token leaked")
                    auth.close()
                }
            }
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

    // expectedAudience 재정의 + 코드 교환 ------------------------------------------------------------------
    //
    // 재정의는 **액세스 토큰**의 기대 audience 다. id_token 의 `aud` 는 OIDC Core §2 · §3.1.3.7 대로 언제나
    // client id 로 본다. 한때 둘이 검증기 하나를 공유해 재정의가 id_token 에도 걸렸고, 재정의한 소비자의 nonce
    // 교환은 서버가 서명한 정상 id_token 에서 「invalid id_token」으로 실패했다. 주입 검증기는 운영 경로처럼
    // `validate()` 의 것, 즉 **재정의 audience** 로 만든다 — 공유 JWKS 는 `IdTokenAudienceJwksTest` 가 잰다.

    private val apiAudience = "api"

    // Keycloak 의 id_token 모양 — typ "ID" 를 싣는다(id_token 검증기는 그 밖의 typ 을 거부한다). 다른 검사를 재는 시험이 종류
    // 거부로 공허하게 통과하지 않게, 거부 시험의 토큰도 이것으로 만든다. [extra] 가 typ 을 바꾸거나(null 이면 뺀다) 더한다.
    private fun idToken(
        key: RSAKey,
        aud: List<String>,
        nonce: String = "the-nonce",
        iss: String = OidcEndpoints.forRealm(config()).issuer,
        alg: JWSAlgorithm = JWSAlgorithm.RS256,
        expiresInMillis: Long? = 60_000,
        extra: JWTClaimsSet.Builder.() -> Unit = {},
    ): String {
        val claims =
            JWTClaimsSet
                .Builder()
                .issuer(iss)
                .audience(aud)
                .subject("user-1")
                .claim("nonce", nonce)
                .claim("typ", "ID")
        expiresInMillis?.let { claims.expirationTime(Date(System.currentTimeMillis() + it)) }
        claims.extra()
        val jwt = SignedJWT(JWSHeader.Builder(alg).keyID(key.keyID).build(), claims.build())
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    private fun stubExchange(
        idToken: String,
        accessToken: String = "AT",
    ) {
        server.stubFor(
            post(urlEqualTo(tokenPath)).willReturn(
                aResponse()
                    .withStatus(200)
                    .withHeader("Content-Type", "application/json")
                    .withBody("""{"access_token":"$accessToken","token_type":"Bearer","expires_in":300,"id_token":"$idToken"}"""),
            ),
        )
    }

    // 운영 경로의 모양 — 주입 검증기의 audience 는 config.expectedAudience(= 재정의)다.
    private fun overridden(
        realmKey: RSAKey,
        skew: Duration = Duration.ofSeconds(30),
    ): AuthClient {
        val cfg = config(expectedAudience = apiAudience)
        val endpoints = OidcEndpoints.forRealm(cfg)
        val validator =
            JwtValidator.withStaticJwks(JWKSet(realmKey.toPublicJWK()), endpoints.issuer, cfg.expectedAudience, skew = skew)
        return AuthClient(cfg, endpoints, validator)
    }

    private suspend fun AuthClient.exchange(expectedNonce: String = "the-nonce"): TokenSet =
        exchangeCode("code", testCodeVerifier, "https://app.example.com/cb", expectedNonce = expectedNonce)

    // Keycloak 은 id_token 에 azp = client id 를 싣는다 — aud 가 둘 이상인 id_token 은 그것이 있어야 통과한다(아래 azp 묶음).
    @Test
    fun `exchangeCode checks the id_token against the client id under an expectedAudience override`() =
        runTest {
            val key = rsaKey()
            for (aud in listOf(listOf("app"), listOf("app", apiAudience), listOf(apiAudience, "app"))) {
                val token = idToken(key, aud) { claim("azp", "app") }
                stubExchange(token)
                val auth = overridden(key)

                assertEquals(token, auth.exchange().idToken, "aud=$aud")
                auth.close()
            }
        }

    @Test
    fun `exchangeCode refuses an id_token whose aud lacks the client id even when it carries the override`() =
        runTest {
            val key = rsaKey()
            for (aud in listOf(listOf(apiAudience), listOf(apiAudience, "other"), listOf("other"))) {
                stubExchange(idToken(key, aud))
                val auth = overridden(key)

                val refused = assertFailsWith<KeycloakAuthException>("aud=$aud") { auth.exchange() }
                assertEquals("Authorization code exchange failed: invalid id_token", refused.message, "aud=$aud")
                assertIs<TokenValidationException>(refused.cause, "aud=$aud")
                auth.close()
            }
        }

    // 교환이 공유 검증기를 바꿔 두지 않는다 — 교환 **뒤**에도 validate() 는 재정의로 본다. 액세스 토큰은 Keycloak 처럼 typ
    // "Bearer" 다(id_token 모양의 typ "ID" 는 validate() 가 거부한다).
    @Test
    fun `validate keeps the expectedAudience override for access tokens after an exchange`() =
        runTest {
            val key = rsaKey()
            val accessForApi = idToken(key, listOf(apiAudience)) { claim("typ", "Bearer") }
            val accessForClient = idToken(key, listOf("app")) { claim("typ", "Bearer") }
            stubExchange(idToken(key, listOf("app")), accessToken = accessForApi)
            val auth = overridden(key)

            val tokens = auth.exchange()

            assertEquals(listOf(apiAudience), auth.validate(tokens.accessToken).audience)
            assertFailsWith<TokenValidationException> { auth.validate(accessForClient) }
            auth.close()
        }

    // audience 만 바뀐다 — iss · alg 핀 · 서명 · exp(원본 검증기의 skew 그대로) · nonce 대조는 재정의 아래서도 같다.
    // skew 를 기본값이 아닌 120초로 준다: 파생 검증기가 기본값으로 되돌아가면 「90초 지난 토큰」에서 갈린다.
    @Test
    fun `exchangeCode under an expectedAudience override still enforces iss, the algorithm pin, exp and the nonce`() =
        runTest {
            val key = rsaKey("k1")
            val invalid =
                mapOf(
                    "foreign iss" to idToken(key, listOf("app"), iss = "https://attacker.example.com/realms/r"),
                    "RS384 under the RS256 pin" to idToken(key, listOf("app"), alg = JWSAlgorithm.RS384),
                    "forged signature" to idToken(rsaKey("k1"), listOf("app")),
                    "no exp" to idToken(key, listOf("app"), expiresInMillis = null),
                    "expired beyond the skew" to idToken(key, listOf("app"), expiresInMillis = -200_000),
                )
            for ((case, token) in invalid) {
                stubExchange(token)
                val auth = overridden(key, skew = Duration.ofSeconds(120))

                val refused = assertFailsWith<KeycloakAuthException>(case) { auth.exchange() }
                assertEquals("Authorization code exchange failed: invalid id_token", refused.message, case)
                assertIs<TokenValidationException>(refused.cause, case)
                auth.close()
            }

            stubExchange(idToken(key, listOf("app"), expiresInMillis = -90_000))
            val withinSkew = overridden(key, skew = Duration.ofSeconds(120))
            assertNotNull(withinSkew.exchange().idToken, "expired by less than the validator's skew")
            withinSkew.close()

            stubExchange(idToken(key, listOf("app"), nonce = "server-nonce"))
            val wrongNonce = overridden(key)
            val refused = assertFailsWith<KeycloakAuthException> { wrongNonce.exchange(expectedNonce = "expected-nonce") }
            assertEquals("Authorization code exchange failed: unexpected nonce", refused.message)
            wrongNonce.close()
        }

    // id_token 의 typ · azp -----------------------------------------------------------------------------------
    //
    // (A) validate() 의 typ 거부(액세스 토큰이 아닌 Keycloak 토큰)는 액세스 토큰 자리에만 걸린다 — Keycloak 의 id_token 은
    // typ "ID" 이므로 교환에 걸리면 정상 교환이 전부 실패한다. (B) OIDC Core §3.1.3.7 4·5: aud 가 둘 이상이면 azp 가 있어야 하고,
    // azp 가 있으면 client id 와 같은 문자열이어야 한다. 거부는 다른 id_token 거부와 같은 꼴(「invalid id_token」 + 원인
    // TokenValidationException)이고 원인 메시지가 azp 를 말한다. 아래 토큰은 전부 Keycloak 처럼 typ "ID" 를 싣는다(Java 동형).

    // 운영 경로의 모양 — 재정의 없음: 주입 검증기의 audience 는 config.expectedAudience(= client id)다.
    private fun plain(realmKey: RSAKey): AuthClient {
        val cfg = config()
        val endpoints = OidcEndpoints.forRealm(cfg)
        val validator = JwtValidator.withStaticJwks(JWKSet(realmKey.toPublicJWK()), endpoints.issuer, cfg.expectedAudience)
        return AuthClient(cfg, endpoints, validator)
    }

    // [idToken] 이 이미 typ "ID" 를 싣는다 — 여기서는 azp 만 더한다.
    private fun typedId(
        key: RSAKey,
        aud: List<String>,
        azp: Any? = null,
    ): String =
        idToken(key, aud) {
            if (azp != null) claim("azp", azp)
        }

    // 거부의 원인이 azp 규칙이다 — 다른 id_token 검사(서명 · iss · aud · exp)의 거부가 이 초록을 대신 채우지 못하게.
    private suspend fun AuthClient.assertRefusedForAzp(case: String) {
        val refused = assertFailsWith<KeycloakAuthException>(case) { exchange() }
        assertEquals("Authorization code exchange failed: invalid id_token", refused.message, case)
        val cause = assertIs<TokenValidationException>(refused.cause, case)
        assertTrue("azp" in cause.message.orEmpty(), "$case: ${cause.message}")
    }

    // Keycloak 이 내는 모양(typ "ID" · azp = client id) — 교환은 받고, 같은 토큰을 validate() 는 액세스 토큰이 아니라고 거부한다.
    @Test
    fun `exchangeCode accepts an id_token typed ID, which validate refuses as not an access token`() =
        runTest {
            val key = rsaKey()
            val token = typedId(key, listOf("app"), azp = "app")
            stubExchange(token)
            val auth = plain(key)

            assertEquals(token, auth.exchange().idToken)
            val refused = assertFailsWith<TokenValidationException> { auth.validate(token) }
            assertEquals("not an access token (typ \"ID\")", refused.message)
            auth.close()
        }

    @Test
    fun `exchangeCode accepts an id_token that passes the azp rule`() =
        runTest {
            val key = rsaKey()
            val passing =
                mapOf(
                    "one audience, no azp" to typedId(key, listOf("app")),
                    "one audience, azp is the client" to typedId(key, listOf("app"), azp = "app"),
                    "two audiences, azp is the client" to typedId(key, listOf("app", "other"), azp = "app"),
                    "two audiences the other way round, azp is the client" to typedId(key, listOf("other", "app"), azp = "app"),
                )
            for ((case, token) in passing) {
                stubExchange(token)
                val auth = plain(key)
                assertEquals(token, auth.exchange().idToken, case)
                auth.close()
            }
        }

    // 마지막 둘은 azp 가 문자열이 아니다(client id 를 담은 배열도 문자열이 아니다).
    @Test
    fun `exchangeCode refuses an id_token that fails the azp rule`() =
        runTest {
            val key = rsaKey()
            val refusedCases =
                mapOf(
                    "one audience, azp names another client" to typedId(key, listOf("app"), azp = "evil"),
                    "two audiences, no azp" to typedId(key, listOf("app", "evil")),
                    "two audiences, azp names the other audience" to typedId(key, listOf("app", "evil"), azp = "evil"),
                    "azp is a number" to typedId(key, listOf("app"), azp = 42L),
                    "azp is an array holding the client id" to typedId(key, listOf("app"), azp = listOf("app")),
                )
            for ((case, token) in refusedCases) {
                stubExchange(token)
                val auth = plain(key)
                auth.assertRefusedForAzp(case)
                auth.close()
            }
        }

    // 교환의 id_token 검사는 공개 validateIdToken 과 같은 함수다 — 종류 규칙(typ 이 정확히 "ID")도 교환에 걸린다. 아래 토큰은
    // 종류 말고는 전부 맞다(서명 · iss · aud = azp = client id · exp · nonce 일치). 거부는 다른 id_token 거부와 같은 꼴(「invalid
    // id_token」 + 원인 TokenValidationException)이고, 원인 메시지가 종류를 말한다(상수 — 토큰의 typ 값을 싣지 않는다).
    @Test
    fun `exchangeCode refuses an id_token that is not typed ID`() =
        runTest {
            val key = rsaKey()
            for (typ in listOf(null, "Bearer")) {
                val token =
                    idToken(key, listOf("app")) {
                        claim("azp", "app")
                        // null 이면 typ 을 싣지 않는다(직렬화가 null 클레임을 뺀다) — 부재다.
                        claim("typ", typ)
                    }
                assertEquals(typ, SignedJWT.parse(token).jwtClaimsSet.getClaim("typ"), "전제: typ=$typ")
                stubExchange(token)
                val auth = plain(key)

                val refused = assertFailsWith<KeycloakAuthException>("typ=$typ") { auth.exchange() }
                assertEquals("Authorization code exchange failed: invalid id_token", refused.message, "typ=$typ")
                val cause = assertIs<TokenValidationException>(refused.cause, "typ=$typ")
                assertEquals("not an id_token (typ is not \"ID\")", cause.message, "typ=$typ")
                auth.close()
            }
        }

    // JSON null 인 azp 도 「있는」 azp 다 — 문자열이 아니므로 거부한다(없는 것으로 읽으면 aud 하나에서 통과한다).
    @Test
    fun `exchangeCode refuses an id_token whose azp is JSON null`() =
        runTest {
            val key = rsaKey()
            val token =
                idToken(key, listOf("app")) {
                    claim("typ", "ID")
                    serializeNullClaims(true)
                    claim("azp", null)
                }
            // 전제: 토큰이 정말 "azp":null 을 싣는다(아니면 이 테스트는 부재를 잰다).
            assertContains(SignedJWT.parse(token).payload.toString(), "\"azp\":null")
            stubExchange(token)
            val auth = plain(key)
            auth.assertRefusedForAzp("azp is JSON null")
            auth.close()
        }

    // 재정의 아래에서도 azp 는 client id 와 대조한다 — 재정의 값(액세스 토큰이 향하는 리소스 서버)이 아니다.
    @Test
    fun `exchangeCode under an expectedAudience override compares the azp with the client id`() =
        runTest {
            val key = rsaKey()
            val refusedCases =
                mapOf(
                    "azp names the override" to typedId(key, listOf("app", apiAudience), azp = apiAudience),
                    "two audiences, no azp" to typedId(key, listOf("app", apiAudience)),
                )
            for ((case, token) in refusedCases) {
                stubExchange(token)
                val auth = overridden(key)
                auth.assertRefusedForAzp(case)
                auth.close()
            }
        }
}
