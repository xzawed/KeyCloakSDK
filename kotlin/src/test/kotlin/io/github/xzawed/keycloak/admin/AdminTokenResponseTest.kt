package io.github.xzawed.keycloak.admin

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.UserRepresentation
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.time.Duration
import java.util.zip.GZIPOutputStream
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

// admin 레인의 토큰 응답 계약(Java `AdminTokenResponseTest` 동형) — admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client
// 내장 TokenManager 가 그 응답을 Jackson 으로 읽는다. 계약: 쓸 수 없는 access_token(누락·null·숫자·불리언·빈 문자열·객체·
// 배열)이면 **admin API 요청을 하나도 보내지 않고** KeycloakTransportException 으로 실패한다 — 오늘 null·객체·배열·누락이
// 이미 그렇게 실패하던 타입이다. 쓸 수 있는 문자열 토큰은 그대로 동작하고, TokenManager 의 갱신(refresh_token 그랜트)도
// 같은 검사를 받는다.
//
// ⚠️ 가짜 admin 엔드포인트는 **성공**(200 사용자)을 낸다 — 강제변환된 토큰으로 나간 요청이 404 로 우연히 실패해 결함이
// 「실패했으니 됐다」로 가려지지 않게. 판정의 무게는 「admin 요청 0 건」이 진다(적대 행렬 W3a 와 같은 기준). 네트워크는
// 로컬 루프백만 쓴다(Docker 불필요).
private const val ATR_REALM = "r"
private const val ATR_TOKEN_PATH = "/realms/$ATR_REALM/protocol/openid-connect/token"
private const val ATR_MISSING = "(missing)"

// 같은 응답에 실린 refresh_token — 거부 오류의 어느 표현에도 찍히면 안 된다.
private const val ATR_RT_CANARY = "ZadminRT-0123456789abcdef"

private fun atrTokenBody(
    rawAccessToken: String,
    extra: String = "",
    expiresIn: Int = 300,
): String {
    val at = if (rawAccessToken == ATR_MISSING) "" else "\"access_token\":$rawAccessToken,"
    return "{$at\"token_type\":\"Bearer\",\"expires_in\":$expiresIn$extra}"
}

// 갱신 시나리오의 첫 응답 — expires_in 1 < TokenManager 최소 유효기간(30s) 이라 다음 호출이 refresh_token 으로 갱신한다.
private val ATR_REFRESHABLE = atrTokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300", expiresIn = 1)

private fun atrGzip(s: String): ByteArray =
    ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(s.toByteArray()) } }.toByteArray()

internal class AdminTokenResponseTest {
    // 토큰 엔드포인트의 응답 — contentEncoding 이 있으면 그 헤더를 달고(본문은 이미 그 코딩으로 된 바이트), typed 가 거짓이면
    // Content-Type 을 달지 않는다.
    private class Reply(
        val status: Int,
        val body: ByteArray,
        val contentEncoding: String? = null,
        val typed: Boolean = true,
    ) {
        constructor(status: Int, body: String) : this(status, body.toByteArray())
    }

    private lateinit var server: HttpServer
    private val lock = Any()

    // 토큰 엔드포인트가 차례로 낼 응답 — 마지막 것은 계속 낸다.
    private val tokenReplies = ArrayDeque<Reply>()
    private val grants = mutableListOf<String>()

    // admin 엔드포인트에 닿은 요청(메서드 경로 · Authorization).
    private val adminHits = mutableListOf<String>()

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { handle(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    private fun handle(ex: HttpExchange) {
        val path = ex.requestURI.path
        val body = ex.requestBody.readAllBytes().decodeToString()
        when {
            path == ATR_TOKEN_PATH -> {
                val r =
                    synchronized(lock) {
                        grants += form(body)["grant_type"] ?: "?"
                        if (tokenReplies.size > 1) tokenReplies.removeFirst() else tokenReplies.first()
                    }
                r.contentEncoding?.let { ex.responseHeaders.add("Content-Encoding", it) }
                send(ex, r.status, r.body, r.typed)
            }
            path.startsWith("/admin/realms/$ATR_REALM/users") -> {
                synchronized(lock) { adminHits += "${ex.requestMethod} $path · ${ex.requestHeaders.getFirst("Authorization")}" }
                if (ex.requestMethod == "POST") {
                    ex.responseHeaders.add("Location", "http://127.0.0.1/admin/realms/$ATR_REALM/users/new-id")
                    send(ex, 201, null)
                } else {
                    send(ex, 200, """{"id":"x","username":"alice"}""")
                }
            }
            else -> send(ex, 404, """{"error":"not found"}""")
        }
    }

    private fun send(
        ex: HttpExchange,
        status: Int,
        body: String?,
    ) {
        if (body == null) {
            ex.sendResponseHeaders(status, -1)
            ex.close()
            return
        }
        send(ex, status, body.toByteArray(), typed = true)
    }

    private fun send(
        ex: HttpExchange,
        status: Int,
        bytes: ByteArray,
        typed: Boolean,
    ) {
        if (typed) ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(status, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }

    private fun form(body: String): Map<String, String> =
        body
            .split("&")
            .filter { it.indexOf('=') > 0 }
            .associate { it.substringBefore('=') to it.substringAfter('=') }

    private fun admin(): AdminClient =
        AdminClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = ATR_REALM,
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = Duration.ofSeconds(5),
            ),
        )

    private fun reset(vararg replies: Reply) =
        synchronized(lock) {
            tokenReplies.clear()
            tokenReplies.addAll(replies)
            grants.clear()
            adminHits.clear()
        }

    private fun adminHits(): List<String> = synchronized(lock) { adminHits.toList() }

    private fun grants(): List<String> = synchronized(lock) { grants.toList() }

    @Test
    fun `unusable access_token sends no admin request and fails as transport`() =
        runTest {
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            // 마지막 행은 중복 키 — 결합은 마지막 값(숫자)을 쓴다(첫 값만 보는 검사는 여기서 Bearer 12345 로 나아간다).
            val shapes = listOf("12345", "true", "\"\"", "null", """{"v":"x"}""", """["x"]""", ATR_MISSING, "\"AT\",\"access_token\":12345")
            for (raw in shapes) {
                reset(Reply(200, atrTokenBody(raw, ",\"refresh_token\":\"$ATR_RT_CANARY\"")))
                table += callExpectingRejection("access_token $raw", wrong)
            }
            println("[AdminTokenResponseTest]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // admin 호출을 내고 그 실패를 돌려준다(성공이면 null). 취소는 그대로 던진다.
    private suspend fun failureOf(block: suspend (AdminClient) -> Unit): Throwable? =
        try {
            admin().use { block(it) }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            e
        }

    // admin 호출 하나를 내고 거부 계약을 잰다 — KeycloakTransportException("Admin request failed") · admin 요청 0 건 · 토큰 요청
    // 정확히 1 건 · 원인 사슬에 java.*·SDK 밖 타입 없음(§4) · 응답의 refresh_token 미노출. 어긋남은 wrong 에 쌓고 표의 한 행을
    // 돌려준다.
    private suspend fun callExpectingRejection(
        label: String,
        wrong: MutableList<String>,
    ): String {
        val thrown = failureOf { it.users().get("x") }
        val hits = adminHits()
        val row =
            "${label.padEnd(24)} → ${thrown?.let { "${it.javaClass.simpleName}(${it.message})" } ?: "성공"} · " +
                "grants ${grants()} · admin $hits"
        if (thrown !is KeycloakTransportException || thrown.message != "Admin request failed") {
            wrong += "$label: KeycloakTransportException(Admin request failed) 가 아니다 — ${thrown?.javaClass?.name ?: "성공"}"
        }
        if (hits.isNotEmpty()) wrong += "$label: 쓸 수 없는 토큰으로 admin 요청이 나갔다 — $hits"
        if (grants().size != 1) wrong += "$label: 토큰 요청이 정확히 한 번이 아니다 — ${grants()}"
        if (thrown == null) return row
        // §4 — 원인 사슬에 하위 라이브러리 인스턴스가 없고(응답을 읽다 난 사슬은 RedactedCause 사본이다), 응답을 인용하지 않는다.
        generateSequence(thrown.cause) { it.cause }.take(16).forEach { c ->
            val n = c.javaClass.name
            if (!n.startsWith("java.") && !n.startsWith("io.github.xzawed.")) wrong += "$label: 원인 사슬에 하위 타입이 샜다 — $n"
        }
        if (ATR_RT_CANARY.take(10) in thrown.stackTraceToString()) wrong += "$label: 오류가 응답의 refresh_token 을 찍었다"
        return row
    }

    // 내용 코딩(Content-Encoding)이 붙은 토큰 응답도 **결합이 읽는 바이트**로 판정한다(Java 동형). 소비자가 RESTEasy 의 gzip
    // 해제를 켜면(resteasy.allowGzip=true → GZIPDecodingInterceptor) 결합은 응답 필터 뒤의 ReaderInterceptor 에서 푼 바이트를
    // 읽는다 — 원시 바이트를 보던 가드는 gzip 으로 온 쓸 수 있는 토큰을 거부해 admin 이 통째로 멈췄다(수정 전 실측: 가드 없이는
    // Bearer good 으로 성공, 가드가 있으면 KeycloakTransportException · admin []). 해제기가 없는 코딩은 결합이 원시 바이트를
    // 그대로 읽으므로 그 바이트로 판정한다 — 헤더 하나로 검사를 건너뛰지 못한다.
    @Test
    fun `content-coded token response is judged on the bytes the binding reads`() =
        runTest {
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            val canary = ",\"refresh_token\":\"$ATR_RT_CANARY\""
            val good = listOf("GET /admin/realms/r/users/x · Bearer good")
            System.setProperty("resteasy.allowGzip", "true")
            try {
                reset(Reply(200, atrGzip(atrTokenBody("\"good\"", canary)), "gzip"))
                failureOf { it.users().get("x") }?.let { wrong += "gzip \"good\": 성공해야 한다 — $it" }
                table += "gzip \"good\" → grants ${grants()} · admin ${adminHits()}"
                if (adminHits() != good || grants() != listOf("client_credentials")) wrong += "gzip \"good\": ${grants()} ${adminHits()}"

                reset(Reply(200, atrGzip(atrTokenBody("12345", canary)), "gzip"))
                table += callExpectingRejection("gzip 12345", wrong)

                // 갱신(refresh_token 그랜트) 응답도 같은 자리에서 판정한다 — 푼 바이트가 쓸 수 있으면 새 토큰으로 나아간다.
                reset(Reply(200, ATR_REFRESHABLE), Reply(200, atrGzip(atrTokenBody("\"AT-2\"")), "gzip"))
                failureOf {
                    it.users().get("x")
                    it.users().get("x")
                }?.let { wrong += "gzip 갱신: 성공해야 한다 — $it" }
                table += "gzip 갱신 \"AT-2\" → grants ${grants()} · admin ${adminHits()}"
                val refreshed = listOf("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2")
                if (adminHits() != refreshed) wrong += "gzip 갱신: ${adminHits()}"
            } finally {
                System.clearProperty("resteasy.allowGzip")
            }
            // 해제기가 없는 코딩(br) — 결합은 원시 바이트(여기서는 평문 JSON)를 읽는다.
            reset(Reply(200, atrTokenBody("12345", canary).toByteArray(), "br"))
            table += callExpectingRejection("br(평문) 12345", wrong)
            reset(Reply(200, atrTokenBody("\"good\"").toByteArray(), "br"))
            failureOf { it.users().get("x") }?.let { wrong += "br(평문) \"good\": 성공해야 한다 — $it" }
            table += "br(평문) \"good\" → admin ${adminHits()}"
            if (adminHits() != good) wrong += "br(평문) \"good\": ${adminHits()}"
            // Content-Type 이 없는 2xx — 결합이 아예 읽지 않는다(RESTEasy extractResult 는 200 이면 스스로
            // ResponseProcessingException 을 던지고, 그 밖의 2xx 면 null 을 돌려줘 TokenManager 가 NPE 로 멈춘다). 판정은 응답 필터가
            // 원시 바이트로 한다 — 그 자리가 빠지면 201 행의 원인 사슬에 ProcessingException 이 그대로 달린다(§4, 200 행은 RESTEasy
            // 가 대신 막아 가려진다).
            for (status in listOf(200, 201)) {
                reset(Reply(status, atrTokenBody("12345", canary).toByteArray(), typed = false))
                table += callExpectingRejection("Content-Type 없음 $status 12345", wrong)
            }
            println("[AdminTokenResponseTest 내용 코딩]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 대조 — 같은 경로에서 문자열 토큰은 GET·POST 둘 다 admin 에 닿는다(위 실패가 다른 원인이 아님을 보인다).
    @Test
    fun `string access_token reaches admin for reads and writes`() =
        runTest {
            reset(Reply(200, atrTokenBody("\"AT-1\"")))
            admin().use { admin ->
                assertEquals("alice", admin.users().get("x").username)
                assertEquals("new-id", admin.users().create(UserRepresentation().apply { username = "bob" }))
            }
            assertEquals(listOf("client_credentials"), grants(), "토큰은 캐시되어 한 번만 부여돼야 한다")
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "POST /admin/realms/r/users · Bearer AT-1"), adminHits())
        }

    // TokenManager 의 갱신(refresh_token 그랜트) 응답도 같은 검사를 받는다 — 쓸 수 있으면 새 토큰으로 나아간다.
    @Test
    fun `refreshed string access_token is used`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(200, atrTokenBody("\"AT-2\"")))
            admin().use { admin ->
                admin.users().get("x")
                admin.users().get("x")
            }
            assertEquals(listOf("client_credentials", "refresh_token"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2"), adminHits())
        }

    @Test
    fun `refreshed unusable access_token sends no admin request`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(200, atrTokenBody("12345")))
            admin().use { admin ->
                admin.users().get("x")
                val e = assertFailsWith<KeycloakTransportException> { admin.users().get("x") }
                assertEquals("Admin request failed", e.message)
            }
            assertEquals(listOf("client_credentials", "refresh_token"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1"), adminHits(), "갱신된 숫자 토큰으로 나아갔다")
        }

    // 오류 상태의 토큰 응답은 검사하지 않고 TokenManager 에 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가
    // BadRequestException 을 받아 client_credentials 로 다시 부여한다(admin-client 의 복구 경로). 검사가 오류 본문(access_token
    // 없음)까지 거부하면 그 예외가 ResponseProcessingException 으로 바뀌어 복구가 끊긴다.
    @Test
    fun `token error status is left to the TokenManager`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(400, """{"error":"invalid_grant"}"""), Reply(200, atrTokenBody("\"AT-3\"")))
            admin().use { admin ->
                admin.users().get("x")
                admin.users().get("x")
            }
            assertEquals(listOf("client_credentials", "refresh_token", "client_credentials"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-3"), adminHits())
        }
}
