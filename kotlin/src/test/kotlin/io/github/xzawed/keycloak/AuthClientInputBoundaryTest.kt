package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.any
import com.github.tomakehurst.wiremock.client.WireMock.anyRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.anyUrl
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import kotlinx.coroutines.test.runTest
import java.net.URISyntaxException
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * 호출자·설정이 넘긴 값을 Nimbus 값 타입(AuthorizationCode·CodeVerifier·RefreshToken·TypelessAccessToken·
 * Scope.Value)이 생성자에서 `IllegalArgumentException` 으로 거부하거나, 호출자 문자열을 `URI` 가
 * `URISyntaxException` 으로 거부하면 §4 경계를 넘어 공개 API 로 샜다. 자매 일곱은 같은 값을 서버로 보내
 * 400 → SDK 인증 오류를 받는다(실측 2026-09-25). 여기서는 요청을 보내지 않은 채 같은 분류로 바꾼다 —
 * 그래서 모든 거부 케이스가 **엔드포인트 적중 0** 도 함께 본다.
 *
 * Java 자매(`AuthClientInputBoundaryTest`)와 같은 계약이다. redirect URI 는 Kotlin 만 문자열로 받으므로
 * (Java 는 `URI`) 그 둘은 이쪽에만 있고, 분류는 Rust `redirect_url()` 과 같은 KeycloakConfigException 이다.
 */
internal class AuthClientInputBoundaryTest {
    private lateinit var server: WireMockServer
    private val validVerifier = "a".repeat(43)

    @BeforeTest
    fun setUp() {
        server = WireMockServer(wireMockConfig().dynamicPort())
        server.start()
    }

    @AfterTest
    fun tearDown() {
        server.stop()
    }

    private fun serving(
        status: Int,
        body: String,
        scopes: List<String> = listOf("openid"),
    ): AuthClient {
        server.stubFor(
            any(anyUrl()).willReturn(
                aResponse().withStatus(status).withHeader("Content-Type", "application/json").withBody(body),
            ),
        )
        return AuthClient(
            KeycloakConfig(
                serverUrl = server.baseUrl(),
                realm = "r",
                clientId = "app",
                clientSecret = "secret".toCharArray(),
                scopes = scopes,
            ),
        )
    }

    private fun hits(): Int = server.findAll(anyRequestedFor(anyUrl())).size

    private val okToken = """{"access_token":"AT","token_type":"Bearer","expires_in":300}"""

    /** RFC 7636 §4.1: 43–128 자, [A-Za-z0-9-._~]. 짧음·빈 값·허용 밖 문자·과길이 넷 다 Nimbus 가 로컬에서 거부한다. */
    @Test
    fun `exchangeCode invalid verifier is an SDK auth error without a request`() =
        runTest {
            val auth = serving(400, """{"error":"invalid_grant"}""")
            for (v in listOf("v", "", "a".repeat(42) + "!", "a".repeat(129))) {
                val e =
                    assertFailsWith<KeycloakAuthException>("verifier length ${v.length}") {
                        auth.exchangeCode("code", v, "http://localhost/cb")
                    }
                assertEquals("Authorization code exchange request error: invalid code_verifier", e.message)
                assertIs<IllegalArgumentException>(e.cause)
            }
            assertEquals(0, hits(), "거부된 값은 토큰 엔드포인트에 닿지 않는다")
        }

    /** 대조군 — 경계값 43 자는 서버까지 간다(위 거부가 다른 원인이 아님을 보인다). */
    @Test
    fun `exchangeCode valid verifier reaches the token endpoint`() =
        runTest {
            val auth = serving(200, okToken)
            assertEquals("AT", auth.exchangeCode("code", validVerifier, "http://localhost/cb").accessToken)
            assertEquals(1, hits())
        }

    @Test
    fun `exchangeCode blank code is an SDK auth error without a request`() =
        runTest {
            val auth = serving(400, """{"error":"invalid_grant"}""")
            for (code in listOf("", "   ")) {
                val e =
                    assertFailsWith<KeycloakAuthException>("code '$code'") {
                        auth.exchangeCode(code, validVerifier, "http://localhost/cb")
                    }
                assertEquals("Authorization code exchange request error: invalid code", e.message)
                assertIs<IllegalArgumentException>(e.cause)
            }
            assertEquals(0, hits())
        }

    @Test
    fun `refresh blank token is an SDK auth error without a request`() =
        runTest {
            val auth = serving(400, """{"error":"invalid_grant"}""")
            for (token in listOf("", "   ")) {
                val e = assertFailsWith<KeycloakAuthException>("refresh_token '$token'") { auth.refresh(token) }
                assertEquals("Token refresh request error: invalid refresh_token", e.message)
                assertIs<IllegalArgumentException>(e.cause)
            }
            assertEquals(0, hits())
        }

    @Test
    fun `introspect blank token is an SDK auth error without a request`() =
        runTest {
            val auth = serving(400, """{"error":"invalid_request"}""")
            for (token in listOf("", "   ")) {
                val e = assertFailsWith<KeycloakAuthException>("token '$token'") { auth.introspect(token) }
                assertEquals("Introspection request error: invalid token", e.message)
                assertIs<IllegalArgumentException>(e.cause)
            }
            assertEquals(0, hits())
        }

    /** 잘못된 콜백 URL 은 IdP 가 거절한 것이 아니라 앱 구성 오류다 — Rust `redirect_url()` 과 같은 분류. */
    @Test
    fun `malformed redirect uri is an SDK config error without a request`() =
        runTest {
            val auth = serving(400, """{"error":"invalid_grant"}""")
            val exchange =
                assertFailsWith<KeycloakConfigException> { auth.exchangeCode("code", validVerifier, "a b") }
            assertIs<URISyntaxException>(exchange.cause)
            val authorize = assertFailsWith<KeycloakConfigException> { auth.createAuthorizationRequest("a b") }
            assertIs<URISyntaxException>(authorize.cause)
            assertEquals(exchange.message, authorize.message)
            assertTrue(exchange.message!!.startsWith("invalid redirect_uri: "), exchange.message)
            assertFalse(exchange.message!!.contains("a b"), "호출자 입력을 메시지에 되울리지 않는다: ${exchange.message}")
            assertEquals(0, hits())
        }

    /**
     * 공백 scope 전례(`AuthClientScopeFallbackTest`)는 createAuthorizationRequest 만 고쳤다 — 같은 설정이
     * client_credentials 에서는 그대로 샜다. 공백 원소만 버리고, 남는 것이 없으면 scope 를 싣지 않는다.
     */
    @Test
    fun `clientCredentials drops blank scopes instead of leaking`() =
        runTest {
            assertEquals("AT", serving(200, okToken, listOf(" ")).clientCredentialsToken().accessToken)
            assertFalse(lastBody().contains("scope="), lastBody())
            server.resetAll()
            serving(200, okToken, listOf("openid", "", "profile")).clientCredentialsToken()
            assertTrue(lastBody().contains("scope=openid+profile"), lastBody())
        }

    /** 대조군 — scope 를 설정하지 않으면 원래부터 scope 를 싣지 않았다(위 드롭이 이것과 같은 모양이다). */
    @Test
    fun `clientCredentials without scopes sends no scope`() =
        runTest {
            serving(200, okToken, emptyList()).clientCredentialsToken()
            assertFalse(lastBody().contains("scope="), lastBody())
        }

    private fun lastBody(): String = server.findAll(anyRequestedFor(anyUrl())).single().bodyAsString
}
