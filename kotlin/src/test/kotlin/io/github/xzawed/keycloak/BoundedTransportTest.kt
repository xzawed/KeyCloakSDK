package io.github.xzawed.keycloak

import org.apache.http.HttpClientConnection
import org.apache.http.HttpConnectionMetrics
import org.apache.http.HttpHost
import org.apache.http.MalformedChunkCodingException
import org.apache.http.MessageConstraintException
import org.apache.http.NoHttpResponseException
import org.apache.http.ProtocolException
import org.apache.http.client.ClientProtocolException
import org.apache.http.config.ConnectionConfig
import org.apache.http.conn.ConnectTimeoutException
import org.apache.http.conn.ConnectionPoolTimeoutException
import org.apache.http.conn.HttpHostConnectException
import org.apache.http.conn.routing.HttpRoute
import org.apache.http.impl.HttpConnectionMetricsImpl
import org.apache.http.impl.conn.ConnectionShutdownException
import org.apache.http.impl.execchain.RequestAbortedException
import org.apache.http.protocol.HttpContext
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.lang.ref.WeakReference
import java.lang.reflect.Proxy
import java.net.ConnectException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLSocketFactory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

// BoundedTransport 의 작은 규칙들 — 예외 보호막·제한 헤더·HttpURLConnection 의 기본 요청 머리·틀 예산 스트림·풀의 쉬는 수명과 연결
// 표식. 네트워크가 없다(연결의 「묻지 않은 바이트」 사례만 루프백 소켓 하나를 쓴다). Java `BoundedTransportTest` 의 이식이다.
private const val BT_MARKER = "ZshieldMARKER"

// 지표와 읽기 타임아웃만 아는 연결 — 나머지 메서드는 부르면 실패한다.
private fun btConnection(
    received: () -> Long,
    timeouts: MutableList<Int>,
): HttpClientConnection {
    val metrics: HttpConnectionMetrics =
        object : HttpConnectionMetricsImpl(null, null) {
            override fun getReceivedBytesCount(): Long = received()
        }
    return Proxy.newProxyInstance(
        HttpClientConnection::class.java.classLoader,
        arrayOf(HttpClientConnection::class.java),
    ) { _, method, args ->
        when (method.name) {
            "getMetrics" -> metrics
            "setSocketTimeout" -> {
                timeouts += args[0] as Int
                null
            }
            else -> throw UnsupportedOperationException(method.name)
        }
    } as HttpClientConnection
}

// 정체만 다른 팩토리 — 같은 일을 하지만 다른 객체다.
private class BtFactory(
    private val delegate: SSLSocketFactory,
) : SSLSocketFactory() {
    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(
        s: Socket,
        host: String,
        port: Int,
        autoClose: Boolean,
    ): Socket = delegate.createSocket(s, host, port, autoClose)

    override fun createSocket(
        host: String,
        port: Int,
    ): Socket = delegate.createSocket(host, port)

    override fun createSocket(
        host: String,
        port: Int,
        local: InetAddress,
        localPort: Int,
    ): Socket = delegate.createSocket(host, port, local, localPort)

    override fun createSocket(
        host: InetAddress,
        port: Int,
    ): Socket = delegate.createSocket(host, port)

    override fun createSocket(
        host: InetAddress,
        port: Int,
        local: InetAddress,
        localPort: Int,
    ): Socket = delegate.createSocket(host, port, local, localPort)
}

// 잡는 것이 없는 람다는 JVM 이 호출 자리마다 하나를 캐시해 수거되지 않는다 — 수거 시험의 검증기는 새 객체여야 한다.
private class BtVerifier(
    private val host: String,
) : HostnameVerifier {
    override fun verify(
        hostname: String?,
        session: javax.net.ssl.SSLSession?,
    ): Boolean = hostname == host
}

internal class BoundedTransportTest {
    // JDK 의 예외(그리고 SDK 의 것)는 그대로 — 같은 인스턴스다.
    @Test
    fun `shield keeps the JDK's own exceptions`() {
        for (e in listOf(
            SocketTimeoutException("Read timed out"),
            ConnectException("refused"),
            IOException("plain"),
            ResponseTooLargeException("token response"),
        )) {
            assertSame(e, BoundedTransport.shield(e))
        }
    }

    // HttpClient 가 JDK 의 연결 실패를 감싼 것 — HttpURLConnection 이 던지는 바로 그 원인을 돌려준다.
    @Test
    fun `shield unwraps the connect failures HttpClient wraps`() {
        val host = HttpHost("127.0.0.1", 1)
        val refused = ConnectException("Connection refused")
        val timedOut = SocketTimeoutException("Connect timed out")
        val loopback = InetAddress.getLoopbackAddress()
        assertSame(refused, BoundedTransport.shield(HttpHostConnectException(refused, host, loopback)))
        assertSame(timedOut, BoundedTransport.shield(ConnectTimeoutException(timedOut, host, loopback)))
    }

    // 틀 오류는 상수 메시지 — 응답의 줄을 싣지 않고 원인도 달지 않는다. 한도 초과는 그렇다고 말한다.
    @Test
    fun `shield replaces framing failures with constant messages`() {
        val quoting =
            listOf(
                MalformedChunkCodingException("Bad chunk header: $BT_MARKER"),
                ClientProtocolException(ProtocolException("Invalid header: $BT_MARKER")),
                NoHttpResponseException(BT_MARKER),
            )
        for (e in quoting) {
            val shielded = BoundedTransport.shield(e)
            assertEquals<Class<*>>(IOException::class.java, shielded.javaClass)
            assertEquals(BoundedTransport.INVALID_RESPONSE, shielded.message)
            assertNull(shielded.cause)
        }
        val limit = BoundedTransport.shield(MessageConstraintException("Maximum line length limit exceeded"))
        assertEquals(BoundedTransport.OVER_LIMITS, limit.message)
        assertEquals("HTTP response framing exceeds 8192-byte lines or 100 header fields", limit.message)
    }

    // 풀의 기다림이 끝난 것 — 응답과 무관한 JDK 의 타임아웃·인터럽트 예외로(원인을 달지 않는다).
    @Test
    fun `shield maps pool waits to the JDK's timeout and interrupt`() {
        val timedOut = BoundedTransport.shield(ConnectionPoolTimeoutException("Timeout waiting for connection from pool"))
        assertEquals<Class<*>>(SocketTimeoutException::class.java, timedOut.javaClass)
        assertEquals(BoundedTransport.POOL_TIMEOUT, timedOut.message)
        val interrupted = BoundedTransport.shield(RequestAbortedException("Request aborted", InterruptedException()))
        assertEquals<Class<*>>(InterruptedIOException::class.java, interrupted.javaClass)
        assertEquals(BoundedTransport.INTERRUPTED, interrupted.message)
        assertNull(interrupted.cause)
    }

    // HttpURLConnection 의 제한 헤더 — `Connection: close` 만 예외, `Sec-*` 는 버린다. 대소문자는 가리지 않는다.
    @Test
    fun `restricted follows HttpURLConnection`() {
        for (name in listOf(
            "Content-Length",
            "host",
            "TRANSFER-ENCODING",
            "Origin",
            "Keep-Alive",
            "Via",
            "Upgrade",
            "Trailer",
            "Content-Transfer-Encoding",
            "Access-Control-Request-Method",
            "Access-Control-Request-Headers",
            "Sec-Fetch-Mode",
        )) {
            assertTrue(BoundedTransport.restricted(name, "x"), name)
        }
        assertTrue(BoundedTransport.restricted("Connection", "keep-alive"))
        assertFalse(BoundedTransport.restricted("Connection", "Close"))
        for (name in listOf("Authorization", "Content-Type", "Accept", "User-Agent", "Cookie", "DPoP")) {
            assertFalse(BoundedTransport.restricted(name, "x"), name)
        }
    }

    // Host 는 기본 포트를 적지 않는다 — HttpClient 는 URL 에 적힌 포트를 그대로 싣는다.
    @Test
    fun `hostHeader omits the default port`() {
        assertEquals("kc.example", BoundedTransport.hostHeader(URI("https://kc.example/x").toURL()))
        assertEquals("kc.example", BoundedTransport.hostHeader(URI("https://kc.example:443/x").toURL()))
        assertEquals("kc.example", BoundedTransport.hostHeader(URI("http://kc.example:80/x").toURL()))
        assertEquals("kc.example:8443", BoundedTransport.hostHeader(URI("https://kc.example:8443/x").toURL()))
    }

    // User-Agent·Accept 는 HttpURLConnection 의 값 — http.agent 가 있으면 앞에 붙고, Accept 는 JDK 판을 따른다.
    @Test
    fun `jdk defaults mirror HttpURLConnection`() {
        assertEquals("Java/21.0.1", BoundedTransport.userAgent(null, "21.0.1"))
        assertEquals("probe/1 Java/21.0.1", BoundedTransport.userAgent("probe/1", "21.0.1"))
        assertEquals("*/*", BoundedTransport.acceptFor(21))
        assertEquals("*/*", BoundedTransport.acceptFor(25))
        assertEquals("text/html, image/gif, image/jpeg, */*; q=0.2", BoundedTransport.acceptFor(17))
    }

    // 틀의 바이트 예산 — 읽기 한 번이 소켓에 요청하는 길이를 자르고(HttpCore 는 큰 요청을 버퍼 없이 소켓에서 바로 읽는다 — Java 의 Grok 레그 2
    // 지적), 그 사이 받은 바이트가 예산을 넘으면 상수 메시지로 거부하며 연결의 읽기 타임아웃을 0 으로 둔다(곧 닫힐 TLS 연결에서 JSSE 가 더
    // 읽지 않게). 예산 안은 그대로 지나간다.
    @Test
    fun `wireBounded caps each read and refuses over budget`() {
        var received = 0L
        var largestAsk = 0
        val socket =
            object : InputStream() {
                override fun read(): Int {
                    received++
                    return 'x'.code
                }

                override fun read(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ): Int {
                    largestAsk = maxOf(largestAsk, len)
                    received += len // 소켓에서 바로 읽은 것처럼 — 요청한 만큼 받는다
                    return len
                }
            }
        val timeouts = mutableListOf<Int>()
        val connection = btConnection({ received }, timeouts)
        val within = BoundedTransport.wireBounded(socket, connection, 1_048_576)
        assertEquals(100, within.read(ByteArray(100), 0, 100))
        assertEquals('x'.code, within.read())
        assertEquals(emptyList(), timeouts, "예산 안에서는 연결을 건드리지 않는다")
        val over = BoundedTransport.wireBounded(socket, connection, 1_000)
        val e = assertFailsWith<IOException> { over.read(ByteArray(1_000_000), 0, 1_000_000) }
        assertEquals("HTTP response body framing exceeds 1000 bytes on the wire", e.message)
        assertEquals(BoundedTransport.MAX_READ, largestAsk, "읽기 한 번이 소켓에 요청한 길이")
        assertEquals(listOf(0), timeouts, "거부하며 읽기 타임아웃을 0 으로")
        assertFailsWith<IOException>("예산을 넘은 뒤의 한 바이트 읽기도 거부한다") { over.read() }
    }

    // 길이 0 의 읽기는 소켓에 닿지 않는다 — HttpCore 의 버퍼는 비었을 때 길이 0 도 기다리고, JDK 의 readNBytes 는 버퍼를 다 채운 뒤 길이
    // 0 으로 한 번 더 묻는다(그래서 상한+1 바이트 뒤 멈춘 서버 앞에서 넘침을 읽기 타임아웃까지 알아채지 못했다).
    @Test
    fun `wireBounded - a zero-length read never reaches the socket`() {
        val socket =
            object : InputStream() {
                override fun read(): Int = throw AssertionError("한 바이트 읽기가 소켓에 닿았다")

                override fun read(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ): Int = throw AssertionError("길이 $len 의 읽기가 소켓에 닿았다")
            }
        assertEquals(0, BoundedTransport.wireBounded(socket, btConnection({ 0 }, mutableListOf()), 1_000).read(ByteArray(4), 4, 0))
    }

    // 읽기가 실패하면(읽기 타임아웃 등) 그 예외 그대로 — 연결의 읽기 타임아웃은 0 으로(HttpClient 가 곧 닫는다).
    @Test
    fun `wireBounded - a failed read quiets the connection`() {
        val timedOut = SocketTimeoutException("Read timed out")
        val socket =
            object : InputStream() {
                override fun read(): Int = throw timedOut

                override fun read(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ): Int = throw timedOut
            }
        val timeouts = mutableListOf<Int>()
        val body = BoundedTransport.wireBounded(socket, btConnection({ 0 }, timeouts), 1_000)
        assertSame(timedOut, assertFailsWith<IOException> { body.read(ByteArray(8), 0, 8) })
        assertSame(timedOut, assertFailsWith<IOException> { body.read() })
        assertEquals(listOf(0, 0), timeouts)
    }

    // 이미 풀로 돌아간 연결(대리자가 떨어져 나가 던진다)은 건드리지 않는다 — 그 실패를 삼킨다.
    @Test
    fun `quiet leaves a returned connection alone`() {
        val detached =
            Proxy.newProxyInstance(HttpClientConnection::class.java.classLoader, arrayOf(HttpClientConnection::class.java)) { _, _, _ ->
                throw ConnectionShutdownException()
            } as HttpClientConnection
        BoundedTransport.quiet(detached)
    }

    // 운송의 연결은 「묻지 않은 바이트가 와 있는가」를 문맥 속성으로 답한다 — 입력 버퍼나 소켓에 바이트가 있으면 참, 없으면 거짓, 소켓을 읽을
    // 수 없으면 참(그 연결은 버린다). 다른 속성은 HttpCore 의 연결 그대로 담는다.
    @Test
    fun `connections answer whether unsolicited bytes wait`() {
        val route = HttpRoute(HttpHost("127.0.0.1", 1))
        BoundedTransport.CONNECTIONS.create(route, ConnectionConfig.DEFAULT).use { conn ->
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
                Socket(InetAddress.getLoopbackAddress(), server.localPort).use { client ->
                    server.accept().use { peer ->
                        val attributes = conn as HttpContext
                        attributes.setAttribute("other", 1)
                        assertEquals(1, attributes.getAttribute("other"))
                        conn.bind(client)
                        assertEquals(false, attributes.getAttribute(BoundedTransport.UNSOLICITED))
                        peer.getOutputStream().write(byteArrayOf('H'.code.toByte(), 'T'.code.toByte()))
                        peer.getOutputStream().flush()
                        for (i in 0 until 100) {
                            if (client.getInputStream().available() > 0) break
                            Thread.sleep(10)
                        }
                        assertEquals(true, attributes.getAttribute(BoundedTransport.UNSOLICITED))
                    }
                }
            }
        }
        val closed = Socket()
        closed.close()
        BoundedTransport.CONNECTIONS.create(route, ConnectionConfig.DEFAULT).use { gone ->
            gone.bind(closed)
            assertEquals(true, (gone as HttpContext).getAttribute(BoundedTransport.UNSOLICITED))
        }
    }

    // 버리는 연결 — 읽기 타임아웃을 0 으로 두고 닫는다. 닫기의 실패는 삼킨다(어차피 쓰지 않는다).
    @Test
    fun `discard quiets then closes and swallows a close failure`() {
        val calls = mutableListOf<String>()
        val failing =
            Proxy.newProxyInstance(
                HttpClientConnection::class.java.classLoader,
                arrayOf(HttpClientConnection::class.java),
            ) { _, method, _ ->
                calls += method.name
                if (method.name == "close") throw IOException("close failed")
                null
            } as HttpClientConnection
        BoundedTransport.discard(failing)
        assertEquals(listOf("setSocketTimeout", "close"), calls)
    }

    // 쉬는 연결의 수명 — 서버의 Keep-Alive: timeout 이 더 짧으면 그것, 없거나 길면 5 초, 0 이면 곧 닫는다.
    @Test
    fun `idleMillis caps the server's keep-alive`() {
        assertEquals(5_000, BoundedTransport.idleMillis(-1))
        assertEquals(1, BoundedTransport.idleMillis(0))
        assertEquals(1_000, BoundedTransport.idleMillis(1_000))
        assertEquals(5_000, BoundedTransport.idleMillis(5_000))
        assertEquals(5_000, BoundedTransport.idleMillis(3_600_000))
    }

    // 풀의 연결 표식 — 같은 팩토리·같은 검증기(정체)일 때만 같다(같은 일을 하는 다른 객체는 다르다). 없는 근원(null)은 하나의 표지로 센다.
    // 문자열 표현은 상수다(근원을 찍지 않는다).
    @Test
    fun `tlsKey is the identity of the factory and the verifier`() {
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val verifier = BtVerifier("a.example")
        val other = BtVerifier("a.example")
        val key = BoundedTransport.TlsKey(factory, verifier)
        assertEquals(key, key)
        assertEquals(key, BoundedTransport.TlsKey(factory, verifier))
        assertEquals(key.hashCode(), BoundedTransport.TlsKey(factory, verifier).hashCode())
        assertNotEquals(key, BoundedTransport.TlsKey(factory, other))
        assertNotEquals(key, BoundedTransport.TlsKey(BtFactory(factory), verifier))
        assertFalse(key.equals("TlsKey"))
        assertEquals(BoundedTransport.TlsKey(null, null), BoundedTransport.TlsKey(null, null))
        assertNotEquals(BoundedTransport.TlsKey(null, verifier), BoundedTransport.TlsKey(factory, verifier))
        assertEquals("TlsKey", key.toString())
    }

    // 근원을 붙잡지 않는다 — 팩토리나 검증기가 수거되면 그 표식은 (자기 자신 말고는) 무엇과도 같지 않다: 그 연결은 다시 쓰이지 않는다.
    // 수거는 GC 가 정하므로, 이 JVM 이 약한 참조를 비우지 않으면 확인을 건너뛴다.
    @Test
    fun `tlsKey does not keep its sources alive`() {
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val keptVerifier = BtVerifier("a.example")
        val keys = doomedKeys(factory, keptVerifier)
        for (i in 0 until 50) {
            if (keys.factoryGone.get() == null && keys.verifierGone.get() == null) break
            System.gc()
            Thread.sleep(20)
        }
        assumeTrue(keys.factoryGone.get() == null && keys.verifierGone.get() == null, "이 JVM 의 GC 가 약한 참조를 비우지 않았다")
        assertNotEquals(keys.deadFactory, keys.deadFactoryTwin)
        assertNotEquals(keys.deadVerifier, keys.deadVerifierTwin)
        assertEquals(keys.deadFactory, keys.deadFactory)
    }

    private class DoomedKeys(
        val deadFactory: BoundedTransport.TlsKey,
        val deadFactoryTwin: BoundedTransport.TlsKey,
        val deadVerifier: BoundedTransport.TlsKey,
        val deadVerifierTwin: BoundedTransport.TlsKey,
        val factoryGone: WeakReference<Any>,
        val verifierGone: WeakReference<Any>,
    )

    // 수거될 근원은 이 함수의 지역값으로만 산다 — 돌아오면 아무도 쥐지 않는다.
    private fun doomedKeys(
        factory: SSLSocketFactory,
        keptVerifier: HostnameVerifier,
    ): DoomedKeys {
        val doomedFactory = BtFactory(factory)
        val doomedVerifier = BtVerifier("b.example")
        return DoomedKeys(
            BoundedTransport.TlsKey(doomedFactory, keptVerifier),
            BoundedTransport.TlsKey(doomedFactory, keptVerifier),
            BoundedTransport.TlsKey(factory, doomedVerifier),
            BoundedTransport.TlsKey(factory, doomedVerifier),
            WeakReference(doomedFactory),
            WeakReference(doomedVerifier),
        )
    }

    // https.protocols·https.cipherSuites 는 HttpURLConnection 처럼 쉼표로만 나눈다 — 없거나 비면 걸지 않는다.
    @Test
    fun `tokens split like HttpsClient`() {
        assertContentEquals(emptyArray(), BoundedTransport.tokens(null))
        assertContentEquals(emptyArray(), BoundedTransport.tokens(""))
        assertContentEquals(arrayOf("TLSv1.2"), BoundedTransport.tokens("TLSv1.2"))
        assertContentEquals(arrayOf("TLSv1.2", " TLSv1.3"), BoundedTransport.tokens("TLSv1.2, TLSv1.3"))
    }

    // JWKS 조회 스레드가 던진 것을 호출자에게 그대로 — 실행 예외의 원인이 런타임 예외·Error 면 던지고, IOException 이면 돌려준다.
    @Test
    fun `the jwks fetch's failure reaches the caller unchanged`() {
        val unchecked = IllegalStateException("x")
        val error = AssertionError("y")
        val io = IOException("z")
        assertSame(unchecked, assertFailsWith<IllegalStateException> { NoRedirectResourceRetriever.rethrow(unchecked) })
        assertSame(error, assertFailsWith<AssertionError> { NoRedirectResourceRetriever.rethrow(error) })
        assertSame(io, NoRedirectResourceRetriever.rethrow(io))
    }
}
