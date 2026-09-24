package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.containing
import com.github.tomakehurst.wiremock.client.WireMock.post
import com.github.tomakehurst.wiremock.client.WireMock.postRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import kotlinx.coroutines.test.runTest
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFailsWith

// 공개 클라이언트(clientSecret 없음)의 refresh·logout 은 Authorization 없이 본문의 client_id 로
// 나가야 한다. client_credentials·introspect 만 로컬 KeycloakConfigException — 서버도 공개
// 클라이언트에게 각각 401/403 으로 거부한다(실측 2026-09-24, KC 26.6). 요청 빌더가 테스트에
// 안 열려 있어 WireMock 이 실제로 보낸 요청을 검사한다(AuthClientTest 와 같은 패턴).
internal class AuthClientPublicClientTest {
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

    private fun publicConfig(): KeycloakConfig =
        KeycloakConfig(
            serverUrl = server.baseUrl(),
            realm = "r",
            clientId = "public-app",
            scopes = listOf("openid"),
        )

    private val tokenPath = "/realms/r/protocol/openid-connect/token"
    private val logoutPath = "/realms/r/protocol/openid-connect/logout"

    @Test
    fun `public client refresh builds request with client_id body and no Authorization`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(tokenPath)).willReturn(
                    aResponse()
                        .withStatus(200)
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"access_token":"AT","token_type":"Bearer","expires_in":300}"""),
                ),
            )
            val auth = AuthClient(publicConfig())

            auth.refresh("rt-1")

            server.verify(
                postRequestedFor(urlEqualTo(tokenPath))
                    .withRequestBody(containing("grant_type=refresh_token"))
                    .withRequestBody(containing("client_id=public-app"))
                    .withRequestBody(containing("refresh_token=rt-1"))
                    .withoutHeader("Authorization"),
            )
            auth.close()
        }

    @Test
    fun `public client logout builds request with client_id body and no Authorization`() =
        runTest {
            server.stubFor(
                post(urlEqualTo(logoutPath)).willReturn(aResponse().withStatus(204)),
            )
            val auth = AuthClient(publicConfig())

            auth.logout("rt-1")

            server.verify(
                postRequestedFor(urlEqualTo(logoutPath))
                    .withRequestBody(containing("client_id=public-app"))
                    .withRequestBody(containing("refresh_token=rt-1"))
                    .withoutHeader("Authorization"),
            )
            auth.close()
        }

    @Test
    fun `public client clientCredentials and introspect still throw KeycloakConfigException`() =
        runTest {
            val auth = AuthClient(publicConfig())

            assertFailsWith<KeycloakConfigException> { auth.clientCredentialsToken() }
            assertFailsWith<KeycloakConfigException> { auth.introspect("some-token") }
            auth.close()
        }
}
