package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import io.github.xzawed.keycloak.RESPONSE_LATE
import io.github.xzawed.keycloak.RedactedCause
import io.github.xzawed.keycloak.TOKEN_RESPONSE_MAX_BYTES
import io.github.xzawed.keycloak.TransportTestTls
import kotlinx.coroutines.runBlocking
import org.apache.http.client.methods.HttpGet
import org.apache.http.protocol.HttpCoreContext
import org.junit.jupiter.api.Timeout
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// admin 레인이 스스로 읽는 응답(자체 토큰 부여 · 자원)은 요청을 보낸 때부터 읽기 타임아웃 안에 다 읽는다(등록부
// `response-read-deadline-divergent`, 판정 2026-10-29). Java `admin.ResponseReadDeadlineTest` 의 이식이다. 공개 API 와 로컬 루프백만 쓴다.
//
// 왜: 읽기 타임아웃은 읽기 하나를 묶을 뿐이라, 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 응답 하나가 흘린 바이트마다 간격 하나씩
// 걸렸다. 수정 전 실측은 이 시험을 수정 전 코드에 돌려 잰 것이다(커밋 메시지) — 흘리기 두 칸이 7 초 넘게 걸려 받아들여졌다. 자원의 성공
// 본문에는 크기 상한이 없으므로(사용자 목록은 정당하게 크다) 그 본문도 이제 읽기 타임아웃 안에 다 와야 한다.
//
// 계약: 흘리기 — 읽기 타임아웃 1 초 · 마지막 10 바이트를 0.7 초마다 — 는 3 초 안에 KeycloakTransportException 이다 — 같은 레인의 읽기
// 타임아웃(멈춤)과 같은 메시지 · 같은 원인 사슬(끝에 SocketTimeoutException) · 응답 바이트를 인용하지 않는다. 경계 = 마감 1 초 + 읽기 하나
// 1 초 + 여유 1 초(auth 의 같은 이름 시험과 같은 셈). 대조: 멈춤(머리와 몇 바이트 뒤 침묵)은 지금처럼 읽기 타임아웃에 실패하고, 상한 바로
// 아래 본문을 네 조각으로 나눠 보내는 건강한 응답은 받아들여진다.
//
// (2) 응답의 틀(머리 블록 · 청크 크기 줄 · 트레일러)과 TLS 레코드를 흘려도 같은 마감에 실패한다 — 엔진의 엔티티 스트림(`AdminEngine.Settled`)은
// 읽기 하나의 앞뒤만 보므로, 마감은 그 교환의 소켓 읽기마다(TLS 면 JSSE 아래의 평문 소켓) 본다(`AdminSockets`). 수정 전 측정은 이 시험을 수정
// 전 코드에 돌려 잰 것이다(커밋 메시지).
internal class ResponseReadDeadlineTest {
    /** 응답의 한 조각 — 쓰기 전에 [delayMillis] 를 쉰다(틀 열거 [Framing] 이 돌려주므로 감추지 않는다). */
    class Piece(
        val delayMillis: Long,
        val bytes: ByteArray,
    )

    /** 레인 — 응답의 모양을 바꾸는 경로와 그 본문. 호출은 둘 다 `users().get("x")` 다(첫 호출이 토큰을 부여받는다). */
    enum class Lane(
        val path: String,
    ) {
        /** admin 자체 토큰 부여 — 내장 TokenManager 의 응답을 토큰 응답 가드가 상한까지 읽는다. */
        TOKEN(TOKEN_PATH),

        /** 자원의 성공 본문 — 결합(Jackson)이 엔진의 스트림으로 읽는다. 크기 상한이 없는 자리다. */
        RESOURCE(USER_PATH),
    }

    /**
     * 원시 HTTP/1.1 서버 — 연결 하나에 요청 여럿(keep-alive: 토큰 부여 뒤 admin 요청이 같은 연결로 온다). 요청마다 [reply](경로 → 조각)가
     * 고른 조각을 차례로 쓴다(조각마다 쉬고 쓴다).
     */
    private class PacedServer(
        tls: SSLContext? = null,
        private val reply: (String) -> List<Piece>,
    ) : AutoCloseable {
        val socket: ServerSocket =
            tls?.serverSocketFactory?.createServerSocket(0, 50, InetAddress.getLoopbackAddress())
                ?: ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        /** [beforeLastPath] 의 응답의 마지막 조각을 쓰기 직전에 부른다(TLS 중계가 거기서부터 흘린다). */
        val beforeLast = AtomicReference<Runnable?>()

        @Volatile
        var beforeLastPath: String? = null

        init {
            Thread(::serve, "admin-paced-server").apply { isDaemon = true }.start()
        }

        val port: Int get() = socket.localPort

        val url: String get() = "http://127.0.0.1:$port"

        private fun serve() {
            while (!socket.isClosed) {
                val s =
                    try {
                        socket.accept()
                    } catch (closed: IOException) {
                        return
                    }
                Thread({ exchanges(s) }, "admin-paced-connection").apply { isDaemon = true }.start()
            }
        }

        private fun exchanges(s: Socket) {
            try {
                s.use {
                    s.soTimeout = HOLD_MILLIS.toInt()
                    if (s is SSLSocket) s.startHandshake()
                    val input = s.getInputStream()
                    val out = s.getOutputStream()
                    while (true) {
                        val path = readRequest(input) ?: break
                        val pieces = reply(path)
                        for ((i, piece) in pieces.withIndex()) {
                            if (piece.delayMillis > 0) Thread.sleep(piece.delayMillis)
                            val last = beforeLast.get()
                            if (i == pieces.size - 1 && last != null && path == beforeLastPath) last.run()
                            out.write(piece.bytes)
                            out.flush()
                        }
                    }
                }
            } catch (clientLeft: IOException) {
                // 클라이언트가 끊었다 — 마감 뒤의 정상 결말이다
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        override fun close() {
            socket.close()
        }
    }

    /**
     * TLS 앞의 TCP 중계 — 서버의 바이트를 곧바로 넘기다가 [trickle] 뒤로는 한 바이트씩 [GAP_MILLIS] 마다 넘긴다. 서버는 마지막 조각(TLS 레코드
     * 하나)을 쓰기 직전에 그것을 부른다 — 그 앞의 레코드는 300 ms 전에 이미 넘어갔다(Java 의 같은 이름 중계와 같다).
     */
    private class TrickleRelay(
        private val target: Int,
    ) : AutoCloseable {
        val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        @Volatile
        private var trickling = false

        init {
            Thread(::serve, "admin-trickle-relay").apply { isDaemon = true }.start()
        }

        val port: Int get() = socket.localPort

        fun trickle() {
            trickling = true
        }

        private fun serve() {
            while (!socket.isClosed) {
                try {
                    val client = socket.accept()
                    val server = Socket(InetAddress.getLoopbackAddress(), target)
                    pump(client, server, false)
                    pump(server, client, true)
                } catch (closed: IOException) {
                    return
                }
            }
        }

        private fun pump(
            from: Socket,
            to: Socket,
            paced: Boolean,
        ) {
            Thread({
                try {
                    from.use {
                        to.use {
                            val input = from.getInputStream()
                            val out = to.getOutputStream()
                            val buffer = ByteArray(16 * 1024)
                            var first = true
                            while (true) {
                                val n = input.read(buffer)
                                if (n <= 0) break
                                if (!paced || !trickling) {
                                    out.write(buffer, 0, n)
                                    out.flush()
                                    continue
                                }
                                for (i in 0 until n) {
                                    // 첫 바이트는 곧바로 — 그 앞의 침묵(서버의 300 ms)에 간격을 더하면 읽기 타임아웃이 먼저 터진다
                                    if (!first) Thread.sleep(GAP_MILLIS)
                                    first = false
                                    out.write(buffer[i].toInt())
                                    out.flush()
                                }
                            }
                        }
                    }
                } catch (gone: IOException) {
                    // 한쪽이 닫았다 — 중계도 끝난다
                } catch (interrupted: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }, "admin-trickle-relay-pump").apply { isDaemon = true }.start()
        }

        override fun close() {
            socket.close()
        }
    }

    /** 응답의 틀 중 흘리는 자리 — 흘리는 바이트는 모두 [TRICKLED] 개다(Java 의 같은 이름 시험과 같은 모양). */
    enum class Framing {
        /** 머리 블록 — 헤더 하나의 값 열 바이트. */
        HEAD {
            override fun pieces(body: ByteArray): List<Piece> =
                listOf(Piece(0, latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Pace: "))) +
                    trickled(latin1("0123456789")) +
                    Piece(0, concat(latin1("\r\nContent-Length: ${body.size}\r\n\r\n"), body))
        },

        /** 마지막 청크의 크기 줄(확장 포함) 열 바이트. */
        CHUNK_SIZE_LINE {
            override fun pieces(body: ByteArray): List<Piece> =
                listOf(
                    Piece(
                        0,
                        concat(CHUNKED_HEAD, latin1(Integer.toHexString(body.size - 1) + "\r\n"), body.copyOf(body.size - 1), latin1("\r\n")),
                    ),
                ) +
                    trickled(latin1("1;a=bcde\r\n")) +
                    Piece(0, concat(byteArrayOf(body[body.size - 1]), latin1("\r\n0\r\n\r\n")))
        },

        /** 마지막 청크 뒤 트레일러 한 줄 열 바이트. */
        TRAILER {
            override fun pieces(body: ByteArray): List<Piece> =
                listOf(Piece(0, concat(CHUNKED_HEAD, latin1(Integer.toHexString(body.size) + "\r\n"), body, latin1("\r\n0\r\n")))) +
                    trickled(latin1("X-T: 012\r\n")) +
                    Piece(0, latin1("\r\n"))
        },
        ;

        abstract fun pieces(body: ByteArray): List<Piece>

        /** 대조 — 같은 자리(흘리기 직전)에서 멈춘다: 그 자리의 읽기 타임아웃이 내는 실패와 견준다(머리의 실패는 본문의 것과 사슬이 다르다). */
        fun stalled(body: ByteArray): List<Piece> = listOf(pieces(body)[0], Piece(HOLD_MILLIS, ByteArray(0)))
    }

    /** 호출 하나 — 돌려준 값, 던진 것(없으면 null), 걸린 시간. */
    private class Outcome(
        val result: Any?,
        val thrown: Throwable?,
        val millis: Long,
    ) {
        fun describe(): String =
            (if (thrown == null) "accepted $result" else "${thrown.javaClass.name}: ${thrown.message}") + " · $millis ms"
    }

    private fun config(url: String): KeycloakConfig =
        KeycloakConfig(
            serverUrl = url,
            realm = "r",
            clientId = "app",
            clientSecret = "s3cr3t".toCharArray(),
            connectTimeout = Duration.ofSeconds(5),
            readTimeout = Duration.ofMillis(READ_TIMEOUT_MILLIS.toLong()),
        )

    private fun bodyOf(lane: Lane): ByteArray = if (lane == Lane.TOKEN) TOKEN_BODY else USER_BODY

    /** [lane] 의 응답만 [pieces] 로 내는 서버에 admin 호출 하나 — 다른 경로는 곧바로 온전히 답한다. */
    private fun run(
        lane: Lane,
        pieces: List<Piece>,
    ): Outcome =
        PacedServer { path ->
            when (path) {
                lane.path -> pieces
                TOKEN_PATH -> whole(TOKEN_BODY)
                USER_PATH -> whole(USER_BODY)
                else -> listOf(Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")))
            }
        }.use { server ->
            AdminClient(config(server.url)).use { admin ->
                val start = System.nanoTime()
                var result: Any? = null
                var thrown: Throwable? = null
                try {
                    result = runBlocking { admin.users().get("x").id }
                } catch (t: Throwable) {
                    thrown = t
                }
                Outcome(result, thrown, (System.nanoTime() - start) / 1_000_000)
            }
        }

    /**
     * [lane] 의 응답만 TLS 레코드 둘([twoRecords])로 내는 TLS 서버를 중계 너머에 두고 admin 호출 하나 — 중계는 그 응답의 마지막 레코드를 흘린다.
     * 엔진은 시험 인증서를 믿는 기본 SSLContext 로 짓는다(RESTEasy 와 이 레인의 풀은 지을 때 그것을 읽는다) — 지은 뒤 되돌린다.
     */
    private fun runTls(lane: Lane): Outcome =
        PacedServer(TransportTestTls.serverIp) { path ->
            when (path) {
                lane.path -> twoRecords(bodyOf(lane))
                TOKEN_PATH -> whole(TOKEN_BODY)
                USER_PATH -> whole(USER_BODY)
                else -> listOf(Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")))
            }
        }.use { server ->
            TrickleRelay(server.port).use { relay ->
                server.beforeLastPath = lane.path
                server.beforeLast.set(Runnable { relay.trickle() })
                val saved = SSLContext.getDefault()
                SSLContext.setDefault(TransportTestTls.trustingContext)
                val built =
                    try {
                        AdminClient(config("https://127.0.0.1:${relay.port}"))
                    } finally {
                        SSLContext.setDefault(saved)
                    }
                built.use { admin ->
                    val start = System.nanoTime()
                    var result: Any? = null
                    var thrown: Throwable? = null
                    try {
                        result = runBlocking { admin.users().get("x").id }
                    } catch (t: Throwable) {
                        thrown = t
                    }
                    Outcome(result, thrown, (System.nanoTime() - start) / 1_000_000)
                }
            }
        }

    /**
     * 마감의 판정 — 같은 레인의 읽기 타임아웃(멈춤 — 실패가 나는 자리가 같아야 사슬이 같다)과 같은 실패여야 한다: 같은 타입 · 같은 메시지 · 같은
     * 원인 사슬(끝에 [SocketTimeoutException]) · [BOUND_MILLIS] 안 · 응답 바이트를 인용하지 않는다.
     */
    private fun expectDeadline(
        label: String,
        lane: Lane,
        o: Outcome,
        stalled: List<Piece> = stalledBody(bodyOf(lane)),
    ) {
        val stall = run(lane, stalled)
        println("[admin.ResponseReadDeadlineTest] $label → ${o.describe()} (멈춤 대조 ${stall.describe()})")
        val thrown = assertNotNull(o.thrown, "$label: 마감 뒤에도 오는 응답을 받아들였다 — ${o.describe()}")
        assertIs<KeycloakTransportException>(thrown, "$label: 전송 실패여야 한다 — ${trace(thrown)}")
        assertTrue(o.millis < BOUND_MILLIS, "$label: $BOUND_MILLIS ms 안에 실패해야 한다 — ${o.describe()}")
        val stalledThrown = assertNotNull(stall.thrown, "$label: 대조(멈춤)가 실패하지 않았다 — ${stall.describe()}")
        assertEquals(stalledThrown.message, thrown.message, "$label: 읽기 타임아웃과 같은 메시지여야 한다")
        assertEquals(chain(stalledThrown), chain(thrown), "$label: 읽기 타임아웃과 같은 원인 사슬이어야 한다 — ${trace(thrown)}")
        assertTrue(SocketTimeoutException::class.java.name in chain(thrown), "$label: ${chain(thrown)} — ${trace(thrown)}")
        assertFalse(trace(thrown).contains(MARKER), "$label: 실패가 응답 바이트를 인용했다 — ${trace(thrown)}")
    }

    private fun trace(t: Throwable): String {
        val out = StringWriter()
        t.printStackTrace(PrintWriter(out, true))
        return out.toString()
    }

    /** 원인 사슬의 타입 이름 — 응답을 인용할 수 있는 사슬은 SDK 가 [RedactedCause] 로 갈아 끼운다(그 사본은 원래 타입의 이름을 쥔다). */
    private fun chain(thrown: Throwable): List<String> =
        generateSequence(thrown) { it.cause }.map { if (it is RedactedCause) it.originalType else it.javaClass.name }.toList()

    /**
     * (1) 응답을 흘리는 서버 — 마감에 실패한다, 같은 레인의 읽기 타임아웃(멈춤)과 같은 실패로: 같은 타입 · 같은 메시지 · 같은 원인 사슬(끝에
     * [SocketTimeoutException]). 수정 전: 두 레인 모두 7 초 넘게 걸려 받아들였다.
     */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a trickled response fails at the deadline`(lane: Lane) {
        expectDeadline("admin $lane 흘리기", lane, run(lane, trickledBody(bodyOf(lane))))
    }

    /**
     * (2) 응답의 틀을 흘리는 서버 — 본문 앞(머리)이나 본문 읽기 하나 **안**(청크 크기 줄 · 트레일러)이어도 마감에 실패한다. 두 레인 모두. 대조는 같은
     * 자리(흘리기 직전)에서 멈춘 응답이다. 수정 전 측정은 커밋 메시지.
     */
    @ParameterizedTest
    @EnumSource(Framing::class)
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `trickled framing fails at the deadline`(framing: Framing) {
        for (lane in Lane.entries) {
            val body = bodyOf(lane)
            expectDeadline("admin $lane 틀 $framing", lane, run(lane, framing.pieces(body)), framing.stalled(body))
        }
    }

    /**
     * (2) TLS 레코드 하나를 흘리는 서버 — JSSE 는 레코드가 다 올 때까지 읽기 하나 안에서 기다린다(그 아래 평문 소켓의 읽기는 바이트마다 끝난다).
     * 마감을 TLS 스트림의 읽기마다만 보면 이 칸이 그대로다 — 마감은 JSSE 아래의 평문 소켓에서 본다. 수정 전 측정은 커밋 메시지.
     */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a trickled TLS record fails at the deadline`(lane: Lane) {
        expectDeadline("admin $lane TLS 레코드", lane, runTls(lane))
    }

    /**
     * 교환의 끝은 그 스레드의 소켓 마감을 지운다 — 남으면 그 스레드가 나중에 하는 소켓 읽기(다음 교환이 연결을 빌리며 엿보는 읽기)가 지난 교환의
     * 마감에 걸린다. 파사드는 IO 스레드에서 교환하므로, 이 레인의 JAX-RS 클라이언트로 이 스레드에서 직접 교환한 뒤 그 마감을 넘겨 시작한 읽기가
     * 그대로인지 본다.
     */
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `an exchange leaves no deadline on its thread`() {
        PacedServer { whole(USER_BODY) }.use { server ->
            val client = AdminClient.buildTimeoutClient(config(server.url))
            try {
                client.target(server.url + USER_PATH).request().get().use { response ->
                    assertEquals(200, response.status)
                    response.readEntity(String::class.java)
                }
            } finally {
                client.close()
            }
            Thread.sleep(READ_TIMEOUT_MILLIS + 200L)
            assertEquals('x'.code, AdminSockets.deadlined(SlowStream(0, 'x'.code)).read(), "교환이 끝난 스레드에 마감이 남았다")
        }
    }

    /**
     * 소켓의 마감 스트림([AdminSockets.deadlined]) — 마감이 없는 스레드의 읽기는 그대로다 · 마감 안의 읽기는 그대로다 · 마감 뒤에 시작하는 읽기는
     * 읽지 않고 실패한다 · 마감 뒤에 끝난 읽기는 그 결과를 내주지 않는다 · 0 은 마감을 두지 않는다. 두 읽기 모두.
     */
    @Test
    fun `the deadlined socket stream checks before and after every read`() {
        try {
            for (array in listOf(false, true)) {
                val one = if (array) 1 else 'x'.code
                AdminSockets.disarm()
                assertEquals(one, read(AdminSockets.deadlined(SlowStream(0, 'x'.code)), array), "마감이 없는 스레드의 읽기는 그대로다")

                AdminSockets.arm(System.nanoTime(), 10_000)
                assertEquals(one, read(AdminSockets.deadlined(SlowStream(0, 'x'.code)), array), "마감 안의 읽기는 그대로다")

                AdminSockets.arm(System.nanoTime(), 50)
                Thread.sleep(80)
                val before = SlowStream(0, 'x'.code)
                val e = assertFailsWith<SocketTimeoutException> { read(AdminSockets.deadlined(before), array) }
                assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다")
                assertEquals(RESPONSE_LATE + "50 ms of sending the request", e.message)

                AdminSockets.arm(System.nanoTime(), 50)
                val after = SlowStream(120, 'x'.code)
                assertFailsWith<SocketTimeoutException> { read(AdminSockets.deadlined(after), array) }
                assertEquals(1, after.reads, "마감을 넘겨 끝난 읽기 — 읽었지만 그 결과를 내주지 않는다")

                AdminSockets.arm(System.nanoTime(), 0)
                Thread.sleep(20)
                assertEquals(one, read(AdminSockets.deadlined(SlowStream(0, 'x'.code)), array), "읽기 타임아웃 0(끝없이)에는 마감도 없다")
            }
        } finally {
            AdminSockets.disarm()
        }
    }

    /** 대조 — 머리와 몇 바이트 뒤 침묵: 지금처럼 읽기 타임아웃 무렵에 전송 실패다. */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `control - a stalled response still fails at the read timeout`(lane: Lane) {
        val o = run(lane, stalledBody(bodyOf(lane)))
        val label = "admin $lane 멈춤"
        println("[admin.ResponseReadDeadlineTest] $label → ${o.describe()}")
        assertIs<KeycloakTransportException>(o.thrown, "$label: 전송 실패여야 한다 — ${o.describe()}")
        assertTrue(o.millis >= READ_TIMEOUT_MILLIS - 100 && o.millis < BOUND_MILLIS, "$label: 읽기 타임아웃 무렵에 실패해야 한다 — ${o.describe()}")
    }

    /** 읽기마다 [millis] 를 쉬고 [result] 를 내주는 스트림(-1 이면 끝) — 읽힌 수를 센다. */
    private class SlowStream(
        private val millis: Long,
        private val result: Int,
    ) : InputStream() {
        var reads = 0

        override fun read(): Int {
            reads++
            Thread.sleep(millis)
            return result
        }

        override fun read(
            b: ByteArray,
            off: Int,
            len: Int,
        ): Int {
            val c = read()
            if (c < 0) return -1
            b[off] = c.toByte()
            return 1
        }
    }

    private fun read(
        input: InputStream,
        array: Boolean,
    ): Int = if (array) input.read(ByteArray(4), 0, 4) else input.read()

    /**
     * 엔진의 스트림([AdminEngine.Settled]) — 마감은 요청을 보낸 때부터다(HttpCore 가 요청 머리를 쓰기 직전에 `http.request_sent` 를 거짓으로 두는
     * 때 — 연결을 빌리고 맺는 시간은 들지 않는다 · 보낸 뒤의 참 표시는 마감을 옮기지 않는다) · 마감 뒤에 시작하는 읽기는 읽지 않고 실패한다 ·
     * 마감을 넘겨 끝난 읽기는 그 결과를 내주지 않는다(늦게 온 끝 -1 도 — 청크의 끝 표시가 늦은 응답). 두 읽기 모두.
     */
    @Test
    fun `the engine stream checks the deadline from when the request was sent`() {
        try {
            engineStreamChecks()
        } finally {
            AdminSockets.disarm() // 보낸 표시가 이 스레드의 소켓 마감도 건다 — 다음 시험에 남기지 않는다
        }
    }

    private fun engineStreamChecks() {
        for (array in listOf(false, true)) {
            val exchange = AdminEngine.Exchange(HttpGet("http://127.0.0.1:1/"), 100)
            Thread.sleep(150) // 손잡이를 만든 때부터 세면 마감이 지났다
            exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, false) // 이제 보낸다
            assertEquals(
                if (array) 1 else 'x'.code,
                read(AdminEngine.Settled(SlowStream(0, 'x'.code), exchange, Long.MAX_VALUE), array),
                "마감은 요청을 보낸 때부터다",
            )
            exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, true)
            Thread.sleep(150)
            val before = SlowStream(0, 'x'.code)
            val e =
                assertFailsWith<SocketTimeoutException>("보낸 뒤의 표시가 마감을 옮겼다") {
                    read(AdminEngine.Settled(before, exchange, Long.MAX_VALUE), array)
                }
            assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다")
            assertEquals(RESPONSE_LATE + "100 ms of sending the request", e.message)

            val late = AdminEngine.Exchange(HttpGet("http://127.0.0.1:1/"), 100)
            late.setAttribute(HttpCoreContext.HTTP_REQ_SENT, false)
            val end = SlowStream(200, -1)
            assertFailsWith<SocketTimeoutException>("마감을 넘겨 온 끝을 받아들였다") {
                read(AdminEngine.Settled(end, late, Long.MAX_VALUE), array)
            }
            assertEquals(1, end.reads)
        }
    }

    /** 대조 — 상한 바로 아래 본문이 네 조각으로 마감 안에 온다: 받아들인다(거짓 마감이 없다). */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `control - a healthy response just under the cap is accepted`(lane: Lane) {
        val o = run(lane, healthyBody(padded(bodyOf(lane), TOKEN_RESPONSE_MAX_BYTES - 1)))
        val label = "admin $lane 건강"
        println("[admin.ResponseReadDeadlineTest] $label → ${o.describe()}")
        assertNull(o.thrown, "$label: 받아들여야 한다 — ${o.thrown?.let { trace(it) }}")
        assertEquals("x", o.result, label)
    }

    private companion object {
        const val READ_TIMEOUT_MILLIS = 1_000
        const val GAP_MILLIS = 700L
        const val TRICKLED = 10
        const val BOUND_MILLIS = 3_000L
        const val HEALTHY_GAP_MILLIS = 150L
        const val HOLD_MILLIS = 10_000L

        /** 실패의 어느 표현에도 찍히면 안 되는 응답 바이트. */
        const val MARKER = "ZdeadlineMARKER0123456789"
        const val TOKEN_PATH = "/realms/r/protocol/openid-connect/token"
        const val USER_PATH = "/admin/realms/r/users/x"
        val TOKEN_BODY: ByteArray = utf8("{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}")
        val USER_BODY: ByteArray = utf8("{\"id\":\"x\",\"username\":\"$MARKER\"}")

        fun utf8(s: String): ByteArray = s.toByteArray(StandardCharsets.UTF_8)

        fun latin1(s: String): ByteArray = s.toByteArray(StandardCharsets.ISO_8859_1)

        fun concat(vararg parts: ByteArray): ByteArray {
            val out = ByteArrayOutputStream()
            for (part in parts) out.writeBytes(part)
            return out.toByteArray()
        }

        fun padded(
            body: ByteArray,
            total: Int,
        ): ByteArray = body.copyOf(total).also { it.fill(' '.code.toByte(), body.size, total) }

        fun head(contentLength: Int): ByteArray =
            latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $contentLength\r\n\r\n")

        fun whole(body: ByteArray): List<Piece> = listOf(Piece(0, concat(head(body.size), body)))

        /** 머리와 본문을 한 번에 쓰되 본문의 마지막 [TRICKLED] 바이트는 [GAP_MILLIS] 마다 하나씩. */
        fun trickledBody(body: ByteArray): List<Piece> =
            listOf(Piece(0, concat(head(body.size), body.copyOf(body.size - TRICKLED)))) +
                (body.size - TRICKLED until body.size).map { Piece(GAP_MILLIS, byteArrayOf(body[it])) }

        /** 머리와 본문의 처음 5 바이트 뒤 침묵(알린 길이는 본문 전체). */
        fun stalledBody(body: ByteArray): List<Piece> =
            listOf(Piece(0, concat(head(body.size), body.copyOf(5))), Piece(HOLD_MILLIS, ByteArray(0)))

        /** 상한 바로 아래 본문을 네 조각으로 — 조각 사이 [HEALTHY_GAP_MILLIS]. */
        fun healthyBody(body: ByteArray): List<Piece> {
            val all = concat(head(body.size), body)
            val quarter = all.size / 4
            return (0 until 4).map { i ->
                val from = i * quarter
                val to = if (i == 3) all.size else from + quarter
                Piece(if (i == 0) 0 else HEALTHY_GAP_MILLIS, all.copyOfRange(from, to))
            }
        }

        val CHUNKED_HEAD: ByteArray =
            latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")

        /** [at] 의 바이트를 [GAP_MILLIS] 마다 하나씩. */
        fun trickled(at: ByteArray): List<Piece> = at.map { Piece(GAP_MILLIS, byteArrayOf(it)) }

        /** TLS 레코드 둘 — 본문의 마지막 [TRICKLED] 바이트는 300 ms 뒤 따로 쓴다(그 레코드를 중계가 흘린다). */
        fun twoRecords(body: ByteArray): List<Piece> =
            listOf(
                Piece(0, concat(head(body.size), body.copyOf(body.size - TRICKLED))),
                Piece(300, body.copyOfRange(body.size - TRICKLED, body.size)),
            )

        /** 요청 하나(머리와 Content-Length 본문)를 읽고 경로를 돌려준다 — 연결이 끝났으면 null. */
        fun readRequest(input: InputStream): String? {
            val head = ByteArrayOutputStream()
            var last4 = 0
            while (true) {
                val b = input.read()
                if (b == -1) return null
                head.write(b)
                last4 = (last4 shl 8) or b
                if (last4 == 0x0d0a0d0a) {
                    val lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n")
                    for (line in lines) {
                        if (line.regionMatches(
                                0,
                                "Content-Length:",
                                0,
                                15,
                                ignoreCase = true,
                            )
                        ) {
                            input.readNBytes(line.substring(15).trim().toInt())
                        }
                    }
                    return lines[0].split(" ")[1]
                }
            }
        }
    }
}
