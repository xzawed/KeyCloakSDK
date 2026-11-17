package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.anyRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.anyUrl
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 인가 요청의 redirect_uri 는 RFC 6749 §3.1.2 의 절대 URI 여야 한다(등록부 authz-request-redirect-unvalidated). Nimbus 11.39 의
 * build() 는 fragment·금지 scheme·금지 쿼리 파라미터를 거부하지만(`AuthClientInputBoundaryTest`) 상대 참조 — 빈 값·`cb`·`/cb`·
 * `//app/cb` — 는 그대로 URL 에 실었다(실측 2026-11-18). SDK 가 파싱한 `URI` 의 절대성을 URL 을 만들기 전에 본다. 검사만 하고
 * 고치지 않는다 — URL 의 redirect_uri 는 호출자 문자열 그대로다(코드 교환이 그 문자열을 그대로 보내므로 둘 중 하나만 정규화하면
 * 두 값이 갈린다, #1133). 그 검사는 인가 요청에만 있다 — 교환과 함께 쓰는 파싱(`redirectUri`)은 그대로다. `URI` 가 파싱하지 못하는
 * 값은 오늘의 파싱 메시지 그대로다. 기록하는 IdP(WireMock) 위에서 돌려 요청이 0 인지도 본다. Java 자매와 같은 계약이다.
 */
internal class AuthClientRedirectUriTest {
    private lateinit var server: WireMockServer
    private val notAbsolute = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"

    @BeforeTest
    fun setUp() {
        server = WireMockServer(wireMockConfig().dynamicPort())
        server.start()
    }

    @AfterTest
    fun tearDown() {
        server.stop()
    }

    // OIDC 경로(scope 에 openid)와 플레인 OAuth2 경로 — build() 가 둘이라 둘 다 본다.
    private fun clients(): List<AuthClient> = listOf(client(listOf("openid")), client(listOf("profile")))

    private fun client(scopes: List<String>): AuthClient =
        AuthClient(KeycloakConfig(serverUrl = server.baseUrl(), realm = "r", clientId = "app", scopes = scopes))

    private fun hits(): Int = server.findAll(anyRequestedFor(anyUrl())).size

    @Test
    fun `relative reference is refused as not absolute`() {
        for (auth in clients()) {
            for (uri in listOf("", "cb", "/cb", "//app/cb")) {
                val e = assertFailsWith<KeycloakConfigException>("'$uri'") { auth.createAuthorizationRequest(uri) }
                assertEquals(notAbsolute, e.message)
                assertNull(e.cause)
            }
        }
        assertEquals(0, hits())
    }

    /** 순서 — 상대 참조에 fragment 가 붙어도 R1 이다(Nimbus 의 fragment 거부보다 먼저 본다). */
    @Test
    fun `relative reference with a fragment is refused as not absolute first`() {
        for (auth in clients()) {
            val e = assertFailsWith<KeycloakConfigException> { auth.createAuthorizationRequest("cb#f") }
            assertEquals(notAbsolute, e.message)
        }
    }

    /** `URI` 가 파싱하지 못하는 값은 오늘의 파싱 메시지 그대로다 — 접두만 본다. */
    @Test
    fun `unparseable value keeps the parse message`() {
        val e = assertFailsWith<KeycloakConfigException> { clients().first().createAuthorizationRequest("not a url") }
        assertTrue(e.message!!.startsWith("invalid redirect_uri: "), e.message)
        assertIs<URISyntaxException>(e.cause)
    }

    /**
     * 등록부 redirect-uri-r3-narrower-than-keycloak — 다른 언어가 R4 로 거부하는 모양(경로의 `[` · scheme 뒤 빈 값)은 여기서 이미
     * 거부된다: 파싱이 Keycloak 이 redirect_uri 를 읽는 것과 같은 `java.net.URI` 라 그 파서의 거부가 그대로 오늘의 파싱 메시지
     * (`invalid redirect_uri: <reason>`)다. 그래서 Kotlin 에는 R4 를 더하지 않는다 — 이 시험이 그 판정을 고정한다. 요청도 0 이다.
     */
    @Test
    fun `java net URI already refuses the shapes R4 adds elsewhere`() {
        for ((value, reason) in listOf("https://app/c[b" to "Illegal character in path", "https:" to "Expected scheme-specific part")) {
            for (auth in clients()) {
                val e = assertFailsWith<KeycloakConfigException>(value) { auth.createAuthorizationRequest(value) }
                assertEquals("invalid redirect_uri: $reason", e.message)
                assertIs<URISyntaxException>(e.cause)
            }
        }
        assertEquals(0, hits())
    }

    @Test
    fun `refusal does not echo the input`() {
        val e =
            assertFailsWith<KeycloakConfigException> { clients().first().createAuthorizationRequest("cb-CANARY-7d1f") }
        assertEquals(notAbsolute, e.message)
        assertFalse(e.toString().contains("CANARY"), e.toString())
    }

    /** 대조군 — 절대 URI 는 URL 의 redirect_uri 에 그대로 실린다(복호한 값이 입력과 같다 — 고치지 않는다). */
    @Test
    fun `absolute uri is carried verbatim`() {
        val accepted =
            listOf("https://app/cb", "https://app/cb?x=1", "myapp:/cb", "com.example.app:/oauth2redirect", "HTTP://LOCALHOST/cb")
        for (auth in clients()) {
            for (uri in accepted) {
                val url = auth.createAuthorizationRequest(uri).authorizationUrl
                assertEquals(uri, queryValue(url, "redirect_uri"), url)
            }
        }
        assertEquals(0, hits())
    }

    private fun queryValue(
        url: String,
        name: String,
    ): String? =
        URI(url)
            .rawQuery
            .split('&')
            .map { it.split('=', limit = 2) }
            .firstOrNull { it[0] == name }
            ?.let { URLDecoder.decode(it[1], Charsets.UTF_8) }
}
