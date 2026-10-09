package io.github.xzawed.keycloak

import org.apache.http.HttpClientConnection
import org.apache.http.HttpConnection
import org.apache.http.HttpException
import org.apache.http.HttpHost
import org.apache.http.HttpRequest
import org.apache.http.HttpRequestInterceptor
import org.apache.http.HttpResponse
import org.apache.http.MessageConstraintException
import org.apache.http.NoHttpResponseException
import org.apache.http.ProtocolException
import org.apache.http.client.HttpRequestRetryHandler
import org.apache.http.client.config.RequestConfig
import org.apache.http.client.methods.HttpRequestBase
import org.apache.http.client.protocol.HttpClientContext
import org.apache.http.config.ConnectionConfig
import org.apache.http.config.MessageConstraints
import org.apache.http.config.Registry
import org.apache.http.config.RegistryBuilder
import org.apache.http.conn.ConnectionKeepAliveStrategy
import org.apache.http.conn.ConnectionPoolTimeoutException
import org.apache.http.conn.ConnectionRequest
import org.apache.http.conn.DnsResolver
import org.apache.http.conn.HttpConnectionFactory
import org.apache.http.conn.ManagedHttpClientConnection
import org.apache.http.conn.routing.HttpRoute
import org.apache.http.conn.socket.ConnectionSocketFactory
import org.apache.http.conn.socket.LayeredConnectionSocketFactory
import org.apache.http.conn.socket.PlainConnectionSocketFactory
import org.apache.http.conn.ssl.DefaultHostnameVerifier
import org.apache.http.entity.BasicHttpEntity
import org.apache.http.impl.DefaultConnectionReuseStrategy
import org.apache.http.impl.client.CloseableHttpClient
import org.apache.http.impl.client.DefaultConnectionKeepAliveStrategy
import org.apache.http.impl.client.HttpClientBuilder
import org.apache.http.impl.conn.DefaultHttpResponseParser
import org.apache.http.impl.conn.DefaultManagedHttpClientConnection
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager
import org.apache.http.impl.conn.SystemDefaultRoutePlanner
import org.apache.http.io.BufferInfo
import org.apache.http.io.HttpMessageParserFactory
import org.apache.http.io.SessionInputBuffer
import org.apache.http.protocol.HttpContext
import org.apache.http.protocol.HttpRequestExecutor
import org.apache.http.util.CharArrayBuffer
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.lang.ref.WeakReference
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ProxySelector
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.util.Locale
import java.util.StringTokenizer
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * auth 레인([CappedResponseSender])과 JWKS 레인([NoRedirectResourceRetriever])의 운송 — Apache HttpClient 4.5 / HttpCore 4.4(admin 레인의
 * RESTEasy 가 이미 가져오는 판)를 **HttpURLConnection 처럼** 쓴다. Java `BoundedTransport` 의 이식이다(같은 한도·같은 풀·같은 대조 시험).
 *
 * 왜 바꿨나: JDK 의 운송(`sun.net.www`)은 응답의 틀에 한도가 없는 자리가 있었다 — 짧은 청크 본문 뒤 EOF 까지 읽으면 트레일러를 한도 없이
 * 담았고(4 KiB 줄 4 MiB → 호출 하나 51.5 MB, 한 줄 512 KiB → 4.3 GB · 1.5 초 — 등록부 `jvm-chunked-trailers-unbounded` 의 kotlin 실측,
 * `ResponseFramingBoundsTest`), 상한을 넘은 청크 본문을 닫으면 쌓인 바이트를 제곱 비용으로 풀었고, 1xx 를 끝없이 받으면 재귀하다
 * `StackOverflowError` 가 공개 API 로 나갔다. 그 운송에는 이것들을 끌 노브가 없다.
 *
 * 그래서 여기서는: (1) 응답 머리의 줄·헤더 수 한도([RESPONSE_MAX_LINE_LENGTH] · [RESPONSE_MAX_HEADER_COUNT] — 상태 줄·헤더·청크 크기 줄·
 * 트레일러 모두)를 건다 · (2) 본문을 EOF 까지 읽지 않은 교환의 연결은 **비우지 않고 끊는다**([cut] — 풀에 돌려주지 않는다) · (3) 첫 줄이
 * 상태 줄이 아니면 곧바로 거부하고(HttpURLConnection 처럼 — HttpClient 는 쓰레기 줄을 한도 없이 건너뛴다) 1xx 중간 응답은
 * [MAX_INTERIM_RESPONSES] 개까지만 받는다 · (4) 연결은 프로세스에 하나인 풀에서 다시 쓴다(아래) · (5) 하위 운송의 예외는 응답을 인용할 수
 * 있으므로(`Bad chunk header: <줄>`) 상수 메시지의 [IOException] 으로 바꾼다([shield]) · (6) 본문을 읽는 동안 받는 틀의 바이트를 본문
 * 상한의 [WIRE_FACTOR] 배로 묶는다([wireBounded]) · (7) 거부하며 닫는 TLS 연결이 더 읽지 않게 한다 — JSSE 는 TLS 1.3 을 닫을 때 도착한
 * 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다린다 — 끊기 전에 그 타임아웃을 0 으로 둔다([quiet]) · (8) 다시 쓰려는 연결에 아무도
 * 묻지 않은 바이트가 와 있으면(앞 응답 뒤에 서버가 더 보냈다) 그 연결을 버린다 — 다음 요청이 그것을 제 응답으로 읽는다(HttpURLConnection
 * 은 응답마다 새 버퍼로 읽어 버퍼에 남은 것을 버렸다). TLS 에서 늦게 도착해 아직 풀리지 않은 바이트는 보이지 않는다 — 같은 서버가 같은
 * 연결로 보낸 것이다.
 *
 * **풀**([POOL]): HttpURLConnection 의 keep-alive 캐시처럼 프로세스에 하나다. 클라이언트마다 풀을 두면 호출마다 클라이언트를 만드는
 * 소비자에게 소켓이 클라이언트 수만큼 쌓인다(AuthClient.close 는 아무것도 닫지 않는다 — 소유하는 풀이 없다). 경로(호스트·포트·프록시)마다
 * [MAX_PER_ROUTE] 개까지 — admin 레인의 RESTEasy 풀과 같은 수이고, 넘는 동시 호출은 연결 타임아웃만큼 연결을 기다린다. 백그라운드 스레드가
 * 없다: 쉰 지 [IDLE_MILLIS] ms(서버의 `Keep-Alive: timeout` 이 더 짧으면 그것 — [idleMillis])가 지난 연결은 다음 교환이 닫고,
 * [VALIDATE_AFTER_MILLIS] ms 넘게 쉰 연결은 빌려줄 때 살아 있는지 본다. 다시 쓴 연결이 응답 바이트 하나 없이 끊기면(쉬는 동안 서버가
 * 닫았다) 쉬는 연결을 닫고 새 연결로 한 번 다시 보낸다. 연결에는 맺을 때의 TLS 근원([TlsKey])을 달아 같은 근원의 교환만 다시 쓴다.
 *
 * ⚠️ Kotlin 에서만: 코루틴 취소([onIo] 의 `runInterruptible`)는 이 운송에서 **풀의 기다림만** 끊는다 — 플랫폼 스레드의 소켓 읽기는
 * 인터럽트를 무시한다. 기다림이 끊긴 호출은 연결을 빌리지 않았으므로 남기는 것이 없다(`ConnectionReuseTest` 의 취소 사례들).
 *
 * ⚠️ **HttpURLConnection 과 같아야 하는 것**(실측 대조 — `TransportParityTest`): 요청 머리(User-Agent · Accept · Host · Connection),
 * 제한 헤더를 버리는 규칙([restricted]), 리다이렉트를 따르지 않음, 내용 코딩을 요청하지도 풀지도 않음(상한은 받은 바이트를 센다), 시스템
 * 프록시(`http(s).proxyHost` — `ProxySelector`), 거절된 CONNECT 는 응답이 아니라 IOException, TLS 단계([HucTls]), 연결 재사용, 요청·응답을
 * 로그에 찍지 않음. **따라하지 않는 것**(JVM 전역 훅 — 키클록의 정상 응답에는 닿지 않는다): `CookieHandler` · `ResponseCache` ·
 * `java.net.Authenticator`(401·407 도전에 답하지 않는다), 새 연결의 한 번 재시도, `http.keepAlive=false` 의 `Connection: close`,
 * `http.maxConnections`(쉬는 연결 5 개).
 */
internal object BoundedTransport {
    /** 1xx 중간 응답을 이보다 많이 받으면 거부한다 — 끝없이 보내는 서버에 시간이 묶이도록(HttpURLConnection 은 재귀하다 넘쳤다). */
    const val MAX_INTERIM_RESPONSES: Int = 8

    /** 본문을 읽는 동안 연결에서 받아도 되는 바이트 — 본문 상한의 이 배수([wireBounded]). */
    const val WIRE_FACTOR: Int = 8

    /** 본문 읽기 한 번이 소켓에 요청하는 최대 바이트 — 그 사이에 받은 바이트를 센다([wireBounded]). */
    const val MAX_READ: Int = 16 * 1024

    /** 경로(호스트·포트·프록시) 하나에 동시에 여는 연결의 상한 — admin 레인의 RESTEasy 풀(경로당 50)과 같다. 넘는 호출은 기다린다. */
    const val MAX_PER_ROUTE: Int = 50

    /** 쉬는 연결의 수명 — HttpURLConnection 의 기본(KeepAliveCache 5 초). */
    const val IDLE_MILLIS: Long = 5_000

    /** 이보다 오래 쉰 연결은 빌려줄 때 1 ms 읽기로 살아 있는지 본다(HttpClient 의 기본값). */
    const val VALIDATE_AFTER_MILLIS: Int = 2_000

    /** 하위 운송이 응답을 해석하지 못했다 — HttpURLConnection 이 같은 경우에 쓰는 말 그대로. 응답을 인용하지 않는다. */
    const val INVALID_RESPONSE: String = "Invalid Http response"

    /** 응답 머리·청크 줄·트레일러가 한도를 넘었다. 응답을 인용하지 않는다. */
    const val OVER_LIMITS: String =
        "HTTP response framing exceeds $RESPONSE_MAX_LINE_LENGTH-byte lines or $RESPONSE_MAX_HEADER_COUNT header fields"

    /** 프록시가 CONNECT 를 거절했다(HttpURLConnection 처럼 응답이 아니라 IOException — 프록시의 응답은 인용하지 않는다). */
    const val TUNNEL_REFUSED: String = "Unable to tunnel through proxy"

    /** 경로의 연결이 모두 쓰이는 동안 연결 타임아웃이 지났다. */
    const val POOL_TIMEOUT: String = "Timed out waiting for a pooled connection"

    /** 연결을 기다리던 스레드가 인터럽트됐다(코루틴 취소 — [onIo] 가 CancellationException 으로 바꾼다). */
    const val INTERRUPTED: String = "Interrupted while waiting for a pooled connection"

    /** HttpURLConnection 의 기본 User-Agent — 그 클래스처럼 초기화 때 한 번 읽는다. */
    val USER_AGENT: String = userAgent(System.getProperty("http.agent"), System.getProperty("java.version"))

    /** HttpURLConnection 의 기본 Accept — JDK 21 부터 `*` `/` `*` 다(17 은 옛 목록). */
    val ACCEPT: String = acceptFor(Runtime.version().feature())

    private const val APACHE = "org.apache.http."
    private const val NAME = "io.github.xzawed.keycloak.BoundedTransport"
    private const val TLS_FACTORY = "$NAME.tlsFactory"
    private const val TLS_VERIFIER = "$NAME.tlsVerifier"

    /** 교환의 읽기 타임아웃 — 풀의 소켓 설정은 교환마다 다르지 않으므로 소켓을 맺는 자리(아래 팩토리들)가 이것으로 건다. */
    private const val READ_TIMEOUT = "$NAME.readTimeout"

    /** 본문을 읽는 동안 받아도 되는 바이트 — 실행기가 본문 스트림에 건다. */
    private const val WIRE_BUDGET = "$NAME.wireBudget"

    /** 이 시도가 연결을 새로 맺었다 — 다시 보내기는 다시 쓴 연결에만 한다. */
    private const val FRESH = "$NAME.fresh"

    /** 이 시도의 요청에 응답 바이트가 하나도 오지 않았다. */
    private const val UNANSWERED = "$NAME.unanswered"

    /** 연결의 속성 — 다시 쓰려는 연결에 아무도 묻지 않은 바이트가 와 있다([CONNECTIONS]). */
    const val UNSOLICITED: String = "$NAME.unsolicited"

    /** HttpURLConnection 이 요청 머리에서 조용히 버리는 이름(소문자) — `sun.net.http.allowRestrictedHeaders` 기본. */
    private val RESTRICTED: Set<String> =
        setOf(
            "access-control-request-headers",
            "access-control-request-method",
            "connection",
            "content-length",
            "content-transfer-encoding",
            "host",
            "keep-alive",
            "origin",
            "trailer",
            "transfer-encoding",
            "upgrade",
            "via",
        )

    /** 없는 TLS 근원 — 약한 참조의 null(사라진 근원)과 가르려고 강하게 쥔 표지다([TlsKey]). */
    private val NO_TLS_SOURCE = Any()

    private val BOUNDED_HEAD: ConnectionConfig =
        ConnectionConfig
            .custom()
            .setMessageConstraints(
                MessageConstraints
                    .custom()
                    .setMaxLineLength(RESPONSE_MAX_LINE_LENGTH)
                    .setMaxHeaderCount(RESPONSE_MAX_HEADER_COUNT)
                    .build(),
            ).build()

    /** 첫 줄이 상태 줄이 아니면 거부하는 응답 해석기 — HttpClient 의 기본은 쓰레기 줄을 한도 없이 건너뛴다. */
    private val STATUS_LINE_FIRST =
        HttpMessageParserFactory<HttpResponse> { buffer, constraints -> StatusLineFirstParser(buffer, constraints) }

    private val CONNECTION_IDS = AtomicLong()

    /**
     * 연결 — HttpCore 의 기본 연결에, 다시 쓰기 전에 묻지 않은 바이트가 와 있는지 답하는 문맥 속성 하나를 더했다([UNSOLICITED] — 풀의
     * 대리자가 그대로 넘긴다). ⚠️ HttpClient 의 기본 공장(`ManagedHttpClientConnectionFactory`)은 쓰지 않는다 — 그 연결은 DEBUG 에서 요청
     * 머리(Authorization 의 Basic 자격 포함)와 오가는 바이트(토큰)를 그대로 찍는다.
     */
    val CONNECTIONS: HttpConnectionFactory<HttpRoute, ManagedHttpClientConnection> =
        HttpConnectionFactory { _, config -> BoundedConnection("keycloak-sdk-" + CONNECTION_IDS.incrementAndGet(), config) }

    /** HttpURLConnection 처럼 이름의 첫 주소 하나에만 붙는다(HttpClient 의 기본은 주소마다 연결 타임아웃을 다시 쓴다). */
    private val FIRST_ADDRESS = DnsResolver { host -> arrayOf(InetAddress.getByName(host)) }

    private val SOCKETS: Registry<ConnectionSocketFactory> =
        RegistryBuilder
            .create<ConnectionSocketFactory>()
            .register("http", PlainSockets)
            .register("https", HucTls)
            .build()

    /** HttpURLConnection 처럼 `keep-alive` — 평문 프록시를 지날 때는 `Proxy-Connection` 이다. 이미 있으면 둔다. */
    private val CONNECTION =
        HttpRequestInterceptor { request, context ->
            val route = HttpClientContext.adapt(context).httpRoute
            val name = if (route.proxyHost != null && !route.isTunnelled) "Proxy-Connection" else "Connection"
            if (!request.containsHeader(name)) request.addHeader(name, "keep-alive")
        }

    /** 서버가 `Keep-Alive: timeout` 으로 준 시간과 [IDLE_MILLIS] 중 짧은 것 — [idleMillis]. */
    private val KEEP_ALIVE =
        ConnectionKeepAliveStrategy { response, context ->
            idleMillis(DefaultConnectionKeepAliveStrategy.INSTANCE.getKeepAliveDuration(response, context))
        }

    /**
     * 한 번만 다시 보낸다 — 풀에서 꺼낸(다시 쓰는) 연결이 응답 바이트 하나 없이 끊겼을 때만(쉬는 동안 서버가 닫은 연결). 새 연결의 실패와
     * 응답이 오다 끊긴 것은 다시 보내지 않는다 — 서버가 처리한 요청(인가 코드·회전하는 refresh 토큰)을 두 번 보내지 않게. 다시 보내기 전에
     * 쉬는 연결을 모두 닫는다 — 하나가 죽었으면 함께 쉬던 것들도 그럴 수 있어(서버가 다시 떴다) 다시 보내기가 또 죽은 연결을 빌리지 않게, 새
     * 연결로 간다. 시도 수의 한도는 그 사이 다른 교환이 죽은 연결을 돌려준 경우를 묶는다.
     */
    private val STALE_ONCE =
        HttpRequestRetryHandler { failure, attempt, context ->
            val stale =
                attempt == 1 &&
                    context.getAttribute(FRESH) == null &&
                    context.getAttribute(UNANSWERED) != null &&
                    (failure is NoHttpResponseException || failure is SocketException)
            if (stale) POOL.closeIdleConnections(0, TimeUnit.MILLISECONDS)
            stale
        }

    /** 교환들이 함께 쓰는 연결 풀 — 프로세스에 하나(객체 설명). */
    val POOL: PoolingHttpClientConnectionManager =
        BoundedPool().apply {
            defaultConnectionConfig = BOUNDED_HEAD
            defaultMaxPerRoute = MAX_PER_ROUTE
            maxTotal = Int.MAX_VALUE // 경로마다의 상한이 묶는다 — 경로는 소비자의 설정이 정한다(응답이 만들지 못한다)
            validateAfterInactivity = VALIDATE_AFTER_MILLIS
        }

    private val CLIENT: CloseableHttpClient =
        HttpClientBuilder
            .create()
            .setConnectionManager(POOL)
            .setConnectionManagerShared(true)
            .setRoutePlanner(SystemDefaultRoutePlanner(null as ProxySelector?))
            .setRequestExecutor(BoundedExecutor())
            .setUserAgent(USER_AGENT)
            .addInterceptorFirst(CONNECTION)
            .setConnectionReuseStrategy(DefaultConnectionReuseStrategy.INSTANCE)
            .setKeepAliveStrategy(KEEP_ALIVE)
            .setRetryHandler(STALE_ONCE)
            .disableRedirectHandling()
            .disableContentCompression()
            .disableCookieManagement()
            .build()

    /**
     * 교환 하나 — 풀의 연결로 [request] 를 보내고 상태와 머리가 오면 [reader] 에 넘긴다. 본문을 EOF 까지 읽었으면 연결은 그때 이미 풀로
     * 돌아갔고(재사용), 아니면(넘침·거부·실패) [cut] 이 그 연결을 읽지 않고 끊는다. 실패는 [shield] 를 거친 IOException 이다. TLS 근원은
     * HttpURLConnection 이 쓰는 소켓 팩토리와 검증기다([HucTls]) — 그 근원이 연결의 표식이다([TlsKey]). ⚠️ [reader] 는 본문 스트림을 닫지
     * 않는다 — 닫기는 나머지를 비운다(HttpCore).
     *
     * 본문을 읽는 동안 연결에서 받은 바이트(청크 머리·확장·트레일러 포함)는 [bodyCap] 의 [WIRE_FACTOR] 배까지다([wireBounded]) — 본문 상한은
     * 본문만 세서, 한 바이트짜리 청크마다 크기 줄을 줄 한도(8,192)까지 채우면(「0000…01」) 상한 안의 본문에 8 GB 의 틀을 실을 수 있었다(Java
     * 실측: 청크 200,000 개에 1.6 GB 를 받아 할당하고 4.0 초 — 그리고 받아들였다). 1 바이트 청크의 틀은 본문의 6 배라 그 응답도 본문 상한에
     * 먼저 닿는다.
     */
    fun <T> exchange(
        request: HttpRequestBase,
        tlsFactory: SSLSocketFactory?,
        verifier: HostnameVerifier?,
        connectTimeoutMillis: Int,
        readTimeoutMillis: Int,
        bodyCap: Int,
        reader: (HttpResponse, InputStream) -> T,
    ): T {
        POOL.closeExpiredConnections() // 스레드 없이 — 수명이 지난 쉬는 연결은 다음 교환이 닫는다
        request.config =
            RequestConfig
                .custom()
                .setConnectTimeout(connectTimeoutMillis)
                .setConnectionRequestTimeout(connectTimeoutMillis)
                .setSocketTimeout(readTimeoutMillis)
                .setAuthenticationEnabled(false)
                .build()
        val context = HttpClientContext.create()
        context.setAttribute(TLS_FACTORY, tlsFactory)
        context.setAttribute(TLS_VERIFIER, verifier)
        context.setAttribute(READ_TIMEOUT, readTimeoutMillis)
        context.setAttribute(WIRE_BUDGET, WIRE_FACTOR.toLong() * bodyCap)
        context.userToken = TlsKey(tlsFactory, verifier)
        try {
            val head = CLIENT.execute(request, context)
            val entity = head.entity
            return reader(head, if (entity == null) InputStream.nullInputStream() else entity.content)
        } catch (e: IOException) {
            throw shield(e)
        } finally {
            cut(request, context)
        }
    }

    /**
     * 교환의 끝. 본문을 EOF 까지 읽은 연결은 그때 이미 풀로 돌아갔다 — 여기서는 아무것도 하지 않는다(이 교환의 연결 대리자는 그때 떨어져
     * 나갔다). 그 밖의 끝(넘침·거부·실패)은 그 연결을 **읽지 않고** 끊는다 — 읽기 타임아웃을 0 으로 두고([quiet]) 요청을 중단하면 HttpClient
     * 가 연결을 SO_LINGER 0 으로 닫고 풀에서 뺀다(`ConnectionHolder.abortConnection`). ⚠️ 본문 스트림을 닫거나 `EntityUtils.consume`·
     * `consumeContent` 로 「놓지」 말 것 — HttpCore 의 닫기는 나머지를 EOF 까지 비우고, `consumeContent` 는 다 읽지 않은 연결을 풀에
     * 돌려준다(다음 교환이 남은 본문을 응답으로 읽는다).
     */
    private fun cut(
        request: HttpRequestBase,
        context: HttpClientContext,
    ) {
        val connection = context.connection
        if (connection != null) quiet(connection)
        request.abort()
    }

    /**
     * 곧 닫을 연결의 읽기 타임아웃을 0 으로 — JSSE 는 TLS 1.3 을 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다리고
     * (타임아웃이 0 이면 읽지 않는다 — `SSLSocketImpl.readLockedDeplete`), 조용한 서버 앞에서 거부가 그만큼 늦었다. 이미 풀로 돌아간 연결
     * (이 교환의 대리자가 떨어져 나갔다)은 건드리지 않는다.
     */
    fun quiet(connection: HttpConnection) {
        try {
            connection.socketTimeout = 0
        } catch (returned: RuntimeException) {
            // 이미 풀로 돌아갔다 — 이 교환의 것이 아니다
        }
    }

    /** 빌린 연결을 다시 쓰지 않고 닫는다 — 읽지 않는다([quiet]). 닫기의 실패는 버린다(어차피 쓰지 않는다). */
    fun discard(connection: HttpConnection) {
        quiet(connection)
        try {
            connection.close()
        } catch (ignored: IOException) {
            // 쓰지 않을 연결이다
        }
    }

    /**
     * 본문 스트림 — 읽기마다 이 연결이 받은 바이트(소켓에서 버퍼로 — HttpCore 의 연결 지표)를 세어, 본문을 읽기 시작한 뒤 [budget] 을
     * 넘으면 상수 메시지로 거부한다. 한 번의 읽기가 넘는 양은 [MAX_READ] 바이트(HttpCore 는 큰 요청을 버퍼를 거치지 않고 소켓에서 바로
     * 읽는다 — 그래서 요청 길이를 자른다)와 청크 머리 한 줄, 트레일러 한 묶음(줄·헤더 수 한도 안)까지다. 길이 0 의 읽기는 소켓에 닿지 않고
     * 0 이다 — HttpCore 의 버퍼는 비었을 때 그것도 기다리고, JDK 의 `readNBytes` 는 다 채운 뒤 길이 0 으로 한 번 더 묻는다. 거부하거나
     * 읽기가 실패하면 연결의 읽기 타임아웃을 0 으로 둔다([quiet]) — HttpClient 가 곧 그 연결을 닫는다.
     */
    fun wireBounded(
        body: InputStream,
        connection: HttpClientConnection,
        budget: Long,
    ): InputStream = WireBoundedStream(body, connection, budget)

    /**
     * 하위 운송의 예외를 응답을 인용하지 않는 것으로 — JDK 의 예외(타임아웃·연결 거부·TLS·DNS)와 SDK 의 것은 그대로 두고, HttpClient 가 JDK
     * 의 예외를 감싼 것(연결 실패)은 그 원인을 꺼내고(HttpURLConnection 이 던지는 바로 그것), 풀의 기다림이 끝난 것은 JDK 의 타임아웃·인터럽트
     * 예외로, 나머지(틀 오류 · 한도 초과)는 상수 메시지의 IOException 이다 — 원인을 달지 않는다(HttpCore 의 메시지는 응답의 줄을 싣는다:
     * `Bad chunk header: <줄>`).
     */
    fun shield(e: IOException): IOException {
        if (!e.javaClass.name.startsWith(APACHE)) return e
        val cause = e.cause
        if (cause is IOException) return shield(cause)
        if (e is ConnectionPoolTimeoutException) return SocketTimeoutException(POOL_TIMEOUT)
        if (e is InterruptedIOException) return InterruptedIOException(INTERRUPTED)
        return IOException(if (e is MessageConstraintException) OVER_LIMITS else INVALID_RESPONSE)
    }

    /** 서버가 준 쉬는 시간(없으면 음수)을 풀의 쉬는 수명으로 — [IDLE_MILLIS] 를 넘지 않고, 0 이면 곧 닫는다(1 ms). */
    fun idleMillis(serverMillis: Long): Long = if (serverMillis < 0) IDLE_MILLIS else serverMillis.coerceIn(1, IDLE_MILLIS)

    private fun readTimeout(context: HttpContext): Int = context.getAttribute(READ_TIMEOUT) as Int

    /** HttpURLConnection 이 조용히 버리는 요청 헤더인가 — `Connection: close` 는 허용하고 `Sec-*` 는 버린다. */
    fun restricted(
        name: String,
        value: String,
    ): Boolean {
        val key = name.lowercase(Locale.ROOT)
        if (key in RESTRICTED) return !(key == "connection" && value.equals("close", ignoreCase = true))
        return key.startsWith("sec-")
    }

    /** 헤더 표를 요청에 싣는다 — HttpURLConnection 의 `addRequestProperty` 처럼 제한 헤더는 버린다. */
    fun addHeaders(
        request: HttpRequestBase,
        headers: Map<String, List<String>>,
    ) {
        for ((name, values) in headers) {
            for (value in values) {
                if (!restricted(name, value)) request.addHeader(name, value)
            }
        }
    }

    /** HttpURLConnection 이 덧붙이는 Host(기본 포트는 적지 않는다)와, 없으면 Accept. */
    fun addJdkDefaults(
        request: HttpRequestBase,
        url: URL,
    ) {
        request.setHeader("Host", hostHeader(url))
        if (!request.containsHeader("Accept")) request.addHeader("Accept", ACCEPT)
    }

    fun hostHeader(url: URL): String {
        val port = url.port
        return if (port == -1 || port == url.defaultPort) url.host else "${url.host}:$port"
    }

    fun userAgent(
        agent: String?,
        javaVersion: String,
    ): String = if (agent == null) "Java/$javaVersion" else "$agent Java/$javaVersion"

    fun acceptFor(jdkFeature: Int): String = if (jdkFeature >= 21) "*/*" else "text/html, image/gif, image/jpeg, */*; q=0.2"

    /** 응답 헤더를 이름(대소문자 그대로)별로 모은다 — 받은 순서 그대로. */
    fun grouped(head: HttpResponse): Map<String, List<String>> {
        val out = linkedMapOf<String, MutableList<String>>()
        for (header in head.allHeaders) out.getOrPut(header.name) { mutableListOf() } += header.value
        return out
    }

    /** HttpURLConnection 처럼 쉼표로 나눈 목록(공백을 다듬지 않는다) — 없거나 비면 빈 배열(그때는 걸지 않는다). */
    fun tokens(value: String?): Array<String> {
        if (value == null) return emptyArray()
        val t = StringTokenizer(value, ",")
        return Array(t.countTokens()) { t.nextToken() }
    }

    /**
     * 풀의 연결에 다는 표식 — 그 연결을 맺은 TLS 근원(소켓 팩토리·검증기)의 정체. 풀은 같은 표식의 교환에만 그 연결을 빌려준다
     * (`RouteSpecificPool.getFree(state)`). HttpURLConnection 은 소켓 팩토리만 가려 검증기가 다른 교환도 검증 없이 다시 썼다 — 더 엄격하다.
     * 근원을 붙잡지 않는다(약한 참조) — 근원이 사라진 표식은 자기 자신 말고는 무엇과도 같지 않아 그 연결은 다시 쓰이지 않고 수명이 지나면
     * 닫힌다(빌리는 교환은 제 근원을 쥐고 있으므로 살아 있다). 없는 근원(null)은 하나의 표지로 센다. 비밀을 쥐지 않고, 문자열 표현은 상수다.
     */
    class TlsKey(
        factory: SSLSocketFactory?,
        verifier: HostnameVerifier?,
    ) {
        private val factory: WeakReference<Any>
        private val verifier: WeakReference<Any>
        private val hash: Int

        init {
            val f: Any = factory ?: NO_TLS_SOURCE
            val v: Any = verifier ?: NO_TLS_SOURCE
            this.factory = WeakReference(f)
            this.verifier = WeakReference(v)
            hash = 31 * System.identityHashCode(f) + System.identityHashCode(v)
        }

        override fun equals(other: Any?): Boolean {
            if (other === this) return true
            if (other !is TlsKey) return false
            val f = factory.get()
            val v = verifier.get()
            return f != null && v != null && f === other.factory.get() && v === other.verifier.get()
        }

        override fun hashCode(): Int = hash

        override fun toString(): String = "TlsKey"
    }

    /**
     * HttpURLConnection 의 TLS 단계(`sun.net.www.protocol.https.HttpsClient.afterConnect`) — 근원(소켓 팩토리·검증기)은 교환의 문맥에서
     * 받는다(상태가 없다). `https.protocols`·`https.cipherSuites` 를 그대로 걸고, 검증기가 JDK 기본이면 핸드셰이크 안에서 RFC 2818 검사를
     * 하고(그래서 불일치는 HttpURLConnection 과 같은 SSLHandshakeException 이다), 아니면 핸드셰이크 뒤 엄격한 검사 → 검증기 순서로 묻는다.
     * ⚠️ 그 기본 검증기를 Apache 의 검증기로 그냥 넘기면 모든 HTTPS 호출이 깨진다 — JDK 의 기본 검증기 객체는 늘 거짓을 돌려주고,
     * HttpURLConnection 이 이름으로 알아보아 따로 처리한다(Java 실측). 핸드셰이크는 교환의 읽기 타임아웃 아래에서 한다.
     */
    object HucTls : LayeredConnectionSocketFactory {
        private const val JDK_DEFAULT_VERIFIER = "javax.net.ssl.HttpsURLConnection.DefaultHostnameVerifier"
        private val STRICT: HostnameVerifier = DefaultHostnameVerifier()
        private val BRACKETED = Regex("^\\[(.*)]$")

        override fun createSocket(context: HttpContext?): Socket = Socket() // JDK 의 기본 소켓 구현 — socksProxyHost 를 따른다

        override fun connectSocket(
            connectTimeout: Int,
            socket: Socket,
            host: HttpHost,
            remoteAddress: InetSocketAddress,
            localAddress: InetSocketAddress?,
            context: HttpContext,
        ): Socket {
            try {
                socket.connect(remoteAddress, connectTimeout)
            } catch (failed: IOException) {
                socket.close()
                throw failed
            }
            return createLayeredSocket(socket, host.hostName, remoteAddress.port, context)
        }

        override fun createLayeredSocket(
            socket: Socket,
            target: String,
            port: Int,
            context: HttpContext,
        ): Socket {
            val factory = context.getAttribute(TLS_FACTORY) as SSLSocketFactory
            val verifier = context.getAttribute(TLS_VERIFIER) as HostnameVerifier
            socket.soTimeout = readTimeout(context)
            val tls = factory.createSocket(socket, target, port, true) as SSLSocket
            try {
                handshake(tls, target, verifier)
            } catch (failed: IOException) {
                throw closedAfter(tls, failed)
            } catch (failed: RuntimeException) {
                throw closedAfter(tls, failed)
            }
            return tls
        }

        /**
         * 넘기기 전의 실패 — 이 소켓을 여기서 닫는다(autoClose 라 그 아래 평문 소켓도). 핸드셰이크 전이라 읽을 것이 없거나 이미 닫혔다
         * (검증기 거부 · JSSE 의 핸드셰이크 실패) — 닫기가 기다리지 않는다(Java 의 SonarCloud S2095 수정과 같다).
         */
        private fun <E : Exception> closedAfter(
            tls: SSLSocket,
            failed: E,
        ): E {
            try {
                tls.close()
            } catch (ignored: IOException) {
                // 실패한 연결이다 — 처음의 실패를 던진다
            }
            return failed
        }

        /** HttpURLConnection 처럼 규약·암호 묶음을 걸고, 이름 검사를 정해 핸드셰이크한다(검사가 뒤에 오면 [checkHostname]). */
        private fun handshake(
            tls: SSLSocket,
            target: String,
            verifier: HostnameVerifier,
        ) {
            val protocols = tokens(System.getProperty("https.protocols"))
            if (protocols.isNotEmpty()) tls.enabledProtocols = protocols
            val suites = tokens(System.getProperty("https.cipherSuites"))
            if (suites.isNotEmpty()) tls.enabledCipherSuites = suites
            var checkAfter = true
            val identification = tls.sslParameters.endpointIdentificationAlgorithm
            if (!identification.isNullOrEmpty()) {
                checkAfter = !identification.equals("HTTPS", ignoreCase = true) // 팩토리가 이미 핸드셰이크 안의 검사를 걸었다
            } else if (JDK_DEFAULT_VERIFIER == verifier.javaClass.canonicalName) {
                val parameters = tls.sslParameters
                parameters.endpointIdentificationAlgorithm = "HTTPS"
                tls.sslParameters = parameters
                checkAfter = false
            }
            tls.startHandshake()
            if (checkAfter) checkHostname(tls, target, verifier)
        }

        /**
         * HttpsClient.checkURLSpoofing — 엄격한 검사가 맞으면 통과, 아니면 검증기에 묻고, 둘 다 아니면 닫고 던진다(닫기 전에 읽기 타임아웃을
         * 0 으로 — 조용한 서버 앞에서 JSSE 가 기다리지 않게).
         */
        private fun checkHostname(
            tls: SSLSocket,
            target: String,
            verifier: HostnameVerifier,
        ) {
            val host = target.replaceFirst(BRACKETED, "$1")
            val session = tls.session
            if (STRICT.verify(host, session) || verifier.verify(host, session)) return
            tls.soTimeout = 0
            tls.close()
            session.invalidate()
            throw IOException("HTTPS hostname wrong:  should be <$target>")
        }
    }

    /** 평문 소켓 — 맺은 뒤 교환의 읽기 타임아웃을 건다(프록시의 CONNECT 응답도 그 아래에서 읽는다). */
    private object PlainSockets : ConnectionSocketFactory {
        override fun createSocket(context: HttpContext?): Socket = Socket()

        override fun connectSocket(
            connectTimeout: Int,
            socket: Socket?,
            host: HttpHost?,
            remoteAddress: InetSocketAddress?,
            localAddress: InetSocketAddress?,
            context: HttpContext,
        ): Socket {
            val connected =
                PlainConnectionSocketFactory
                    .getSocketFactory()
                    .connectSocket(connectTimeout, socket, host, remoteAddress, localAddress, context)
            connected.soTimeout = readTimeout(context)
            return connected
        }
    }

    /** 첫 줄이 상태 줄이 아니면 곧바로 거부한다 — 쓰레기 줄을 건너뛰지 않는다(HttpURLConnection 의 「Invalid Http response」). */
    private class StatusLineFirstParser(
        buffer: SessionInputBuffer,
        constraints: MessageConstraints?,
    ) : DefaultHttpResponseParser(buffer, null, null, constraints) {
        override fun reject(
            line: CharArrayBuffer?,
            count: Int,
        ): Boolean = true
    }

    /** [CONNECTIONS] 가 짓는 연결 — HttpCore 의 기본 연결(로그 없음)에 [UNSOLICITED] 속성을 더했다. */
    private class BoundedConnection(
        id: String,
        config: ConnectionConfig,
    ) : DefaultManagedHttpClientConnection(
            id,
            config.bufferSize,
            config.fragmentSizeHint,
            null,
            null,
            config.messageConstraints,
            null,
            null,
            null,
            STATUS_LINE_FIRST,
        ) {
        override fun getAttribute(id: String?): Any? = if (id == UNSOLICITED) unsolicited() else super.getAttribute(id)

        /** 입력 버퍼에 남은 바이트, 또는 소켓에 와 있는 바이트(TLS 면 JSSE 가 이미 푼 것만 보인다). 요청을 보내기 전이니 묻지 않은 것이다. */
        private fun unsolicited(): Boolean =
            try {
                (sessionInputBuffer as BufferInfo).length() > 0 || socket.getInputStream().available() > 0
            } catch (gone: IOException) {
                true
            }
    }

    /**
     * 1xx 를 세고, 거절된 CONNECT 를 IOException 으로 바꾸고, 본문에 틀 예산을 걸고([wireBounded]), 실패한 시도가 응답 바이트를 받았는지
     * 적는 실행기 — 상태가 없어 모든 교환이 함께 쓴다. 응답을 받다 실패하면 HttpCore 가 곧 연결을 닫으므로 그 전에 읽기 타임아웃을 0 으로
     * 둔다([quiet] — 요청을 쓰다 실패한 연결은 이미 죽어 JSSE 가 기다릴 것이 없다).
     */
    private class BoundedExecutor : HttpRequestExecutor() {
        override fun execute(
            request: HttpRequest,
            conn: HttpClientConnection,
            context: HttpContext,
        ): HttpResponse {
            val before = conn.metrics.receivedBytesCount
            val response =
                try {
                    super.execute(request, conn, context)
                } catch (e: IOException) {
                    if (conn.metrics.receivedBytesCount == before) context.setAttribute(UNANSWERED, true)
                    throw e
                }
            // HttpClient 는 거절된 CONNECT 의 응답(본문까지 통째로 버퍼에 담아)을 호출자에게 돌려준다 — 받기 전에 끊는다.
            if (request.requestLine.method == "CONNECT" && response.statusLine.statusCode != 200) throw IOException(TUNNEL_REFUSED)
            return response
        }

        override fun doReceiveResponse(
            request: HttpRequest,
            conn: HttpClientConnection,
            context: HttpContext,
        ): HttpResponse {
            try {
                var interim = 0
                while (true) {
                    val response = conn.receiveResponseHeader()
                    if (response.statusLine.statusCode >= 200) {
                        if (canResponseHaveBody(request, response)) {
                            conn.receiveResponseEntity(response)
                            // HttpCore 가 만든 그대로의 엔티티(BHttpConnectionBase.prepareInput) — 그 스트림 위에, EOF 를 알아채 연결을 놓는
                            // HttpClient 의 감싸개 아래에 건다: 마지막 읽기(트레일러 포함)까지 연결을 쥔 채로 센다.
                            val entity = response.entity as BasicHttpEntity
                            entity.content = wireBounded(entity.content, conn, context.getAttribute(WIRE_BUDGET) as Long)
                        }
                        return response
                    }
                    if (interim >= MAX_INTERIM_RESPONSES) throw ProtocolException("too many interim responses")
                    interim++
                }
            } catch (e: IOException) {
                quiet(conn)
                throw e
            } catch (e: HttpException) {
                quiet(conn)
                throw e
            } catch (e: RuntimeException) {
                quiet(conn)
                throw e
            }
        }
    }

    /** [POOL] 의 관리자 — 새로 맺은 시도를 표시하고, 다시 쓰려는 연결을 빌려주기 전에 걸러 내고, 닫히지 않는다. */
    private class BoundedPool :
        PoolingHttpClientConnectionManager(SOCKETS, CONNECTIONS, null, FIRST_ADDRESS, -1, TimeUnit.MILLISECONDS) {
        override fun connect(
            conn: HttpClientConnection,
            route: HttpRoute,
            connectTimeout: Int,
            context: HttpContext,
        ) {
            context.setAttribute(FRESH, true)
            super.connect(conn, route, connectTimeout, context)
        }

        override fun requestConnection(
            route: HttpRoute?,
            state: Any?,
        ): ConnectionRequest = ScreenedLease(super.requestConnection(route, state))

        override fun shutdown() {
            // 닫지 않는다 — HttpClient 는 교환 중에 Error 가 나면 관리자를 닫는데, 이 풀은 프로세스에 하나라 그러면 이 JVM 의 auth·JWKS
            // 레인이 끝난다. 그 교환이 쥔 연결은 exchange 의 끝(cut)이 끊는다.
        }
    }

    /**
     * 빌려주기 전에 거르는 대여 — 다시 쓰려는 연결에 묻지 않은 바이트가 와 있다(앞 응답 뒤에 서버가 더 보냈다) — 다음 요청이 그것을 제
     * 응답으로 읽는다. 닫으면 HttpClient 가 같은 자리에 새 소켓을 맺는다(그 시도는 새 연결이다). HttpURLConnection 은 응답마다 새 버퍼로
     * 읽어 버퍼에 남은 것을 버렸다(Java 실측).
     */
    private class ScreenedLease(
        private val lease: ConnectionRequest,
    ) : ConnectionRequest {
        override fun get(
            timeout: Long,
            unit: TimeUnit?,
        ): HttpClientConnection {
            val conn = lease.get(timeout, unit)
            if (conn.isOpen && (conn as HttpContext).getAttribute(UNSOLICITED) == true) discard(conn)
            return conn
        }

        override fun cancel(): Boolean = lease.cancel()
    }

    /** [wireBounded] 의 스트림. */
    private class WireBoundedStream(
        body: InputStream,
        private val connection: HttpClientConnection,
        private val budget: Long,
    ) : FilterInputStream(body) {
        private val metrics = connection.metrics
        private val start = metrics.receivedBytesCount
        private val overBudget = "HTTP response body framing exceeds $budget bytes on the wire"

        override fun read(): Int {
            try {
                val b = super.read()
                requireWithinBudget()
                return b
            } catch (e: IOException) {
                quiet(connection)
                throw e
            }
        }

        override fun read(
            buffer: ByteArray,
            offset: Int,
            length: Int,
        ): Int {
            if (length == 0) return 0
            try {
                val n = super.read(buffer, offset, minOf(length, MAX_READ))
                requireWithinBudget()
                return n
            } catch (e: IOException) {
                quiet(connection)
                throw e
            }
        }

        private fun requireWithinBudget() {
            if (metrics.receivedBytesCount - start > budget) throw IOException(overBudget)
        }
    }
}
