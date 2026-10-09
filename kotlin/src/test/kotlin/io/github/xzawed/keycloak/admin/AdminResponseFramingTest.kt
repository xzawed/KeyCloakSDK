package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import kotlinx.coroutines.runBlocking
import org.apache.http.client.config.RequestConfig
import org.apache.http.client.methods.Configurable
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager
import org.jboss.resteasy.client.jaxrs.ResteasyClient
import org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.lang.management.ManagementFactory
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// admin 레인의 응답 **틀** — RESTEasy 가 쓰는 HttpCore 는 응답 머리 줄·헤더 수·트레일러에 한도가 없었다(기본 `MessageConstraints` -1).
// 짧은 청크 본문 뒤 4 KiB 트레일러 줄 32 MiB 를 토큰 응답이 달고 오면 토큰은 받아들여지고 호출 하나가 수십 MB 를 더 할당했다(등록부
// `jvm-chunked-trailers-unbounded`). 그리고 HttpCore 의 틀 오류는 응답 바이트를 메시지에 싣는다(「Bad chunk header: <줄>」 · 「Invalid
// header: <줄>」 — `jvm-admin-token-guard-residuals` (3)). Java `AdminResponseFramingTest` 의 이식이다.
//
// 계약: (1) [AdminClient.buildTimeoutClient] 의 엔진은 auth 레인과 같은 줄·헤더 수 한도를 건다 — 풀 크기(50)와 타임아웃은 그대로다.
// (2) 트레일러가 한도를 넘는 응답은 토큰이든 admin 자원이든 [KeycloakTransportException] 으로 실패하고 할당이 묶인다. (3) 틀이 깨진
// 응답의 거부는 그 줄을 인용하지 않는다. 네트워크는 로컬 루프백만 쓴다. ⚠️ admin 호출은 Dispatchers.IO 에서 돈다 — 할당은 모든 스레드의
// 합으로 잰다(JDK 21 은 끝난 스레드까지 · 17 은 살아 있는 스레드의 합).
private const val AF_CAP = 1_048_576
private const val AF_REALM = "r"
private const val AF_TOKEN_PATH = "/realms/$AF_REALM/protocol/openid-connect/token"
private const val AF_MARKER = "ZadminFrameMARKER0123"
private val AF_TOKEN = """{"access_token":"good","token_type":"Bearer","expires_in":300}""".toByteArray()
private val AF_USER = """{"id":"x","username":"alice"}""".toByteArray()

// 32 MiB 트레일러를 거부하는 admin 호출 하나가 써도 되는 할당(클라이언트 조립 밖) — 상한의 16 배.
private const val AF_FRAMING_BOUND = 16L * AF_CAP

private fun afLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun interface AfReply {
    fun write(out: OutputStream)
}

private fun afLengthDelimited(body: ByteArray) =
    AfReply { out ->
        out.write(afLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n"))
        out.write(body)
    }

private fun afChunkedHead(
    out: OutputStream,
    body: ByteArray,
) {
    out.write(
        afLatin1(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n${Integer.toHexString(body.size)}\r\n",
        ),
    )
    out.write(body)
    out.write(afLatin1("\r\n"))
}

// 짧은 청크 본문 뒤 4 KiB 트레일러 줄 32 MiB.
private fun afManyTrailers(body: ByteArray) =
    AfReply { out ->
        afChunkedHead(out, body)
        out.write(afLatin1("0\r\n"))
        val line = ByteArray(4096) { 'A'.code.toByte() }
        afLatin1("X-Trail-x: ").copyInto(line)
        line[4094] = '\r'.code.toByte()
        line[4095] = '\n'.code.toByte()
        repeat(8192) { out.write(line) }
        out.write(afLatin1("\r\n"))
    }

// 짧은 청크 본문 뒤 둘째 청크 크기 줄 자리에 표식.
private fun afBadChunkHeader(body: ByteArray) =
    AfReply { out ->
        afChunkedHead(out, body)
        out.write(afLatin1("$AF_MARKER\r\nxx\r\n0\r\n\r\n"))
    }

// 짧은 청크 본문 뒤 콜론 없는 트레일러 줄에 표식.
private fun afBadTrailer(body: ByteArray) =
    AfReply { out ->
        afChunkedHead(out, body)
        out.write(afLatin1("0\r\n$AF_MARKER\r\n\r\n"))
    }

// 응답 머리에 콜론 없는 헤더 줄(표식) — 그 뒤는 멀쩡한 Content-Length 본문.
private fun afColonlessHeader(body: ByteArray) =
    AfReply { out ->
        out.write(afLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n$AF_MARKER\r\nContent-Length: ${body.size}\r\n\r\n"))
        out.write(body)
    }

// 상태 코드 자리에 표식.
private fun afBadStatusLine(body: ByteArray) =
    AfReply { out ->
        out.write(afLatin1("HTTP/1.1 $AF_MARKER OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n"))
        out.write(body)
    }

// 미디어 타입 없는 2xx 청크 본문 뒤 둘째 청크 크기 줄 자리에 표식(등록부의 후보 — extractResult 의 finally close).
private fun afUntypedBadChunkHeader(body: ByteArray) =
    AfReply { out ->
        out.write(afLatin1("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n${Integer.toHexString(body.size)}\r\n"))
        out.write(body)
        out.write(afLatin1("\r\n$AF_MARKER\r\nxx\r\n0\r\n\r\n"))
    }

// 원시 HTTP 서버 — 토큰 엔드포인트와 admin 사용자 엔드포인트에 각자의 응답을 낸다. 연결마다 응답 하나 뒤 닫는다.
private class AfRawServer : AutoCloseable {
    val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val adminHits = AtomicInteger()
    val token = AtomicReference(afLengthDelimited(AF_TOKEN))
    val users = AtomicReference(afLengthDelimited(AF_USER))

    init {
        Thread(::serve, "raw-admin-framing-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    private fun serve() {
        while (!socket.isClosed) {
            val s =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            Thread({ answer(s) }, "raw-admin-framing-exchange").apply { isDaemon = true }.start()
        }
    }

    private fun answer(s: Socket) {
        try {
            s.use {
                s.soTimeout = 10_000
                val input = s.getInputStream()
                val head = ByteArrayOutputStream()
                var last4 = 0
                while (true) {
                    val b = input.read()
                    if (b == -1) break
                    head.write(b)
                    last4 = (last4 shl 8) or b
                    if (last4 == 0x0d0a0d0a) break
                }
                val lines = head.toString(Charsets.ISO_8859_1).split("\r\n")
                var contentLength = 0
                for (line in lines) {
                    if (line.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) {
                        contentLength = line.substring(15).trim().toInt()
                    }
                }
                input.readNBytes(contentLength)
                val path = lines[0].split(" ").getOrElse(1) { "" }
                val out = s.getOutputStream()
                when {
                    path == AF_TOKEN_PATH -> token.get().write(out)
                    path.startsWith("/admin/realms/$AF_REALM/users") -> {
                        adminHits.incrementAndGet()
                        users.get().write(out)
                    }
                    else -> out.write(afLatin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
                }
                out.flush()
                s.shutdownOutput()
                while (input.read() >= 0) {
                    // 클라이언트가 닫을 때까지
                }
            }
        } catch (clientLeft: IOException) {
            // 클라이언트가 끊었다 — 거부의 정상 결말이다
        }
    }

    override fun close() {
        socket.close()
    }
}

private fun afConfig(port: Int): KeycloakConfig =
    KeycloakConfig(
        "http://127.0.0.1:$port",
        AF_REALM,
        "app",
        "s3cr3t".toCharArray(),
        connectTimeout = Duration.ofSeconds(5),
        readTimeout = Duration.ofSeconds(20),
    )

// 이 JVM 의 모든 스레드가 할당한 바이트 — JDK 21 의 합계(끝난 스레드 포함)를 반사로 읽고(시험 컴파일은 17 API 로 묶여 있다), 없으면
// 살아 있는 스레드마다의 합이다.
private fun afAllocatedAllThreads(): Long {
    val bean = ManagementFactory.getThreadMXBean()
    assumeTrue(bean is com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM")
    val threads = bean as com.sun.management.ThreadMXBean
    assumeTrue(threads.isThreadAllocatedMemorySupported && threads.isThreadAllocatedMemoryEnabled, "스레드 할당 계수가 꺼져 있다")
    val total = runCatching { com.sun.management.ThreadMXBean::class.java.getMethod("getTotalThreadAllocatedBytes") }.getOrNull()
    if (total != null) return total.invoke(threads) as Long
    return threads.getThreadAllocatedBytes(threads.allThreadIds).filter { it > 0 }.sum()
}

// admin 호출 하나의 결과 — 던진 것(없으면 null)과 할당(클라이언트 조립은 잰 구간 밖).
private class AfOutcome(
    val thrown: Throwable?,
    val allocated: Long,
) {
    fun describe(): String =
        (if (thrown == null) "accepted" else "${thrown.javaClass.name}: ${thrown.message}") + " · allocated $allocated B"
}

private fun afCall(server: AfRawServer): AfOutcome =
    AdminClient(afConfig(server.port)).use { admin ->
        val before = afAllocatedAllThreads()
        val thrown =
            try {
                runBlocking { admin.users().get("x") }
                null
            } catch (t: Throwable) {
                t
            }
        AfOutcome(thrown, afAllocatedAllThreads() - before)
    }

internal class AdminResponseFramingTest {
    // (2) 토큰 응답의 트레일러가 한도를 넘으면 그 토큰으로 admin 요청을 보내지 않고 실패한다 — 할당이 묶인다.
    @Test
    fun `a token response with huge trailers is rejected before any admin request`() {
        AfRawServer().use { server ->
            afCall(server) // 예열 — 클래스 적재·JIT 를 잰 구간 밖으로
            server.adminHits.set(0)
            server.token.set(afManyTrailers(AF_TOKEN))
            val o = afCall(server)
            println("[AdminResponseFramingTest] 토큰 응답 32 MiB 트레일러 → ${o.describe()} · admin ${server.adminHits.get()}")
            assertIs<KeycloakTransportException>(o.thrown, o.describe())
            assertEquals(0, server.adminHits.get(), "한도를 넘는 토큰 응답으로 admin 요청이 나갔다")
            assertTrue(o.allocated < AF_FRAMING_BOUND, o.describe())
        }
    }

    // (2) admin 자원 응답도 같은 한도다 — 사용자 조회의 트레일러가 한도를 넘으면 전송 실패다.
    @Test
    fun `an admin response with huge trailers is rejected`() {
        AfRawServer().use { server ->
            afCall(server)
            server.users.set(afManyTrailers(AF_USER))
            val o = afCall(server)
            println("[AdminResponseFramingTest] 사용자 응답 32 MiB 트레일러 → ${o.describe()}")
            assertIs<KeycloakTransportException>(o.thrown, o.describe())
            assertTrue(o.allocated < AF_FRAMING_BOUND, o.describe())
        }
    }

    // (3) 틀이 깨진 응답 — 청크 크기 줄·트레일러 줄·콜론 없는 헤더 줄·상태 줄·미디어 타입 없는 청크 크기 줄에 표식. 거부가 어디서
    // 나든(토큰 응답 · admin 자원 응답) SDK 예외의 원인 사슬 전체가 표식을 싣지 않는다.
    @Test
    fun `malformed framing is rejected without quoting the response`() {
        val table = mutableListOf<String>()
        val wrong = mutableListOf<String>()
        val kinds =
            listOf<Pair<String, (ByteArray) -> AfReply>>(
                "청크 크기 줄" to ::afBadChunkHeader,
                "트레일러 줄" to ::afBadTrailer,
                "콜론 없는 헤더 줄" to ::afColonlessHeader,
                "상태 줄" to ::afBadStatusLine,
                "미디어 타입 없는 청크 크기 줄" to ::afUntypedBadChunkHeader,
            )
        AfRawServer().use { server ->
            for (where in listOf("토큰 응답", "사용자 응답")) {
                for ((kind, reply) in kinds) {
                    server.token.set(if (where == "토큰 응답") reply(AF_TOKEN) else afLengthDelimited(AF_TOKEN))
                    server.users.set(if (where == "사용자 응답") reply(AF_USER) else afLengthDelimited(AF_USER))
                    val o = afCall(server)
                    table += "$where $kind → ${o.describe()}"
                    val trace = o.thrown?.stackTraceToString().orEmpty()
                    if (AF_MARKER in trace) wrong += "$where $kind: 거부가 응답 바이트를 인용했다:\n$trace"
                }
            }
        }
        println("[AdminResponseFramingTest 틀 오류 인용]\n  " + table.joinToString("\n  "))
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // (1) 엔진 구성 — 줄 8,192 바이트 · 헤더 100 개 한도, 그리고 오늘의 풀 크기(50 · 경로당 50)와 타임아웃. ⚠️ 풀 크기는 빌더를 바꾸면
    // 조용히 10 으로 준다(.claude/rules/kotlin.md) — 그래서 여기서 잰다.
    @Test
    fun `the engine bounds the response head and keeps the pool and the timeouts`() {
        val client = AdminClient.buildTimeoutClient(afConfig(1))
        try {
            @Suppress("DEPRECATION")
            val engine = (client as ResteasyClient).httpEngine() as ApacheHttpClient43Engine
            val http = engine.httpClient
            val cmField = http.javaClass.getDeclaredField("connManager")
            cmField.isAccessible = true
            val pool = cmField.get(http) as PoolingHttpClientConnectionManager
            assertEquals(50, pool.maxTotal, "풀 크기")
            assertEquals(50, pool.defaultMaxPerRoute, "경로당 풀 크기")
            val config = assertNotNull(pool.defaultConnectionConfig, "연결 구성이 없다 — 응답 머리 한도가 없다(HttpCore 기본 -1)")
            assertEquals(8192, config.messageConstraints.maxLineLength, "줄 한도")
            assertEquals(100, config.messageConstraints.maxHeaderCount, "헤더 수 한도")
            val rc: RequestConfig = (http as Configurable).config
            assertEquals(5_000, rc.connectTimeout, "연결 타임아웃")
            assertEquals(20_000, rc.socketTimeout, "읽기 타임아웃")
        } finally {
            client.close()
        }
    }
}
