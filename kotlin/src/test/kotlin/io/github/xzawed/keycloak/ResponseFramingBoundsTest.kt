package io.github.xzawed.keycloak

import com.nimbusds.common.contenttype.ContentType
import com.nimbusds.oauth2.sdk.http.HTTPRequest
import org.junit.jupiter.api.Assertions.assertTimeoutPreemptively
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.lang.management.ManagementFactory
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.URL
import java.time.Duration
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

// 응답의 **틀**(헤더 줄·청크 크기 줄·청크 확장·트레일러)과 상한을 넘는 본문의 **닫기**가 SDK 의 상한에 비례해 묶이는가 —
// auth 레인([CappedResponseSender])과 JWKS 레인([NoRedirectResourceRetriever]). Java `ResponseFramingBoundsTest` 의 이식이다.
//
// 왜: 본문 상한(1 MiB · JWKS 51,200)은 SDK 가 요청하는 본문 바이트만 센다. 짧은 청크 본문 뒤 EOF 까지 읽으면 운송이 트레일러를
// 담고, 상한을 넘은 본문을 거부하며 연결을 닫으면 운송이 나머지를 비운다 — 둘 다 그 운송의 몫이다. JDK(`sun.net`
// ChunkedInputStream)는 트레일러에 한도가 없었고(4 MiB 줄 → 51.5 MB · 한 줄 512 KiB → 4.3 GB · 1.5 초 — 등록부
// `jvm-chunked-trailers-unbounded` 의 kotlin 실측), 평문 청크 닫기는 쌓인 바이트의 제곱 비용이었다(`close-drain-time-unbounded`).
//
// ⚠️ 닫기 시험(`an endless …`)의 차이는 **리눅스에서만** 보인다 — JDK 의 닫기는 소켓에 이미 쌓인 바이트를 읽는데, Windows 루프백의
// 수신 버퍼는 작다. 그래서 이 시험의 적색은 Docker 리눅스에서도 잰다(커밋 메시지). 할당은 호출 스레드의 몫이다 — 예열 뒤에 잰다.
//
// 응답 인용 검사는 원인 사슬 전체(`stackTraceToString`)에 표식이 없어야 하고, 사슬에 하위 운송의 타입(`org.apache.http.*`)이
// 없어야 한다(§4 — 호출부가 원인을 그대로 단다).
private const val RFB_CAP = 1_048_576
private val RFB_TOKEN = """{"access_token":"AT","token_type":"Bearer","expires_in":300}""".toByteArray()
private val RFB_JWKS = """{"keys":[{"kty":"oct","kid":"k1","k":"AAAA"}]}""".toByteArray()

// 거부의 어느 표현에도 찍히면 안 되는 응답 바이트.
private const val RFB_MARKER = "ZframeMARKER0123456789"

// 32 MiB 트레일러·한 줄 1 MiB 트레일러·16 MiB 헤더 줄·청크 확장을 거부하는 호출 하나가 써도 되는 할당 — 상한의 16 배.
private const val RFB_FRAMING_BOUND = 16L * RFB_CAP

// 1 바이트 청크로 끝없이 오는 본문을 상한에서 거부하는 호출 하나의 할당 한도. 상한+1 바이트를 읽는 동안 청크 머리 백만 개를
// 해석하므로 상한의 수십 배가 정상이다(Java 실측 HttpCore ≈ 37 MB) — 닫기가 비우던 때는 리눅스에서 수십 GB 였다.
private const val RFB_ENDLESS_BODY_BOUND = 96L * RFB_CAP

private fun rfbLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun rfbFilled(
    size: Int,
    c: Char,
): ByteArray = ByteArray(size) { c.code.toByte() }

// 서버가 쓰는 응답 — 끝없는 응답은 클라이언트가 떠나 쓰기가 실패할 때까지 쓴다.
private fun interface RfbReply {
    fun write(
        out: OutputStream,
        server: RfbRawServer,
    )
}

private fun rfbChunkedHead(
    out: OutputStream,
    body: ByteArray,
) {
    out.write(
        rfbLatin1(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" +
                Integer.toHexString(body.size) + "\r\n",
        ),
    )
    out.write(body)
    out.write(rfbLatin1("\r\n"))
}

private fun rfbRepeat(
    out: OutputStream,
    server: RfbRawServer,
    block: ByteArray,
    total: Long,
) {
    var left = total
    while (left > 0 && !server.stop) {
        val k = minOf(block.size.toLong(), left).toInt()
        out.write(block, 0, k)
        left -= k
    }
}

// 짧은 청크 본문 뒤 4 KiB 트레일러 줄을 total 바이트.
private fun rfbManyTrailers(
    body: ByteArray,
    total: Long,
) = RfbReply { out, server ->
    rfbChunkedHead(out, body)
    out.write(rfbLatin1("0\r\n"))
    val line = rfbFilled(4096, 'A')
    rfbLatin1("X-Trail-x: ").copyInto(line)
    line[4094] = '\r'.code.toByte()
    line[4095] = '\n'.code.toByte()
    rfbRepeat(out, server, line, total)
    out.write(rfbLatin1("\r\n"))
}

// 짧은 청크 본문 뒤 size 바이트짜리 트레일러 한 줄.
private fun rfbOneTrailer(
    body: ByteArray,
    size: Int,
) = RfbReply { out, server ->
    rfbChunkedHead(out, body)
    out.write(rfbLatin1("0\r\nX-Trail-Big: "))
    rfbRepeat(out, server, rfbFilled(64 * 1024, 'A'), size.toLong())
    out.write(rfbLatin1("\r\n\r\n"))
}

// size 바이트짜리 응답 헤더 한 줄 — 그 뒤는 멀쩡한 Content-Length 본문.
private fun rfbOneHeaderLine(
    body: ByteArray,
    size: Int,
) = RfbReply { out, server ->
    out.write(rfbLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Big: "))
    rfbRepeat(out, server, rfbFilled(64 * 1024, 'B'), size.toLong())
    out.write(rfbLatin1("\r\nContent-Length: ${body.size}\r\n\r\n"))
    out.write(body)
}

// 둘째 청크의 크기 줄에 size 바이트짜리 청크 확장.
private fun rfbChunkExtension(
    body: ByteArray,
    size: Int,
) = RfbReply { out, server ->
    rfbChunkedHead(out, body)
    out.write(rfbLatin1("1;x="))
    rfbRepeat(out, server, rfbFilled(64 * 1024, 'A'), size.toLong())
    out.write(rfbLatin1("\r\n \r\n0\r\n\r\n"))
}

// 짧은 청크 본문 뒤 1 바이트 청크를 64 KiB 덩이로 끝없이 — 전속력으로 쓰는 서버.
private fun rfbEndlessOneByteChunks(body: ByteArray) =
    RfbReply { out, server ->
        rfbChunkedHead(out, body)
        val one = rfbLatin1("1\r\n \r\n")
        val block = ByteArray(one.size * 10_922)
        for (i in 0 until 10_922) one.copyInto(block, i * one.size)
        while (!server.stop) out.write(block)
    }

// 응답 바이트를 그대로 쓴다.
private fun rfbRaw(response: String) = RfbReply { out, _ -> out.write(rfbLatin1(response)) }

// 1xx 중간 응답을 끝없이 — 각 응답에 표식을 싣는다.
private fun rfbEndlessInterim() =
    RfbReply { out, server ->
        val interim = rfbLatin1("HTTP/1.1 103 Early Hints\r\nLink: </$RFB_MARKER>; rel=preload\r\n\r\n")
        while (!server.stop) out.write(interim)
    }

// 상태 줄 대신 짧은 쓰레기 줄을 끝없이.
private fun rfbEndlessGarbage() =
    RfbReply { out, server ->
        val line = rfbLatin1("$RFB_MARKER\r\n")
        while (!server.stop) out.write(line)
    }

// 짧은 청크 본문 뒤 1 바이트 청크를 끝없이 — 크기 줄마다 0 을 zeros 개 채운다(「0000…01」, 값은 1).
private fun rfbEndlessPaddedChunks(
    body: ByteArray,
    zeros: Int,
) = RfbReply { out, server ->
    rfbChunkedHead(out, body)
    val chunk = ByteArray(zeros + 6)
    chunk.fill('0'.code.toByte(), 0, zeros)
    rfbLatin1("1\r\n \r\n").copyInto(chunk, zeros)
    while (!server.stop) out.write(chunk)
}

// 1 바이트 청크 count 개 — 본문 상한 안의 멀쩡한(그러나 잘게 나눈) 청크 본문.
private fun rfbTinyChunks(
    body: ByteArray,
    count: Int,
) = RfbReply { out, _ ->
    rfbChunkedHead(out, body)
    val one = rfbLatin1("1\r\n \r\n")
    for (i in 0 until count) out.write(one)
    out.write(rfbLatin1("0\r\n\r\n"))
}

// 원시 HTTP 서버 — 요청 머리와 Content-Length 본문을 읽고 응답을 쓴다. 쓴 바이트를 센다.
private class RfbRawServer(
    val reply: RfbReply,
) : AutoCloseable {
    val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val written = AtomicLong()

    @Volatile var stop = false

    init {
        Thread(::serve, "raw-framing-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    private fun serve() {
        while (!stop) {
            try {
                socket.accept().use { s ->
                    s.soTimeout = 10_000
                    val input = s.getInputStream()
                    input.readNBytes(readRequestHead(input))
                    val sink = s.getOutputStream()
                    val out =
                        object : OutputStream() {
                            override fun write(b: Int) {
                                sink.write(b)
                                written.incrementAndGet()
                            }

                            override fun write(
                                b: ByteArray,
                                off: Int,
                                len: Int,
                            ) {
                                sink.write(b, off, len)
                                written.addAndGet(len.toLong())
                            }
                        }
                    reply.write(out, this)
                    out.flush()
                    s.shutdownOutput()
                    while (input.read() >= 0) {
                        // 클라이언트가 닫을 때까지
                    }
                }
            } catch (clientLeft: IOException) {
                // 클라이언트가 떠났다 — 끝없는 응답의 정상 결말이다(닫힌 서버 소켓이면 while 이 끝낸다)
            }
        }
    }

    // 요청 머리를 읽고 Content-Length 를 돌려준다(없으면 0).
    private fun readRequestHead(input: InputStream): Int {
        val head = ByteArrayOutputStream()
        var last4 = 0
        while (true) {
            val b = input.read()
            if (b == -1) break
            head.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0d0a0d0a) break
        }
        for (line in head.toString(Charsets.ISO_8859_1).split("\r\n")) {
            if (line.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) return line.substring(15).trim().toInt()
        }
        return 0
    }

    override fun close() {
        stop = true
        socket.close()
    }
}

private fun rfbTokenRequest(port: Int): HTTPRequest =
    HTTPRequest(HTTPRequest.Method.POST, URI("http://127.0.0.1:$port/token").toURL()).apply {
        entityContentType = ContentType.APPLICATION_URLENCODED
        body = "grant_type=client_credentials"
        connectTimeout = 5_000
        readTimeout = 20_000
        followRedirects = false // AuthClient.applyTimeouts 와 같다
    }

private fun rfbCerts(port: Int): URL = URI("http://127.0.0.1:$port/certs").toURL()

// 레인 호출의 결과 — 던진 것(없으면 null)·호출 스레드의 할당·벽시계 시간.
private class RfbOutcome(
    val thrown: Throwable?,
    val allocated: Long,
    val millis: Long,
) {
    fun describe(): String =
        (if (thrown == null) "accepted" else "${thrown.javaClass.name}: ${thrown.message}") + " · allocated $allocated B · $millis ms"
}

private enum class RfbLane(
    val body: ByteArray,
    val cap: Long,
) {
    AUTH(RFB_TOKEN, RFB_CAP.toLong()) {
        override fun run(port: Int) {
            rfbTokenRequest(port).send(CappedResponseSender("token response"))
        }
    },
    JWKS(RFB_JWKS, 51_200L) {
        override fun run(port: Int) {
            NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(rfbCerts(port))
        }
    }, ;

    abstract fun run(port: Int)
}

private fun rfbAllocationCounter(): com.sun.management.ThreadMXBean {
    val bean = ManagementFactory.getThreadMXBean()
    assumeTrue(
        bean is com.sun.management.ThreadMXBean && bean.isThreadAllocatedMemorySupported && bean.isThreadAllocatedMemoryEnabled,
        "스레드 할당 계수기가 없는 JVM",
    )
    return bean as com.sun.management.ThreadMXBean
}

private fun rfbWarm(lane: RfbLane) {
    val body = String(lane.body, Charsets.UTF_8)
    RfbRawServer(rfbRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${lane.body.size}\r\n\r\n$body")).use {
        lane.run(it.port)
    }
}

// reply 를 내는 서버에 레인을 한 번 부르고 잰다 — 같은 레인을 작은 정상 응답으로 먼저 예열한다.
private fun rfbMeasure(
    lane: RfbLane,
    reply: RfbReply,
): RfbOutcome {
    rfbWarm(lane)
    val threads = rfbAllocationCounter()
    RfbRawServer(reply).use { server ->
        val before = threads.currentThreadAllocatedBytes
        val start = System.nanoTime()
        val thrown =
            try {
                lane.run(server.port)
                null
            } catch (t: Throwable) {
                t
            }
        return RfbOutcome(thrown, threads.currentThreadAllocatedBytes - before, (System.nanoTime() - start) / 1_000_000)
    }
}

private fun rfbPreemptively(block: () -> RfbOutcome): RfbOutcome = assertTimeoutPreemptively(Duration.ofSeconds(30), block)

// 거부의 계약 — IOException · 원인 사슬에 표식도 하위 운송의 타입도 없다.
private fun rfbExpectRejectedWithoutQuoting(
    label: String,
    thrown: Throwable?,
) {
    assertIs<IOException>(thrown, "$label: IOException 으로 거부해야 한다 — $thrown")
    val trace = thrown.stackTraceToString()
    assertFalse(RFB_MARKER in trace, "$label: 거부가 응답 바이트를 인용했다:\n$trace")
    generateSequence<Throwable>(thrown) { it.cause }.take(16).forEach { t ->
        assertFalse(t.javaClass.name.startsWith("org.apache.http."), "$label: 하위 운송의 예외 타입이 원인 사슬에 남았다 — ${t.javaClass.name}")
    }
}

internal class ResponseFramingBoundsTest {
    // ───────────── 트레일러 (jvm-chunked-trailers-unbounded) ─────────────

    @Test
    fun `auth - many trailer lines are rejected with a bounded allocation`() {
        val o = rfbMeasure(RfbLane.AUTH, rfbManyTrailers(RFB_TOKEN, 32L shl 20))
        println("[ResponseFramingBoundsTest] auth 32 MiB 트레일러 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 32 MiB 트레일러", o.thrown)
        assertTrue(o.allocated < RFB_FRAMING_BOUND, "auth 32 MiB 트레일러: ${o.describe()}")
    }

    @Test
    fun `auth - one huge trailer line is rejected with a bounded allocation`() {
        val o = rfbMeasure(RfbLane.AUTH, rfbOneTrailer(RFB_TOKEN, 1 shl 20))
        println("[ResponseFramingBoundsTest] auth 1 MiB 트레일러 한 줄 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 1 MiB 트레일러 한 줄", o.thrown)
        assertTrue(o.allocated < RFB_FRAMING_BOUND, "auth 1 MiB 트레일러 한 줄: ${o.describe()}")
    }

    @Test
    fun `jwks - many trailer lines are rejected`() {
        val o = rfbMeasure(RfbLane.JWKS, rfbManyTrailers(RFB_JWKS, 32L shl 20))
        println("[ResponseFramingBoundsTest] jwks 32 MiB 트레일러 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("jwks 32 MiB 트레일러", o.thrown)
    }

    @Test
    fun `jwks - one huge trailer line is rejected promptly`() {
        val o = rfbMeasure(RfbLane.JWKS, rfbOneTrailer(RFB_JWKS, 1 shl 20))
        println("[ResponseFramingBoundsTest] jwks 1 MiB 트레일러 한 줄 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("jwks 1 MiB 트레일러 한 줄", o.thrown)
        assertTrue(o.millis < 3_000, "jwks 1 MiB 트레일러 한 줄: ${o.describe()}")
    }

    // ───────────── 헤더 줄·청크 확장 (운송의 줄 한도) ─────────────

    @Test
    fun `auth - a huge header line is rejected with a bounded allocation`() {
        val o = rfbMeasure(RfbLane.AUTH, rfbOneHeaderLine(RFB_TOKEN, 16 shl 20))
        println("[ResponseFramingBoundsTest] auth 16 MiB 헤더 줄 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 16 MiB 헤더 줄", o.thrown)
        assertTrue(o.allocated < RFB_FRAMING_BOUND, "auth 16 MiB 헤더 줄: ${o.describe()}")
    }

    @Test
    fun `auth - a huge chunk extension is rejected with a bounded allocation`() {
        val o = rfbMeasure(RfbLane.AUTH, rfbChunkExtension(RFB_TOKEN, 16 shl 20))
        println("[ResponseFramingBoundsTest] auth 16 MiB 청크 확장 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 16 MiB 청크 확장", o.thrown)
        assertTrue(o.allocated < RFB_FRAMING_BOUND, "auth 16 MiB 청크 확장: ${o.describe()}")
    }

    // ───────────── 상한을 넘은 본문의 닫기 (close-drain-time-unbounded) ─────────────

    // 끝없는 1 바이트 청크 본문 — 상한에서 거부하고 곧바로 돌아온다(닫기가 나머지를 비우지 않는다). 닫기가 나머지를 비우면 끝없는
    // 본문에서 돌아오지 않는다 — 빌드를 붙잡지 않고 실패하게 시간을 건다.
    @Test
    fun `auth - an endless chunked body is refused promptly`() {
        val o = rfbPreemptively { rfbMeasure(RfbLane.AUTH, rfbEndlessOneByteChunks(RFB_TOKEN)) }
        println("[ResponseFramingBoundsTest] auth 끝없는 1 바이트 청크 → ${o.describe()}")
        assertIs<ResponseTooLargeException>(o.thrown, o.describe())
        assertTrue(o.millis < 5_000, "auth 끝없는 1 바이트 청크: ${o.describe()}")
        assertTrue(o.allocated < RFB_ENDLESS_BODY_BOUND, "auth 끝없는 1 바이트 청크: ${o.describe()}")
    }

    // JWKS 레인 — 51,200 바이트 상한에서 거부하고 곧바로 돌아온다.
    @Test
    fun `jwks - an endless chunked body is refused promptly`() {
        val o = rfbPreemptively { rfbMeasure(RfbLane.JWKS, rfbEndlessOneByteChunks(RFB_JWKS)) }
        println("[ResponseFramingBoundsTest] jwks 끝없는 1 바이트 청크 → ${o.describe()}")
        assertIs<IOException>(o.thrown, o.describe())
        assertEquals("Exceeded configured input limit of 51200 bytes", o.thrown.message)
        assertTrue(o.millis < 5_000, "jwks 끝없는 1 바이트 청크: ${o.describe()}")
    }

    // 크기 줄을 줄 한도까지 채운 1 바이트 청크(Java 의 Grok 레그 A 지적 — 재현: 청크 200,000 개에 1.6 GB 를 받아 할당하고 4.0 초, 그리고
    // 받아들였다). 본문을 읽는 동안 받은 틀이 본문 상한의 8 배를 넘으면 거부한다 — 두 레인 모두 곧바로, 할당이 묶인 채로.
    @Test
    fun `padded chunk-size lines are refused on the wire budget`() {
        for (lane in RfbLane.entries) {
            val o = rfbPreemptively { rfbMeasure(lane, rfbEndlessPaddedChunks(lane.body, 8000)) }
            println("[ResponseFramingBoundsTest] ${lane.name} 채운 크기 줄의 1 바이트 청크 → ${o.describe()}")
            assertIs<IOException>(o.thrown, o.describe())
            assertEquals("HTTP response body framing exceeds ${8 * lane.cap} bytes on the wire", o.thrown.message)
            assertTrue(o.millis < 5_000, "${lane.name}: ${o.describe()}")
            assertTrue(o.allocated < 8 * RFB_FRAMING_BOUND, "${lane.name}: ${o.describe()}")
        }
    }

    // 대조 — 상한 안의 본문을 1 바이트 청크로 잘게 나눠도(틀이 본문의 6 배) 두 레인 모두 받아들인다.
    @Test
    fun `control - tiny chunks under the cap are accepted`() {
        RfbRawServer(rfbTinyChunks(RFB_TOKEN, 100_000)).use { server ->
            val response = rfbTokenRequest(server.port).send(CappedResponseSender("token response"))
            assertEquals(200, response.statusCode)
            assertEquals(RFB_TOKEN.size + 100_000 + System.lineSeparator().length, response.body.length)
        }
        RfbRawServer(rfbTinyChunks(RFB_JWKS, 40_000)).use { server ->
            val r = NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(rfbCerts(server.port))
            assertEquals(RFB_JWKS.size + 40_000, r.content.length)
        }
    }

    // ───────────── 끝없는 머리 ─────────────

    // 1xx 중간 응답을 끝없이 보내는 서버 — 곧바로 IOException 으로 끝난다(시간·할당이 응답 수를 따르지 않는다).
    @Test
    fun `auth - endless interim responses are refused promptly`() {
        val o = rfbPreemptively { rfbMeasure(RfbLane.AUTH, rfbEndlessInterim()) }
        println("[ResponseFramingBoundsTest] auth 끝없는 1xx → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 끝없는 1xx", o.thrown)
        assertTrue(o.millis < 5_000, "auth 끝없는 1xx: ${o.describe()}")
    }

    // 상태 줄 대신 쓰레기 줄을 끝없이 보내는 서버 — 첫 줄에서 거부한다(JDK 처럼 「Invalid Http response」).
    @Test
    fun `auth - endless garbage before the status line is refused promptly`() {
        val o = rfbPreemptively { rfbMeasure(RfbLane.AUTH, rfbEndlessGarbage()) }
        println("[ResponseFramingBoundsTest] auth 끝없는 쓰레기 줄 → ${o.describe()}")
        rfbExpectRejectedWithoutQuoting("auth 끝없는 쓰레기 줄", o.thrown)
        assertTrue(o.millis < 5_000, "auth 끝없는 쓰레기 줄: ${o.describe()}")
    }

    // ───────────── 거부가 응답 바이트를 인용하지 않는다 ─────────────

    // 틀이 깨진 응답 — 청크 크기 줄·트레일러 줄·상태 줄·첫 줄에 표식. 각 레인이 IOException 으로 거부하고 표식을 싣지 않는다.
    @Test
    fun `malformed framing is rejected without quoting the response`() {
        val chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        for (lane in RfbLane.entries) {
            val body = String(lane.body, Charsets.UTF_8)
            val hex = Integer.toHexString(lane.body.size)
            val cases =
                listOf(
                    "청크 크기 줄" to "$chunked$hex\r\n$body\r\n$RFB_MARKER\r\nxx\r\n0\r\n\r\n",
                    "트레일러 줄" to "$chunked$hex\r\n$body\r\n0\r\n$RFB_MARKER\r\n\r\n",
                    "상태 줄" to "HTTP/1.1 abc $RFB_MARKER\r\nContent-Length: 2\r\n\r\n{}",
                    "첫 줄" to "$RFB_MARKER\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
                )
            for ((kind, response) in cases) {
                val o = rfbMeasure(lane, rfbRaw(response))
                println("[ResponseFramingBoundsTest] ${lane.name} $kind 표식 → ${o.describe()}")
                rfbExpectRejectedWithoutQuoting("${lane.name} $kind", o.thrown)
            }
        }
    }

    // 대조 — 같은 서버의 멀쩡한 청크 응답(트레일러 둘)은 두 레인 모두 받아들인다(위 거부가 서버 고장이 아님을 보인다).
    @Test
    fun `control - well-formed chunked responses with trailers are accepted`() {
        val trailers = "0\r\nX-Trail-A: one\r\nX-Trail-B: two\r\n\r\n"
        RfbRawServer { out, _ ->
            rfbChunkedHead(out, RFB_TOKEN)
            out.write(rfbLatin1(trailers))
        }.use { server ->
            assertEquals(200, rfbTokenRequest(server.port).send(CappedResponseSender("token response")).statusCode)
        }
        RfbRawServer { out, _ ->
            rfbChunkedHead(out, RFB_JWKS)
            out.write(rfbLatin1(trailers))
        }.use { server ->
            val r = NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(rfbCerts(server.port))
            assertEquals(String(RFB_JWKS, Charsets.UTF_8), r.content)
        }
    }
}
