package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import io.mockk.verify
import jakarta.ws.rs.client.ClientRequestContext
import jakarta.ws.rs.client.ClientResponseContext
import jakarta.ws.rs.core.Response
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// TokenResponseGuard 단위(Java `TokenResponseGuardTest` 동형) — 무엇을 쓸 수 있는 access_token 으로 보는가(JSON 모양)와 어느
// 응답을 보는가(범위). 끝에서 끝까지의 계약(admin 요청 0 건 · 예외 타입 · 갱신)은 `AdminTokenResponseTest` 가 진다.
// 모양 표의 적대 항목 일부는 독립 레그(Grok)가 낸 것이다 — 중복 키(결합은 마지막 값), 중첩, 대소문자, UTF-16.
//
// ⚠️ 요청·응답 컨텍스트는 **인터페이스**라 MockK 로 만든다(JAX-RS 추상 클래스 Response 를 목으로 만들면 JDK 21 에서 멈춘다 —
// `.claude/rules/kotlin.md`). 상태는 실제 enum `Response.Status` 를 쓴다.
private const val TRG_TOKEN = "http://kc/auth/realms/r/protocol/openid-connect/token"
private const val TRG_NUMBER = """{"access_token":12345}"""

internal class TokenResponseGuardTest {
    private fun usable(json: String): Boolean = TokenResponseGuard.carriesUsableAccessToken(json.toByteArray())

    @Test
    fun `usable shapes`() {
        val shapes =
            listOf(
                """{"access_token":"AT","token_type":"Bearer","expires_in":300}""",
                """{"access_token":"12345"}""", // 따옴표 친 숫자는 진짜 문자열이다
                """{"access_token":" "}""", // 계약은 「비어 있지 않음」 — 공백 판정은 IdP 몫(Go 와 같다)
                """{"x":{"access_token":1},"y":[1,{"a":[2]}],"access_token":"AT"}""", // 중첩은 결합되지 않는다
                """{"access_token":"A","access_token":"B"}""", // 중복이어도 전부 문자열이면 된다
                "{\"access\\u005ftoken\":\"AT\"}", // 이스케이프된 키도 같은 이름이다(JSON 파서가 푼다)
                """{"access_token":"AT"} trailing""", // 뒤따르는 내용은 결합(Jackson)이 판정한다
            )
        val wrong = shapes.filterNot(::usable)
        assertTrue(wrong.isEmpty(), "거부했다: $wrong")
    }

    @Test
    fun `unusable shapes`() {
        val shapes =
            listOf(
                """{"access_token":12345}""",
                """{"access_token":1.5}""",
                """{"access_token":-0}""",
                """{"access_token":true}""",
                """{"access_token":false}""",
                """{"access_token":null}""",
                """{"access_token":""}""",
                """{"access_token":{"v":"x"}}""",
                """{"access_token":[]}""",
                """{"access_token":["x"]}""",
                """{"token_type":"Bearer","expires_in":300}""", // 누락
                "{}",
                """{"x":{"access_token":"AT"}}""", // 중첩만 있다 — 누락이다
                """{"access_token":"AT","access_token":12345}""", // 결합은 마지막 값(숫자)을 쓴다
                """{"access_token":12345,"access_token":"AT"}""", // 어느 것이 결합될지는 파서 설정 몫
                "{\"access\\u005ftoken\":true}",
                """{"ACCESS_TOKEN":"AT"}""", // 결합은 대소문자를 가린다
                """{"Access_Token":"AT","access_token":1}""",
                """[{"access_token":"AT"}]""", // 최상위가 객체가 아니다
                "\"AT\"",
                "12345",
                "null",
                "",
                "   ",
                """{"access_token":"AT"""", // 잘린 JSON
                """{"access_token":"AT",""",
                """{"access_token":""",
                "Zcanary-0123456789abcdef", // JSON 이 아니다
                "{'access_token':'AT'}",
            )
        val wrong = shapes.filter(::usable)
        assertTrue(wrong.isEmpty(), "받아들였다: $wrong")
    }

    // Jackson 결합과 같은 자동 인코딩 감지 — 다시 디코딩하지 않는다(UTF-16 본문을 UTF-8 로 읽으면 거짓 거부다).
    @Test
    fun `detects the encoding like the binding`() {
        assertTrue(TokenResponseGuard.carriesUsableAccessToken("""{"access_token":"AT"}""".toByteArray(Charsets.UTF_16LE)))
        assertFalse(TokenResponseGuard.carriesUsableAccessToken(TRG_NUMBER.toByteArray(Charsets.UTF_16BE)))
    }

    // ───────────── 범위 — 어느 응답을 보는가 ─────────────

    private fun request(
        method: String,
        uri: String,
    ): ClientRequestContext {
        val req = mockk<ClientRequestContext>()
        every { req.method } returns method
        every { req.uri } returns URI.create(uri)
        return req
    }

    private fun response(
        status: Response.Status,
        body: InputStream?,
    ): ClientResponseContext {
        val res = mockk<ClientResponseContext>(relaxed = true)
        every { res.statusInfo } returns status
        every { res.entityStream } returns body
        return res
    }

    private fun bytes(s: String): InputStream = ByteArrayInputStream(s.toByteArray())

    @Test
    fun `leaves every other response untouched`() {
        val guard = TokenResponseGuard()
        val others =
            listOf(
                Triple("GET", TRG_TOKEN, Response.Status.OK), // 토큰 요청은 POST 다
                Triple("POST", "http://kc/admin/realms/r/users", Response.Status.CREATED), // admin 자원
                Triple("GET", "http://kc/admin/realms/r/users/x", Response.Status.OK),
                // ⚠️ 원시 경로로 본다 — 렐름 이름의 %2F 가 경로 조각을 지어내지 못한다
                Triple("POST", "http://kc/admin/realms/a%2Fprotocol%2Fopenid-connect%2Ftoken", Response.Status.OK),
                Triple("POST", TRG_TOKEN, Response.Status.BAD_REQUEST), // 오류는 TokenManager 몫
                Triple("POST", TRG_TOKEN, Response.Status.UNAUTHORIZED),
                Triple("POST", "$TRG_TOKEN/introspect", Response.Status.OK),
            )
        for ((method, uri, status) in others) {
            val res = response(status, bytes(TRG_NUMBER))
            guard.filter(request(method, uri), res)
            verify(exactly = 0) { res.entityStream }
            verify(exactly = 0) { res.entityStream = any() }
        }
    }

    @Test
    fun `usable token response is handed on byte for byte`() {
        val body = """{"access_token":"AT","expires_in":300,"refresh_token":"RT","x":[1]}"""
        val res = response(Response.Status.OK, bytes(body))
        val handed = slot<InputStream>()
        every { res.entityStream = capture(handed) } just runs
        TokenResponseGuard().filter(request("POST", TRG_TOKEN), res)
        assertEquals(body, handed.captured.readAllBytes().decodeToString())
    }

    @Test
    fun `unusable token response is rejected without quoting it`() {
        for (body in listOf(bytes(TRG_NUMBER), bytes("""{"access_token":""}"""), null)) {
            val res = response(Response.Status.OK, body)
            val e = assertFailsWith<IOException> { TokenResponseGuard().filter(request("POST", TRG_TOKEN), res) }
            assertEquals("token endpoint response carries no usable access_token", e.message)
            assertNull(e.cause)
            verify(exactly = 0) { res.entityStream = any() }
        }
    }

    // 배선 — admin 의 JAX-RS 클라이언트에 등록돼 있어야 한다(TokenManager 의 토큰 요청이 그 클라이언트로 나간다).
    @Test
    fun `timeout client registers the guard`() {
        val config = KeycloakConfig("https://kc.example.com", "r", "app", "s3cr3t".toCharArray())
        AdminClient.buildTimeoutClient(config).use { client ->
            assertTrue(client.configuration.isRegistered(TokenResponseGuard::class.java))
        }
    }
}
