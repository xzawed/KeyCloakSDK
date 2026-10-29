package io.github.xzawed.keycloak

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import com.nimbusds.oauth2.sdk.http.HTTPRequest
import kotlinx.coroutines.runBlocking
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
import java.net.URI
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.Date
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 읽기 타임아웃 안에 다 읽는다 — auth(토큰) 레인과 JWKS(콜드 적재) 레인(등록부
// `response-read-deadline-divergent`, 판정 2026-10-29). Java `ResponseReadDeadlineTest` 의 이식이다. 공개 API 와 로컬 루프백만 쓴다(TLS 레코드
// 한 칸과 스레드의 마감 한 칸만 송신기를 직접 부른다).
//
// 왜: 읽기 타임아웃(SO_TIMEOUT)은 읽기 **하나**를 묶을 뿐이라, 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 응답 하나가 흘린
// 바이트마다 간격 하나씩 걸렸다(최악 ≈ 상한 × 읽기 타임아웃). 수정 전 실측은 이 시험을 수정 전 코드에 돌려 잰 것이다(커밋 메시지) — 흘리기
// 여섯 칸이 모두 7 초 넘게 걸려 **받아들여졌고**, TLS 레코드 하나를 흘리면 그 레코드의 바이트 수만큼 걸렸다. 코루틴 취소도 그 소켓 읽기는
// 끊지 못한다(`onIo` — 플랫폼 스레드의 블로킹 읽기는 인터럽트를 무시한다) — 마감이 그 읽기를 끝낸다.
//
// 계약: (1) 흘리기 — 읽기 타임아웃 1 초 · 마지막 10 바이트를 0.7 초마다 — 는 3 초 안에 그 레인의 읽기 타임아웃과 같은 실패다(원인 사슬에
// SocketTimeoutException · 응답 바이트를 인용하지 않는다). 경계 = 마감(읽기 타임아웃) + 읽기 하나(마감 직전에 시작한 읽기는 지금처럼 읽기
// 타임아웃까지 기다린다) + 여유 1 초(다른 빌드가 함께 도는 기계의 깨움 지연 — 그래도 수정 전과 4 초 넘게 떨어진다). (2) 응답의 틀(머리 줄 ·
// 청크 크기 줄 · 트레일러)과 TLS 레코드를 흘려도 같다 — 마감은 하위 운송의 호출 하나 **안**이 아니라 그 교환의 소켓 읽기마다(TLS 면 JSSE
// 아래의 평문 소켓) 본다. 대조: 멈춤(머리와 몇 바이트 뒤 침묵)은 지금처럼 읽기 타임아웃에 실패하고, 상한 바로 아래 본문을 네 조각으로 나눠
// 보내는 건강한 응답은 받아들여진다.
internal class ResponseReadDeadlineTest {
    /** 응답의 한 조각 — 쓰기 전에 [delayMillis] 를 쉰다. */
    private class Piece(
        val delayMillis: Long,
        val bytes: ByteArray,
    )

    /** 응답의 틀 중 흘리는 자리 — 흘리는 바이트는 모두 [TRICKLED] 개다. */
    enum class Framing {
        /** 머리 블록 — 헤더 하나의 값 열 바이트. */
        HEAD,

        /** 마지막 청크의 크기 줄(확장 포함) 열 바이트. */
        CHUNK_SIZE_LINE,

        /** 마지막 청크 뒤 트레일러 한 줄 열 바이트. */
        TRAILER,
    }

    /** 레인 — 응답을 내는 경로. */
    enum class Lane(
        val path: String,
    ) {
        /** client_credentials 토큰 — `AuthClient.clientCredentialsToken`. */
        TOKEN("$REALM_PATH/token"),

        /** JWKS 콜드 적재 — `AuthClient.validate` 의 첫 호출(키 집합 상한 51,200 바이트). */
        JWKS("$REALM_PATH/certs"),
    }

    /**
     * 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결마다 요청 하나(머리와 Content-Length 본문)를 읽고 [reply](경로 → 조각)가 고른 조각을 차례로
     * 쓴다(조각마다 쉬고 쓴다). 다 쓴 뒤에는 쓰지 않고 붙든다 — 클라이언트가 닫을 때까지(최대 [HOLD_MILLIS]). [beforeLast] 가 있으면 마지막
     * 조각을 쓰기 직전에 부른다(TLS 중계가 거기서부터 흘린다).
     */
    private class PacedServer(
        tls: SSLContext?,
        private val reply: (String) -> List<Piece>,
    ) : AutoCloseable {
        val socket: ServerSocket =
            tls?.serverSocketFactory?.createServerSocket(0, 50, InetAddress.getLoopbackAddress())
                ?: ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        @Volatile
        var beforeLast: (() -> Unit)? = null

        init {
            Thread(::serve, "paced-server").apply { isDaemon = true }.start()
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
                Thread({ answer(s) }, "paced-connection").apply { isDaemon = true }.start()
            }
        }

        private fun answer(s: Socket) {
            try {
                s.use {
                    s.soTimeout = HOLD_MILLIS.toInt()
                    if (s is SSLSocket) s.startHandshake()
                    val input = s.getInputStream()
                    val path = readRequest(input) ?: return
                    val out = s.getOutputStream()
                    val pieces = reply(path)
                    for ((i, piece) in pieces.withIndex()) {
                        if (piece.delayMillis > 0) Thread.sleep(piece.delayMillis)
                        if (i == pieces.size - 1) beforeLast?.invoke()
                        out.write(piece.bytes)
                        out.flush()
                    }
                    while (input.read() >= 0) {
                        // 클라이언트가 닫을 때까지 붙든다
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
     * TLS 앞의 TCP 중계 — 서버의 바이트를 곧바로 넘기다가 [trickle] 뒤로는 한 바이트씩 [GAP_MILLIS] 마다 넘긴다(첫 바이트는 곧바로 — 그 앞의
     * 침묵에 간격을 더하면 읽기 타임아웃이 먼저 터진다). 서버는 마지막 조각(TLS 레코드 하나)을 쓰기 직전에 그것을 부른다 — 그 앞의 레코드는
     * 300 ms 전에 이미 넘어갔다.
     */
    private class TrickleRelay(
        private val target: Int,
    ) : AutoCloseable {
        val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())

        @Volatile
        private var trickling = false

        init {
            Thread(::serve, "trickle-relay").apply { isDaemon = true }.start()
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
            }, "trickle-relay-pump").apply { isDaemon = true }.start()
        }

        override fun close() {
            socket.close()
        }
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

    /** 읽기마다 [millis] 를 쉬고 한 바이트를 내주는 스트림 — 읽힌 수를 센다. */
    private class SlowStream(
        private val millis: Long,
    ) : InputStream() {
        var reads = 0

        override fun read(): Int {
            reads++
            Thread.sleep(millis)
            return 'x'.code
        }

        override fun read(
            b: ByteArray,
            off: Int,
            len: Int,
        ): Int {
            b[off] = read().toByte()
            return 1
        }
    }

    private fun time(call: () -> Any?): Outcome {
        val start = System.nanoTime()
        var result: Any? = null
        var thrown: Throwable? = null
        try {
            result = call()
        } catch (t: Throwable) {
            thrown = t
        }
        return Outcome(result, thrown, (System.nanoTime() - start) / 1_000_000)
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

    private fun signedToken(url: String): String {
        val jwt =
            SignedJWT(
                JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
                JWTClaimsSet
                    .Builder()
                    .issuer("$url/realms/r")
                    .audience("app")
                    .subject("u1")
                    .expirationTime(Date(System.currentTimeMillis() + 60_000))
                    .build(),
            )
        jwt.sign(RSASSASigner(SIGNING))
        return jwt.serialize()
    }

    private fun bodyOf(lane: Lane): ByteArray = if (lane == Lane.TOKEN) TOKEN_BODY else JWKS_BODY

    // 상한 바로 아래 — 상한에 닿으면 넘침이다(Nimbus 의 셈)라 JWKS 도 한 바이트 아래다
    private fun healthyBodyOf(lane: Lane): ByteArray =
        if (lane == Lane.TOKEN) padded(TOKEN_BODY, TOKEN_RESPONSE_MAX_BYTES - 1) else padded(JWKS_BODY, JWKS_CAP - 1)

    private fun call(
        lane: Lane,
        url: String,
    ): Any? =
        AuthClient(config(url)).use { client ->
            runBlocking {
                if (lane == Lane.TOKEN) {
                    client.clientCredentialsToken().also { assertEquals(MARKER, it.accessToken, "받아들인 토큰이 응답의 것이 아니다") }
                    "token"
                } else {
                    client.validate(signedToken(url)).subject
                }
            }
        }

    private fun failure(lane: Lane): Class<out Throwable> =
        if (lane == Lane.TOKEN) KeycloakTransportException::class.java else TokenValidationException::class.java

    private fun run(
        lane: Lane,
        pieces: List<Piece>,
    ): Outcome {
        warm(lane)
        return PacedServer(null) { path ->
            if (path == lane.path) pieces else listOf(Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")))
        }.use { server -> time { call(lane, server.url) } }
    }

    /**
     * 레인을 작은 정상 응답으로 이 JVM 에서 한 번 먼저 부른다 — 첫 호출의 클래스 적재·코루틴 디스패처 기동(실측: 첫 호출만 약 0.7–0.9 초 더 —
     * 요청을 보내기 전이라 마감에는 들지 않는다)이 시한을 먹지 않게.
     */
    private fun warm(lane: Lane) {
        if (!WARMED.add(lane)) return
        PacedServer(null) { listOf(Piece(0, concat(head(bodyOf(lane).size), bodyOf(lane)))) }.use { server -> call(lane, server.url) }
    }

    private fun trace(t: Throwable): String {
        val out = StringWriter()
        t.printStackTrace(PrintWriter(out, true))
        return out.toString()
    }

    /** 마감의 실패 — 그 레인의 실패 타입 · 원인 사슬에 읽기 타임아웃과 같은 타입 · 응답 바이트 인용 없음 · 시한 안. */
    private fun expectDeadline(
        label: String,
        failure: Class<out Throwable>,
        o: Outcome,
    ) {
        println("[ResponseReadDeadlineTest] $label → ${o.describe()}")
        val thrown = assertNotNull(o.thrown, "$label: 마감 뒤에도 오는 응답을 받아들였다 — ${o.describe()}")
        assertTrue(failure.isInstance(thrown), "$label: 그 레인의 실패 타입이 아니다 — ${trace(thrown)}")
        assertTrue(o.millis < BOUND_MILLIS, "$label: $BOUND_MILLIS ms 안에 실패해야 한다 — ${o.describe()}")
        assertTrue(
            generateSequence(thrown) { it.cause }.any { it is SocketTimeoutException },
            "$label: 읽기 타임아웃과 같은 타입(SocketTimeoutException)이 원인 사슬에 없다 — ${trace(thrown)}",
        )
        assertFalse(trace(thrown).contains(MARKER), "$label: 실패가 응답 바이트를 인용했다 — ${trace(thrown)}")
    }

    // ───────────── 본문 ─────────────

    /** (1) 본문을 흘리는 서버 — 마감에 실패한다. 수정 전: 두 레인 모두 7 초 넘게 걸려 받아들였다. */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a trickled body fails at the deadline`(lane: Lane) {
        expectDeadline("$lane 흘리기", failure(lane), run(lane, trickledBody(bodyOf(lane))))
    }

    /** 대조 — 머리와 몇 바이트 뒤 침묵: 지금처럼 읽기 타임아웃에 실패한다(마감이 먼저 끊지도, 더 기다리지도 않는다). */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `control - a stalled body still fails at the read timeout`(lane: Lane) {
        val o = run(lane, stalledBody(bodyOf(lane)))
        val label = "$lane 멈춤"
        println("[ResponseReadDeadlineTest] $label → ${o.describe()}")
        assertTrue(failure(lane).isInstance(o.thrown), "$label: 실패해야 한다 — ${o.describe()}")
        assertTrue(o.millis >= READ_TIMEOUT_MILLIS - 100 && o.millis < BOUND_MILLIS, "$label: 읽기 타임아웃 무렵에 실패해야 한다 — ${o.describe()}")
    }

    /** 대조 — 상한 바로 아래 본문이 네 조각으로 마감 안에 온다: 받아들인다(거짓 마감이 없다). */
    @ParameterizedTest
    @EnumSource(Lane::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `control - a healthy response just under the cap is accepted`(lane: Lane) {
        val o = run(lane, healthyBody(healthyBodyOf(lane)))
        println("[ResponseReadDeadlineTest] $lane 건강 → ${o.describe()}")
        assertNull(o.thrown, "$lane 건강: 받아들여야 한다 — ${o.thrown?.let { trace(it) }}")
    }

    // ───────────── 틀과 TLS 레코드 ─────────────

    /**
     * (2) 응답의 틀을 흘리는 서버 — 본문 읽기 하나 **안**(청크 크기 줄 · 트레일러)이나 본문 앞(머리)이어도 마감에 실패한다. 수정 전: 셋 다 7 초
     * 넘게 걸려 받아들였다. 레인은 토큰이다 — JWKS 레인은 같은 운송이다.
     */
    @ParameterizedTest
    @EnumSource(Framing::class)
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `trickled framing fails at the deadline`(framing: Framing) {
        expectDeadline("TOKEN 틀 $framing", KeycloakTransportException::class.java, run(Lane.TOKEN, framed(framing, TOKEN_BODY)))
    }

    /**
     * (2) TLS 레코드 하나를 흘리는 서버 — JSSE 는 레코드가 다 올 때까지 읽기 하나 안에서 기다린다(그 아래 평문 소켓의 읽기는 바이트마다
     * 끝난다). 마감을 TLS 스트림의 읽기마다만 보면 이 칸이 그대로다 — 마감은 JSSE 아래의 평문 소켓에서 본다. 송신기를 직접 부른다(요청의 소켓
     * 팩토리가 시험 인증서를 믿는다 — 전역 기본값을 바꾸지 않는다). 수정 전: 레코드의 바이트 수 × 0.7 초 뒤 받아들였다.
     */
    @Test
    @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a trickled TLS record fails at the deadline`() {
        val pieces =
            listOf(
                Piece(0, concat(head(TOKEN_BODY.size), TOKEN_BODY.copyOf(TOKEN_BODY.size - TRICKLED))),
                Piece(300, TOKEN_BODY.copyOfRange(TOKEN_BODY.size - TRICKLED, TOKEN_BODY.size)),
            )
        PacedServer(TransportTestTls.serverIp) { pieces }.use { server ->
            TrickleRelay(server.port).use { relay ->
                server.beforeLast = relay::trickle
                val req = HTTPRequest(HTTPRequest.Method.POST, URI.create("https://127.0.0.1:${relay.port}$REALM_PATH/token").toURL())
                req.body = "grant_type=client_credentials"
                req.connectTimeout = 5_000
                req.readTimeout = READ_TIMEOUT_MILLIS
                req.followRedirects = false
                req.sslSocketFactory = TransportTestTls.trusting
                expectDeadline("TOKEN TLS 레코드", IOException::class.java, time { CappedResponseSender("token response").send(req) })
            }
        }
    }

    // ───────────── 마감 스트림 ─────────────

    private fun read(
        input: InputStream,
        array: Boolean,
    ): Int = if (array) input.read(ByteArray(4), 0, 4) else input.read()

    /**
     * 마감 스트림 — 마감이 없는 스레드의 읽기는 그대로다 · 마감 안의 읽기는 그대로다 · 마감 뒤에 시작하는 읽기는 읽지 않고 실패한다 · 마감 뒤에
     * 끝난 읽기는 그 결과를 내주지 않는다 · 0 은 마감을 두지 않는다. 두 읽기(한 바이트 · 배열) 모두.
     */
    @Test
    fun `the deadlined stream checks before and after every read`() {
        try {
            for (array in listOf(false, true)) {
                val one = if (array) 1 else 'x'.code
                BoundedTransport.disarm()
                assertEquals(one, read(BoundedTransport.deadlined(SlowStream(0)), array), "마감이 없는 스레드의 읽기는 그대로다")

                BoundedTransport.arm(10_000)
                assertEquals(one, read(BoundedTransport.deadlined(SlowStream(0)), array), "마감 안의 읽기는 그대로다")

                BoundedTransport.arm(50)
                Thread.sleep(80)
                val before = SlowStream(0)
                val e = assertFailsWith<SocketTimeoutException> { read(BoundedTransport.deadlined(before), array) }
                assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다")
                assertEquals(BoundedTransport.LATE + "50 ms of sending the request", e.message)

                BoundedTransport.arm(50)
                val after = SlowStream(120)
                assertFailsWith<SocketTimeoutException> { read(BoundedTransport.deadlined(after), array) }
                assertEquals(1, after.reads, "마감을 넘겨 끝난 읽기 — 읽었지만 그 결과를 내주지 않는다")

                BoundedTransport.arm(0)
                Thread.sleep(20)
                assertEquals(one, read(BoundedTransport.deadlined(SlowStream(0)), array), "읽기 타임아웃 0(끝없이)에는 마감도 없다")
            }
        } finally {
            BoundedTransport.disarm()
        }
    }

    /**
     * 교환의 끝은 그 스레드의 마감을 지운다 — 남으면 그 스레드가 나중에 하는 소켓 읽기(다음 교환이 연결을 빌리며 엿보는 1 ms 읽기)가 지난 교환의
     * 마감에 걸린다. 짧은 읽기 타임아웃의 교환 하나 뒤, 그 마감을 넘겨 시작한 읽기가 그대로다. 송신기를 이 스레드에서 직접 부른다(공개 API 는
     * IO 디스패처의 스레드에서 돈다).
     */
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `an exchange leaves no deadline on its thread`() {
        PacedServer(null) { listOf(Piece(0, concat(head(TOKEN_BODY.size), TOKEN_BODY))) }.use { server ->
            val req = HTTPRequest(HTTPRequest.Method.POST, URI.create("${server.url}$REALM_PATH/token").toURL())
            req.body = "grant_type=client_credentials"
            req.connectTimeout = 5_000
            req.readTimeout = 200
            req.followRedirects = false
            assertEquals(200, CappedResponseSender("token response").send(req).statusCode)
            Thread.sleep(300)
            assertEquals('x'.code, BoundedTransport.deadlined(SlowStream(0)).read(), "교환이 끝난 스레드에 마감이 남았다")
        }
    }

    private companion object {
        /** 교환의 읽기 타임아웃 — 등록부 실측과 같은 값. 마감도 이 길이다(요청을 보낸 때부터). */
        const val READ_TIMEOUT_MILLIS = 1_000

        /** 흘리는 바이트 사이의 간격 — 읽기 타임아웃의 0.7 배라 읽기마다의 타임아웃은 터지지 않는다. */
        const val GAP_MILLIS = 700L

        /** 흘리는 바이트 수 — 수정 전에는 그 수만큼 간격이 걸렸다(10 × 700 ms). */
        const val TRICKLED = 10

        /** 실패해야 하는 시한 — 마감 1 초 + 읽기 하나 1 초 + 여유 1 초(머리 주석). */
        const val BOUND_MILLIS = 3_000L

        /** 건강한 대조의 조각 사이 간격 — 네 조각이 마감 안에(합 0.45 초) 온다. */
        const val HEALTHY_GAP_MILLIS = 150L

        /** 멈춤 대조에서 서버가 아무것도 쓰지 않고 붙드는 시간 — 읽기 타임아웃보다 넉넉히 길다. */
        const val HOLD_MILLIS = 10_000L
        const val JWKS_CAP = 51_200

        /** 실패의 어느 표현에도 찍히면 안 되는 응답 바이트. */
        const val MARKER = "ZdeadlineMARKER0123456789"
        const val REALM_PATH = "/realms/r/protocol/openid-connect"
        val TOKEN_BODY: ByteArray = utf8("{\"access_token\":\"$MARKER\",\"token_type\":\"Bearer\",\"expires_in\":300}")
        val SIGNING: RSAKey by lazy { RSAKeyGenerator(2048).keyID("k1").generate() }
        val JWKS_BODY: ByteArray by lazy { utf8(JWKSet(SIGNING.toPublicJWK()).toString()) }
        val CHUNKED_HEAD: ByteArray = latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")

        /** 이 JVM 에서 이미 한 번 부른 레인([warm]). */
        val WARMED: MutableSet<Lane> = ConcurrentHashMap.newKeySet()

        fun utf8(s: String): ByteArray = s.toByteArray(StandardCharsets.UTF_8)

        fun latin1(s: String): ByteArray = s.toByteArray(StandardCharsets.ISO_8859_1)

        fun concat(vararg parts: ByteArray): ByteArray {
            val out = ByteArrayOutputStream()
            for (part in parts) out.writeBytes(part)
            return out.toByteArray()
        }

        /** [body] 뒤를 JSON 공백으로 채워 [total] 바이트로. */
        fun padded(
            body: ByteArray,
            total: Int,
        ): ByteArray = body.copyOf(total).also { it.fill(' '.code.toByte(), body.size, total) }

        fun head(contentLength: Int): ByteArray =
            latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $contentLength\r\n\r\n")

        /** [at] 의 바이트를 [gap] 마다 하나씩 — 앞의 조각에 이어. */
        fun MutableList<Piece>.trickle(
            at: ByteArray,
            gap: Long,
        ) {
            for (b in at) add(Piece(gap, byteArrayOf(b)))
        }

        /** 머리와 본문을 한 번에 쓰되 본문의 마지막 [TRICKLED] 바이트는 [GAP_MILLIS] 마다 하나씩. */
        fun trickledBody(body: ByteArray): List<Piece> =
            mutableListOf(Piece(0, concat(head(body.size), body.copyOf(body.size - TRICKLED)))).apply {
                trickle(body.copyOfRange(body.size - TRICKLED, body.size), GAP_MILLIS)
            }

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

        fun framed(
            framing: Framing,
            body: ByteArray,
        ): List<Piece> =
            mutableListOf<Piece>().apply {
                when (framing) {
                    Framing.HEAD -> {
                        add(Piece(0, latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Pace: ")))
                        trickle(latin1("0123456789"), GAP_MILLIS)
                        add(Piece(0, concat(latin1("\r\nContent-Length: ${body.size}\r\n\r\n"), body)))
                    }
                    Framing.CHUNK_SIZE_LINE -> {
                        add(
                            Piece(
                                0,
                                concat(
                                    CHUNKED_HEAD,
                                    latin1(Integer.toHexString(body.size - 1) + "\r\n"),
                                    body.copyOf(body.size - 1),
                                    latin1("\r\n"),
                                ),
                            ),
                        )
                        trickle(latin1("1;a=bcde\r\n"), GAP_MILLIS)
                        add(Piece(0, concat(byteArrayOf(body[body.size - 1]), latin1("\r\n0\r\n\r\n"))))
                    }
                    Framing.TRAILER -> {
                        add(Piece(0, concat(CHUNKED_HEAD, latin1(Integer.toHexString(body.size) + "\r\n"), body, latin1("\r\n0\r\n"))))
                        trickle(latin1("X-T: 012\r\n"), GAP_MILLIS)
                        add(Piece(0, latin1("\r\n")))
                    }
                }
            }

        /** 서버가 쓴 응답을 읽는 요청 하나(머리와 Content-Length 본문) — 경로를 돌려준다, 연결이 끝났으면 null. */
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
