package io.github.xzawed.keycloak

import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import com.sun.net.httpserver.HttpServer
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.lang.management.ManagementFactory
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

// CappedResponseSender 단위 — (1) 상한 안의 응답은 Nimbus 자신의 `HTTPRequest.send()` 와 **같은** HTTPResponse 다(상태·상태
// 문구·헤더·본문 문자열 — 줄 끝과 깨진 UTF-8 까지), (2) 상한을 넘으면 상한만 말하는 예외, (3) 상한+1 바이트 너머를 요청하지 않고,
// (4) 읽은 만큼만 할당한다. 공개 API 의 끝에서 끝까지 계약(다섯 레인)은 `TokenResponseCapTest` 가 진다.
private const val CRS_CAP = 1_048_576
private const val CRS_PATH = "/realms/r/protocol/openid-connect/token"

// HotSpot 의 스레드 할당 계수기 — 없는 JVM 에서는 할당 시험을 건너뛴다.
private fun crsAllocatedThisThread(): Long {
    val bean = ManagementFactory.getThreadMXBean()
    assumeTrue(bean is com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM")
    val threads = bean as com.sun.management.ThreadMXBean
    assumeTrue(threads.isThreadAllocatedMemorySupported && threads.isThreadAllocatedMemoryEnabled)
    return threads.currentThreadAllocatedBytes
}

// 정해진 크기의 본문(앞부분 head + JSON 공백) — 배경 배열 없이 만들고, 요청받은 길이와 내준 바이트를 센다.
private class CrsCountingBody(
    private val head: ByteArray,
    private val size: Long,
) : InputStream() {
    var requested = 0L
        private set
    var served = 0L
        private set

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
        requested += len
        if (served >= size) return -1
        val n = minOf(len.toLong(), size - served).toInt()
        for (i in 0 until n) {
            b[off + i] = if (served < head.size) head[served.toInt()] else ' '.code.toByte()
            served++
        }
        return n
    }
}

// 요청 하나를 받고 아무 응답 없이 닫는 원시 서버 — 상태 줄을 받지 못한 실패. 받은 요청 수를 센다.
private class CrsSilentServer : AutoCloseable {
    val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val requests = AtomicInteger()

    init {
        Thread(::serve, "crs-silent-server").apply { isDaemon = true }.start()
    }

    private fun serve() {
        while (!socket.isClosed) {
            try {
                socket.accept().use { s ->
                    s.soTimeout = 5_000
                    val input = s.getInputStream()
                    var last4 = 0
                    while (last4 != 0x0d0a0d0a) {
                        val b = input.read()
                        if (b == -1) break
                        last4 = (last4 shl 8) or b
                    }
                    requests.incrementAndGet()
                }
            } catch (gone: IOException) {
                // 닫힌 서버 소켓 · 떠난 클라이언트
            }
        }
    }

    override fun close() {
        socket.close()
    }
}

internal class CappedResponseSenderTest {
    private lateinit var server: HttpServer

    // 서버가 낼 응답 — 원시 바이트 그대로(Content-Length 틀), 204·304 는 본문 없이.
    @Volatile private var status = 200

    @Volatile private var body = ByteArray(0)

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { ex ->
            ex.requestBody.readAllBytes()
            ex.responseHeaders.add("Content-Type", "application/json; charset=UTF-8")
            ex.responseHeaders.add("X-Multi", "a")
            ex.responseHeaders.add("X-Multi", "b")
            val b = body
            if (status == 204 || b.isEmpty()) {
                ex.sendResponseHeaders(status, -1)
                ex.close()
            } else {
                ex.sendResponseHeaders(status, b.size.toLong())
                ex.responseBody.use { it.write(b) }
            }
        }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    private fun request(method: HTTPRequest.Method = HTTPRequest.Method.POST): HTTPRequest =
        HTTPRequest(method, URI("http://127.0.0.1:${server.address.port}$CRS_PATH")).apply {
            connectTimeout = 5_000
            readTimeout = 5_000
            followRedirects = false
            if (method == HTTPRequest.Method.POST) {
                setHeader("Content-Type", "application/x-www-form-urlencoded")
                this.body = "grant_type=client_credentials"
            }
        }

    // 두 응답이 같은가 — 상태·상태 문구·헤더(서버가 매번 다시 찍는 Date 는 뺀다)·본문 문자열. ⚠️ JDK 17 의 HttpURLConnection 은 거듭 오는
    // 헤더의 값 순서를 뒤집는다(JDK-8133686 은 18 에서 고쳐졌다 — 리눅스 Docker 17.0.20.1 실측: X-multi [b, a] 대 새 운송 [a, b]) — 17 에서는
    // 값의 집합으로 비교한다(TransportParityTest 와 같은 정규화). 새 운송은 받은 순서를 지킨다.
    private fun same(
        stock: HTTPResponse,
        capped: HTTPResponse,
    ): String? {
        val strip = { r: HTTPResponse ->
            r.headerMap
                .filterKeys { !it.equals("Date", ignoreCase = true) }
                .mapValues { (_, values) -> if (Runtime.version().feature() < 18) values.sorted() else values }
        }
        return when {
            stock.statusCode != capped.statusCode -> "상태 ${stock.statusCode} != ${capped.statusCode}"
            stock.statusMessage != capped.statusMessage -> "상태 문구 ${stock.statusMessage} != ${capped.statusMessage}"
            strip(stock) != strip(capped) -> "헤더 ${strip(stock)} != ${strip(capped)}"
            stock.body != capped.body -> "본문 ${stock.body?.take(80)} != ${capped.body?.take(80)}"
            else -> null
        }
    }

    // 상한 안의 응답은 Nimbus 의 send() 와 같은 HTTPResponse 다 — 줄 끝(LF·CRLF·CR·없음)은 플랫폼 줄 구분자로, 깨진 UTF-8 은 U+FFFD
    // 로 같은 문자열이 되고, 빈 본문은 둘 다 null, 오류 상태는 오류 스트림에서 읽는다. 정확히 상한인 본문까지 같다.
    @Test
    fun `a response within the cap is the same HTTPResponse Nimbus' own send builds`() {
        val utf8Broken = byteArrayOf('{'.code.toByte(), 0xFF.toByte(), 0xC3.toByte(), 0x28, '}'.code.toByte())
        val bodies =
            listOf(
                "lf" to (200 to "{\"a\":1}\n".toByteArray()),
                "crlf" to (200 to "{\"a\":1}\r\n\r\n".toByteArray()),
                "cr" to (200 to "{\"a\":\r1}\rx".toByteArray()),
                "끝 줄바꿈 없음" to (200 to "{\"access_token\":\"AT\"}".toByteArray()),
                "다중 바이트" to (200 to "{\"d\":\"한글 😀\"}".toByteArray()),
                "깨진 UTF-8" to (200 to utf8Broken),
                "빈 본문" to (200 to ByteArray(0)),
                "204" to (204 to ByteArray(0)),
                "400 오류 본문" to (400 to "{\"error\":\"invalid_grant\"}\n".toByteArray()),
                "401 빈 오류" to (401 to ByteArray(0)),
                "302 본문" to (302 to "moved\n".toByteArray()),
                "정확히 상한" to (200 to ByteArray(CRS_CAP) { i -> if (i % 64 == 63) '\n'.code.toByte() else ' '.code.toByte() }),
            )
        val wrong = mutableListOf<String>()
        for ((label, reply) in bodies) {
            status = reply.first
            body = reply.second
            for (method in listOf(HTTPRequest.Method.POST, HTTPRequest.Method.GET)) {
                val stock = request(method).send()
                val capped = request(method).send(CappedResponseSender("token response"))
                same(stock, capped)?.let { wrong += "$label $method: $it" }
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // strict(토큰·introspection) — 2xx 본문의 잘못된 UTF-8 은 본문을 인용하지 않는 ResponseNotUtf8Exception 이다(끝까지 온 응답을 쓸 수
    // 없다 — 등록부 token-response-class-divergent · Java 동형). 잘못된 꼴은 대체 문자를 낳는 다섯이다 — 이음 바이트가 아닌 바이트 · UTF-8
    // 에 없는 바이트 · 겹침 꼴 · 서로게이트 · 끝에서 잘린 열. 그 밖은 strict 가 아닌 송신과 같은 응답이다: 유효한 UTF-8 · BOM · 4 KiB
    // 버퍼를 여러 번 채우는 글자 수 · 오류 상태의 잘못된 UTF-8(판정은 상태가 한다) · 빈 본문 · 204 · 302. 상한을 넘는 본문은 UTF-8 을
    // 보기 전에 ResponseTooLargeException 이다(다 읽지 않았다).
    @Test
    fun `strict rejects an invalid UTF-8 success body and is the plain sender otherwise`() {
        val wrong = mutableListOf<String>()
        val malformed =
            listOf(
                byteArrayOf(0xC3.toByte(), 0x28),
                byteArrayOf(0xFF.toByte(), 0xFE.toByte()),
                byteArrayOf(0xC0.toByte(), 0xAF.toByte()),
                byteArrayOf(0xED.toByte(), 0xA0.toByte(), 0x80.toByte()),
            )
        for (code in listOf(200, 201, 299)) {
            status = code
            // 마지막 줄 — 디코더의 4 KiB 버퍼를 넘긴 뒤의 잘못된 바이트(첫 버퍼만 재는 검사 — 넘침에서 멈춤 — 가 놓친다, 독립 레그의 변이)
            val bodies =
                malformed.map { "{\"access_token\":\"a".toByteArray() + it + "b\"}".toByteArray() } +
                    listOf("{\"access_token\":\"ab\"}".toByteArray() + byteArrayOf(0xE2.toByte(), 0x82.toByte())) +
                    listOf("{\"access_token\":\"${"é".repeat(5_000)}".toByteArray() + byteArrayOf(0xFF.toByte()) + "\"}".toByteArray())
            for (bad in bodies) {
                body = bad
                val e = runCatching { request().send(CappedResponseSender("token response", strict = true)) }.exceptionOrNull()
                if (e !is ResponseNotUtf8Exception || e.message != "token response is not valid UTF-8" || e.cause != null) {
                    wrong += "$code ${bad.contentToString()}: ResponseNotUtf8Exception 이 아니다 — $e"
                }
            }
        }
        val same =
            listOf(
                200 to "{\"d\":\"한글 😀\"}".toByteArray(),
                200 to byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "{\"a\":1}".toByteArray(),
                200 to "{\"x\":\"${"é".repeat(5_000)}\"}".toByteArray(),
                400 to "{\"error\":\"invalid_grant\",\"error_description\":\"bad ".toByteArray() + byteArrayOf(0xFF.toByte()) +
                    "\"}".toByteArray(),
                503 to "<html>".toByteArray() + byteArrayOf(0xC3.toByte(), 0x28) + "</html>".toByteArray(),
                200 to ByteArray(0),
                204 to ByteArray(0),
                302 to "moved\n".toByteArray(),
            )
        for ((code, payload) in same) {
            status = code
            body = payload
            val plain = request().send(CappedResponseSender("token response"))
            val strict = request().send(CappedResponseSender("token response", strict = true))
            same(plain, strict)?.let { wrong += "$code ${payload.size} bytes: $it" }
        }
        status = 200
        body = ByteArray(CRS_CAP) { ' '.code.toByte() } + byteArrayOf(0xFF.toByte())
        val over = runCatching { request().send(CappedResponseSender("token response", strict = true)) }.exceptionOrNull()
        if (over !is ResponseTooLargeException) wrong += "상한+1 의 잘못된 UTF-8: ResponseTooLargeException 이 아니다 — $over"
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // 오류 상태의 갈래 — 본문 있는 4xx·본문 없는 5xx·성공이 Nimbus 의 send() 와 같은 HTTPResponse 다(POST·GET). 상태 줄을 받지 못한
    // 실패는 둘 다 IOException 이다 — 새 운송의 메시지는 응답과 무관한 상수이고, 새 연결의 실패라 다시 보내지 않는다(Nimbus 의 send()
    // 는 HttpURLConnection 이라 같은 실패에 POST 를 새 연결로 한 번 더 보냈다 — sun.net.http.retryPost). ⚠️ 예전 시험은 가짜
    // HttpURLConnection 의 null 헤더 키·값 갈래를 쟀다 — 새 운송의 헤더는 HttpCore 가 만든 것이라 그 갈래가 없다.
    @Test
    fun `the error branches are what Nimbus' send builds and a missing status line is an IOException`() {
        val wrong = mutableListOf<String>()
        val cases =
            listOf(
                400 to "{\"error\":\"invalid_client\"}".toByteArray(),
                503 to ByteArray(0),
                200 to "{\"access_token\":\"AT\"}".toByteArray(),
            )
        for ((code, payload) in cases) {
            status = code
            body = payload
            for (method in listOf(HTTPRequest.Method.POST, HTTPRequest.Method.GET)) {
                val stock = request(method).send()
                val capped = request(method).send(CappedResponseSender("token response"))
                same(stock, capped)?.let { wrong += "$code $method: $it" }
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        CrsSilentServer().use { silent ->
            val url = URI("http://127.0.0.1:${silent.socket.localPort}$CRS_PATH")
            val silentRequest = {
                HTTPRequest(HTTPRequest.Method.POST, url).apply {
                    connectTimeout = 5_000
                    readTimeout = 5_000
                    followRedirects = false
                    this.body = "grant_type=client_credentials"
                }
            }
            assertFailsWith<IOException> { silentRequest().send() }
            val stockRequests = silent.requests.getAndSet(0)
            val cappedFailure = assertFailsWith<IOException> { silentRequest().send(CappedResponseSender("token response")) }
            assertEquals("Invalid Http response", cappedFailure.message)
            assertNull(cappedFailure.cause)
            for (i in 0 until 50) {
                if (silent.requests.get() > 0) break
                Thread.sleep(20)
            }
            println("[CappedResponseSenderTest] 상태 줄 없음 → Nimbus send() 요청 $stockRequests · 새 운송 ${silent.requests.get()} · $cappedFailure")
            assertEquals(1, silent.requests.get(), "새 연결의 실패를 다시 보냈다")
        }
    }

    // 상한을 넘는 본문(2xx 든 오류든)은 상한만 말하는 예외다 — 응답을 인용하지 않는다.
    @Test
    fun `a body above the cap is refused with a message that names only the cap`() {
        for (code in listOf(200, 400)) {
            status = code
            body = ByteArray(CRS_CAP + 1) { i -> if (i < 7) "SECRET-"[i].code.toByte() else ' '.code.toByte() }
            val e = assertFailsWith<ResponseTooLargeException> { request().send(CappedResponseSender("token response")) }
            assertEquals("token response exceeds 1048576 bytes", e.message)
            assertNull(e.cause)
        }
        assertEquals(CRS_CAP, TOKEN_RESPONSE_MAX_BYTES)
    }

    // 읽기는 상한+1 바이트 너머를 요청하지 않는다(넘침을 알아챌 한 바이트까지) — 끝없는 본문에서도, 정확히 상한인 본문에서도.
    @Test
    fun `the read asks for no more than cap plus one bytes`() {
        val endless = CrsCountingBody("{}".toByteArray(), 32L shl 20)
        assertNull(readWithinCap(endless))
        assertEquals(CRS_CAP + 1L, endless.served)
        assertTrue(endless.requested <= CRS_CAP + 1L, "요청한 바이트 ${endless.requested} > 상한+1")

        val atCap = CrsCountingBody("{}".toByteArray(), CRS_CAP.toLong())
        assertEquals(CRS_CAP, readWithinCap(atCap)?.size)
        assertEquals(CRS_CAP.toLong(), atCap.served)
        assertTrue(atCap.requested <= CRS_CAP + 1L, "요청한 바이트 ${atCap.requested} > 상한+1")

        val small = "{\"access_token\":\"AT\"}".toByteArray()
        assertContentEquals(small, readWithinCap(ByteArrayInputStream(small)))
    }

    // 쥐는 메모리는 읽은 바이트에 비례한다 — 약 2 KiB 토큰 응답 하나를 실제 연결로 받는 동안 이 스레드의 할당이 상한의 1/4 안이고
    // (상한만 한 버퍼를 미리 잡지 않는다), 32 MiB 본문을 거부하는 동안도 상한의 세 배 안이다. 대조: Nimbus 의 send() 는 같은 32 MiB
    // 에 그 본문보다 많이 할당한다(계수기가 그 차이를 본다는 증거). 먼저 한 번씩 보내 데운다(클래스 로딩을 재지 않는다).
    @Test
    fun `memory follows the bytes read`() {
        val small = ("{\"access_token\":\"" + "A".repeat(1_900) + "\",\"token_type\":\"Bearer\",\"expires_in\":300}").toByteArray()
        status = 200
        body = small
        request().send(CappedResponseSender("token response"))
        val before = crsAllocatedThisThread()
        val ok = request().send(CappedResponseSender("token response"))
        val smallAllocated = crsAllocatedThisThread() - before
        assertEquals(String(small), ok.body.trimEnd())

        body = ByteArray(32 shl 20) { ' '.code.toByte() }
        assertFailsWith<ResponseTooLargeException> { request().send(CappedResponseSender("token response")) }
        val before2 = crsAllocatedThisThread()
        assertFailsWith<ResponseTooLargeException> { request().send(CappedResponseSender("token response")) }
        val hugeAllocated = crsAllocatedThisThread() - before2

        val before3 = crsAllocatedThisThread()
        request().send()
        val stockAllocated = crsAllocatedThisThread() - before3
        body = ByteArray(0)
        println(
            "[CappedResponseSenderTest 할당] ${small.size} 바이트 → $smallAllocated · 32 MiB 거부 → $hugeAllocated · " +
                "Nimbus send() 32 MiB → $stockAllocated",
        )
        assertTrue(smallAllocated < CRS_CAP / 4, "${small.size} 바이트 응답 하나에 $smallAllocated 바이트를 할당했다")
        assertTrue(hugeAllocated < 3L * (CRS_CAP + 1), "32 MiB 본문을 거부하며 $hugeAllocated 바이트를 할당했다")
        assertTrue(stockAllocated > 32L shl 20, "대조: Nimbus send() 가 32 MiB 에 $stockAllocated 바이트만 할당했다 — 계수기를 의심할 것")
    }
}
