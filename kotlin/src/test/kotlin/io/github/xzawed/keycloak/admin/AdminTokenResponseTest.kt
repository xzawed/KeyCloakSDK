package io.github.xzawed.keycloak.admin

import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.UserRepresentation
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.Locale
import java.util.zip.GZIPOutputStream
import kotlin.concurrent.thread
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

private fun atrGzip(s: String): ByteArray = atrGzip(s.toByteArray())

private fun atrGzip(plain: ByteArray): ByteArray =
    ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(plain) } }.toByteArray()

// JSON 뒤를 JSON 공백으로 채워 정확히 size 바이트로 — 결합에게는 같은 값이다.
private fun atrPadTo(
    json: String,
    size: Int,
): ByteArray {
    val head = json.toByteArray()
    return ByteArray(size) { i -> if (i < head.size) head[i] else ' '.code.toByte() }
}

// 깨진 전송 시험의 첫 부분(쓸 수 있는 토큰 + 공백) — 상한+1 보다 커서 가드는 그 앞 상한+1 바이트만 읽고 거부한다.
private const val ATR_FIRST = 60_000

// CRLF(또는 LF)로 끝나는 HTTP 한 줄 — 줄 끝은 빼고.
private fun atrHttpLine(input: InputStream): String {
    val line = ByteArrayOutputStream()
    var c = input.read()
    while (c >= 0 && c != '\n'.code) {
        if (c != '\r'.code) line.write(c)
        c = input.read()
    }
    return line.toString(Charsets.ISO_8859_1)
}

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

    private fun admin(): AdminClient = admin(server.address.port, Duration.ofSeconds(5))

    private fun admin(
        port: Int,
        readTimeout: Duration,
    ): AdminClient =
        AdminClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:$port",
                realm = ATR_REALM,
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = readTimeout,
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

    // admin 호출을 내고 그 실패를 돌려준다(성공이면 null). 취소는 그대로 던진다. client 는 다른 토큰 엔드포인트를 겨눌 때.
    private suspend fun failureOf(
        client: () -> AdminClient = { admin() },
        block: suspend (AdminClient) -> Unit,
    ): Throwable? =
        try {
            client().use { block(it) }
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
        client: () -> AdminClient = { admin() },
    ): String {
        val thrown = failureOf(client) { it.users().get("x") }
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

    // admin 호출 하나가 Bearer good 으로 나아가 성공하는지 — 어긋남은 wrong 에, 행은 table 에.
    private suspend fun expectGood(
        label: String,
        wrong: MutableList<String>,
        table: MutableList<String>,
    ) {
        failureOf { it.users().get("x") }?.let { wrong += "$label: 성공해야 한다 — $it" }
        table += "$label → grants ${grants()} · admin ${adminHits()}"
        if (adminHits() != listOf("GET /admin/realms/r/users/x · Bearer good") || grants() != listOf("client_credentials")) {
            wrong += "$label: ${grants()} ${adminHits()}"
        }
    }

    // 크기 상한(Java 동형) — 토큰 응답 본문이 상한(JWKS 응답 상한, Nimbus JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT)을 넘으면 그
    // 안의 토큰이 쓸 수 있어도 쓸 수 없는 토큰과 똑같이 거부한다 — KeycloakTransportException · admin 요청 0 건 · 토큰 요청 1 건.
    // 상한 안의 쓸 수 있는 토큰은 평문·gzip 모두 그대로 동작한다. 판정은 결합이 읽는 바이트로 하므로 gzip 은 **푼** 크기로
    // 잰다. 본문은 쓸 수 있는 토큰 뒤를 JSON 공백으로 채운 것이다 — 가드 없이 결합만 있으면 스트리밍으로 통과하는 모양이고,
    // 수정 전 가드는 그것을 통째로 버퍼링해 힙보다 크면 OutOfMemoryError 를 냈다.
    @Test
    fun `token response above the cap is rejected like an unusable token`() =
        runTest {
            val cap = JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            val body = atrTokenBody("\"good\"", ",\"refresh_token\":\"$ATR_RT_CANARY\"")
            reset(Reply(200, atrPadTo(body, cap)))
            expectGood("평문 = 상한", wrong, table)
            reset(Reply(200, atrPadTo(body, cap + 1)))
            table += callExpectingRejection("평문 = 상한+1", wrong)
            for (status in listOf(200, 201)) {
                reset(Reply(status, atrPadTo(body, cap + 1), typed = false))
                table += callExpectingRejection("Content-Type 없음 $status = 상한+1", wrong)
            }
            System.setProperty("resteasy.allowGzip", "true")
            try {
                reset(Reply(200, atrGzip(atrPadTo(body, cap)), "gzip"))
                expectGood("gzip 푼 크기 = 상한", wrong, table)
                reset(Reply(200, atrGzip(atrPadTo(body, cap + 1)), "gzip"))
                table += callExpectingRejection("gzip 푼 크기 = 상한+1", wrong)
            } finally {
                System.clearProperty("resteasy.allowGzip")
            }
            println("[AdminTokenResponseTest 크기 상한 $cap]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 거부한 뒤 연결을 놓다가 실패해도 거부는 그대로다(Java 동형) — 상한을 넘는 응답(쓸 수 있는 토큰 + 공백)의 나머지 전송이
    // 깨져도(ReleaseFault) 결과는 쓸 수 없는 토큰과 같다: KeycloakTransportException · admin 요청 0 건 · 토큰 요청 1 건 · 걸러진
    // 원인 사슬 · 응답 바이트 미노출. ⚠️ 미디어 타입이 없는 2xx 는 응답 필터에서 거부되고 RESTEasy(ClientInvocation.invoke)가 그
    // 응답을 try/catch 없이 닫는다 — 닫기가 HttpCore 로 나머지를 비우다 난 오류가 거부를 대신해 jakarta.ws.rs.ProcessingException·
    // org.apache.http.* 사슬로 나갔고(RedactedCause 로 걸러지지 않았다), 청크 크기 줄 오류는 「Bad chunk header: <그 줄>」 로 응답
    // 바이트(여기서는 refresh_token)를 찍었다. 본문을 통째로 읽던 그 전 가드는 그 오류를 판정 안에서 만나 걸러진 사슬이었다(실측).
    // 미디어 타입이 있으면 RESTEasy 가 닫기 실패를 삼킨다(대조 행).
    @Test
    fun `token response above the cap stays rejected when releasing the connection fails`() =
        runTest {
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            RawEndpoint().use { raw ->
                val client = { admin(raw.port, Duration.ofSeconds(2)) }
                for (fault in ReleaseFault.entries) {
                    for (status in listOf(200, 201)) {
                        raw.reply(fault, status, typed = false)
                        table += callExpectingRejection("Content-Type 없음 $status · $fault", wrong, client)
                    }
                }
                raw.reply(ReleaseFault.BAD_CHUNK_HEADER, 200, typed = true)
                table += callExpectingRejection("application/json 200 · ${ReleaseFault.BAD_CHUNK_HEADER}", wrong, client)
            }
            println("[AdminTokenResponseTest 거부 뒤 연결 해제 실패]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 상한을 넘는 첫 부분 뒤에서 깨지는 전송 — 가드가 거부한 뒤 연결을 놓으며 나머지를 비울 때 그 비우기가 실패한다.
    private enum class ReleaseFault {
        // 다음 청크 크기 줄이 16진이 아니다 — HttpCore 가 그 줄을 「Bad chunk header: …」 에 그대로 싣는다(여기서는 refresh_token).
        BAD_CHUNK_HEADER,

        // 청크 도중에 연결이 끊긴다(TruncatedChunkException).
        TRUNCATED_CHUNK,

        // Content-Length 보다 적게 보내고 끊는다(ConnectionClosedException).
        SHORT_CONTENT_LENGTH,

        // Content-Length 보다 적게 보내고 멈춘다 — 비우기가 읽기 타임아웃을 만난다(SocketTimeoutException).
        STALL,
    }

    // 바이트를 그대로 쓰는 토큰 엔드포인트 — com.sun HttpServer 는 전송 틀(청크·길이)을 스스로 짜서 깨진 틀을 낼 수 없다. 토큰
    // 요청과 admin 요청을 이 시험의 grants·adminHits 에 적고, admin 은 handle 처럼 성공을 낸다.
    private inner class RawEndpoint : AutoCloseable {
        private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        @Volatile private var fault = ReleaseFault.BAD_CHUNK_HEADER

        @Volatile private var status = 200

        @Volatile private var typed = false

        val port: Int get() = socket.localPort

        init {
            thread(isDaemon = true, name = "raw-token-endpoint") { serve() }
        }

        fun reply(
            fault: ReleaseFault,
            status: Int,
            typed: Boolean,
        ) {
            this.fault = fault
            this.status = status
            this.typed = typed
            reset()
        }

        private fun serve() {
            while (!socket.isClosed) {
                val s =
                    try {
                        socket.accept()
                    } catch (closed: IOException) {
                        return
                    }
                thread(isDaemon = true, name = "raw-token-exchange") { answer(s) }
            }
        }

        private fun answer(s: Socket) {
            try {
                s.use { exchange(it) }
            } catch (clientWentAway: IOException) {
                // 클라이언트가 연결을 끊었다 — 깨진 전송의 정상 결말이다
            }
        }

        private fun exchange(s: Socket) {
            s.soTimeout = 10_000
            val input = BufferedInputStream(s.getInputStream())
            val requestLine = atrHttpLine(input).split(" ")
            val headers = mutableMapOf<String, String>()
            while (true) {
                val h = atrHttpLine(input)
                if (h.isEmpty()) break
                val colon = h.indexOf(':')
                if (colon > 0) headers[h.substring(0, colon).trim().lowercase(Locale.ROOT)] = h.substring(colon + 1).trim()
            }
            val body = input.readNBytes(headers["content-length"]?.toInt() ?: 0).decodeToString()
            val path = requestLine.getOrElse(1) { "" }
            val out = BufferedOutputStream(s.getOutputStream())
            when {
                path == ATR_TOKEN_PATH -> {
                    synchronized(lock) { grants += form(body)["grant_type"] ?: "?" }
                    writeBrokenToken(out)
                    if (fault == ReleaseFault.STALL) input.read() // 클라이언트가 끊을 때까지(읽기 타임아웃 뒤) 연결을 붙든다
                }
                path.startsWith("/admin/realms/$ATR_REALM/users") -> {
                    synchronized(lock) { adminHits += "${requestLine[0]} $path · ${headers["authorization"]}" }
                    val user = """{"id":"x","username":"alice"}""".toByteArray()
                    val head =
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                            "Content-Length: ${user.size}\r\nConnection: close\r\n\r\n"
                    out.write(head.toByteArray(Charsets.ISO_8859_1))
                    out.write(user)
                    out.flush()
                }
                else -> {
                    out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                    out.flush()
                }
            }
        }

        private fun writeBrokenToken(out: OutputStream) {
            val chunked = fault == ReleaseFault.BAD_CHUNK_HEADER || fault == ReleaseFault.TRUNCATED_CHUNK
            val declared = if (fault == ReleaseFault.BAD_CHUNK_HEADER) ATR_FIRST else ATR_FIRST + 10_000
            val head =
                "HTTP/1.1 $status ${if (status == 200) "OK" else "Created"}\r\n" +
                    (if (typed) "Content-Type: application/json\r\n" else "") +
                    (if (chunked) "Transfer-Encoding: chunked\r\n" else "Content-Length: $declared\r\n") +
                    "Connection: close\r\n\r\n"
            out.write(head.toByteArray(Charsets.ISO_8859_1))
            if (chunked) out.write("${Integer.toHexString(declared)}\r\n".toByteArray(Charsets.ISO_8859_1))
            out.write(atrPadTo(atrTokenBody("\"good\"", ",\"refresh_token\":\"$ATR_RT_CANARY\""), ATR_FIRST))
            if (fault == ReleaseFault.BAD_CHUNK_HEADER) {
                // 다음 청크 크기 자리에 응답 내용 — 16진이 아니므로 HttpCore 가 이 줄을 오류 메시지에 그대로 싣는다
                out.write("\r\n\"refresh_token\":\"$ATR_RT_CANARY\"\r\n".toByteArray(Charsets.ISO_8859_1))
            }
            out.flush()
        }

        override fun close() = socket.close()
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
