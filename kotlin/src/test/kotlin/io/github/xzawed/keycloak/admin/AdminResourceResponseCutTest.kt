package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.TOKEN_RESPONSE_MAX_BYTES
import io.github.xzawed.keycloak.TransportTestTls
import kotlinx.coroutines.runBlocking
import org.apache.http.client.methods.HttpGet
import org.junit.jupiter.api.Timeout
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import org.keycloak.representations.idm.UserRepresentation
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

// admin 자원 응답에서 SDK 가 읽지 않는 본문은 읽지 않는다 — 결과를 얻은 뒤 닫을 때 끝인지 한 번만 엿보고(소켓 기다림 1 ms), 끝이
// 아니면 연결을 끊는다. 오류 본문은 상한(`TOKEN_RESPONSE_MAX_BYTES`)까지만 쥔다. 토큰 응답 갈래는
// `AdminRejectedResponseCutTest` 가 맡는다.
//
// 수정 전(실측 2026-10-25, Windows · JDK 21.0.8 · 루프백 · main ee862c6): RESTEasy 는 결과를 얻은 응답을 닫고
// (`ClientResponse.close` → `releaseConnection(true)`) HttpCore 의 닫기(`ContentLengthInputStream`·
// `ChunkedInputStream.close`)가 나머지를 EOF 까지 비웠다 — 아래 2xx 다섯 자리 모두 서버가 64 MiB 를 끝까지 썼다. 미디어 타입이
// 있는 오류 상태는 `ClientInvocation.extractResult` 의 `bufferEntity` 가 본문을 통째로 담아 64 MiB 오류 본문에 호출 하나가
// JVM 전체로 약 477 MB 를 할당했고 그 본문 전부가 예외의 `keycloakError` 에 실렸다. 결과 뒤 멈춘 서버 앞에서는 닫기가 읽기
// 타임아웃을 기다린 끝에 쓸 수 있던 응답이 전송 실패가 됐다(평문 4,019–4,042 ms — 읽기 타임아웃 4 초 · TLS 1.3 은 닫기가 한 번 더
// 읽어 8,027–8,096 ms). Java `AdminResourceResponseCutTest` 의 이식이다 — Grok 레그가 옮기고 main 에서 RED 를 쟀고 PM 이 다시 쟀다(두 실행의
// 범위를 적는다).
//
// 계약: (1) SDK 가 읽지 않는 2xx 본문(create 의 201 · update·delete 의 2xx — 미디어 타입 유무) — 서버는 상한과 소켓 버퍼를 넘어
// 쓰지 못하고 호출은 그 결과를 돌려준다. (2) 오류 본문 — 상한까지만 쥐고(상태와 본문 머리는 그대로) 나머지는 읽지 않는다. (3) 결과 뒤
// 멈춘 서버 — 평문과 TLS 1.3 모두 읽기 타임아웃을 기다리지 않고 결과를 돌려준다. 대조: EOF 까지 읽은 응답의 연결은 지금처럼 다시
// 쓰이고, 엿보려고 낮춘 기다림은 다음 교환에 남지 않으며, 상한 안의 오류 본문은 통째로 실리고, 성공 본문에는 상한이 없다. 공개 API 와
// 로컬 루프백만 쓴다(길이 0 의 읽기 한 건만 엔진의 스트림을 직접 잰다).
// ⚠️ admin 호출은 Dispatchers.IO 에서 돈다 — 할당은 JVM-wide(모든 스레드의 합)로 잰다. 그 합계를 못 읽으면 할당 단언만 건너뛴다.
//
// ⚠️ 미디어 타입이 있는 JSON 성공 본문(get·search)은 이 계약 밖이다 — 결합(Jackson)이 값 뒤의 공백까지 EOF 로 읽는다
// (`FAIL_ON_TRAILING_TOKENS` — 실측 스택 `ObjectReader._verifyNoTrailingTokens`). 그 공백은 JSON 텍스트이고 성공 본문에는
// 상한을 걸지 않는다(`TOKEN_RESPONSE_MAX_BYTES` 의 설명) — 그 본문 중간에 멈춘 서버는 읽기마다의 타임아웃
// 몫이고, 흘리는 서버는 요청을 보낸 때부터의 마감 몫이다(`ResponseReadDeadlineTest`).
private const val ARR_REALM = "r"
private const val ARR_TOKEN_PATH = "/realms/$ARR_REALM/protocol/openid-connect/token"
private val ARR_TOKEN =
    """{"access_token":"good","token_type":"Bearer","expires_in":300}""".toByteArray(Charsets.UTF_8)
private const val ARR_USER = """{"id":"x","username":"alice"}"""
private const val ARR_NOT_FOUND = """{"error":"User not found"}"""
private const val ARR_TYPED = "Content-Type: application/json\r\n"
private const val ARR_LOCATION = "Location: http://127.0.0.1:1/admin/realms/$ARR_REALM/users/abc\r\n"

// 쓰지 않는 나머지의 길이 — 수정 전에는 닫기가 이것을 끝까지 비웠다.
private const val ARR_HUGE = 64L shl 20

// 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼(리눅스 tcp_rmem 6 MiB · tcp_wmem 4 MiB)를 넉넉히 넘는 16 MiB.
private const val ARR_WRITTEN_BOUND = 16L shl 20

// 64 MiB 오류 본문 호출 하나의 JVM-wide 할당 한도 — 근거(측정)는 `an error body is held only up to the cap`.
private const val ARR_ERROR_ALLOCATION_BOUND = 64L shl 20

// 멈춤 갈래 하나를 되풀이하는 횟수 — 근거는 `a server stalled after the result is not waited for`.
private const val ARR_STALL_REPEATS = 5

private fun arrLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

// admin 자원 응답 하나 — 쓴 본문 바이트를 written 에 센다. 돌려주는 값은 연결을 이어 쓸지다.
internal fun interface ArrReply {
    fun write(
        out: OutputStream,
        written: AtomicLong,
    ): Boolean
}

// admin 호출 하나. suspend 호출은 이 람다 안에서 runBlocking 으로 감싼다.
internal fun interface ArrCall {
    fun run(admin: AdminClient): Any?
}

// 공백 count 바이트를 64 KiB 씩 쓴다.
private fun arrSpaces(
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

// head 뒤를 공백으로 채운 total 바이트의 Content-Length 본문.
private fun arrPadded(
    status: String,
    headers: String,
    head: String,
    total: Long,
): ArrReply =
    ArrReply { out, written ->
        out.write(arrLatin1("HTTP/1.1 $status\r\n${headers}Content-Length: $total\r\n\r\n"))
        val h = head.toByteArray(Charsets.UTF_8)
        out.write(h)
        written.addAndGet(h.size.toLong())
        arrSpaces(out, total - h.size, written)
        out.flush()
        true
    }

private fun arrExact(
    status: String,
    headers: String,
    body: String,
): ArrReply = arrPadded(status, headers, body, body.toByteArray(Charsets.UTF_8).size.toLong())

// 공백 sent 바이트만 보내고(알린 길이는 1 MiB) 20 초 동안 읽지도 쓰지도 않고 붙든다.
private fun arrStalled(
    status: String,
    headers: String,
    sent: Long,
): ArrReply =
    ArrReply { out, written ->
        out.write(arrLatin1("HTTP/1.1 $status\r\n${headers}Content-Length: ${1L shl 20}\r\n\r\n"))
        arrSpaces(out, sent, written)
        out.flush()
        LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)) // 읽지 않고 붙든다(인터럽트면 일찍 깬다 — 시험이 끝난 뒤다)
        false
    }

// 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결 하나에 요청 여럿(keep-alive). 토큰 엔드포인트는 쓸 수 있는 토큰을, admin 사용자 경로는
// admin(「메서드 경로」 → 응답)이 고른 응답을 낸다. 받아들인 연결 수 · admin 요청 수 · 마지막 admin 응답이 쓴 본문 바이트를 센다.
private class ArrRawServer(
    tls: SSLContext?,
    private val admin: (String) -> ArrReply,
) : AutoCloseable {
    val socket: ServerSocket =
        tls?.serverSocketFactory?.createServerSocket(0, 50, InetAddress.getLoopbackAddress())
            ?: ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val connections = AtomicInteger()
    val adminHits = AtomicInteger()
    val written = AtomicLong()

    // 마지막 admin 응답의 쓰기가 끝났다(성공·실패) — 시험 스레드가 기다린다.
    val replied = AtomicReference(CountDownLatch(1))

    init {
        Thread(::serve, "admin-resource-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    // 마지막 admin 응답의 쓰기가 끝날 때까지(최대 30 초) — 끝나지 않으면 거짓.
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
            Thread({ exchanges(s) }, "admin-resource-connection").apply { isDaemon = true }.start()
        }
    }

    private fun exchanges(s: Socket) {
        try {
            s.use {
                s.soTimeout = 20_000
                if (s is SSLSocket) s.startHandshake()
                val input = BufferedInputStream(s.getInputStream())
                val out = s.getOutputStream()
                var requestLine = request(input)
                while (requestLine != null) {
                    if (!answer(requestLine, out)) return
                    requestLine = request(input)
                }
            }
        } catch (clientLeft: IOException) {
            // 클라이언트가 끊었다 — 끊기의 정상 결말이다
        }
    }

    private fun answer(
        request: String,
        out: OutputStream,
    ): Boolean {
        val path = request.substring(request.indexOf(' ') + 1)
        if (path == ARR_TOKEN_PATH) {
            out.write(arrLatin1("HTTP/1.1 200 OK\r\n$ARR_TYPED" + "Content-Length: ${ARR_TOKEN.size}\r\n\r\n"))
            out.write(ARR_TOKEN)
            out.flush()
            return true
        }
        if (path.startsWith("/admin/realms/$ARR_REALM/users")) {
            adminHits.incrementAndGet()
            written.set(0)
            val done = replied.get()
            try {
                return admin(request).write(out, written)
            } finally {
                done.countDown()
            }
        }
        out.write(arrLatin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
        out.flush()
        return true
    }

    // 요청 하나(머리와 Content-Length 본문)를 읽고 「메서드 경로」를 돌려준다 — 연결이 끝났으면 null.
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
                val first = lines[0].split(" ")
                return first[0] + " " + first[1]
            }
            b = input.read()
        }
        return null
    }

    override fun close() {
        socket.close()
    }
}

private fun arrConfig(
    scheme: String,
    port: Int,
    readTimeout: Duration,
): KeycloakConfig =
    KeycloakConfig(
        serverUrl = "$scheme://127.0.0.1:$port",
        realm = ARR_REALM,
        clientId = "app",
        clientSecret = "s3cr3t".toCharArray(),
        connectTimeout = Duration.ofSeconds(5),
        readTimeout = readTimeout,
    )

private fun arrAdmin(
    server: ArrRawServer,
    readTimeout: Duration,
): AdminClient = AdminClient(arrConfig("http", server.port, readTimeout))

// TLS admin — 시험 인증서를 믿는 기본 SSLContext 로 엔진을 짓는다(RESTEasy 는 지을 때 그것을 읽는다). 끝에서 되돌린다.
private fun arrTlsAdmin(
    server: ArrRawServer,
    readTimeout: Duration,
): AdminClient {
    val saved = SSLContext.getDefault()
    SSLContext.setDefault(TransportTestTls.trustingContext)
    try {
        return AdminClient(arrConfig("https", server.port, readTimeout))
    } finally {
        SSLContext.setDefault(saved)
    }
}

// 이 JVM 의 모든 스레드의 할당 합계를 읽는 함수 — admin 호출은 Dispatchers.IO 에서 돈다. JDK 21 API(getTotalThreadAllocatedBytes)라
// (시험 컴파일은 17 API 로 묶여 있다) 반사로 부르고, 없거나 꺼져 있으면 null 이다(그때는 할당 단언만 건너뛴다).
private fun arrTotalAllocation(): (() -> Long)? {
    val bean = ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean ?: return null
    val total =
        runCatching { com.sun.management.ThreadMXBean::class.java.getMethod("getTotalThreadAllocatedBytes") }.getOrNull()
            ?: return null
    if ((total.invoke(bean) as Long) < 0) return null
    return { total.invoke(bean) as Long }
}

// admin 호출 하나 — 돌려준 값, 던진 것(없으면 null), 걸린 시간, JVM-wide 할당(없으면 null — 그 단언만 건너뛴다).
private class ArrOutcome(
    val result: Any?,
    val thrown: Throwable?,
    val millis: Long,
    val allocated: Long?,
) {
    fun describe(): String {
        val what =
            if (thrown == null) {
                "returned $result"
            } else {
                "${thrown.javaClass.simpleName}(${thrown.message})"
            }
        val alloc = if (allocated == null) "JVM-wide allocated unavailable" else "JVM-wide allocated $allocated B"
        return "$what · $millis ms · $alloc"
    }
}

private fun arrCall(
    admin: AdminClient,
    call: ArrCall,
): ArrOutcome {
    val total = arrTotalAllocation()
    val before = total?.invoke()
    val start = System.nanoTime()
    var result: Any? = null
    var thrown: Throwable? = null
    try {
        result = call.run(admin)
    } catch (t: Throwable) {
        thrown = t
    }
    val millis = (System.nanoTime() - start) / 1_000_000
    val allocated = if (before == null || total == null) null else total() - before
    return ArrOutcome(result, thrown, millis, allocated)
}

private fun arrUser(): UserRepresentation = UserRepresentation().apply { username = "u" }

// SDK 가 읽지 않는 2xx 본문의 자리 다섯 — 응답과 호출과 그 결과.
internal enum class ArrSite(
    val reply: ArrReply,
    val call: ArrCall,
    val expected: Any?,
) {
    CREATE_UNTYPED(
        arrPadded("201 Created", ARR_LOCATION, "", ARR_HUGE),
        ArrCall { admin -> runBlocking { admin.users().create(arrUser()) } },
        "abc",
    ),
    CREATE_TYPED(
        arrPadded("201 Created", ARR_LOCATION + ARR_TYPED, "{}", ARR_HUGE),
        ArrCall { admin -> runBlocking { admin.users().create(arrUser()) } },
        "abc",
    ),
    UPDATE_TYPED(
        arrPadded("200 OK", ARR_TYPED, "{}", ARR_HUGE),
        ArrCall { admin ->
            runBlocking { admin.users().update("x", arrUser()) }
            "void"
        },
        "void",
    ),
    DELETE_TYPED(
        arrPadded("200 OK", ARR_TYPED, "{}", ARR_HUGE),
        ArrCall { admin ->
            runBlocking { admin.users().delete("x") }
            "void"
        },
        "void",
    ),
    DELETE_UNTYPED(
        arrPadded("200 OK", "", "", ARR_HUGE),
        ArrCall { admin ->
            runBlocking { admin.users().delete("x") }
            "void"
        },
        "void",
    ),
}

internal class AdminResourceResponseCutTest {
    // (1) SDK 가 읽지 않는 2xx 본문은 읽지 않는다 — 호출은 결과를 돌려주고 서버는 64 MiB 를 다 쓰지 못한다. 수정 전: 다섯 자리 모두 끝까지.
    @ParameterizedTest
    @EnumSource(ArrSite::class)
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `the remainder of a resource response is not read on`(site: ArrSite) {
        ArrRawServer(null) { _ -> site.reply }.use { server ->
            val o = arrAdmin(server, Duration.ofSeconds(20)).use { admin -> arrCall(admin, site.call) }
            val finished = server.awaitReply()
            val row =
                "$site → ${o.describe()} · server wrote ${server.written.get()} B" +
                    if (finished) "" else " (still writing)"
            println("[AdminResourceResponseCutTest] $row")
            assertNull(o.thrown, row)
            assertEquals(site.expected, o.result, row)
            assertTrue(
                finished && server.written.get() <= ARR_WRITTEN_BOUND,
                "쓰지 않는 나머지를 읽었다 — $row (한도 $ARR_WRITTEN_BOUND)",
            )
        }
    }

    // (2) 오류 본문은 상한까지만 쥔다 — 상태의 갈래(404·409)와 본문 머리는 그대로, `keycloakError` 는 상한을 넘지 않고, 서버는 64 MiB 를
    // 다 쓰지 못하고, 호출의 JVM-wide 할당은 `ARR_ERROR_ALLOCATION_BOUND` 안이다. 미디어 타입이 없는 오류 상태는 RESTEasy 가 버퍼에 담지
    // 않고 닫는다(비우기 갈래). 한도의 근거(2026-10-25 실측, Windows · JDK 21.0.8, JVM 전체): 미디어 타입이 있는 64 MiB 오류 본문의
    // 호출 하나가 수정 전 476.5–477.1 MB(서버 64 MiB 끝까지), 예열 뒤 수정본 11.3 · 10.8 MB(서버 1.6–1.8 MB) — 한도 64 MiB(67.1 MB)는
    // 수정 뒤보다 6 배, 수정 전보다 7 배 떨어진다. JVM-wide 합계를 못 읽으면 그 할당 단언만 건너뛴다.
    @Test
    @Timeout(value = 180, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `an error body is held only up to the cap`() {
        val wrong = mutableListOf<String>()

        data class Case(
            val label: String,
            val reply: ArrReply,
            val call: ArrCall,
            val type: Class<out KeycloakAdminException>,
            val head: String?,
        )
        // 예열 — 이 JVM 의 첫 admin 호출은 RESTEasy·Jackson 을 적재해 JVM 전체로 약 108 MB 를 더 할당했다(첫 줄 get 만 그만큼 컸다 — 수정 전
        // get 585.1 · delete 476.6 MB, 수정 뒤 119.4 · 11.0 MB). 그 몫은 오류 본문과 무관하니 잰 구간 밖에서 같은 길(404 typed)을 한 번 돈다.
        ArrRawServer(null) { _ -> arrExact("404 Not Found", ARR_TYPED, ARR_NOT_FOUND) }.use { server ->
            arrAdmin(server, Duration.ofSeconds(20)).use { admin -> arrCall(admin) { a -> runBlocking { a.users().get("x") } } }
        }
        val cases =
            listOf(
                Case(
                    "get 404 typed",
                    arrPadded("404 Not Found", ARR_TYPED, ARR_NOT_FOUND, ARR_HUGE),
                    ArrCall { admin -> runBlocking { admin.users().get("x") } },
                    KeycloakAdminException.NotFound::class.java,
                    ARR_NOT_FOUND,
                ),
                Case(
                    "get 404 untyped",
                    arrPadded("404 Not Found", "", ARR_NOT_FOUND, ARR_HUGE),
                    ArrCall { admin -> runBlocking { admin.users().get("x") } },
                    KeycloakAdminException.NotFound::class.java,
                    null,
                ),
                Case(
                    "delete 404 typed",
                    arrPadded("404 Not Found", ARR_TYPED, ARR_NOT_FOUND, ARR_HUGE),
                    ArrCall { admin ->
                        runBlocking { admin.users().delete("x") }
                        "void"
                    },
                    KeycloakAdminException.NotFound::class.java,
                    ARR_NOT_FOUND,
                ),
                Case(
                    "create 409 typed",
                    arrPadded("409 Conflict", ARR_TYPED, """{"errorMessage":"exists"}""", ARR_HUGE),
                    ArrCall { admin -> runBlocking { admin.users().create(arrUser()) } },
                    KeycloakAdminException.Conflict::class.java,
                    null,
                ),
            )
        for (c in cases) {
            ArrRawServer(null) { _ -> c.reply }.use { server ->
                val o = arrAdmin(server, Duration.ofSeconds(20)).use { admin -> arrCall(admin, c.call) }
                val finished = server.awaitReply()
                val error = (o.thrown as? KeycloakAdminException)?.keycloakError
                val errorLength = error?.length ?: 0
                val row =
                    "${c.label} → ${o.describe()} · keycloakError $errorLength chars · server wrote ${server.written.get()} B" +
                        if (finished) "" else " (still writing)"
                println("[AdminResourceResponseCutTest] $row")
                if (!c.type.isInstance(o.thrown)) wrong += "${c.label}: ${c.type.simpleName} 가 아니다 — $row"
                if (c.head != null && (error == null || !error.startsWith(c.head))) {
                    wrong += "${c.label}: 본문 머리를 잃었다 — $row"
                }
                if (errorLength > TOKEN_RESPONSE_MAX_BYTES) wrong += "${c.label}: 상한을 넘는 본문을 쥐었다 — $row"
                if (!finished || server.written.get() > ARR_WRITTEN_BOUND) {
                    wrong += "${c.label}: 오류 본문의 나머지를 읽었다 — $row"
                }
                val allocated = o.allocated
                if (allocated != null && allocated > ARR_ERROR_ALLOCATION_BOUND) {
                    wrong += "${c.label}: JVM-wide 할당이 한도를 넘었다 — $row"
                }
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // 대조 — 성공 본문에는 상한을 걸지 않는다(정당하게 크다): 상한을 넘는 사용자 목록도 통째로 결합된다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a success body past the cap is read whole`() {
        val users = TOKEN_RESPONSE_MAX_BYTES / ARR_USER.length + 1_000
        val body = (1..users).joinToString(",", "[", "]") { ARR_USER }
        ArrRawServer(null) { _ -> arrExact("200 OK", ARR_TYPED, body) }.use { server ->
            arrAdmin(server, Duration.ofSeconds(20)).use { admin ->
                val o = arrCall(admin) { a -> runBlocking { a.users().search("u", 0, users).size } }
                println("[AdminResourceResponseCutTest] 사용자 $users 명(${body.length} B) → ${o.describe()}")
                assertTrue(body.length > TOKEN_RESPONSE_MAX_BYTES)
                assertEquals<Any?>(users, o.result, o.describe())
            }
        }
    }

    // 대조 — 상한 안의 오류 본문은 통째로 실리고, 한 바이트 넘으면 상한까지 잘린다(경계).
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `an error body at the cap is carried whole`() {
        for (total in longArrayOf(TOKEN_RESPONSE_MAX_BYTES.toLong(), TOKEN_RESPONSE_MAX_BYTES + 1L)) {
            ArrRawServer(null) { _ -> arrPadded("404 Not Found", ARR_TYPED, ARR_NOT_FOUND, total) }.use { server ->
                arrAdmin(server, Duration.ofSeconds(20)).use { admin ->
                    val o = arrCall(admin) { a -> runBlocking { a.users().get("x") } }
                    val e = assertIs<KeycloakAdminException.NotFound>(o.thrown, o.describe())
                    val chars = e.keycloakError?.length ?: -1
                    println("[AdminResourceResponseCutTest] 404 $total B → keycloakError $chars chars")
                    assertEquals(TOKEN_RESPONSE_MAX_BYTES, chars, "$total B 본문 → $chars chars")
                    assertTrue(e.keycloakError?.startsWith(ARR_NOT_FOUND) == true)
                }
            }
        }
    }

    // (3) 결과 뒤 멈춘 서버를 기다리지 않는다 — create 201(1 MiB 를 알린 본문)의 머리만 받은 뒤, 읽기 타임아웃 4 초의 절반 안에 그 id 를
    // 돌려준다. 두 갈래: 본문 64 KiB 가 와 있다(엿보기가 바이트를 받는다) · 본문이 한 바이트도 없다(엿보기의 1 ms 가 다한다 — HttpClient 가
    // 그 연결을 닫고, TLS 1.3 이면 그 닫기가 한 번 더 읽는다). 평문과 TLS 1.3 각각, 갈래마다 `ARR_STALL_REPEATS` 번 — 끊긴 TLS 연결의
    // 닫기 실패(「Premature end of Content-Length delimited message body」)는 실행마다 났다 안 났다 했다(Java 실측 — 한 번 잰 시험은 통과하고
    // 같은 JVM 의 40 번 되풀이는 40 번 다 났다). 수정 전: 평문 4,019–4,042 ms 에 전송 실패 · TLS 1.3 은 닫기가 한 번 더 기다려
    // 8,027–8,096 ms.
    // 서버 TLS 1.3 은 `TransportTestTls.serverIp`, 클라이언트는 `TransportTestTls.trustingContext` 다.
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a server stalled after the result is not waited for`() {
        val wrong = mutableListOf<String>()
        val readTimeout = Duration.ofSeconds(4)

        data class Case(
            val label: String,
            val tls: SSLContext?,
            val sent: Long,
        )
        val cases =
            listOf(
                Case("평문 · 본문 64 KiB 뒤 멈춤", null, 65_536L),
                Case("평문 · 본문 없이 멈춤", null, 0L),
                Case("TLS 1.3 · 본문 64 KiB 뒤 멈춤", TransportTestTls.serverIp, 65_536L),
                Case("TLS 1.3 · 본문 없이 멈춤", TransportTestTls.serverIp, 0L),
            )
        for (c in cases) {
            for (r in 1..ARR_STALL_REPEATS) {
                ArrRawServer(c.tls) { _ -> arrStalled("201 Created", ARR_LOCATION, c.sent) }.use { server ->
                    val o =
                        (if (c.tls == null) arrAdmin(server, readTimeout) else arrTlsAdmin(server, readTimeout)).use { admin ->
                            arrCall(admin) { a -> runBlocking { a.users().create(arrUser()) } }
                        }
                    val row = "${c.label} #$r → ${o.describe()} (읽기 타임아웃 4,000 ms)"
                    println("[AdminResourceResponseCutTest] $row")
                    val before = wrong.size
                    if (o.thrown != null || o.result != "abc") wrong += "${c.label}: 결과를 돌려주지 않았다 — $row"
                    if (o.millis >= readTimeout.toMillis() / 2) wrong += "${c.label}: 멈춘 서버를 기다렸다 — $row"
                    if (wrong.size > before) break // 한 갈래의 첫 실패로 충분하다(수정 전에는 되풀이마다 4–8 초)
                }
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // 길이 0 의 읽기는 아래 스트림에 넘기지 않는다 — JDK 의 `readNBytes` 는 버퍼 한 칸을 채울 때마다 길이 0 으로 한 번 더 묻고 HttpCore 의
    // 빈 버퍼는 그것도 소켓에서 기다린다(`raw()` 로 응답 스트림을 받은 소비자가 닿는다). 아래 스트림이 길이 0 의 읽기를 받으면 실패하게 해
    // 잰다. 오류 본문의 상한은 한 바이트씩 읽는 길에서도 같다.
    @Test
    fun `a zero-length read does not reach the stream`() {
        val refusesZero =
            object : InputStream() {
                override fun read(): Int = 'x'.code

                override fun read(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ): Int {
                    if (len == 0) throw AssertionError("길이 0 의 읽기가 아래 스트림에 닿았다")
                    b[off] = 'x'.code.toByte()
                    return 1
                }
            }
        val exchange = AdminEngine.Exchange(HttpGet("http://127.0.0.1:1/"), 60_000)
        val settled = AdminEngine.Settled(refusesZero, exchange, Long.MAX_VALUE)
        assertEquals(0, settled.read(ByteArray(1), 0, 0))
        assertEquals(1, settled.read(ByteArray(1), 0, 1))
        // 상한은 한 바이트씩 읽어도 같다 — limit 바이트 뒤에는 아래 스트림을 읽지 않고 끝(-1)이다
        val capped = AdminEngine.Settled(refusesZero, exchange, 2)
        assertEquals('x'.code, capped.read())
        assertEquals('x'.code, capped.read())
        assertEquals(-1, capped.read())
    }

    // 오류 본문을 상한까지 받은 뒤 멈춘 서버도 기다리지 않는다 — RESTEasy 의 `bufferEntity` 는 상한에서 끝난 것처럼 보이는 스트림을 다
    // 읽고 `releaseConnection` 으로 닫으며, 그 닫기가 엿보기 뒤 끊는다. 404(미디어 타입 있음)가 상한만큼 쓰고 멈추면 읽기 타임아웃 4 초의
    // 절반 안에 NotFound 가 온다(상태가 전송 실패로 바뀌지 않는다). 평문과 TLS 1.3 각각. Grok 레그의 지적을 재는 시험이다(Java 와 같다).
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a server stalled after a capped error body is not waited for`() {
        val wrong = mutableListOf<String>()
        val readTimeout = Duration.ofSeconds(4)
        val declared = TOKEN_RESPONSE_MAX_BYTES + (1L shl 20)
        val capThenStall =
            ArrReply { out, written ->
                val h = ARR_NOT_FOUND.toByteArray(Charsets.UTF_8)
                out.write(arrLatin1("HTTP/1.1 404 Not Found\r\n${ARR_TYPED}Content-Length: $declared\r\n\r\n"))
                out.write(h)
                written.addAndGet(h.size.toLong())
                arrSpaces(out, (TOKEN_RESPONSE_MAX_BYTES - h.size).toLong(), written)
                out.flush()
                LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)) // 상한만큼 쓰고 읽지도 쓰지도 않고 붙든다
                false
            }
        for (tls in listOf<SSLContext?>(null, TransportTestTls.serverIp)) {
            val label = if (tls == null) "평문" else "TLS 1.3"
            ArrRawServer(tls) { _ -> capThenStall }.use { server ->
                val o =
                    (if (tls == null) arrAdmin(server, readTimeout) else arrTlsAdmin(server, readTimeout)).use { admin ->
                        arrCall(admin) { a -> runBlocking { a.users().get("x") } }
                    }
                val row = "$label · 404 상한 뒤 멈춤 → ${o.describe()} (읽기 타임아웃 4,000 ms)"
                println("[AdminResourceResponseCutTest] $row")
                val e = o.thrown as? KeycloakAdminException.NotFound
                if (e == null || e.keycloakError?.length != TOKEN_RESPONSE_MAX_BYTES) {
                    wrong += "$label: 상한까지의 본문을 실은 NotFound 가 아니다 — $row"
                }
                if (o.millis >= readTimeout.toMillis() / 2) wrong += "$label: 멈춘 서버를 기다렸다 — $row"
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
    }

    // `raw()` 로 오류 응답의 스트림을 읽어도 상한에서 끝난다 — 소비자의 readEntity(InputStream) 은 상한만큼 읽고 끝(-1)을 본다(예외가
    // 아니다 — 예외로 알리면 RESTEasy 의 bufferEntity 가 ProcessingException 을 내 파사드가 상태 갈래를 잃는다). Java 와 같다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a raw error stream ends at the cap`() {
        val total = TOKEN_RESPONSE_MAX_BYTES + 10L
        ArrRawServer(null) { _ -> arrPadded("500 Internal Server Error", ARR_TYPED, ARR_NOT_FOUND, total) }.use { server ->
            arrAdmin(server, Duration.ofSeconds(20)).use { admin ->
                val read =
                    admin.raw().realm(ARR_REALM).users().delete("x").use { r ->
                        assertEquals(500, r.status)
                        r.readEntity(InputStream::class.java).readAllBytes().size
                    }
                println("[AdminResourceResponseCutTest] raw() 500 $total B → 읽은 바이트 $read")
                assertEquals(TOKEN_RESPONSE_MAX_BYTES, read)
            }
        }
    }

    // 대조 — 끊긴 연결은 풀로 돌아가지 않는다: 나머지를 끊은 create 다음의 get 은 새 연결에서 성공한다(연결 2).
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a cut connection is not returned to the pool`() {
        ArrRawServer(null) { request ->
            if (request.startsWith("POST")) {
                arrPadded("201 Created", ARR_LOCATION, "", 16L shl 20)
            } else {
                arrExact("200 OK", ARR_TYPED, ARR_USER)
            }
        }.use { server ->
            arrAdmin(server, Duration.ofSeconds(20)).use { admin ->
                val cut = arrCall(admin) { a -> runBlocking { a.users().create(arrUser()) } }
                val next = arrCall(admin) { a -> runBlocking { a.users().get("x").username } }
                val row = "create ${cut.describe()} · get ${next.describe()} · 연결 ${server.connections.get()}"
                println("[AdminResourceResponseCutTest] $row")
                assertEquals<Any?>("abc", cut.result, row)
                assertEquals<Any?>("alice", next.result, row)
                assertEquals(2, server.connections.get(), "끊긴 연결을 다시 썼거나 연결이 더 열렸다 — $row")
            }
        }
    }

    // 대조 — EOF 까지 읽은 응답의 연결은 지금처럼 다시 쓰인다(create 201 빈 본문 · get · search · update 204 · delete 204 가 연결 하나에서).
    // 엿보려고 낮춘 기다림(1 ms)은 다음 교환에 남지 않는다 — 300 ms 늦게 답하는 get 도 같은 연결에서 성공한다(HttpClient 가 교환마다 읽기
    // 타임아웃을 다시 건다).
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `responses read to their end keep their connection`() {
        val late =
            ArrReply { out, written ->
                LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(300))
                arrExact("200 OK", ARR_TYPED, ARR_USER).write(out, written)
            }
        ArrRawServer(null) { request ->
            when {
                request.startsWith("POST") -> arrExact("201 Created", ARR_LOCATION, "")
                request.startsWith("PUT") || request.startsWith("DELETE") -> arrExact("204 No Content", "", "")
                request.contains("?") -> arrExact("200 OK", ARR_TYPED, "[$ARR_USER]")
                request.endsWith("/late") -> late
                else -> arrExact("200 OK", ARR_TYPED, ARR_USER)
            }
        }.use { server ->
            arrAdmin(server, Duration.ofSeconds(20)).use { admin ->
                val outcomes =
                    listOf(
                        arrCall(admin) { a -> runBlocking { a.users().create(arrUser()) } },
                        arrCall(admin) { a -> runBlocking { a.users().get("x").username } },
                        arrCall(admin) { a -> runBlocking { a.users().search("u", 0, 10).size } },
                        arrCall(admin) { a ->
                            runBlocking { a.users().update("x", arrUser()) }
                            "void"
                        },
                        arrCall(admin) { a ->
                            runBlocking { a.users().delete("x") }
                            "void"
                        },
                        arrCall(admin) { a -> runBlocking { a.users().get("late").username } },
                    )
                val row = StringBuilder()
                for (o in outcomes) row.append(o.describe()).append(" | ")
                row.append("admin ${server.adminHits.get()} · 연결 ${server.connections.get()}")
                println("[AdminResourceResponseCutTest] $row")
                val expected: List<Any?> = listOf("abc", "alice", 1, "void", "void", "alice")
                assertEquals(expected, outcomes.map { it.result }, row.toString())
                assertEquals(1, server.connections.get(), "EOF 까지 읽은 응답의 연결을 다시 쓰지 않았다 — $row")
            }
        }
    }
}
