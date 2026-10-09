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
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Timeout
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import java.time.Duration
import java.util.Date
import java.util.concurrent.Callable
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// 연결 재사용 — auth·JWKS 운송의 프로세스 풀은 HttpURLConnection 의 keep-alive 처럼 연결을 다시 쓰되, 한도 안에서다: EOF 까지 읽은
// 응답의 연결만 풀로 돌아가고(재사용), 넘침·거부·실패의 연결은 읽지 않고 끊겨 돌아가지 않으며, 같은 TLS 근원의 교환만 연결을 함께
// 쓰고, 쉬는 동안 서버가 닫은 연결은 빌려줄 때 걸러지거나 한 번 다시 보내진다. 백그라운드 스레드가 없고, 거부하며 닫는 TLS 연결은
// 조용한 서버 앞에서 기다리지 않는다. Java `ConnectionReuseTest` 의 이식이다(25 사례) — 그 위에 Kotlin 만의 것: 코루틴 취소(onIo 의
// runInterruptible)는 풀의 기다림만 끊는다 — 취소된 호출이 빌린 연결을 남기지 않는가, 그리고 그 끊김이 JWKS 강제 재조회 창을 버리지
// 않는가.
//
// ⚠️ 풀은 프로세스에 하나다 — 시험마다 새 서버(새 포트 = 새 경로)를 써서 서로의 연결을 다시 쓰지 않는다. 연결 수는 서버가 받아들인
// 수로 잰다. 시간 한도는 별도 스레드에서 끊는다(SEPARATE_THREAD) — 블로킹 소켓 읽기는 인터럽트로 멈추지 않아, 회귀(예: 거부한 본문을
// 비우는 닫기)가 빌드를 붙잡지 않고 실패하게.
private val CRT_ACTIVE = """{"active":true,"client_id":"app"}""".toByteArray()

// 운송의 상수 — 시험은 SDK 상수를 빌리지 않고 수로 고정한다(값이 바뀌면 이 시험이 먼저 안다).
private const val CRT_CAP = 1_048_576
private const val CRT_MAX_PER_ROUTE = 50
private const val CRT_IDLE_MILLIS = 5_000L
private const val CRT_VALIDATE_AFTER_MILLIS = 2_000L
private const val CRT_INVALID_RESPONSE = "Invalid Http response"
private const val CRT_POOL_TIMEOUT = "Timed out waiting for a pooled connection"

// 인증서의 이름(other.example)이 아니라 접속한 이름이 루프백이면 받아들이는 검증기.
private val CRT_ACCEPTS_LOOPBACK = HostnameVerifier { host, _ -> host == "127.0.0.1" }

// 무엇이든 거부하는 검증기(접속한 이름이 결코 아닌 이름만 받아들인다).
private val CRT_REJECTS = HostnameVerifier { host, _ -> host == "never.invalid" }

private fun crtLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun crtOk(body: ByteArray): ByteArray =
    ByteArrayOutputStream()
        .apply {
            write(crtLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n"))
            write(body)
        }.toByteArray()

// 연결 하나를 맡는 서버 쪽 코드 — 읽기·쓰기·닫기를 시험이 정한다.
private fun interface CrtHandler {
    fun handle(peer: CrtPeer)
}

// 원시 서버 — 연결마다 새 스레드에서 handler 를 돌린다. 받아들인 연결 수, 지금 열린 수의 최고치, 받은 요청을 적는다.
private class CrtRawServer(
    tls: SSLContext?,
    private val handler: CrtHandler,
) : AutoCloseable {
    val socket: ServerSocket =
        tls?.serverSocketFactory?.createServerSocket(0, 100, InetAddress.getLoopbackAddress())
            ?: ServerSocket(0, 100, InetAddress.getLoopbackAddress())
    val accepted = AtomicInteger()
    val open = AtomicInteger()
    val peakOpen = AtomicInteger()

    // 「연결 번호 요청 줄」 — 연결 번호는 받아들인 순서(1 부터).
    val requests = CopyOnWriteArrayList<String>()

    init {
        Thread(::serve, "reuse-raw-server").apply { isDaemon = true }.start()
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
            val index = accepted.incrementAndGet()
            Thread({ run(s, index) }, "reuse-raw-connection").apply { isDaemon = true }.start()
        }
    }

    private fun run(
        s: Socket,
        index: Int,
    ) {
        peakOpen.accumulateAndGet(open.incrementAndGet(), ::maxOf)
        try {
            s.use {
                s.soTimeout = 30_000
                if (s is SSLSocket) s.startHandshake()
                handler.handle(CrtPeer(this, s, index))
            }
        } catch (gone: Exception) {
            // 클라이언트가 떠났다(끊기·TLS 거부 포함)
        } finally {
            open.decrementAndGet()
        }
    }

    // 요청 줄의 연결 번호와 메서드만 — 「1 POST」 꼴.
    fun connectionsAndMethods(): List<String> = requests.map { it.substring(0, it.indexOf(' ', 2)) }

    override fun close() {
        socket.close()
    }
}

// 서버 쪽 연결 하나.
private class CrtPeer(
    val server: CrtRawServer,
    val socket: Socket,
    val index: Int,
) {
    val input: InputStream = socket.getInputStream()
    val out: OutputStream = socket.getOutputStream()

    // 요청 하나(머리 + Content-Length 본문) — 그 전에 클라이언트가 닫으면 null. 받은 요청은 서버에 적는다.
    fun readRequest(): String? {
        val head = ByteArrayOutputStream()
        var last4 = 0
        while (true) {
            val b = input.read()
            if (b == -1) return null
            head.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0d0a0d0a) break
        }
        val lines = head.toString(Charsets.ISO_8859_1).split("\r\n")
        var length = 0
        for (h in lines) {
            if (h.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) length = h.substring(15).trim().toInt()
        }
        input.readNBytes(length)
        server.requests += "$index ${lines[0]}"
        return lines[0]
    }

    fun write(bytes: ByteArray) {
        out.write(bytes)
        out.flush()
    }

    // 요청마다 reply — 클라이언트가 닫을 때까지.
    fun serveAll(reply: ByteArray) {
        while (readRequest() != null) write(reply)
    }
}

private fun crtAuth(
    base: String,
    connectTimeout: Duration = Duration.ofSeconds(2),
    readTimeout: Duration = Duration.ofSeconds(5),
): AuthClient =
    AuthClient(
        KeycloakConfig(base, "r", "app", "s3cr3t".toCharArray(), connectTimeout = connectTimeout, readTimeout = readTimeout),
    )

// Nimbus 의 기본 TLS 근원을 시험 팩토리로 바꾼 채 block 을 돈다 — 끝에서 되돌린다(Gradle 은 한 JVM 에서 클래스를 차례로 돈다).
private fun <T> crtWithTrustingNimbusDefault(block: () -> T): T {
    val saved = HTTPRequest.getDefaultSSLSocketFactory()
    try {
        HTTPRequest.setDefaultSSLSocketFactory(TransportTestTls.trusting)
        return block()
    } finally {
        HTTPRequest.setDefaultSSLSocketFactory(saved)
    }
}

// CappedResponseSender 로 보내는 POST — 요청의 TLS 근원(팩토리·검증기)과 타임아웃을 시험이 정한다.
private fun crtPost(
    url: String,
    factory: SSLSocketFactory?,
    verifier: HostnameVerifier?,
    readTimeoutMs: Int,
): HTTPRequest =
    HTTPRequest(HTTPRequest.Method.POST, URI(url).toURL()).apply {
        body = "grant_type=client_credentials"
        connectTimeout = 2_000
        readTimeout = readTimeoutMs
        followRedirects = false
        if (factory != null) sslSocketFactory = factory
        if (verifier != null) hostnameVerifier = verifier
    }

private fun crtGet(url: String): HTTPRequest =
    HTTPRequest(HTTPRequest.Method.GET, URI(url).toURL()).apply {
        connectTimeout = 2_000
        readTimeout = 3_000
        followRedirects = false
        sslSocketFactory = TransportTestTls.trusting
    }

private fun HTTPRequest.sendCapped(): HTTPResponse = send(CappedResponseSender("token response"))

private fun crtLeased(): Int = BoundedTransport.POOL.totalStats.leased

// n 개의 호출을 각자의 데몬 스레드에서 함께 시작한다 — ExecutorService 를 쓰지 않는다(JDK 19 부터 AutoCloseable 인데 이 시험은 17 API 로
// 컴파일돼 그 close() 를 부를 수 없다 — Java 의 SonarCloud S2095 수정과 같은 모양). 끝나면 crtCancelAll 로 남은 것을 중단한다.
private fun <T> crtConcurrently(
    n: Int,
    call: () -> T,
): List<FutureTask<T>> =
    List(n) {
        FutureTask(Callable { call() }).also { Thread(it, "reuse-test-call").apply { isDaemon = true }.start() }
    }

private fun crtCancelAll(tasks: List<FutureTask<*>>) {
    tasks.forEach { it.cancel(true) }
}

private fun crtThreadNames(): MutableSet<String> =
    Thread
        .getAllStackTraces()
        .keys
        .filter { it.isAlive }
        .map { it.name }
        .toSortedSet()

// 시스템 속성 몇을 바꾼 채 block 을 돌고 끝에서 되돌린다.
private fun <T> crtWithProperties(
    values: Map<String, String>,
    block: () -> T,
): T {
    val saved = values.keys.associateWith { System.getProperty(it) }
    try {
        values.forEach { (k, v) -> System.setProperty(k, v) }
        return block()
    } finally {
        saved.forEach { (k, v) -> if (v == null) System.clearProperty(k) else System.setProperty(k, v) }
    }
}

private fun crtElapsedMillis(start: Long): Long = (System.nanoTime() - start) / 1_000_000

// 만든 TLS 소켓을 쥐는 팩토리 — 운송이 넘기지 못한 그 소켓 객체를 닫았는지 본다. 서버 쪽에서는 구별되지 않는다: 닫지 않아도 교환의 abort 가
// 그 아래 평문 소켓(connectSocket 전에 연결에 묶인다)을 SO_LINGER 0 으로 끊는다.
private class CrtRecordingFactory(
    private val delegate: SSLSocketFactory,
) : SSLSocketFactory() {
    val created = CopyOnWriteArrayList<SSLSocket>()

    private fun record(s: Socket): Socket = s.also { created += it as SSLSocket }

    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(
        s: Socket,
        host: String,
        port: Int,
        autoClose: Boolean,
    ): Socket = record(delegate.createSocket(s, host, port, autoClose))

    override fun createSocket(
        host: String,
        port: Int,
    ): Socket = record(delegate.createSocket(host, port))

    override fun createSocket(
        host: String,
        port: Int,
        local: InetAddress,
        localPort: Int,
    ): Socket = record(delegate.createSocket(host, port, local, localPort))

    override fun createSocket(
        host: InetAddress,
        port: Int,
    ): Socket = record(delegate.createSocket(host, port))

    override fun createSocket(
        host: InetAddress,
        port: Int,
        local: InetAddress,
        localPort: Int,
    ): Socket = record(delegate.createSocket(host, port, local, localPort))
}

internal class ConnectionReuseTest {
    // ───────────── 재사용 ─────────────

    // AuthClient 의 introspection 20 번이 연결 하나로 간다 — 서버는 연결 하나에서 요청 20 개를 받는다.
    @Test
    fun `sequential AuthClient calls share one connection`() {
        CrtRawServer(null) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { repeat(20) { assertTrue(auth.introspect("tok-$it").active) } }
            assertEquals(1, server.accepted.get(), "연결 ${server.accepted} · ${server.requests}")
            assertEquals(20, server.requests.size)
            assertTrue(server.requests.all { it.startsWith("1 POST ") }, server.requests.toString())
            assertEquals(0, crtLeased())
        }
    }

    // HTTPS 도 같다 — 연결 하나(그래서 핸드셰이크 하나)에서 요청 20 개. TLS 근원은 Nimbus 의 기본값이다(SDK 의 호출과 같다).
    @Test
    fun `sequential HTTPS calls share one connection and one handshake`() {
        CrtRawServer(TransportTestTls.serverIp) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { server ->
            crtWithTrustingNimbusDefault {
                val auth = crtAuth("https://127.0.0.1:${server.port}")
                runBlocking { repeat(20) { assertTrue(auth.introspect("tok-$it").active) } }
            }
            assertEquals(1, server.accepted.get(), "연결 ${server.accepted} · ${server.requests}")
            assertEquals(20, server.requests.size)
        }
    }

    // 풀은 프로세스에 하나다 — AuthClient 를 호출마다 새로 만드는 소비자도 연결 하나를 함께 쓴다(HttpURLConnection 의 keep-alive 캐시와
    // 같다). 클라이언트마다 풀을 두었다면 연결이 클라이언트 수만큼 생겼을 것이다.
    @Test
    fun `many AuthClients share the process pool`() {
        CrtRawServer(null) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { server ->
            runBlocking { repeat(100) { assertTrue(crtAuth("http://127.0.0.1:${server.port}").introspect("tok").active) } }
            assertEquals(1, server.accepted.get())
            assertEquals(100, server.requests.size)
        }
    }

    // 경로마다 연결은 50 개까지 — 60 개를 함께 부르면 서버에 동시에 열린 연결은 50 개이고, 나머지는 연결을 기다렸다가 성공한다.
    @Test
    fun `concurrent calls are bounded per route`() {
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                Thread.sleep(300)
                p.write(crtOk(CRT_ACTIVE))
            }
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            val results = runBlocking { (1..60).map { async(Dispatchers.Default) { auth.introspect("tok").active } }.awaitAll() }
            assertTrue(results.all { it })
            println("[ConnectionReuseTest] 동시 60 호출 → 서버가 받아들인 연결 ${server.accepted} · 동시에 열린 최고 ${server.peakOpen}")
            assertEquals(CRT_MAX_PER_ROUTE, server.peakOpen.get())
            assertEquals(60, server.requests.size)
        }
    }

    // ───────────── 끊기 — 다 읽지 않은 연결은 풀로 돌아가지 않는다 ─────────────

    // 상한을 넘는 본문(끝없는 1 바이트 청크) — 거부한 연결은 읽지 않고 끊긴다: 서버의 쓰기가 곧 실패하고, 다음 호출은 새 연결이며, 그
    // 새 연결은 다시 쓰인다(연결 2 개에 요청 3 개).
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a rejected response is cut and never returned to the pool`() {
        val written = AtomicLong()
        val cutAt = AtomicLong()
        val one = crtLatin1("1\r\n \r\n")
        val block = ByteArray(one.size * 1024)
        for (i in 0 until 1024) one.copyInto(block, i * one.size)
        CrtRawServer(null) { p ->
            if (p.index > 1) {
                p.serveAll(crtOk(CRT_ACTIVE))
                return@CrtRawServer
            }
            p.readRequest()
            p.write(crtLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"))
            try {
                while (true) {
                    p.out.write(block)
                    written.addAndGet(block.size.toLong())
                }
            } catch (cut: IOException) {
                cutAt.set(System.nanoTime())
            }
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            val e = assertFailsWith<KeycloakTransportException> { runBlocking { auth.introspect("tok") } }
            val returned = System.nanoTime()
            assertIs<ResponseTooLargeException>(e.cause)
            assertEquals(0, crtLeased(), "거부한 연결이 빌린 채로 남았다")
            for (i in 0 until 50) {
                if (cutAt.get() != 0L) break
                Thread.sleep(100)
            }
            assertNotEquals(0L, cutAt.get(), "서버의 쓰기가 실패하지 않았다 — 연결이 끊기지 않았다")
            println(
                "[ConnectionReuseTest] 끝없는 본문 → ${e.cause} · 서버가 쓴 $written B · 끊김은 돌아온 뒤 " +
                    "${maxOf(0, (cutAt.get() - returned) / 1_000_000)} ms",
            )
            runBlocking {
                assertTrue(auth.introspect("tok").active)
                assertTrue(auth.introspect("tok").active)
            }
            assertEquals(2, server.accepted.get(), server.requests.toString())
            assertEquals(listOf("1 POST", "2 POST", "2 POST"), server.connectionsAndMethods())
        }
    }

    // 거부가 풀의 자리를 남기지 않는다 — 경로의 상한(50)보다 많은 거부(JWKS 상한 51,200 바이트를 넘는 본문) 뒤에도 빌린 연결은 0 이고,
    // 거부마다 연결을 기다리지 않는다(자리가 새면 51 번째부터 연결 타임아웃만큼 기다려 실패했을 것이다).
    @Test
    fun `rejects never leak pool slots`() {
        val tooBig = crtOk(ByteArray(60_000))
        CrtRawServer(null) { it.serveAll(tooBig) }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val jwks = NoRedirectResourceRetriever(2_000, 5_000)
            for (i in 0 until 60) {
                val e = assertFailsWith<IOException>("거부 $i") { jwks.retrieveResource(certs) }
                assertEquals("Exceeded configured input limit of 51200 bytes", e.message, "거부 $i")
            }
            assertEquals(0, crtLeased())
            assertEquals(60, server.accepted.get(), "거부한 연결은 다시 쓰이지 않는다")
        }
    }

    // 다시 쓴 연결에도 틀 예산은 그대로다 — 첫 응답은 받아들이고, 같은 연결의 두 번째 응답(채운 청크 크기 줄)은 거부한다.
    @Test
    fun `a reused connection still enforces the wire budget`() {
        val padded =
            ByteArrayOutputStream().apply {
                write(crtLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"))
                val chunk = crtLatin1("0".repeat(8_000) + "1\r\n \r\n")
                repeat(60) { write(chunk) }
                write(crtLatin1("0\r\n\r\n"))
            }
        val keys = crtOk("""{"keys":[{"kty":"oct","kid":"k1","k":"AAAA"}]}""".toByteArray())
        CrtRawServer(null) { p ->
            p.readRequest()
            p.write(keys)
            p.readRequest()
            p.write(padded.toByteArray())
            p.readRequest()
        }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val jwks = NoRedirectResourceRetriever(2_000, 5_000)
            assertNotNull(jwks.retrieveResource(certs))
            val e = assertFailsWith<IOException> { jwks.retrieveResource(certs) }
            assertEquals("HTTP response body framing exceeds 409600 bytes on the wire", e.message)
            assertEquals(1, server.accepted.get(), "두 번째 조회는 다시 쓴 연결이어야 한다")
        }
    }

    // ───────────── 묻지 않은 바이트 ─────────────

    // 응답 뒤에 서버가 더 보낸 바이트(다음 응답처럼 생긴 「EVIL」)는 다음 호출의 응답이 되지 않는다 — 다시 쓰려는 연결에 묻지 않은 바이트가
    // 와 있으면 그 연결은 버리고 새 연결을 맺는다. 204 · Content-Length 0 · 본문 · 청크 본문 뒤에 같은 쓰기로 붙인 것(평문 · TLS)과, 평문에서
    // 앞 응답을 다 읽은 뒤 늦게 도착한 것. HttpURLConnection 은 응답마다 새 버퍼로 읽어 버퍼에 남은 것을 버렸다(Java 실측 — 다음 호출은
    // 서버의 답을 기다렸다).
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `bytes sent after a response are never read as the next response`() {
        val evil = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nEVIL"
        val outcomes = linkedMapOf<String, String>()
        outcomes["204 뒤"] = secondCallAfter(null, "HTTP/1.1 204 No Content\r\n\r\n$evil", null)
        outcomes["Content-Length 0 뒤"] = secondCallAfter(null, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n$evil", null)
        outcomes["본문 뒤"] = secondCallAfter(null, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}$evil", null)
        outcomes["청크 본문 뒤"] =
            secondCallAfter(null, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n$evil", null)
        outcomes["204 뒤 늦게(평문)"] = secondCallAfter(null, "HTTP/1.1 204 No Content\r\n\r\n", evil)
        outcomes["204 뒤(TLS)"] = secondCallAfter(TransportTestTls.serverIp, "HTTP/1.1 204 No Content\r\n\r\n$evil", null)
        println("[ConnectionReuseTest] 응답 뒤에 붙인 바이트 → $outcomes")
        assertTrue(outcomes.values.all { it == "GOOD · 연결 2" }, outcomes.toString())
    }

    // 첫 연결은 첫 요청에 first(뒤에 붙은 바이트 포함)를 보내고, late 가 있으면 100 ms 뒤 그것을 더 보낸 다음 답하지 않는다(두 번째
    // 요청이 이 연결로 오면 응답 대신 그 바이트를 읽거나 기다린다). 뒤의 연결은 「GOOD」 을 답한다. 두 번째 호출의 본문과 연결 수.
    private fun secondCallAfter(
        tls: SSLContext?,
        first: String,
        late: String?,
    ): String {
        CrtRawServer(tls) { p ->
            if (p.index > 1) {
                p.serveAll(crtLatin1("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nGOOD"))
                return@CrtRawServer
            }
            p.readRequest()
            p.write(crtLatin1(first))
            if (late != null) {
                Thread.sleep(100)
                p.write(crtLatin1(late))
            }
            p.readRequest()
            Thread.sleep(20_000)
        }.use { server ->
            val url = (if (tls == null) "http" else "https") + "://127.0.0.1:${server.port}/x"
            crtGet(url).sendCapped()
            Thread.sleep(300)
            return try {
                "${crtGet(url).sendCapped().body.toString().trim()} · 연결 ${server.accepted.get()}"
            } catch (e: IOException) {
                "$e · 연결 ${server.accepted.get()}"
            }
        }
    }

    // ───────────── TLS 근원 ─────────────

    // 연결은 같은 TLS 근원의 교환만 다시 쓴다 — 받아들이는 검증기로 맺은 연결을 거부하는 검증기의 교환이 다시 쓰지 않는다(새 연결에서
    // 검증하고 거부한다). HttpURLConnection 은 소켓 팩토리만 가려 이 교환이 검증 없이 성공했다. 원래 근원의 교환은 첫 연결을 다시 쓴다.
    @Test
    fun `a pooled connection is reused only under the same TLS config`() {
        CrtRawServer(TransportTestTls.serverOther) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { server ->
            val url = "https://127.0.0.1:${server.port}/token"
            val trusting = TransportTestTls.trusting
            assertEquals(200, crtPost(url, trusting, CRT_ACCEPTS_LOOPBACK, 5_000).sendCapped().statusCode)
            val rejected = assertFailsWith<IOException> { crtPost(url, trusting, CRT_REJECTS, 5_000).sendCapped() }
            assertEquals("HTTPS hostname wrong:  should be <127.0.0.1>", rejected.message)
            assertEquals(200, crtPost(url, trusting, CRT_ACCEPTS_LOOPBACK, 5_000).sendCapped().statusCode)
            assertEquals(2, server.accepted.get(), server.requests.toString())
            assertEquals(listOf("1 POST /token HTTP/1.1", "1 POST /token HTTP/1.1"), server.requests.toList())
        }
    }

    // ───────────── 쉬는 동안 닫힌 연결 ─────────────

    // 쉬는 동안 서버가 닫은 연결(Connection: close 없이)을 곧바로 다시 쓰면 응답 바이트 하나 없이 끊긴다 — 그때만 새 연결로 한 번 다시
    // 보낸다. 서버는 그 요청을 한 번 받는다.
    @Test
    fun `a connection the server closed while idle is sent again once`() {
        CrtRawServer(null) { p ->
            if (p.index == 1) {
                p.readRequest()
                p.write(crtOk(CRT_ACTIVE))
                return@CrtRawServer // 닫는다
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { assertTrue(auth.introspect("tok").active) }
            Thread.sleep(200) // 서버의 FIN 이 닿을 시간 — 빌려줄 때 보는 시간(2 초)보다 짧다
            runBlocking { assertTrue(auth.introspect("tok").active) }
            assertEquals(2, server.accepted.get())
            assertEquals(listOf("1 POST", "2 POST"), server.connectionsAndMethods())
        }
    }

    // 새 연결이 응답 없이 끊기면 다시 보내지 않는다 — 서버가 처리했을지 모르는 요청(인가 코드·회전하는 refresh 토큰)을 두 번 보내지 않게.
    @Test
    fun `a fresh connection that gets no response is not sent again`() {
        CrtRawServer(null) { it.readRequest() }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            val e = assertFailsWith<KeycloakTransportException> { runBlocking { auth.introspect("tok") } }
            assertEquals(CRT_INVALID_RESPONSE, e.cause?.message)
            assertEquals(1, server.accepted.get())
            assertEquals(1, server.requests.size)
        }
    }

    // 다시 보낸 시도도 응답 없이 끊기면 거기서 끝난다 — 한 번만 다시 보낸다(서버는 그 요청을 두 번까지만 받는다).
    @Test
    fun `the stale retry is made only once`() {
        CrtRawServer(null) { p ->
            p.readRequest()
            if (p.index == 1) p.write(crtOk(CRT_ACTIVE)) // 첫 연결만 답하고 닫는다 · 다음 연결은 받고 답하지 않고 닫는다
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { assertTrue(auth.introspect("tok").active) }
            Thread.sleep(200)
            val e = assertFailsWith<KeycloakTransportException> { runBlocking { auth.introspect("tok") } }
            assertEquals(CRT_INVALID_RESPONSE, e.cause?.message)
            assertEquals(2, server.accepted.get())
            assertEquals(2, server.requests.size, server.requests.toString())
        }
    }

    // 다시 보내기는 새 연결로 간다 — 함께 쉬던 연결 둘이 모두 죽었으면(서버가 둘 다 닫았다) 첫 시도가 하나를 빌려 끊기고, 다시 보내기는
    // 다른 죽은 연결이 아니라 새 연결을 맺는다(다시 보내기 전에 쉬는 연결을 닫는다). 그 호출은 성공한다 — 다시 보내기가 남은 죽은 연결을
    // 빌렸다면 두 시도 모두 끊겨 실패했을 것이다.
    @Test
    fun `the stale retry goes out on a fresh connection even when other pooled connections are stale`() {
        val both = CountDownLatch(2)
        CrtRawServer(null) { p ->
            if (p.index <= 2) {
                p.readRequest()
                both.countDown()
                assertTrue(both.await(10, TimeUnit.SECONDS)) // 둘 다 열린 채로 답한다 — 풀에 연결 둘이 쉬게
                p.write(crtOk(CRT_ACTIVE))
                Thread.sleep(100)
                return@CrtRawServer // 닫는다(Connection: close 없이)
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking {
                val a = async(Dispatchers.Default) { auth.introspect("a").active }
                val b = async(Dispatchers.Default) { auth.introspect("b").active }
                assertTrue(a.await())
                assertTrue(b.await())
            }
            Thread.sleep(300) // 두 연결의 FIN 이 닿을 시간 — 빌려줄 때 보는 시간(2 초)보다 짧다
            runBlocking { assertTrue(auth.introspect("c").active) }
            assertEquals(3, server.accepted.get(), server.requests.toString())
        }
    }

    // 쉬는 동안 RST 로 끊긴 연결 — 다시 쓰면 연결 재설정(SocketException)이고, 응답 바이트 없이 끊긴 것이라 한 번 다시 보낸다.
    @Test
    fun `a connection the server reset while idle is sent again once`() {
        CrtRawServer(null) { p ->
            if (p.index == 1) {
                p.readRequest()
                p.write(crtOk(CRT_ACTIVE))
                p.socket.setSoLinger(true, 0) // 닫으며 RST
                return@CrtRawServer
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { assertTrue(auth.introspect("tok").active) }
            Thread.sleep(200)
            runBlocking { assertTrue(auth.introspect("tok").active) }
            assertEquals(2, server.accepted.get())
            assertEquals(listOf("1 POST", "2 POST"), server.connectionsAndMethods())
        }
    }

    // 다시 쓴 연결에서 서버가 요청을 다 읽고 답 없이 닫으면(응답 바이트 0 — NoHttpResponseException) 한 번 다시 보낸다. ⚠️ 그래서 서버는
    // 그 요청을 두 번 받는다 — 응답 바이트가 없으면 처리됐는지 알 수 없다. HttpURLConnection 도 이때 다시 보냈다(새 연결이어도).
    @Test
    fun `a reused connection closed after reading the request is sent again once`() {
        CrtRawServer(null) { p ->
            if (p.index == 1) {
                p.readRequest()
                p.write(crtOk(CRT_ACTIVE))
                p.readRequest() // 다 읽고 답 없이 닫는다
                return@CrtRawServer
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking {
                assertTrue(auth.introspect("tok").active)
                assertTrue(auth.introspect("tok").active)
            }
            assertEquals(2, server.accepted.get())
            assertEquals(listOf("1 POST", "1 POST", "2 POST"), server.connectionsAndMethods())
        }
    }

    // 다시 쓴 연결이라도 응답이 오기 시작한 뒤 끊기면 다시 보내지 않는다(서버가 처리했을 수 있다) — 서버가 100 Continue 를 보내고 닫으면
    // 그 호출은 실패하고 새 연결을 맺지 않는다.
    @Test
    fun `a reused connection that started answering is not sent again`() {
        CrtRawServer(null) { p ->
            p.readRequest()
            p.write(crtOk(CRT_ACTIVE))
            p.readRequest()
            p.write(crtLatin1("HTTP/1.1 100 Continue\r\n\r\n")) // 그리고 닫는다
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { assertTrue(auth.introspect("tok").active) }
            assertFailsWith<KeycloakTransportException> { runBlocking { auth.introspect("tok") } }
            assertEquals(1, server.accepted.get())
            assertEquals(2, server.requests.size)
        }
    }

    // 다시 쓴 연결의 읽기 타임아웃은 다시 보내지 않는다 — 서버가 받아 처리하는 중일 수 있다. 실패는 그 타임아웃 한 번이다.
    @Test
    fun `a timeout on a reused connection is not sent again`() {
        CrtRawServer(null) { p ->
            p.readRequest()
            p.write(crtOk(CRT_ACTIVE))
            p.readRequest()
            Thread.sleep(5_000)
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}", readTimeout = Duration.ofSeconds(1))
            runBlocking { assertTrue(auth.introspect("tok").active) }
            val e = assertFailsWith<KeycloakTransportException> { runBlocking { auth.introspect("tok") } }
            assertIs<SocketTimeoutException>(e.cause)
            assertEquals(1, server.accepted.get())
            assertEquals(2, server.requests.size)
        }
    }

    // 경로의 연결 50 개가 모두 쓰이는 동안 연결 타임아웃(1 초)이 지나면, 연결을 기다리던 호출은 JDK 의 타임아웃이다(응답과 무관한 상수
    // 메시지 — 연결을 빌리지 못했으니 끊을 것도 없다). 연결을 쥔 호출들은 그대로 끝난다.
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a call that cannot get a pooled connection times out after the connect timeout`() {
        val busy = CountDownLatch(CRT_MAX_PER_ROUTE)
        CrtRawServer(null) { p ->
            p.readRequest()
            busy.countDown()
            Thread.sleep(3_000)
            p.write(crtOk(CRT_ACTIVE))
        }.use { server ->
            val base = "http://127.0.0.1:${server.port}"
            val holder = crtAuth(base, readTimeout = Duration.ofSeconds(10))
            runBlocking {
                val holders = (1..CRT_MAX_PER_ROUTE).map { async(Dispatchers.Default) { holder.introspect("tok").active } }
                assertTrue(busy.await(10, TimeUnit.SECONDS), "연결 50 개가 차지 않았다")
                val waiting = crtAuth(base, Duration.ofSeconds(1), Duration.ofSeconds(10))
                val start = System.nanoTime()
                val e = assertFailsWith<KeycloakTransportException> { waiting.introspect("tok") }
                val millis = crtElapsedMillis(start)
                assertIs<SocketTimeoutException>(e.cause)
                assertEquals(CRT_POOL_TIMEOUT, e.cause?.message)
                assertTrue(millis in 900 until 2_900, "$millis ms")
                assertTrue(holders.awaitAll().all { it })
            }
            assertEquals(CRT_MAX_PER_ROUTE, server.accepted.get())
            assertEquals(0, crtLeased())
        }
    }

    // 2 초 넘게 쉰 연결은 빌려줄 때 살아 있는지 본다 — 서버가 반쯤 닫은(보내기만 닫고 받기는 연) 연결에 요청을 보내지 않고 새 연결을
    // 맺는다. 서버는 반쯤 닫은 연결에서 요청을 받지 않는다.
    @Test
    fun `a connection idle longer than the validation window is checked before reuse`() {
        CrtRawServer(null) { p ->
            if (p.index == 1) {
                p.readRequest()
                p.write(crtOk(CRT_ACTIVE))
                p.socket.shutdownOutput()
                p.readRequest() // 들어오면 적힌다 — 들어오면 안 된다
                return@CrtRawServer
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            runBlocking { assertTrue(auth.introspect("tok").active) }
            Thread.sleep(CRT_VALIDATE_AFTER_MILLIS + 300L)
            runBlocking { assertTrue(auth.introspect("tok").active) }
            assertEquals(listOf("1 POST", "2 POST"), server.connectionsAndMethods())
        }
    }

    // 쉬는 연결의 수명(5 초)은 스레드 없이 지킨다 — 수명이 지난 연결은 다음 교환(어느 경로든)이 닫는다. 그 전에는 아무것도 닫지 않는다
    // (백그라운드 스레드가 없다). 서버가 Keep-Alive 를 주지 않으면 HttpClient 의 기본은 무한이다. ⚠️ Java 와 달리 송신을 호출 스레드에서
    // 바로 부른다 — AuthClient 의 suspend 호출은 Dispatchers.IO 의 일꾼 스레드를 만들어 「운송이 스레드를 만들었다」를 가린다.
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `an expired idle connection is closed by the next exchange without a thread`() {
        val closedAt = AtomicLong()
        CrtRawServer(null) { p ->
            p.serveAll(crtOk(CRT_ACTIVE))
            closedAt.set(System.nanoTime())
        }.use { a ->
            CrtRawServer(null) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { b ->
                assertEquals(200, crtPost("http://127.0.0.1:${a.port}/token", null, null, 5_000).sendCapped().statusCode)
                val before = crtThreadNames()
                Thread.sleep(CRT_IDLE_MILLIS + 300L)
                assertEquals(0L, closedAt.get(), "수명이 지났어도 교환이 없으면 아무것도 닫지 않는다(스레드가 없다)")
                val exchange = System.nanoTime()
                assertEquals(200, crtPost("http://127.0.0.1:${b.port}/token", null, null, 5_000).sendCapped().statusCode)
                for (i in 0 until 50) {
                    if (closedAt.get() != 0L) break
                    Thread.sleep(20)
                }
                assertNotEquals(0L, closedAt.get(), "다음 교환이 수명이 지난 연결을 닫지 않았다")
                assertTrue(closedAt.get() >= exchange)
                val created = crtThreadNames()
                created.removeAll(before)
                created.removeIf { it.startsWith("reuse-raw-") }
                assertEquals(emptySet(), created, "운송이 스레드를 만들었다")
            }
        }
    }

    // 교환 중의 Error(여기서는 검증기가 던진 AssertionError)는 그대로 나가고 풀을 닫지 않는다 — HttpClient 는 그때 관리자를 닫는데, 이
    // 풀은 프로세스에 하나라 그러면 이 JVM 의 auth·JWKS 레인이 끝난다. 그 교환이 쥔 연결은 돌아가지 않고 끊긴다.
    @Test
    fun `an Error inside an exchange does not shut the pool down`() {
        CrtRawServer(TransportTestTls.serverOther) { it.serveAll(crtOk(CRT_ACTIVE)) }.use { server ->
            val url = "https://127.0.0.1:${server.port}/token"
            val throwing = HostnameVerifier { _, _ -> throw AssertionError("검증기 실패") }
            assertFailsWith<AssertionError> { crtPost(url, TransportTestTls.trusting, throwing, 5_000).sendCapped() }
            assertEquals(0, crtLeased())
            assertEquals(200, crtPost(url, TransportTestTls.trusting, CRT_ACCEPTS_LOOPBACK, 5_000).sendCapped().statusCode)
        }
    }

    // TLS 단계의 런타임 예외는 그대로 나가고 — HttpURLConnection 도 같은 예외를 그대로 냈다 — 그 TLS 소켓은 넘기기 전에 닫힌다(Java 의
    // SonarCloud S2095 수정): 그 TLS 소켓은 연결에 묶이기 전이라 HttpClient 는 그 객체를 닫지 않는다. 두 자리 — 핸드셰이크 뒤 검증기가 던진
    // IllegalStateException · 핸드셰이크 전 https.protocols 의 없는 규약에 setEnabledProtocols 가 던진 IllegalArgumentException.
    // ⚠️ 서버가 보는 끝으로는 닫기를 지운 변이(k04)를 못 잡는다 — 그 아래 평문 소켓은 connectSocket 전에 연결에 묶여 교환의 abort 가
    // SO_LINGER 0 으로 끊는다(k04 실측: 평문 소켓 닫힘 · 서버는 「Connection reset」 · TLS 소켓 객체는 열림). 그래서 시험이 TLS 소켓을 쥐고 본다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a RuntimeException in the TLS stage passes through and closes the TLS socket`() {
        val rejects = HostnameVerifier { _, _ -> throw IllegalStateException("검증기 실패") }
        tlsStageFailure("검증기", emptyMap(), rejects) { e -> e is IllegalStateException && e.message == "검증기 실패" }
        tlsStageFailure("https.protocols", mapOf("https.protocols" to "TLSv9"), CRT_ACCEPTS_LOOPBACK) { e -> e is IllegalArgumentException }
    }

    private fun tlsStageFailure(
        label: String,
        properties: Map<String, String>,
        verifier: HostnameVerifier,
        expected: (Throwable) -> Boolean,
    ) {
        val ended = CountDownLatch(1)
        CrtRawServer(TransportTestTls.serverOther) { p ->
            if (p.index == 1) {
                try {
                    p.readRequest() // 클라이언트가 닫으면 null 이나 예외로 끝난다
                } finally {
                    ended.countDown()
                }
                return@CrtRawServer
            }
            p.serveAll(crtOk(CRT_ACTIVE))
        }.use { server ->
            val url = "https://127.0.0.1:${server.port}/token"
            val recording = CrtRecordingFactory(TransportTestTls.trusting)
            val thrown =
                crtWithProperties(properties) { runCatching { crtPost(url, recording, verifier, 5_000).sendCapped() }.exceptionOrNull() }
            println("[ConnectionReuseTest] TLS 단계의 런타임 예외($label) → $thrown · 만든 TLS 소켓 ${recording.created.map { it.isClosed }}")
            assertTrue(thrown != null && expected(thrown), "$label: $thrown")
            assertEquals(listOf(true), recording.created.map { it.isClosed }, "$label: 넘기지 못한 TLS 소켓이 열린 채 남았다")
            if (properties.isEmpty()) assertTrue(ended.await(5, TimeUnit.SECONDS), "$label: 서버가 연결의 끝을 보지 못했다")
            assertEquals(0, crtLeased())
            assertEquals(200, crtPost(url, TransportTestTls.trusting, CRT_ACCEPTS_LOOPBACK, 5_000).sendCapped().statusCode)
        }
    }

    // ───────────── 소켓 타임아웃 — 풀의 소켓 설정이 아니라 교환의 읽기 타임아웃 ─────────────

    // TCP 는 받지만 TLS 핸드셰이크에 답하지 않는 서버 — 교환의 읽기 타임아웃(1 초)에 끝난다.
    @Test
    @Timeout(value = 15, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a stalled TLS handshake is bounded by the read timeout`() {
        CrtRawServer(null) { Thread.sleep(20_000) }.use { silent ->
            val start = System.nanoTime()
            val e =
                assertFailsWith<IOException> {
                    crtPost("https://127.0.0.1:${silent.port}/token", TransportTestTls.trusting, CRT_ACCEPTS_LOOPBACK, 1_000).sendCapped()
                }
            val millis = crtElapsedMillis(start)
            assertIs<SocketTimeoutException>(e)
            assertTrue(millis < 5_000, "$millis ms")
        }
    }

    // CONNECT 를 받고 답하지 않는 프록시 — 교환의 읽기 타임아웃(1 초)에 끝난다.
    @Test
    @Timeout(value = 15, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a stalled proxy CONNECT is bounded by the read timeout`() {
        CrtRawServer(null) { p ->
            p.readRequest()
            Thread.sleep(20_000)
        }.use { proxy ->
            crtWithProperties(mapOf("https.proxyHost" to "127.0.0.1", "https.proxyPort" to proxy.port.toString())) {
                val start = System.nanoTime()
                val e =
                    assertFailsWith<IOException> {
                        crtPost("https://kc.invalid/token", TransportTestTls.trusting, CRT_ACCEPTS_LOOPBACK, 1_000).sendCapped()
                    }
                val millis = crtElapsedMillis(start)
                assertIs<SocketTimeoutException>(e)
                assertTrue(millis < 5_000, "$millis ms")
                assertTrue(proxy.requests[0].endsWith("CONNECT kc.invalid:443 HTTP/1.1"), proxy.requests.toString())
            }
        }
    }

    // ───────────── 조용한 TLS 서버 앞의 거부 — 닫기가 기다리지 않는다 ─────────────

    // TLS 1.3 을 닫을 때 JSSE 는 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다린다 — 거부한 뒤 조용한(닫지도 않는) 서버 앞에서
    // 그만큼 늦었다(Java 실측 8,025 ms · 12,206 ms). 거부의 세 자리가 읽기 타임아웃(8 초)을 기다리지 않는다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a reject against a silent TLS server does not wait for the read timeout`() {
        val slow = mutableListOf<String>()
        // 상태 줄이 아닌 첫 줄 뒤 조용하다 — 머리 단계의 거부(실행기)
        rejectFast(slow, "머리 단계", TransportTestTls.serverIp, CRT_ACCEPTS_LOOPBACK, { p ->
            p.readRequest()
            p.write(crtLatin1("HTTP/1.1 abc Weird\r\n"))
            Thread.sleep(20_000)
        }, CRT_INVALID_RESPONSE)
        // 상한보다 긴 본문을 알리고 상한+1 바이트 뒤 조용하다 — 본문 단계의 거부(교환의 끝)
        rejectFast(slow, "상한+1 뒤 멈춤", TransportTestTls.serverIp, CRT_ACCEPTS_LOOPBACK, { p ->
            p.readRequest()
            p.write(crtLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${CRT_CAP + 10}\r\n\r\n"))
            p.write(ByteArray(CRT_CAP + 1))
            Thread.sleep(20_000)
        }, "token response exceeds 1048576 bytes")
        // 핸드셰이크 뒤 아무것도 보내지도 읽지도 않는다(세션 티켓도 없다) — 검증기의 거부(HttpURLConnection 의 checkURLSpoofing)
        rejectFast(
            slow,
            "검증기 거부",
            TransportTestTls.serverOtherWithoutTickets,
            CRT_REJECTS,
            { Thread.sleep(20_000) },
            "HTTPS hostname wrong:  should be <127.0.0.1>",
        )
        assertTrue(slow.isEmpty(), slow.joinToString("\n"))
    }

    private fun rejectFast(
        slow: MutableList<String>,
        label: String,
        tls: SSLContext,
        verifier: HostnameVerifier,
        handler: CrtHandler,
        message: String,
    ) {
        CrtRawServer(tls, handler).use { server ->
            val start = System.nanoTime()
            val e =
                assertFailsWith<IOException>(label) {
                    crtPost("https://127.0.0.1:${server.port}/token", TransportTestTls.trusting, verifier, 8_000).sendCapped()
                }
            val millis = crtElapsedMillis(start)
            println("[ConnectionReuseTest] 조용한 TLS 서버 · $label → $e · $millis ms (읽기 타임아웃 8,000)")
            assertEquals(message, e.message, label)
            if (millis >= 4_000) slow += "$label: $millis ms"
        }
    }

    // 본문 중간에서 멈춘 서버 — 읽기 타임아웃(2 초)에 한 번 끝나고, 그 연결을 닫으며 한 번 더 기다리지 않는다(JSSE 가 닫기에서 읽기
    // 타임아웃을 또 기다리면 4 초였다).
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a body stalled midway times out once`() {
        CrtRawServer(TransportTestTls.serverIp) { p ->
            p.readRequest()
            p.write(crtLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{\"acti"))
            Thread.sleep(20_000)
        }.use { server ->
            val start = System.nanoTime()
            val e =
                assertFailsWith<IOException> {
                    crtPost("https://127.0.0.1:${server.port}/token", TransportTestTls.trusting, CRT_ACCEPTS_LOOPBACK, 2_000).sendCapped()
                }
            val millis = crtElapsedMillis(start)
            println("[ConnectionReuseTest] 본문 중간에서 멈춘 TLS 서버 → $e · $millis ms (읽기 타임아웃 2,000)")
            assertIs<SocketTimeoutException>(e)
            assertTrue(millis < 3_500, "$millis ms")
        }
    }

    // ───────────── 코루틴 취소 (Kotlin) — runInterruptible 의 인터럽트는 풀의 기다림만 끊는다 ─────────────

    // 경로의 50 자리를 쥔 동안 연결을 기다리던 호출 60 개를 취소한다 — 기다림은 인터럽트로 곧바로 끝나고(연결을 빌리지 않았다), 빌린 연결은
    // 쥔 50 개뿐이며, 그 50 이 돌아온 뒤에는 0 이고 다시 쓰인다(연결 50 개 그대로). 쥐는 쪽은 플랫폼 스레드 50 개다 — Dispatchers.IO 의
    // 일꾼(64)은 기다리는 60 개에 남긴다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `cancelled calls waiting for a pooled connection leave nothing leased`() {
        val busy = CountDownLatch(CRT_MAX_PER_ROUTE)
        val release = CountDownLatch(1)
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                busy.countDown()
                check(release.await(30, TimeUnit.SECONDS)) { "시험이 자리를 풀지 않았다" }
                p.write(crtOk(CRT_ACTIVE))
            }
        }.use { server ->
            val base = "http://127.0.0.1:${server.port}"
            val waiting = crtAuth(base, Duration.ofSeconds(20), Duration.ofSeconds(20))
            val held = crtConcurrently(CRT_MAX_PER_ROUTE) { crtPost("$base/token", null, null, 30_000).sendCapped().statusCode }
            try {
                assertTrue(busy.await(10, TimeUnit.SECONDS), "연결 50 개가 차지 않았다")
                val outcomes = CopyOnWriteArrayList<String>()
                val millis =
                    runBlocking {
                        val waiters =
                            (1..60).map {
                                launch(Dispatchers.Default) {
                                    try {
                                        waiting.introspect("tok")
                                        outcomes += "returned"
                                    } catch (e: CancellationException) {
                                        outcomes += "cancelled"
                                        throw e
                                    } catch (e: Throwable) {
                                        outcomes += e.toString()
                                    }
                                }
                            }
                        delay(500) // 기다리는 자리에 닿게
                        assertEquals(CRT_MAX_PER_ROUTE, crtLeased(), "기다리는 호출이 연결을 빌렸다")
                        val start = System.nanoTime()
                        waiters.forEach { it.cancel() }
                        waiters.joinAll()
                        crtElapsedMillis(start)
                    }
                println("[ConnectionReuseTest] 연결을 기다리던 60 호출 취소 → $millis ms · 결말 ${outcomes.groupingBy { it }.eachCount()}")
                assertEquals(List(60) { "cancelled" }, outcomes.toList())
                assertTrue(millis < 2_000, "취소가 풀의 기다림을 끊지 못했다 — $millis ms")
                assertEquals(CRT_MAX_PER_ROUTE, crtLeased())
                release.countDown()
                held.forEach { assertEquals(200, it.get(20, TimeUnit.SECONDS)) }
            } finally {
                release.countDown()
                crtCancelAll(held)
            }
            assertEquals(0, crtLeased())
            runBlocking { repeat(10) { assertTrue(waiting.introspect("tok").active) } }
            assertEquals(CRT_MAX_PER_ROUTE, server.accepted.get(), "취소한 호출이 연결을 열었거나 돌아온 연결이 다시 쓰이지 않았다")
            assertEquals(0, crtLeased())
        }
    }

    // 소켓을 읽는 중인 호출 40 개를 취소한다 — 플랫폼 스레드의 블로킹 읽기는 인터럽트를 무시하므로 교환은 끝까지 가고(본문을 EOF 까지 읽어
    // 연결이 풀로 돌아간다), 취소는 그 뒤에 CancellationException 으로 나온다. 빌린 연결은 0 이고, 그 40 개가 다음 호출에 다시 쓰인다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `cancelled calls mid-exchange leave nothing leased and their connections are reused`() {
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                Thread.sleep(500)
                p.write(crtOk(CRT_ACTIVE))
            }
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}")
            val cancelled = AtomicInteger()
            runBlocking {
                val calls =
                    (1..40).map {
                        launch(Dispatchers.Default) {
                            try {
                                auth.introspect("tok")
                            } catch (e: CancellationException) {
                                cancelled.incrementAndGet()
                                throw e
                            }
                        }
                    }
                delay(150)
                calls.forEach { it.cancel() }
                calls.joinAll()
            }
            assertEquals(40, cancelled.get())
            assertEquals(0, crtLeased())
            assertEquals(40, server.accepted.get())
            runBlocking { (1..40).map { async(Dispatchers.Default) { auth.introspect("tok").active } }.awaitAll() }
            assertEquals(40, server.accepted.get(), "취소된 교환의 연결이 다시 쓰이지 않았다")
            assertEquals(0, crtLeased())
        }
    }

    // 아무 때나 취소한다 — 호출 300 개를 시차를 두고 띄우고 0–20 ms 뒤 취소한다(어떤 것은 연결을 기다리는 중, 어떤 것은 연결을 빌린 직후,
    // 어떤 것은 읽는 중). 끝나면 빌린 연결은 0 이고 열린 연결은 경로의 상한 안이다.
    @Test
    @Timeout(value = 90, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `cancellations at any moment never leave a connection leased`() {
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                Thread.sleep(Random.nextLong(0, 6))
                p.write(crtOk(CRT_ACTIVE))
            }
        }.use { server ->
            val auth = crtAuth("http://127.0.0.1:${server.port}", Duration.ofSeconds(5), Duration.ofSeconds(5))
            val ends = CopyOnWriteArrayList<String>()
            runBlocking {
                val calls =
                    (1..300).map {
                        // ATOMIC — 시작 전에 취소돼도 본문이 돈다(첫 중단점에서 취소를 본다): 결말이 300 개 다 적힌다
                        launch(Dispatchers.Default, start = CoroutineStart.ATOMIC) {
                            try {
                                auth.introspect("tok")
                                ends += "returned"
                            } catch (e: CancellationException) {
                                ends += "cancelled"
                                throw e
                            } catch (e: Throwable) {
                                ends += e.javaClass.simpleName + "(" + e.cause + ")"
                            }
                        }.also { job ->
                            launch {
                                delay(Random.nextLong(0, 21))
                                job.cancel()
                            }
                        }
                    }
                calls.joinAll()
            }
            println(
                "[ConnectionReuseTest] 아무 때나 취소한 300 호출 → ${ends.groupingBy {
                    it
                }.eachCount()} · 연결 ${server.accepted} · 동시 최고 ${server.peakOpen}",
            )
            assertEquals(300, ends.size)
            assertTrue(ends.all { it == "returned" || it == "cancelled" }, ends.filter { it != "returned" && it != "cancelled" }.toString())
            assertEquals(0, crtLeased())
            assertTrue(server.peakOpen.get() <= CRT_MAX_PER_ROUTE, "동시 연결 ${server.peakOpen}")
        }
    }

    // JWKS 조회 중에 인터럽트된 호출자 — 조회는 제 스레드에서 끝까지 가고 호출자는 그 결과를 받으며, 인터럽트 표시는 남는다(Java
    // JwksCancellationTest 의 계약 · 아래 창 사례의 바탕). 서버가 /certs 를 500 ms 늦게 답하는 동안 100 ms 에 인터럽트한다.
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a JWKS fetch whose caller is interrupted still returns its result and keeps the interrupt flag`() {
        val jwks = """{"keys":[{"kty":"oct","kid":"k1","k":"AAAA"}]}""".toByteArray()
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                Thread.sleep(500)
                p.write(crtOk(jwks))
            }
        }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val outcome = AtomicReference<String>()
            val caller =
                Thread {
                    val r = runCatching { NoRedirectResourceRetriever(2_000, 5_000).retrieveResource(certs) }
                    outcome.set("${r.map { it.content.length }} · 인터럽트 ${Thread.currentThread().isInterrupted}")
                }
            caller.start()
            Thread.sleep(100)
            caller.interrupt()
            caller.join(10_000)
            println("[ConnectionReuseTest] 인터럽트된 JWKS 호출자 → ${outcome.get()}")
            assertEquals("Success(${jwks.size}) · 인터럽트 true", outcome.get())
            assertEquals(0, crtLeased())
        }
    }

    // 같은 계약의 실패 쪽 — 늦게 끝난 조회가 실패(503)해도 호출자는 그 실패를 그대로 받고 인터럽트 표시는 남는다(되살리기가 성공의 길에만
    // 있으면 이 사례가 깨진다). 실패한 조회는 지금처럼 실패로 올라간다(창을 쓴다 — 의도된 동작).
    @Test
    @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a JWKS fetch whose caller is interrupted still reports its failure and keeps the interrupt flag`() {
        CrtRawServer(null) { p ->
            while (p.readRequest() != null) {
                Thread.sleep(500)
                p.write(crtLatin1("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"))
            }
        }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val outcome = AtomicReference<String>()
            val caller =
                Thread {
                    val r = runCatching { NoRedirectResourceRetriever(2_000, 5_000).retrieveResource(certs) }
                    outcome.set("${r.exceptionOrNull()} · 인터럽트 ${Thread.currentThread().isInterrupted}")
                }
            caller.start()
            Thread.sleep(100)
            caller.interrupt()
            caller.join(10_000)
            println("[ConnectionReuseTest] 인터럽트된 JWKS 호출자(조회 실패) → ${outcome.get()}")
            assertEquals("java.io.IOException: JWKS endpoint returned HTTP 503 · 인터럽트 true", outcome.get())
            assertEquals(0, crtLeased())
        }
    }

    // 취소가 JWKS 강제 재조회 창을 버리지 않는다 — 경로의 50 자리가 다 쓰이는 동안 회전한 키(k2)의 검증이 강제 재조회를 정하고(Nimbus 는
    // 그때 창의 크레딧을 쓴다) 연결을 기다리다 취소돼도, 그 조회는 끝까지 가서 캐시를 채운다: 자리가 풀린 뒤 k2 검증은 /certs 를 더 치지
    // 않고 성공한다. HttpURLConnection 은 플랫폼 스레드의 읽기라 인터럽트를 무시했다(등록부 jwks-forced-refetch-window-burned 「kotlin 은
    // 해당 없음」) — 풀의 기다림은 인터럽트에 끝나므로 그 판정이 이 운송에서 다시 서야 한다. 창은 240 초라 시험 동안 다시 열리지 않는다.
    @Test
    @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
    fun `a validation cancelled while its forced JWKS refetch waits for a pooled connection still fills the cache`() {
        val k1 = RSAKeyGenerator(2048).keyID("k1").generate()
        val k2 = RSAKeyGenerator(2048).keyID("k2").generate()
        val served = AtomicReference(JWKSet(k1.toPublicJWK()))
        val certs = AtomicInteger()
        val busy = CountDownLatch(CRT_MAX_PER_ROUTE)
        val release = CountDownLatch(1)
        CrtRawServer(null) { p ->
            while (true) {
                val line = p.readRequest() ?: break
                if (line.contains("/certs")) {
                    certs.incrementAndGet()
                    p.write(crtOk(served.get().toString().toByteArray()))
                } else {
                    busy.countDown()
                    check(release.await(30, TimeUnit.SECONDS)) { "시험이 자리를 풀지 않았다" }
                    p.write(crtOk(CRT_ACTIVE))
                }
            }
        }.use { server ->
            val base = "http://127.0.0.1:${server.port}"
            val config =
                KeycloakConfig(
                    base,
                    "r",
                    "app",
                    "s3cr3t".toCharArray(),
                    connectTimeout = Duration.ofSeconds(20),
                    readTimeout = Duration.ofSeconds(20),
                    jwksMinRefetch = Duration.ofSeconds(240),
                )
            val issuer = "$base/realms/r"
            val validator = JwtValidator.forRealm(OidcEndpoints.forRealm(config), config, "app")
            runBlocking { assertEquals("u1", validator.validate(crtSigned(k1, issuer)).subject) } // 캐시를 k1 로 데운다
            assertEquals(1, certs.get())
            served.set(JWKSet(listOf(k1.toPublicJWK(), k2.toPublicJWK())))
            val held = crtConcurrently(CRT_MAX_PER_ROUTE) { crtPost("$base/token", null, null, 30_000).sendCapped().statusCode }
            try {
                assertTrue(busy.await(10, TimeUnit.SECONDS), "연결 50 개가 차지 않았다")
                val ended = AtomicReference<String>()
                runBlocking {
                    val job =
                        launch(Dispatchers.Default) {
                            try {
                                validator.validate(crtSigned(k2, issuer))
                                ended.set("returned")
                            } catch (e: CancellationException) {
                                ended.set("cancelled")
                                throw e
                            } catch (e: Throwable) {
                                ended.set(e.toString())
                            }
                        }
                    delay(500) // 강제 재조회가 연결을 기다리는 자리에 닿게
                    job.cancel()
                    delay(300)
                    release.countDown() // 자리를 푼다 — 조회가 살아 있으면 이제 연결을 빌린다
                    job.join()
                }
                held.forEach { assertEquals(200, it.get(20, TimeUnit.SECONDS)) }
                println("[ConnectionReuseTest] 연결을 기다리던 강제 재조회 취소 → ${ended.get()} · /certs ${certs.get()}")
                assertEquals("cancelled", ended.get())
            } finally {
                release.countDown()
                crtCancelAll(held)
            }
            val after = runCatching { runBlocking { validator.validate(crtSigned(k2, issuer)).subject } }
            println("[ConnectionReuseTest] 취소 뒤 k2 검증 → $after · /certs ${certs.get()}")
            assertEquals("u1", after.getOrNull(), "취소가 창을 버렸다 — 회전한 키가 창이 닫힐 때까지 거부된다: $after")
            assertEquals(2, certs.get(), "강제 재조회는 한 번이어야 한다")
            assertEquals(0, crtLeased())
        }
    }
}

private fun crtSigned(
    key: RSAKey,
    issuer: String,
): String {
    val claims =
        JWTClaimsSet
            .Builder()
            .issuer(issuer)
            .audience("app")
            .subject("u1")
            .issueTime(Date())
            .expirationTime(Date(System.currentTimeMillis() + 60_000))
            .build()
    val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(), claims)
    jwt.sign(RSASSASigner(key))
    return jwt.serialize()
}
