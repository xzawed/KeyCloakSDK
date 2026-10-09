package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import io.github.xzawed.keycloak.TransportTestTls
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Timeout
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.lang.management.ManagementFactory
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.LockSupport
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

// admin 레인이 거부한 토큰 응답은 더 읽지 않는다 — 그 연결을 끊고 풀에 돌려주지 않는다(Java `AdminRejectedResponseCutTest` 동형 ·
// auth 레인과 같은 규칙: EOF 까지 읽은 본문만 연결을 돌려주고, 그 밖의 끝은 읽기 타임아웃을 0 으로 둔 채 끊는다).
//
// 수정 전(실측 2026-10-09, Windows · JDK 21.0.8 · 루프백): `TokenResponseGuard` 는 상한+1 바이트를 읽고 거부한 뒤 스트림을 닫았고,
// HttpCore 의 닫기는 나머지를 EOF 까지 비웠다 — 거부 자리 모두 서버가 64 MiB 본문을 끝까지 썼고, 1 바이트 청크면 할당이 비운 양을
// 따라 자랐고, 멈춘 서버 앞에서 거부가 읽기 타임아웃을 기다렸다. 비운 연결은 풀로 돌아가 다음 호출이 다시 썼다.
//
// 계약: (1) 거부 자리 모두 서버가 상한과 소켓 버퍼를 넘어 쓰지 못한다. (2) 멈춘 서버 앞의 거부는 읽기 타임아웃을 기다리지 않는다(평문 ·
// TLS 1.3). (3) 1 바이트 청크 본문의 할당은 상한 너머의 길이를 따라 자라지 않는다. (4) 끊긴 연결은 다시 쓰이지 않는다. 대조: EOF 까지
// 읽은 응답의 연결은 지금처럼 다시 쓰인다. 공개 API 와 로컬 루프백만 쓴다. ⚠️ admin 호출은 Dispatchers.IO 에서 돈다 — 할당은 모든
// 스레드의 합으로 잰다(JDK 21 API — 17 이면 그 단언을 건너뛴다).
private const val ARC_CAP = 1_048_576
private const val ARC_REALM = "r"
private const val ARC_TOKEN_PATH = "/realms/$ARC_REALM/protocol/openid-connect/token"
private const val ARC_USABLE = """{"access_token":"good","token_type":"Bearer","expires_in":300}"""
private val ARC_USER = """{"id":"x","username":"alice"}""".toByteArray()

// 거부되는 본문의 길이 — 수정 전에는 닫기가 이것을 끝까지 비웠다.
private const val ARC_HUGE = 64L shl 20

// 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼(리눅스 tcp_rmem 6 MiB · tcp_wmem 4 MiB)를 넉넉히 넘는 16 MiB.
private const val ARC_WRITTEN_BOUND = 16L shl 20

// 1 바이트 청크 본문이 길어질 때 더 써도 되는 할당 — 상한 너머는 읽지 않으므로 소음뿐이다.
private const val ARC_ALLOCATION_GROWTH_BOUND = 8L * ARC_CAP

private fun arcLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun arcHead(
    status: String,
    typed: Boolean,
    framing: String,
): ByteArray = arcLatin1("HTTP/1.1 $status\r\n" + (if (typed) "Content-Type: application/json\r\n" else "") + framing + "\r\n\r\n")

// 토큰 엔드포인트의 응답 하나 — 쓴 본문 바이트를 written 에 센다. 돌려주는 값은 연결을 이어 쓸지다.
private fun interface ArcReply {
    fun write(
        input: InputStream,
        out: OutputStream,
        written: AtomicLong,
    ): Boolean
}

private fun arcJson(body: String): ArcReply {
    val b = body.toByteArray()
    return ArcReply { _, out, written ->
        out.write(arcHead("200 OK", true, "Content-Length: ${b.size}"))
        out.write(b)
        out.flush()
        written.addAndGet(b.size.toLong())
        true
    }
}

// 공백 count 바이트를 64 KiB 씩 쓴다.
private fun arcSpaces(
    out: OutputStream,
    count: Long,
    written: AtomicLong,
) {
    val slab = ByteArray(64 * 1024) { ' '.code.toByte() }
    var left = count
    while (left > 0) {
        val k = minOf(left, slab.size.toLong()).toInt()
        out.write(slab, 0, k)
        written.addAndGet(k.toLong())
        left -= k
    }
}

// json 뒤를 JSON 공백으로 채운 total 바이트의 Content-Length 본문.
private fun arcPadded(
    status: String,
    typed: Boolean,
    json: String,
    total: Long,
): ArcReply =
    ArcReply { _, out, written ->
        out.write(arcHead(status, typed, "Content-Length: $total"))
        val h = json.toByteArray()
        out.write(h)
        written.addAndGet(h.size.toLong())
        arcSpaces(out, total - h.size, written)
        out.flush()
        true
    }

// 쓸 수 있는 토큰(청크 하나) 뒤에 1 바이트 청크(공백)를 이어 total 바이트를 채운 청크 본문.
private fun arcOneByteChunks(total: Long): ArcReply =
    ArcReply { _, out, written ->
        out.write(arcHead("200 OK", true, "Transfer-Encoding: chunked"))
        val h = ARC_USABLE.toByteArray()
        out.write(arcLatin1(Integer.toHexString(h.size) + "\r\n"))
        out.write(h)
        out.write(arcLatin1("\r\n"))
        written.addAndGet(h.size.toLong())
        val unit = arcLatin1("1\r\n \r\n")
        val slab = ByteArray(unit.size * 10_000)
        for (i in 0 until 10_000) System.arraycopy(unit, 0, slab, i * unit.size, unit.size)
        var left = total - h.size
        while (left > 0) {
            val n = minOf(left, 10_000L).toInt()
            out.write(slab, 0, n * unit.size)
            written.addAndGet(n.toLong())
            left -= n
        }
        out.write(arcLatin1("0\r\n\r\n"))
        out.flush()
        true
    }

// declared 바이트를 알리고 sent 바이트(쓸 수 있는 토큰 + 공백)만 보낸 뒤 멈춘다 — 20 초 동안 연결을 붙들고 **읽지도 않는다**. ⚠️ 읽으면
// TLS 1.3 에서 클라이언트의 close_notify 에 답해 닫게 되고, 그러면 JSSE 가 닫을 때 기다릴 바이트가 생겨 끊기 전에 읽기 타임아웃을 0 으로
// 두지 않아도 거부가 빨랐다(그 단계를 지운 변이가 살았다 — Java 실측).
private fun arcStalled(
    declared: Long,
    sent: Long,
): ArcReply =
    ArcReply { _, out, written ->
        out.write(arcHead("200 OK", true, "Content-Length: $declared"))
        val h = ARC_USABLE.toByteArray()
        out.write(h)
        arcSpaces(out, sent - h.size, written)
        out.flush()
        LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)) // 읽지 않고 붙든다(인터럽트면 일찍 깬다 — 시험이 끝난 뒤다)
        false
    }

// 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결 하나에 요청 여럿(keep-alive). 토큰 엔드포인트는 token 을, admin 사용자 조회는 사용자
// 하나를 낸다. 받아들인 연결 수 · 토큰 요청 수 · admin 요청 수 · 마지막 토큰 응답이 쓴 본문 바이트를 센다.
private class ArcRawServer(
    tls: SSLContext?,
) : AutoCloseable {
    val socket: ServerSocket =
        tls?.serverSocketFactory?.createServerSocket(0, 50, InetAddress.getLoopbackAddress())
            ?: ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val connections = AtomicInteger()
    val tokenHits = AtomicInteger()
    val adminHits = AtomicInteger()
    val written = AtomicLong()

    // 마지막 토큰 응답의 쓰기가 끝났거나(성공·실패) — 시험 스레드가 바꾸고 서버 스레드가 센다.
    val replied = AtomicReference(CountDownLatch(1))
    val token = AtomicReference(arcJson(ARC_USABLE))

    init {
        Thread(::serve, "admin-cut-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    fun reply(r: ArcReply) {
        token.set(r)
        written.set(0)
        replied.set(CountDownLatch(1))
        tokenHits.set(0)
        adminHits.set(0)
    }

    // 마지막 토큰 응답의 쓰기가 끝날 때까지(최대 30 초) — 끝나지 않으면 거짓.
    fun awaitReply(): Boolean = replied.get().await(30, TimeUnit.SECONDS)

    private fun serve() {
        while (!socket.isClosed) {
            val s =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            connections.incrementAndGet()
            Thread({ exchanges(s) }, "admin-cut-connection").apply { isDaemon = true }.start()
        }
    }

    private fun exchanges(s: Socket) {
        try {
            s.use {
                s.soTimeout = 20_000
                if (s is SSLSocket) s.startHandshake()
                val input = BufferedInputStream(s.getInputStream())
                val out = s.getOutputStream()
                var path = request(input)
                while (path != null) {
                    if (!answer(path, input, out)) return
                    path = request(input)
                }
            }
        } catch (clientLeft: IOException) {
            // 클라이언트가 끊었다 — 거부의 정상 결말이다
        }
    }

    private fun answer(
        path: String,
        input: InputStream,
        out: OutputStream,
    ): Boolean {
        if (path == ARC_TOKEN_PATH) {
            tokenHits.incrementAndGet()
            val done = replied.get()
            try {
                return token.get().write(input, out, written)
            } finally {
                done.countDown()
            }
        }
        if (path.startsWith("/admin/realms/$ARC_REALM/users")) {
            adminHits.incrementAndGet()
            out.write(arcHead("200 OK", true, "Content-Length: ${ARC_USER.size}"))
            out.write(ARC_USER)
        } else {
            out.write(arcLatin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
        }
        out.flush()
        return true
    }

    // 요청 하나(머리와 Content-Length 본문)를 읽고 그 경로를 돌려준다 — 연결이 끝났으면 null.
    private fun request(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        var last4 = 0
        var b = input.read()
        while (b != -1) {
            head.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0d0a0d0a) {
                val lines = head.toString(Charsets.ISO_8859_1).split("\r\n")
                for (line in lines) {
                    if (line.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) {
                        input.readNBytes(line.substring(15).trim().toInt())
                    }
                }
                return lines[0].split(" ")[1]
            }
            b = input.read()
        }
        return null
    }

    override fun close() {
        socket.close()
    }
}

private fun arcConfig(
    scheme: String,
    port: Int,
    readTimeout: Duration,
): KeycloakConfig =
    KeycloakConfig(
        serverUrl = "$scheme://127.0.0.1:$port",
        realm = ARC_REALM,
        clientId = "app",
        clientSecret = "s3cr3t".toCharArray(),
        connectTimeout = Duration.ofSeconds(5),
        readTimeout = readTimeout,
    )

private fun arcAdmin(
    server: ArcRawServer,
    readTimeout: Duration,
): AdminClient = AdminClient(arcConfig("http", server.port, readTimeout))

// TLS admin — 시험 인증서를 믿는 기본 SSLContext 로 엔진을 짓는다(RESTEasy 는 지을 때 그것을 읽는다). 끝에서 되돌린다.
private fun arcTlsAdmin(
    server: ArcRawServer,
    readTimeout: Duration,
): AdminClient {
    val saved = SSLContext.getDefault()
    SSLContext.setDefault(TransportTestTls.trustingContext)
    try {
        return AdminClient(arcConfig("https", server.port, readTimeout))
    } finally {
        SSLContext.setDefault(saved)
    }
}

// 이 JVM 의 모든 스레드가 지금까지 할당한 바이트 — JDK 21 API 라(시험 컴파일은 17 API 로 묶여 있다) 반사로 부른다.
private fun arcAllocatedAllThreads(): Long {
    val bean = ManagementFactory.getThreadMXBean()
    assumeTrue(bean is com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM")
    val total = runCatching { com.sun.management.ThreadMXBean::class.java.getMethod("getTotalThreadAllocatedBytes") }.getOrNull()
    assumeTrue(total != null, "JDK 21 미만 — 모든 스레드의 할당 합계를 못 잰다")
    val bytes = total!!.invoke(bean) as Long
    assumeTrue(bytes >= 0, "스레드 할당 계수가 꺼져 있다")
    return bytes
}

// admin 호출 하나 — 던진 것(없으면 null), 걸린 시간, 모든 스레드의 할당(measure 일 때만).
private class ArcOutcome(
    val thrown: Throwable?,
    val millis: Long,
    val allocated: Long,
) {
    fun describe(): String =
        (if (thrown == null) "accepted" else "${thrown.javaClass.simpleName}(${thrown.message})") +
            " · $millis ms · allocated $allocated B"
}

private fun arcCall(
    admin: AdminClient,
    measure: Boolean = false,
): ArcOutcome {
    val before = if (measure) arcAllocatedAllThreads() else 0L
    val start = System.nanoTime()
    val thrown =
        try {
            runBlocking { admin.users().get("x") }
            null
        } catch (t: Throwable) {
            t
        }
    val millis = (System.nanoTime() - start) / 1_000_000
    return ArcOutcome(thrown, millis, if (measure) arcAllocatedAllThreads() - before else 0L)
}

private fun arcExpectRejected(
    label: String,
    o: ArcOutcome,
    server: ArcRawServer,
    wrong: MutableList<String>,
) {
    if (o.thrown !is KeycloakTransportException || o.thrown.message != "Admin request failed") {
        wrong += "$label: KeycloakTransportException(Admin request failed) 가 아니다 — ${o.describe()}"
    }
    if (server.adminHits.get() != 0) wrong += "$label: admin 요청이 나갔다 — ${server.adminHits.get()}"
}

// 세 거부 자리 — 결합 직전 ReaderInterceptor · 응답 필터(미디어 타입 없는 2xx) · 오류 상태의 상한.
internal enum class ArcSite(
    val status: String,
    val typed: Boolean,
    val head: String,
) {
    TYPED_2XX("200 OK", true, ARC_USABLE),
    UNTYPED_2XX("201 Created", false, ARC_USABLE),
    ERROR_STATUS("400 Bad Request", true, """{"error":"invalid_grant"}"""),
}

internal class AdminRejectedResponseCutTest {
    // (1) 거부한 응답은 더 읽지 않는다 — 서버는 64 MiB 본문의 상한과 소켓 버퍼 너머를 쓰지 못한다. 수정 전: 세 자리 모두 끝까지.
    @ParameterizedTest
    @EnumSource(ArcSite::class)
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a rejected token response is not read on`(site: ArcSite) {
        val wrong = mutableListOf<String>()
        ArcRawServer(null).use { server ->
            server.reply(arcPadded(site.status, site.typed, site.head, ARC_HUGE))
            val o = arcAdmin(server, Duration.ofSeconds(20)).use { arcCall(it) }
            val finished = server.awaitReply()
            val row =
                "$site ${ARC_HUGE shr 20} MiB → ${o.describe()} · server wrote ${server.written.get()} B" +
                    if (finished) "" else " (still writing)"
            println("[AdminRejectedResponseCutTest] $row")
            arcExpectRejected(site.toString(), o, server, wrong)
            if (!finished || server.written.get() > ARC_WRITTEN_BOUND) {
                wrong += "$site: 거부한 뒤에도 본문을 읽었다 — $row (한도 $ARC_WRITTEN_BOUND)"
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // (2) 거부는 멈춘 서버를 기다리지 않는다 — 읽기 타임아웃 4 초의 절반 안에 끝나야 한다. 세 모양: 평문 상한+64 KiB 뒤 멈춤(닫기가
    // 나머지를 기다렸다) · 평문 정확히 상한+1 뒤 멈춤(JDK 의 readNBytes 가 다 채운 뒤 길이 0 으로 한 번 더 묻고 HttpCore 의 빈 버퍼는
    // 그것도 소켓에서 기다린다) · TLS 1.3 정확히 상한+1 뒤 멈춤(그 둘에 더해 JSSE 는 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼
    // 한 번 더 읽는다 — 끊기 전에 그 타임아웃을 0 으로 둔다).
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a rejection does not wait for a stalled server`() {
        val wrong = mutableListOf<String>()
        val readTimeout = Duration.ofSeconds(4)
        ArcRawServer(null).use { plainAfter64k ->
            ArcRawServer(null).use { plainAfterCap ->
                ArcRawServer(TransportTestTls.serverIp).use { tlsAfterCap ->
                    plainAfter64k.reply(arcStalled(ARC_CAP + (1L shl 20), ARC_CAP + 65_536L))
                    plainAfterCap.reply(arcStalled(ARC_CAP + (1L shl 20), ARC_CAP + 1L))
                    tlsAfterCap.reply(arcStalled(ARC_CAP + (1L shl 20), ARC_CAP + 1L))
                    val cases =
                        listOf(
                            "평문 · 상한+64 KiB 뒤 멈춤" to plainAfter64k,
                            "평문 · 상한+1 뒤 멈춤" to plainAfterCap,
                            "TLS 1.3 · 상한+1 뒤 멈춤" to tlsAfterCap,
                        )
                    for ((label, server) in cases) {
                        val admin = if (server === tlsAfterCap) arcTlsAdmin(server, readTimeout) else arcAdmin(server, readTimeout)
                        val o = admin.use { arcCall(it) }
                        println("[AdminRejectedResponseCutTest] $label → ${o.describe()} (읽기 타임아웃 4,000 ms)")
                        arcExpectRejected(label, o, server, wrong)
                        if (o.millis >= readTimeout.toMillis() / 2) wrong += "$label: 거부가 멈춘 서버를 기다렸다 — ${o.millis} ms"
                    }
                }
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // (3) 1 바이트 청크 본문 — 상한까지는 읽어야 하지만(판정) 그 너머의 길이가 할당을 키우지 않는다. 2 MiB 와 8 MiB 의 할당 차가 소음
    // 안이다(수정 전: 닫기가 청크 머리마다 문자열을 만들며 끝까지 비웠다).
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `one-byte chunks past the cap do not grow the allocation`() {
        ArcRawServer(null).use { server ->
            arcAdmin(server, Duration.ofSeconds(20)).use { arcCall(it) } // 예열 — 클래스 적재·JIT 를 잰 구간 밖으로
            val sizes = longArrayOf(2L shl 20, 8L shl 20)
            val allocated = LongArray(2)
            for (i in sizes.indices) {
                server.reply(arcOneByteChunks(sizes[i]))
                val o = arcAdmin(server, Duration.ofSeconds(20)).use { arcCall(it, measure = true) }
                server.awaitReply()
                println(
                    "[AdminRejectedResponseCutTest] 1 바이트 청크 ${sizes[i] shr 20} MiB → ${o.describe()} · " +
                        "server wrote ${server.written.get()} B",
                )
                assertIs<KeycloakTransportException>(o.thrown, o.describe())
                allocated[i] = o.allocated
            }
            val growth = allocated[1] - allocated[0]
            assertTrue(growth < ARC_ALLOCATION_GROWTH_BOUND, "본문이 6 MiB 더 길어 할당이 $growth B 더 늘었다 — 상한 너머를 읽었다")
        }
    }

    // (4) 끊긴 연결은 풀로 돌아가지 않는다 — 다음 호출은 새 연결을 맺어 성공한다. 수정 전: 비운 연결을 다시 썼다(연결 1).
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a cut connection is not returned to the pool`() {
        ArcRawServer(null).use { server ->
            arcAdmin(server, Duration.ofSeconds(20)).use { admin ->
                server.reply(arcPadded("200 OK", true, ARC_USABLE, 16L shl 20))
                val rejected = arcCall(admin)
                server.awaitReply()
                server.token.set(arcJson(ARC_USABLE))
                val next = arcCall(admin)
                val row = "거부 ${rejected.describe()} · 다음 ${next.describe()} · 연결 ${server.connections.get()}"
                println("[AdminRejectedResponseCutTest] $row")
                assertIs<KeycloakTransportException>(rejected.thrown, row)
                assertNull(next.thrown, row)
                assertEquals(2, server.connections.get(), "끊긴 연결을 다시 썼거나 연결이 더 열렸다 — $row")
            }
        }
    }

    // 대조 — EOF 까지 읽은 응답의 연결은 지금처럼 다시 쓰인다: 쓸 수 있는 토큰(부여 + 갱신 둘)과 admin 응답 셋이 연결 하나에서, 그리고
    // 상한 안에서 거부한 토큰(본문을 끝까지 읽었다)의 연결도 다음 호출이 다시 쓴다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `responses read to their end keep their connection`() {
        val refreshing =
            """{"access_token":"good","token_type":"Bearer","expires_in":1,"refresh_token":"rt","refresh_expires_in":300}"""
        ArcRawServer(null).use { server ->
            server.reply(arcJson(refreshing))
            arcAdmin(server, Duration.ofSeconds(20)).use { admin -> repeat(3) { assertNull(arcCall(admin).thrown) } }
            val used = "토큰 ${server.tokenHits.get()} · admin ${server.adminHits.get()} · 연결 ${server.connections.get()}"
            println("[AdminRejectedResponseCutTest] 쓸 수 있는 토큰(부여·갱신) → $used")
            assertEquals(3, server.tokenHits.get(), used) // expires_in 1 < TokenManager 최소 유효기간 30 초 — 호출마다 갱신한다
            assertEquals(3, server.adminHits.get(), used)
            assertEquals(1, server.connections.get(), "EOF 까지 읽은 응답의 연결을 다시 쓰지 않았다 — $used")
        }
        ArcRawServer(null).use { server ->
            arcAdmin(server, Duration.ofSeconds(20)).use { admin ->
                server.reply(arcJson("""{"access_token":12345,"token_type":"Bearer","expires_in":300}"""))
                val rejected = arcCall(admin)
                server.token.set(arcJson(ARC_USABLE))
                val next = arcCall(admin)
                val row = "상한 안의 거부 ${rejected.describe()} · 다음 ${next.describe()} · 연결 ${server.connections.get()}"
                println("[AdminRejectedResponseCutTest] $row")
                assertIs<KeycloakTransportException>(rejected.thrown, row)
                assertNull(next.thrown, row)
                assertEquals(1, server.connections.get(), "EOF 까지 읽고 거부한 응답의 연결을 다시 쓰지 않았다 — $row")
            }
        }
    }
}
