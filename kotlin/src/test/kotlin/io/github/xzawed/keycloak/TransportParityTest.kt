package io.github.xzawed.keycloak

import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import com.nimbusds.jose.util.DefaultResourceRetriever
import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

// 운송을 바꿔도 **HttpURLConnection 이 하던 그대로**인가 — 같은 서버에 Nimbus 의 `send()`(HttpURLConnection)와 [CappedResponseSender] 를
// 나란히 붙여 서버가 받은 요청 바이트, 돌려받은 응답, TLS·프록시의 결말을 대조한다. JWKS 레인은 Nimbus 의 `DefaultResourceRetriever` 와
// 대조한다. Java `TransportParityTest` 의 이식이다(15 사례).
//
// 대조의 기준은 지금 이 JVM 의 HttpURLConnection 자신이다 — 그래서 JDK 판마다 다른 값(17 의 Accept 목록 · User-Agent 의 판 번호)도 그
// JDK 에서 맞는지 잰다. ⚠️ 응답 헤더 값의 순서는 JDK 17 의 HttpURLConnection 이 뒤집는다(JDK-8133686 은 18 에서 고쳐졌다) — 같은 이름이
// 거듭 오는 헤더는 17 에서만 값의 집합으로 비교한다.
//
// ⚠️ 전역 상태(시스템 프록시 속성 · Nimbus·HttpURLConnection 의 TLS 기본값 · `https.protocols`)를 바꾸는 시험은 끝에서 되돌린다 —
// Gradle 은 한 JVM 에서 클래스를 차례로 돈다.
private const val TP_REALM = "r"
private const val TP_TOKEN_PATH = "/realms/$TP_REALM/protocol/openid-connect/token"
private val TP_TOKEN = """{"access_token":"AT","token_type":"Bearer","expires_in":300}""".toByteArray()
private val TP_JWKS = """{"keys":[{"kty":"oct","kid":"k1","k":"AAAA"}]}""".toByteArray()
private const val TP_MARKER = "ZparityMARKER0123"

// 프록시가 CONNECT 를 거절했을 때 새 운송의 메시지(프록시의 응답은 인용하지 않는다).
private const val TP_TUNNEL_REFUSED = "Unable to tunnel through proxy"

// 인증서의 이름(other.example)이 아니라 접속한 이름이 루프백이면 받아들이는 검증기 — 엄격한 검사 뒤에 묻는 자리를 잰다.
private val TP_ACCEPTS_LOOPBACK = HostnameVerifier { host, _ -> host == "127.0.0.1" }

private fun tpLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun tpOk(body: ByteArray): ByteArray =
    ByteArrayOutputStream()
        .apply {
            write(tpLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n"))
            write(body)
        }.toByteArray()

// 받은 요청 하나 — 요청 줄, 헤더 줄들, 본문.
internal class TpCaptured(
    val requestLine: String,
    val headers: List<String>,
    val body: String,
) {
    // 비교용 — 헤더 줄은 순서와 무관하게 같은 묶음이어야 한다(값은 바이트 그대로).
    fun normalized(): String = requestLine + "\n" + headers.sorted().joinToString("\n") + "\n\n" + body

    fun header(name: String): String? =
        headers.firstOrNull { it.regionMatches(0, "$name:", 0, name.length + 1, ignoreCase = true) }?.substring(name.length + 1)?.trim()

    override fun toString(): String = requestLine

    companion object {
        fun read(input: InputStream): TpCaptured? {
            val head = ByteArrayOutputStream()
            var last4 = 0
            while (true) {
                val b = input.read()
                if (b == -1) return null
                head.write(b)
                last4 = (last4 shl 8) or b
                if (last4 == 0x0d0a0d0a) break
            }
            val lines = head.toString(Charsets.ISO_8859_1).split("\r\n").filter { it.isNotEmpty() }
            val headers = lines.drop(1)
            var length = 0
            for (h in headers) {
                if (h.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) length = h.substring(15).trim().toInt()
            }
            return TpCaptured(lines[0], headers, String(input.readNBytes(length), Charsets.ISO_8859_1))
        }
    }
}

// 요청 하나에 응답을 쓴다 — 끝없는 응답은 쓰기가 실패할 때까지 쓴다.
private fun interface TpResponder {
    fun respond(
        request: TpCaptured,
        out: OutputStream,
        server: TpCaptureServer,
    )
}

// 기록하는 원시 서버 — 연결 하나에 요청을 여럿 받는다(HttpURLConnection 도 새 운송도 연결을 다시 쓴다). 요청마다 reply 가 응답을
// 쓴다. TLS 면 맺은 규약을 적는다.
private class TpCaptureServer(
    tls: SSLContext?,
    val reply: TpResponder,
) : AutoCloseable {
    constructor(tls: SSLContext?, reply: (TpCaptured) -> ByteArray) : this(
        tls,
        TpResponder { request, out, server ->
            val r = reply(request)
            out.write(r)
            server.written.addAndGet(r.size.toLong())
        },
    )

    val socket: ServerSocket =
        tls?.serverSocketFactory?.createServerSocket(0, 50, InetAddress.getLoopbackAddress())
            ?: ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val requests = CopyOnWriteArrayList<TpCaptured>()
    val protocols = CopyOnWriteArrayList<String>()
    val suites = CopyOnWriteArrayList<String>()
    val written = AtomicLong()

    @Volatile var stop = false

    init {
        Thread(::serve, "parity-capture-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    private fun serve() {
        while (!stop) {
            val s =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            Thread({ answer(s) }, "parity-capture-exchange").apply { isDaemon = true }.start()
        }
    }

    private fun answer(s: Socket) {
        try {
            s.use {
                s.soTimeout = 10_000
                if (s is SSLSocket) {
                    s.startHandshake()
                    protocols += s.session.protocol
                    suites += s.session.cipherSuite
                }
                val input = s.getInputStream()
                val out = s.getOutputStream()
                while (!stop) {
                    val c = TpCaptured.read(input) ?: return
                    requests += c
                    reply.respond(c, out, this)
                    out.flush()
                    if (c.requestLine.startsWith("CONNECT")) return
                }
            }
        } catch (clientLeft: IOException) {
            // 클라이언트가 떠났다(TLS 거부·끊기 포함)
        }
    }

    override fun close() {
        stop = true
        socket.close()
    }
}

private fun tpAuthClient(base: String): AuthClient = AuthClient(KeycloakConfig(base, TP_REALM, "app", "s3cr3t".toCharArray()))

// AuthClient 가 내는 다섯 요청 모양 — base 의 엔드포인트로, AuthClient 자신의 빌더와 applyTimeouts 로 만든다.
private fun tpShapes(base: String): Map<String, HTTPRequest> {
    val auth = tpAuthClient(base)
    return sortedMapOf(
        "client_credentials" to auth.applyTimeouts(auth.buildClientCredentialsRequest()),
        "refresh_token" to auth.applyTimeouts(auth.buildRefreshRequest("rt-1")),
        "authorization_code" to auth.applyTimeouts(auth.buildExchangeCodeRequest("code-1", "v".repeat(43), "https://app.example/cb")),
        "introspection" to auth.applyTimeouts(auth.buildIntrospectionRequest("tok-1")),
        "logout" to auth.applyTimeouts(auth.buildLogoutRequest("rt-1")),
    )
}

private fun tpCapped(req: HTTPRequest): HTTPResponse = req.send(CappedResponseSender("token response"))

private fun tpOutcome(call: () -> Unit): Throwable? =
    try {
        call()
        null
    } catch (t: Throwable) {
        t
    }

// 같은 요청을 둘에 보내고 결말(상태 또는 예외 타입·메시지)을 비교할 수 있게 적는다. ⚠️ JDK 25 의 HttpURLConnection 은 이름 검사 실패를
// 「Wrong HTTPS hostname: should be <…>」로 쓴다(17·21 은 「HTTPS hostname wrong:  should be <…>」 — Java 실측 25.0.4) — 타입은 같다.
// 새 운송은 17·21 의 문구를 쓰므로 비교 전에 25 의 문구를 그것으로 맞춘다.
private fun tpFate(call: () -> Unit): String {
    val t = tpOutcome(call) ?: return "ok"
    return t.javaClass.name +
        if (t is SSLHandshakeException) "" else ": " + t.message?.replace("Wrong HTTPS hostname: ", "HTTPS hostname wrong:  ")
}

private fun tpTlsRequest(
    port: Int,
    factory: SSLSocketFactory?,
    verifier: HostnameVerifier?,
): HTTPRequest =
    tpShapes("https://127.0.0.1:$port").getValue("client_credentials").apply {
        sslSocketFactory = factory
        hostnameVerifier = verifier
    }

private fun tpComparable(headers: Map<String, List<String>>): Map<String, List<String>> {
    val out = sortedMapOf<String, List<String>>(String.CASE_INSENSITIVE_ORDER)
    for ((name, values) in headers) {
        // JDK 17 의 HttpURLConnection 은 거듭 오는 헤더의 값 순서를 뒤집는다
        out[name] = if (Runtime.version().feature() < 18) values.sorted() else values.toList()
    }
    return out
}

// 소켓을 만들 때 끝점 식별을 미리 거는 팩토리 — HttpURLConnection 은 그것이 HTTPS 면 핸드셰이크 뒤 검사를 하지 않고, 비었으면 없는
// 것으로 본다.
private fun tpPresetIdentification(
    delegate: SSLSocketFactory,
    algorithm: String,
): SSLSocketFactory =
    object : SSLSocketFactory() {
        private fun preset(s: Socket): Socket {
            val tls = s as SSLSocket
            tls.sslParameters = tls.sslParameters.apply { endpointIdentificationAlgorithm = algorithm }
            return tls
        }

        override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

        override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

        override fun createSocket(
            s: Socket,
            host: String,
            port: Int,
            autoClose: Boolean,
        ): Socket = preset(delegate.createSocket(s, host, port, autoClose))

        override fun createSocket(
            host: String,
            port: Int,
        ): Socket = preset(delegate.createSocket(host, port))

        override fun createSocket(
            host: String,
            port: Int,
            local: InetAddress,
            localPort: Int,
        ): Socket = preset(delegate.createSocket(host, port, local, localPort))

        override fun createSocket(
            host: InetAddress,
            port: Int,
        ): Socket = preset(delegate.createSocket(host, port))

        override fun createSocket(
            host: InetAddress,
            port: Int,
            local: InetAddress,
            localPort: Int,
        ): Socket = preset(delegate.createSocket(host, port, local, localPort))
    }

// CONNECT 를 받아 주는 프록시 — 어느 대상이든 target 포트로 잇고 두 방향을 그대로 나른다.
private class TpTunnelProxy(
    private val target: Int,
) : AutoCloseable {
    val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val connects = CopyOnWriteArrayList<String>()

    init {
        Thread(::serve, "parity-tunnel-proxy").apply { isDaemon = true }.start()
    }

    private fun serve() {
        while (!socket.isClosed) {
            val client =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            Thread({ tunnel(client) }, "parity-tunnel").apply { isDaemon = true }.start()
        }
    }

    private fun tunnel(client: Socket) {
        try {
            client.use {
                Socket(InetAddress.getLoopbackAddress(), target).use { upstream ->
                    val connect = TpCaptured.read(client.getInputStream()) ?: return
                    connects += connect.requestLine
                    client.getOutputStream().write(tpLatin1("HTTP/1.1 200 Connection established\r\n\r\n"))
                    client.getOutputStream().flush()
                    Thread({ pipe(client, upstream) }, "parity-tunnel-up").apply { isDaemon = true }.start()
                    pipe(upstream, client)
                }
            }
        } catch (gone: IOException) {
            // 한쪽이 닫았다
        }
    }

    private fun pipe(
        from: Socket,
        to: Socket,
    ) {
        try {
            from.getInputStream().transferTo(to.getOutputStream())
            to.shutdownOutput()
        } catch (gone: IOException) {
            // 한쪽이 닫았다
        }
    }

    override fun close() {
        socket.close()
    }
}

// 시스템 속성 몇을 바꾼 채 block 을 돌고 끝에서 되돌린다.
private fun <T> tpWithProperties(
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

internal class TransportParityTest {
    // ───────────── 요청 ─────────────

    // AuthClient 의 다섯 요청 — 서버가 받은 요청 줄·헤더 줄 묶음·본문이 HttpURLConnection 이 보낸 것과 바이트까지 같다.
    @Test
    fun `requests are byte for byte what HttpURLConnection sends`() {
        TpCaptureServer(null) { tpOk(TP_TOKEN) }.use { server ->
            val wrong = mutableListOf<String>()
            for ((name, req) in tpShapes("http://127.0.0.1:${server.port}")) {
                server.requests.clear()
                req.send()
                tpCapped(req)
                assertEquals(2, server.requests.size, name)
                val stock = server.requests[0].normalized()
                val capped = server.requests[1].normalized()
                println("[TransportParityTest] $name 요청\n" + capped.replace(Regex("(?m)^Authorization: .*$"), "Authorization: <생략>"))
                if (stock != capped) wrong += "$name:\n--- HttpURLConnection\n$stock\n--- 새 운송\n$capped"
            }
            assertTrue(wrong.isEmpty(), wrong.joinToString("\n"))
        }
    }

    // 본문 없는 요청(GET)과 요청에 실린 Accept — HttpURLConnection 처럼 Accept 를 덮지 않고 Content-Length 도 싣지 않는다.
    @Test
    fun `a GET with its own Accept is sent like HttpURLConnection sends it`() {
        TpCaptureServer(null) { tpOk(TP_TOKEN) }.use { server ->
            val get = HTTPRequest(HTTPRequest.Method.GET, URI("http://127.0.0.1:${server.port}/x?a=1&b=%20").toURL())
            get.setHeader("Accept", "application/json")
            get.send()
            tpCapped(get)
            assertEquals(server.requests[0].normalized(), server.requests[1].normalized())
            assertEquals("application/json", server.requests[1].header("Accept"))
            assertNull(server.requests[1].header("Content-Length"))
        }
    }

    // 본문도 Content-Type 도 없는 POST(SDK 는 이렇게 보내지 않는다 — 운송의 갈래를 잰다) — 새 운송은 본문을 싣는 요청으로 보내
    // `Content-Length: 0` 이고 Content-Type 을 지어내지 않는다. HttpURLConnection 과 다른 머리는 이 사례가 출력에 적는다.
    @Test
    fun `a POST without a body or a content type is sent as an empty entity`() {
        TpCaptureServer(null) { tpOk(TP_TOKEN) }.use { server ->
            val post = HTTPRequest(HTTPRequest.Method.POST, URI("http://127.0.0.1:${server.port}/x").toURL())
            post.send()
            assertEquals(200, tpCapped(post).statusCode)
            val stock = server.requests[0]
            val mine = server.requests[1]
            println("[TransportParityTest] 본문 없는 POST\n--- HttpURLConnection\n${stock.normalized()}\n--- 새 운송\n${mine.normalized()}")
            assertEquals(stock.requestLine, mine.requestLine)
            assertEquals("0", mine.header("Content-Length"))
            assertNull(mine.header("Content-Type"))
            assertEquals("", mine.body)
        }
    }

    // HttpURLConnection 이 조용히 버리는 헤더를 요청이 싣고 오면 새 운송도 버린다 — Content-Length(HttpClient 는 「already present」로
    // 던졌다)·Host(HttpClient 는 그대로 보냈다)·Transfer-Encoding·Origin·Sec-*·Keep-Alive·Via. `Connection: close` 는 그대로 간다.
    @Test
    fun `restricted headers are dropped like HttpURLConnection drops them`() {
        TpCaptureServer(null) { tpOk(TP_TOKEN) }.use { server ->
            val req = tpShapes("http://127.0.0.1:${server.port}").getValue("client_credentials")
            req.setHeader("Content-Length", "999")
            req.setHeader("Host", "evil.example")
            req.setHeader("Transfer-Encoding", "chunked")
            req.setHeader("Origin", "https://evil.example")
            req.setHeader("Sec-Fetch-Mode", "cors")
            req.setHeader("Keep-Alive", "timeout=5")
            req.setHeader("Via", "1.1 evil")
            req.setHeader("Connection", "close")
            req.send()
            assertEquals(200, tpCapped(req).statusCode)
            val stock = server.requests[0]
            val mine = server.requests[1]
            assertEquals(stock.normalized(), mine.normalized())
            assertEquals("127.0.0.1:${server.port}", mine.header("Host"))
            assertEquals(mine.body.length.toString(), mine.header("Content-Length"))
            assertEquals("close", mine.header("Connection"))
            assertNull(mine.header("Origin"))
            assertNull(mine.header("Sec-Fetch-Mode"))
        }
    }

    // 리다이렉트는 따르지 않는다 — HttpClient 의 기본은 POST 의 303 을 GET 으로, GET 의 302 를 따른다. AuthClient 가 끄는 플래그
    // (followRedirects=false)의 POST 303 은 HttpURLConnection 과 같이 303 을 돌려주고, ⚠️ 플래그가 켜진 GET 302 도 이 송신은 따르지
    // 않는다(Nimbus 의 send() 는 따른다 — SSRF 하드닝).
    @Test
    fun `redirects are never followed`() {
        TpCaptureServer(null) { c ->
            if (c.requestLine.contains("/elsewhere")) {
                tpOk(TP_TOKEN)
            } else {
                val status = if (c.requestLine.startsWith("POST")) "303 See Other" else "302 Found"
                tpLatin1("HTTP/1.1 $status\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n")
            }
        }.use { server ->
            val post = tpShapes("http://127.0.0.1:${server.port}").getValue("client_credentials")
            assertEquals(303, post.send().statusCode)
            assertEquals(303, tpCapped(post).statusCode)
            val get = HTTPRequest(HTTPRequest.Method.GET, URI("http://127.0.0.1:${server.port}/x").toURL())
            assertTrue(get.followRedirects, "Nimbus 의 기본은 따르기다")
            assertEquals(302, tpCapped(get).statusCode)
            assertTrue(server.requests.none { it.requestLine.contains("/elsewhere") }, "리다이렉트 대상에 요청이 갔다 — ${server.requests}")
        }
    }

    // ───────────── 응답 ─────────────

    // Keycloak 26.6.4 의 토큰 응답 머리(소문자 content-length 포함 — Java 실측 캡처)와 거듭 오는 헤더 — 상태·메시지·헤더 표·본문이
    // Nimbus send() 와 같다.
    @Test
    fun `a Keycloak shaped response is what Nimbus send builds`() {
        val response =
            tpLatin1(
                "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nPragma: no-cache\r\ncontent-length: ${TP_TOKEN.size}" +
                    "\r\nContent-Type: application/json\r\nReferrer-Policy: no-referrer\r\n" +
                    "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\nX-Content-Type-Options: nosniff\r\n" +
                    "X-Frame-Options: SAMEORIGIN\r\nX-Robots-Tag: none\r\nX-Multi: a\r\nX-Multi: b\r\nSet-Cookie: k1=v1\r\n" +
                    "Set-Cookie: k2=v2\r\n\r\n" + String(TP_TOKEN, Charsets.ISO_8859_1),
            )
        TpCaptureServer(null) { response }.use { server ->
            val req = tpShapes("http://127.0.0.1:${server.port}").getValue("client_credentials")
            val stock = req.send()
            val capped = tpCapped(req)
            assertEquals(stock.statusCode, capped.statusCode)
            assertEquals(stock.statusMessage, capped.statusMessage)
            assertEquals(stock.body, capped.body)
            assertEquals(tpComparable(stock.headerMap), tpComparable(capped.headerMap))
        }
    }

    // 본문 없는 204(Keycloak 의 logout 모양) — 상태·메시지·헤더·본문 없음이 Nimbus send() 와 같다.
    @Test
    fun `a no content response is what Nimbus send builds`() {
        TpCaptureServer(null) {
            tpLatin1("HTTP/1.1 204 No Content\r\nCache-Control: no-cache\r\nX-Frame-Options: SAMEORIGIN\r\n\r\n")
        }.use { server ->
            val req = tpShapes("http://127.0.0.1:${server.port}").getValue("logout")
            val stock = req.send()
            val capped = req.send(CappedResponseSender("logout response"))
            assertEquals(204, capped.statusCode)
            assertEquals(stock.statusMessage, capped.statusMessage)
            assertNull(capped.body)
            assertEquals(stock.body, capped.body)
            assertEquals(tpComparable(stock.headerMap), tpComparable(capped.headerMap))
        }
    }

    // ───────────── 프록시 ─────────────

    // 시스템 프록시(http.proxyHost)를 따른다 — 프록시가 받은 요청(절대 URI 의 요청 줄 · Proxy-Connection)이 HttpURLConnection 의 것과
    // 같다. HTTPS 의 CONNECT 를 프록시가 거절하면(502) 둘 다 IOException 이다 — 새 운송은 프록시의 응답을 돌려주지 않고(HttpClient 의
    // 기본은 그 502 를 응답으로 돌려준다), 메시지에 프록시의 바이트를 싣지 않는다.
    @Test
    fun `the system proxy is honoured and a refused CONNECT is an IOException`() {
        TpCaptureServer(null) { c ->
            if (c.requestLine.startsWith("CONNECT")) {
                tpLatin1("HTTP/1.1 502 Bad Gateway $TP_MARKER\r\nContent-Length: 0\r\n\r\n")
            } else {
                tpOk(TP_TOKEN)
            }
        }.use { proxy ->
            val port = proxy.port.toString()
            tpWithProperties(
                mapOf(
                    "http.proxyHost" to "127.0.0.1",
                    "http.proxyPort" to port,
                    "https.proxyHost" to "127.0.0.1",
                    "https.proxyPort" to port,
                ),
            ) {
                val plain = tpShapes("http://kc.invalid").getValue("client_credentials")
                plain.send()
                assertEquals(200, tpCapped(plain).statusCode)
                assertEquals(2, proxy.requests.size, "두 요청 모두 프록시를 지나야 한다")
                assertEquals("POST http://kc.invalid$TP_TOKEN_PATH HTTP/1.1", proxy.requests[1].requestLine)
                assertEquals(proxy.requests[0].normalized(), proxy.requests[1].normalized())

                proxy.requests.clear()
                val tls = tpShapes("https://kc.invalid").getValue("client_credentials")
                val stock = tpOutcome { tls.send() }
                val capped = tpOutcome { tpCapped(tls) }
                println("[TransportParityTest] 거절된 CONNECT → HttpURLConnection $stock · 새 운송 $capped · 프록시가 받은 ${proxy.requests}")
                assertIs<IOException>(stock)
                assertIs<IOException>(capped)
                assertEquals(TP_TUNNEL_REFUSED, capped.message)
                assertFalse(TP_MARKER in capped.stackTraceToString(), "거절이 프록시의 응답을 인용했다")
                assertTrue(
                    proxy.requests.all { it.requestLine.startsWith("CONNECT kc.invalid:443") },
                    "CONNECT 만 받았어야 한다 — ${proxy.requests}",
                )
            }
        }
    }

    // 프록시를 지나는 HTTPS — CONNECT 가 받아지면 터널 너머의 TLS 서버가 받은 요청(Host · Connection — 터널 안에서는 Proxy-Connection 이
    // 아니다)이 HttpURLConnection 의 것과 같고, 이름 검사는 대상 이름(kc.invalid)으로 한다.
    @Test
    fun `an HTTPS request through a proxy tunnel is what HttpURLConnection sends`() {
        TpCaptureServer(TransportTestTls.serverTunnelled) { tpOk(TP_TOKEN) }.use { tls ->
            TpTunnelProxy(tls.port).use { proxy ->
                val nimbusDefault = HTTPRequest.getDefaultSSLSocketFactory()
                try {
                    HTTPRequest.setDefaultSSLSocketFactory(TransportTestTls.trusting)
                    tpWithProperties(mapOf("https.proxyHost" to "127.0.0.1", "https.proxyPort" to proxy.socket.localPort.toString())) {
                        val req = tpShapes("https://kc.invalid").getValue("client_credentials")
                        val stock = tpFate { req.send() }
                        val capped = tpFate { tpCapped(req) }
                        println("[TransportParityTest] 프록시 터널 HTTPS → $stock · $capped · CONNECT ${proxy.connects}")
                        assertEquals("ok", stock)
                        assertEquals("ok", capped)
                        assertEquals(listOf("CONNECT kc.invalid:443 HTTP/1.1", "CONNECT kc.invalid:443 HTTP/1.1"), proxy.connects.toList())
                        assertEquals(2, tls.requests.size)
                        assertEquals(tls.requests[0].normalized(), tls.requests[1].normalized())
                        assertEquals("kc.invalid", tls.requests[1].header("Host"))
                    }
                } finally {
                    HTTPRequest.setDefaultSSLSocketFactory(nimbusDefault)
                }
            }
        }
    }

    // ───────────── TLS ─────────────

    // TLS 근원 — 요청의 팩토리, 없으면 Nimbus 의 기본 팩토리(HttpURLConnection 의 전역이 아니다 — 오늘과 같다)를 쓴다. 검증기가 JDK 기본이면
    // 이름이 맞지 않는 인증서는 핸드셰이크에서 거부되고(같은 예외 타입), 다른 검증기면 그 판정을 따른다(맞지 않으면 같은 「HTTPS hostname
    // wrong」). 결말이 HttpURLConnection 과 같다.
    @Test
    fun `tls follows the request and Nimbus defaults like HttpURLConnection`() {
        val trusting = TransportTestTls.trusting
        val jdkDefault = HTTPRequest.getDefaultHostnameVerifier()
        val rejects = HostnameVerifier { _, _ -> false }
        val handshake = SSLHandshakeException::class.java.name
        // ⚠️ 행마다 새 서버(새 포트)다 — HttpURLConnection 은 TLS 연결을 URL·팩토리로 캐시해 다시 쓰고, 다시 쓴 연결은 검증기를 다시
        // 묻지 않는다(앞 행이 받아들이는 검증기로 맺은 연결이면 거부하는 검증기의 행도 통과했다 — Java 실측).
        val rows =
            listOf(
                listOf("요청의 팩토리 · JDK 기본 검증기", TransportTestTls.serverIp, trusting, jdkDefault, "ok"),
                listOf("이름이 다른 인증서 · JDK 기본 검증기", TransportTestTls.serverOther, trusting, jdkDefault, handshake),
                listOf("이름이 다른 인증서 · 받아들이는 검증기", TransportTestTls.serverOther, trusting, TP_ACCEPTS_LOOPBACK, "ok"),
                listOf(
                    "이름이 다른 인증서 · 거부하는 검증기",
                    TransportTestTls.serverOther,
                    trusting,
                    rejects,
                    "java.io.IOException: HTTPS hostname wrong:  should be <127.0.0.1>",
                ),
                // 엄격한 검사가 먼저다 — 이름이 맞으면 검증기는 묻지 않는다(HttpsClient.checkURLSpoofing)
                listOf("맞는 인증서 · 거부하는 검증기", TransportTestTls.serverIp, trusting, rejects, "ok"),
                listOf("믿지 않는 인증서", TransportTestTls.serverIp, SSLSocketFactory.getDefault() as SSLSocketFactory, jdkDefault, handshake),
                listOf(
                    "팩토리가 이미 HTTPS 검사를 건다 · 받아들이는 검증기",
                    TransportTestTls.serverOther,
                    tpPresetIdentification(trusting, "HTTPS"),
                    TP_ACCEPTS_LOOPBACK,
                    handshake,
                ),
                // 빈 이름은 없는 것과 같다 — 기본 검증기면 HTTPS 검사를 건다
                listOf(
                    "팩토리가 빈 식별을 건다 · JDK 기본 검증기",
                    TransportTestTls.serverOther,
                    tpPresetIdentification(trusting, ""),
                    jdkDefault,
                    handshake,
                ),
                // HTTPS 가 아닌 식별(LDAPS)은 핸드셰이크 안에서 그 규칙으로 검사된다 — 맞지 않으면 핸드셰이크가 실패한다
                listOf(
                    "팩토리가 LDAPS 식별을 건다 · 받아들이는 검증기",
                    TransportTestTls.serverOther,
                    tpPresetIdentification(trusting, "LDAPS"),
                    TP_ACCEPTS_LOOPBACK,
                    handshake,
                ),
            )
        val wrong = mutableListOf<String>()
        for (row in rows) {
            TpCaptureServer(row[1] as SSLContext) { tpOk(TP_TOKEN) }.use { server ->
                val req = tpTlsRequest(server.port, row[2] as SSLSocketFactory, row[3] as HostnameVerifier)
                val stock = tpFate { req.send() }
                val capped = tpFate { tpCapped(req) }
                println("[TransportParityTest] TLS ${row[0]} → HttpURLConnection $stock · 새 운송 $capped")
                if (stock != row[4] || capped != row[4]) wrong += "${row[0]}: 기대 ${row[4]} · $stock · $capped"
            }
        }

        val nimbusDefault = HTTPRequest.getDefaultSSLSocketFactory()
        try {
            HTTPRequest.setDefaultSSLSocketFactory(trusting)
            TpCaptureServer(TransportTestTls.serverIp) { tpOk(TP_TOKEN) }.use { ip ->
                val req = tpTlsRequest(ip.port, null, null)
                val stock = tpFate { req.send() }
                val capped = tpFate { tpCapped(req) }
                if (stock != "ok" || capped != "ok") wrong += "Nimbus 기본 팩토리: $stock · $capped"
            }
            // Java 와 같이 묶음 행은 https.protocols=TLSv1.2 가 걸린 채로 돈다
            tpWithProperties(mapOf("https.protocols" to "TLSv1.2")) {
                TpCaptureServer(TransportTestTls.serverIp) { tpOk(TP_TOKEN) }.use { fresh ->
                    // 캐시된 연결을 쓰지 않게 새 서버
                    val req12 = tpTlsRequest(fresh.port, null, null)
                    val stock12 = tpFate { req12.send() }
                    val capped12 = tpFate { tpCapped(req12) }
                    println("[TransportParityTest] https.protocols=TLSv1.2 → $stock12 · $capped12 · 맺은 규약 ${fresh.protocols}")
                    if (stock12 != "ok" || capped12 != "ok" || fresh.protocols.toList() != listOf("TLSv1.2", "TLSv1.2")) {
                        wrong += "https.protocols=TLSv1.2: $stock12 · $capped12 · ${fresh.protocols}"
                    }
                }
                val suite = "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
                tpWithProperties(mapOf("https.cipherSuites" to suite)) {
                    TpCaptureServer(TransportTestTls.serverIp) { tpOk(TP_TOKEN) }.use { fresh ->
                        val reqSuite = tpTlsRequest(fresh.port, null, null)
                        val stockSuite = tpFate { reqSuite.send() }
                        val cappedSuite = tpFate { tpCapped(reqSuite) }
                        println("[TransportParityTest] https.cipherSuites=$suite → $stockSuite · $cappedSuite · 맺은 묶음 ${fresh.suites}")
                        if (stockSuite != "ok" || cappedSuite != "ok" || fresh.suites.toList() != listOf(suite, suite)) {
                            wrong += "https.cipherSuites: $stockSuite · $cappedSuite · ${fresh.suites}"
                        }
                    }
                }
            }
        } finally {
            HTTPRequest.setDefaultSSLSocketFactory(nimbusDefault)
        }
        assertTrue(wrong.isEmpty(), wrong.joinToString("\n"))
    }

    // 닫힌 포트에 HTTPS — 연결 거부는 HttpURLConnection 처럼 JDK 의 ConnectException 이다(HttpClient 의 감싼 타입이 아니다).
    @Test
    fun `a refused HTTPS connection is the JDK's ConnectException`() {
        val closed = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val req = tpTlsRequest(closed, TransportTestTls.trusting, HTTPRequest.getDefaultHostnameVerifier())
        val stock = tpOutcome { req.send() }
        val capped = tpOutcome { tpCapped(req) }
        assertEquals<Class<*>?>(stock?.javaClass, capped?.javaClass)
        assertEquals<Class<*>?>(ConnectException::class.java, capped?.javaClass)
    }

    // 상한을 넘는 HTTPS 본문 — 끝없는 1 바이트 청크를 전속력으로. 거부한 뒤 끊으므로 곧바로 돌아온다(예전 운송의 HTTPS 닫기는 바이트가
    // 이어지는 동안 버리기를 멈추지 않았다). 끊는 동안 JSSE 가 이미 도착한 바이트를 버리는 몫은 서버가 쓴 양으로 적는다.
    @Test
    fun `an endless HTTPS body is refused promptly`() {
        val one = tpLatin1("1\r\n \r\n")
        val block = ByteArray(one.size * 10_922)
        for (i in 0 until 10_922) one.copyInto(block, i * one.size)
        val head =
            tpLatin1(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" +
                    Integer.toHexString(TP_TOKEN.size) + "\r\n" + String(TP_TOKEN, Charsets.ISO_8859_1) + "\r\n",
            )
        TpCaptureServer(TransportTestTls.serverIp) { _, out, s ->
            out.write(head)
            while (!s.stop) {
                out.write(block)
                s.written.addAndGet(block.size.toLong())
            }
        }.use { server ->
            val req = tpTlsRequest(server.port, TransportTestTls.trusting, HTTPRequest.getDefaultHostnameVerifier())
            val start = System.nanoTime()
            val thrown = tpOutcome { tpCapped(req) }
            val millis = (System.nanoTime() - start) / 1_000_000
            val atReturn = server.written.get()
            Thread.sleep(500)
            println(
                "[TransportParityTest] HTTPS 끝없는 1 바이트 청크 → $thrown · $millis ms · 서버가 쓴 $atReturn B(돌아온 뒤 0.5 초 동안 " +
                    "${server.written.get() - atReturn} B 더)",
            )
            assertIs<ResponseTooLargeException>(thrown)
            assertTrue(millis < 10_000, "$millis ms")
        }
    }

    // ───────────── JWKS 레인 ─────────────

    // JWKS 조회 — 요청이 Nimbus 의 DefaultResourceRetriever(HttpURLConnection) 와 같고, 51,200 바이트 상한의 경계도 같다(정확히 51,200
    // 바이트는 그쪽도 거부한다 — BoundedInputStream 은 상한에 닿으면 던진다).
    @Test
    fun `jwks request and size limit match Nimbus' default retriever`() {
        val limit = JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT
        for (size in listOf(TP_JWKS.size, limit - 1, limit)) {
            val body = ByteArray(size) { ' '.code.toByte() }
            TP_JWKS.copyInto(body)
            TpCaptureServer(null) { tpOk(body) }.use { server ->
                val certs = URI("http://127.0.0.1:${server.port}/realms/r/protocol/openid-connect/certs").toURL()
                val stock = tpFate { DefaultResourceRetriever(5_000, 20_000, limit).retrieveResource(certs) }
                val capped = tpFate { NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs) }
                println("[TransportParityTest] JWKS $size 바이트 → $stock · $capped")
                assertEquals(stock, capped, "$size 바이트")
                assertEquals(if (size < limit) "ok" else "java.io.IOException: Exceeded configured input limit of 51200 bytes", capped)
                if (size == TP_JWKS.size) assertEquals(server.requests[0].normalized(), server.requests[1].normalized())
            }
        }
    }

    // JWKS 레인의 TLS 근원은 HttpURLConnection 의 전역 기본값이다(Nimbus 기본 리트리버와 같다) — 내용과 Content-Type 도 같다.
    @Test
    fun `jwks tls follows HttpsURLConnection defaults`() {
        TpCaptureServer(TransportTestTls.serverIp) { tpOk(TP_JWKS) }.use { server ->
            val certs = URI("https://127.0.0.1:${server.port}/certs").toURL()
            val saved = HttpsURLConnection.getDefaultSSLSocketFactory()
            try {
                assertIs<SSLHandshakeException>(
                    tpOutcome { NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs) },
                    "믿지 않는 인증서",
                )
                HttpsURLConnection.setDefaultSSLSocketFactory(TransportTestTls.trusting)
                val stock = DefaultResourceRetriever(5_000, 20_000, 51_200).retrieveResource(certs)
                val capped = NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs)
                assertEquals(stock.content, capped.content)
                assertEquals(stock.contentType, capped.contentType)
            } finally {
                HttpsURLConnection.setDefaultSSLSocketFactory(saved)
            }
        }
    }

    // Content-Type 이 없는 JWKS 응답 — 내용은 같고 Content-Type 은 둘 다 없다.
    @Test
    fun `jwks without a Content-Type is what Nimbus' default retriever returns`() {
        val untyped = tpLatin1("HTTP/1.1 200 OK\r\nContent-Length: ${TP_JWKS.size}\r\n\r\n" + String(TP_JWKS, Charsets.ISO_8859_1))
        TpCaptureServer(null) { untyped }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val stock = DefaultResourceRetriever(5_000, 20_000, 51_200).retrieveResource(certs)
            val capped = NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs)
            assertEquals(stock.content, capped.content)
            assertNull(stock.contentType)
            assertNull(capped.contentType)
        }
    }

    // JWKS 의 비-2xx 는 조회 실패다 — 메시지는 상태 코드만 싣는다(이유 문구는 응답 바이트다).
    @Test
    fun `jwks - a non-2xx status fails without quoting the reason`() {
        TpCaptureServer(null) { tpLatin1("HTTP/1.1 503 $TP_MARKER\r\nContent-Length: 0\r\n\r\n") }.use { server ->
            val certs = URI("http://127.0.0.1:${server.port}/certs").toURL()
            val t = tpOutcome { NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs) }
            assertIs<IOException>(t)
            assertEquals("JWKS endpoint returned HTTP 503", t.message)
            assertFalse(TP_MARKER in t.stackTraceToString())
        }
    }
}
