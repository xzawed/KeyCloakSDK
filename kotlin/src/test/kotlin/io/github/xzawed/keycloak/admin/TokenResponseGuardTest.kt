package io.github.xzawed.keycloak.admin

import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import io.github.xzawed.keycloak.KeycloakConfig
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import io.mockk.verify
import jakarta.ws.rs.Priorities
import jakarta.ws.rs.client.ClientRequestContext
import jakarta.ws.rs.client.ClientResponseContext
import jakarta.ws.rs.client.ClientResponseFilter
import jakarta.ws.rs.core.MediaType
import jakarta.ws.rs.core.Response
import jakarta.ws.rs.ext.ReaderInterceptor
import jakarta.ws.rs.ext.ReaderInterceptorContext
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.lang.management.ManagementFactory
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
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

// 크기 상한은 JWKS 응답 상한 그 자체다(NoRedirectResourceRetriever 가 Nimbus 에 넘기는 상수) — 시험은 그 상수로 경계를 잰다.
private const val TRG_CAP = JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT
private const val TRG_USABLE = """{"access_token":"AT","expires_in":300}"""

// 쓸 수 있는 토큰 뒤를 JSON 공백으로 채워 정확히 size 바이트로 — 결합에게는 여전히 쓸 수 있는 본문이다.
private fun trgPadded(size: Int): ByteArray {
    val head = TRG_USABLE.toByteArray()
    return ByteArray(size) { i -> if (i < head.size) head[i] else ' '.code.toByte() }
}

// 끝없는 본문 — 쓸 수 있는 토큰 뒤에 JSON 공백이 끝없이 온다. 가드가 limit 바이트 너머를 **요청하기만 해도** 시험을 깬다(실제
// 소켓이라면 그만큼 읽혔을 것이다). OOM 에 기대지 않고 「본문 크기에 비례해 읽는가」를 잰다.
private class TrgEndlessBody(
    private val limit: Long,
) : InputStream() {
    private val head = TRG_USABLE.toByteArray()
    var served = 0L
        private set
    var overread = false
        private set

    override fun read(): Int {
        val one = ByteArray(1)
        read(one, 0, 1)
        return one[0].toInt() and 0xff
    }

    override fun read(
        b: ByteArray,
        off: Int,
        len: Int,
    ): Int {
        if (len == 0) return 0
        if (len > limit - served) {
            overread = true
            throw AssertionError("가드가 $served 바이트 뒤에서 $len 바이트를 더 요청했다 — 상한+1 = $limit")
        }
        for (i in 0 until len) {
            b[off + i] = if (served < head.size) head[served.toInt()] else ' '.code.toByte()
            served++
        }
        return len
    }
}

// 정해진 크기의 본문(쓸 수 있는 토큰 + 공백) — 배경 배열 없이 만들어 시험 자신의 할당을 재지 않는다.
private class TrgSizedBody(
    private val size: Long,
) : InputStream() {
    private val head = TRG_USABLE.toByteArray()
    private var pos = 0L

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
    }

    override fun read(
        b: ByteArray,
        off: Int,
        len: Int,
    ): Int {
        if (len == 0) return 0
        if (pos >= size) return -1
        val n = minOf(len.toLong(), size - pos).toInt()
        for (i in 0 until n) {
            b[off + i] = if (pos < head.size) head[pos.toInt()] else ' '.code.toByte()
            pos++
        }
        return n
    }
}

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
        every { req.setProperty(any(), any()) } just runs
        return req
    }

    // ⚠️ 미디어 타입은 명시한다 — relaxed 목은 mediaType 에 null 이 아닌 목을 돌려줘 원시 바이트 판정 자리를 건너뛴다.
    private fun response(
        status: Response.Status,
        body: InputStream?,
        mediaType: MediaType? = null,
    ): ClientResponseContext {
        val res = mockk<ClientResponseContext>(relaxed = true)
        every { res.statusInfo } returns status
        every { res.entityStream } returns body
        every { res.mediaType } returns mediaType
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
            val req = request(method, uri)
            val res = response(status, bytes(TRG_NUMBER), MediaType.APPLICATION_JSON_TYPE)
            guard.filter(req, res)
            verify(exactly = 0) { res.entityStream }
            verify(exactly = 0) { res.entityStream = any() }
            verify(exactly = 0) { req.setProperty(any(), any()) } // 표시가 없으면 ReaderInterceptor 도 그 엔티티를 보지 않는다
        }
    }

    // 범위 안이고 미디어 타입이 있으면 응답 필터는 엔티티를 읽지 않고 표시만 단다 — 결합은 ReaderInterceptor 사슬(gzip 해제
    // 등)을 거친 바이트를 읽으므로 판정은 가장 안쪽 ReaderInterceptor(aroundReadFrom) 몫이다.
    @Test
    fun `token response with a media type is marked for the reader, not read by the filter`() {
        val req = request("POST", TRG_TOKEN)
        val res = response(Response.Status.OK, bytes(TRG_NUMBER), MediaType.APPLICATION_JSON_TYPE)
        TokenResponseGuard().filter(req, res)
        verify(exactly = 1) { req.setProperty(TokenResponseGuard.JUDGE_ENTITY, true) }
        verify(exactly = 0) { res.entityStream }
        verify(exactly = 0) { res.entityStream = any() }
    }

    // ⚠️ 아래 두 테스트의 응답은 미디어 타입이 없다 — 결합이 아예 읽지 않는 2xx 라 응답 필터가 원시 바이트로 판정하는 자리다
    // (RESTEasy extractResult 는 미디어 타입이 없으면 엔티티를 읽지 않는다 — 200 이면 ResponseProcessingException, 그 밖의 2xx 면
    // null).
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

    // ───────────── ReaderInterceptor — 결합이 읽을 바이트를 판정한다 ─────────────

    private fun readContext(
        mark: Any?,
        body: InputStream?,
    ): ReaderInterceptorContext {
        val ctx = mockk<ReaderInterceptorContext>()
        every { ctx.getProperty(TokenResponseGuard.JUDGE_ENTITY) } returns mark
        every { ctx.inputStream } returns body
        every { ctx.inputStream = any() } just runs
        every { ctx.proceed() } returns "bound"
        return ctx
    }

    @Test
    fun `reader leaves unmarked entities untouched`() {
        for (mark in listOf(null, false, "true")) {
            val ctx = readContext(mark, bytes(TRG_NUMBER))
            assertEquals("bound", TokenResponseGuard().aroundReadFrom(ctx))
            verify(exactly = 0) { ctx.inputStream }
            verify(exactly = 0) { ctx.inputStream = any() }
        }
    }

    @Test
    fun `reader hands a usable marked entity on byte for byte`() {
        val body = """{"access_token":"AT","expires_in":300,"refresh_token":"RT","x":[1]}"""
        val ctx = readContext(true, bytes(body))
        val handed = slot<InputStream>()
        every { ctx.inputStream = capture(handed) } just runs
        assertEquals("bound", TokenResponseGuard().aroundReadFrom(ctx))
        assertEquals(body, handed.captured.readAllBytes().decodeToString())
    }

    @Test
    fun `reader rejects an unusable marked entity without quoting it`() {
        for (body in listOf(bytes(TRG_NUMBER), bytes("""{"access_token":""}"""), null)) {
            val ctx = readContext(true, body)
            val e = assertFailsWith<IOException> { TokenResponseGuard().aroundReadFrom(ctx) }
            assertEquals("token endpoint response carries no usable access_token", e.message)
            assertNull(e.cause)
            verify(exactly = 0) { ctx.proceed() }
            verify(exactly = 0) { ctx.inputStream = any() }
        }
    }

    // ───────────── 크기 상한 — 판정이 읽고 쥐는 바이트 ─────────────

    // 상한을 넘는 본문은 쓸 수 있는 토큰이 들어 있어도 쓸 수 없는 토큰과 같은 상수 메시지로 거부하고, 그 판정을 위해 상한+1
    // 바이트까지만 읽는다 — 두 진입점 모두(미디어 타입 없는 응답 필터 · 결합 직전 ReaderInterceptor).
    @Test
    fun `body above the cap is rejected without reading past cap plus one`() {
        val raw = TrgEndlessBody(TRG_CAP + 1L)
        val res = response(Response.Status.OK, raw)
        val filtered = assertFailsWith<IOException> { TokenResponseGuard().filter(request("POST", TRG_TOKEN), res) }
        assertEquals("token endpoint response carries no usable access_token", filtered.message)
        assertNull(filtered.cause)
        assertFalse(raw.overread)
        assertEquals(TRG_CAP + 1L, raw.served, "넘침을 알아챌 한 바이트까지 읽어야 한다")
        verify(exactly = 0) { res.entityStream = any() }

        val decoded = TrgEndlessBody(TRG_CAP + 1L)
        val ctx = readContext(true, decoded)
        val read = assertFailsWith<IOException> { TokenResponseGuard().aroundReadFrom(ctx) }
        assertEquals("token endpoint response carries no usable access_token", read.message)
        assertNull(read.cause)
        assertFalse(decoded.overread)
        assertEquals(TRG_CAP + 1L, decoded.served, "넘침을 알아챌 한 바이트까지 읽어야 한다")
        verify(exactly = 0) { ctx.proceed() }
        verify(exactly = 0) { ctx.inputStream = any() }
    }

    // 경계 — 정확히 상한인 본문은 바이트 그대로 넘기고, 한 바이트 더 크면 거부한다(두 진입점).
    @Test
    fun `body of exactly the cap is handed on, one byte more is rejected`() {
        val atCap = trgPadded(TRG_CAP)
        val res = response(Response.Status.OK, ByteArrayInputStream(atCap))
        val handed = slot<InputStream>()
        every { res.entityStream = capture(handed) } just runs
        TokenResponseGuard().filter(request("POST", TRG_TOKEN), res)
        assertContentEquals(atCap, handed.captured.readAllBytes())

        val ctx = readContext(true, ByteArrayInputStream(atCap))
        val read = slot<InputStream>()
        every { ctx.inputStream = capture(read) } just runs
        assertEquals("bound", TokenResponseGuard().aroundReadFrom(ctx))
        assertContentEquals(atCap, read.captured.readAllBytes())

        val over = response(Response.Status.OK, ByteArrayInputStream(trgPadded(TRG_CAP + 1)))
        val e = assertFailsWith<IOException> { TokenResponseGuard().filter(request("POST", TRG_TOKEN), over) }
        assertEquals("token endpoint response carries no usable access_token", e.message)
        verify(exactly = 0) { over.entityStream = any() }
        val overRead = readContext(true, ByteArrayInputStream(trgPadded(TRG_CAP + 1)))
        val e2 = assertFailsWith<IOException> { TokenResponseGuard().aroundReadFrom(overRead) }
        assertEquals("token endpoint response carries no usable access_token", e2.message)
        verify(exactly = 0) { overRead.proceed() }
    }

    // 쥐는 메모리도 본문 크기와 무관하다 — 16 MiB 본문을 판정하는 동안 이 스레드가 할당한 바이트가 상한의 몇 배 안이다(수정 전
    // readAllBytes 는 본문 전체와 그 사본을 할당했다). HotSpot 의 스레드 할당 계수기로 잰다 — OOM 에 기대지 않는다.
    @Test
    fun `rejecting a huge body allocates independently of its size`() {
        val bean = ManagementFactory.getThreadMXBean()
        assumeTrue(bean is com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM")
        val threads = bean as com.sun.management.ThreadMXBean
        assumeTrue(threads.isThreadAllocatedMemorySupported && threads.isThreadAllocatedMemoryEnabled)
        val huge = 16L shl 20
        val guard = TokenResponseGuard()
        val req = request("POST", TRG_TOKEN)
        judge(guard, req, response(Response.Status.OK, TrgSizedBody(huge))) // 데우기 — 클래스 로딩의 할당을 재지 않는다
        val res = response(Response.Status.OK, TrgSizedBody(huge))
        val before = threads.currentThreadAllocatedBytes
        val rejected = judge(guard, req, res)
        val allocated = threads.currentThreadAllocatedBytes - before
        assertTrue(allocated < 4L * (TRG_CAP + 1), "$huge 바이트 본문 하나를 판정하며 $allocated 바이트를 할당했다")
        assertNotNull(rejected, "상한을 넘는 본문을 넘겼다")
    }

    // 응답 필터 판정 하나 — 거부면 그 예외를, 통과면 null 을 돌려준다(할당을 재는 구간에 단언을 두지 않는다).
    private fun judge(
        guard: TokenResponseGuard,
        req: ClientRequestContext,
        res: ClientResponseContext,
    ): IOException? =
        try {
            guard.filter(req, res)
            null
        } catch (e: IOException) {
            e
        }

    // 배선 — admin 의 JAX-RS 클라이언트에 두 계약으로 등록돼 있어야 한다(TokenManager 의 토큰 요청이 그 클라이언트로 나간다).
    // ReaderInterceptor 는 오름차순으로 돌므로 가장 큰 우선순위 값이 결합 바로 앞이다 — gzip 해제(Priorities.ENTITY_CODER)보다
    // 작아지면 원시 바이트를 판정하게 된다.
    @Test
    fun `timeout client registers the guard`() {
        val config = KeycloakConfig("https://kc.example.com", "r", "app", "s3cr3t".toCharArray())
        AdminClient.buildTimeoutClient(config).use { client ->
            assertTrue(client.configuration.isRegistered(TokenResponseGuard::class.java))
            val contracts = client.configuration.getContracts(TokenResponseGuard::class.java)
            assertEquals(Priorities.USER, contracts[ClientResponseFilter::class.java])
            assertEquals(Int.MAX_VALUE, contracts[ReaderInterceptor::class.java])
        }
    }
}
