package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.RESPONSE_LATE
import org.apache.http.config.RegistryBuilder
import org.apache.http.conn.socket.ConnectionSocketFactory
import org.apache.http.conn.socket.PlainConnectionSocketFactory
import org.apache.http.conn.ssl.SSLConnectionSocketFactory
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager
import org.apache.http.protocol.HttpContext
import java.io.FilterInputStream
import java.io.InputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext

/**
 * admin 레인의 소켓(Java `AdminSockets` 동형) — 읽기마다 이 스레드가 지금 하는 교환의 마감을 본다. 상태 줄·헤더·청크 크기 줄·트레일러·본문·TLS
 * 레코드가 모두 이 읽기로 온다(TLS 는 이 위에 겹친다 — JSSE 는 레코드를 이 소켓의 스트림에서 읽는다). auth 레인의
 * [io.github.xzawed.keycloak.BoundedTransport] 와 같은 규칙이되 그 객체를 부르지 않는다 — 건드리면 admin 만 쓰는 소비자에게도 auth 의 프로세스
 * 풀이 지어진다.
 *
 * 왜: 엔진의 엔티티 스트림([AdminEngine.Settled])은 읽기 하나의 앞뒤에서만 마감을 본다. 그 밖인 응답 머리와, 읽기 하나 안의 틀(청크 크기 줄 ·
 * 트레일러)·TLS 레코드는 읽기마다의 타임아웃만 묶어 — 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 읽기 타임아웃 1 초에 7 초(틀)와
 * 33 초(TLS 레코드)가 걸렸다(Java 실측 — 그 커밋 메시지 · 이 레인은 `admin.ResponseReadDeadlineTest`). 그 소켓은 RESTEasy 가 지은 풀의
 * 것이라, 같은 크기·수명·소켓 설정의 풀을 이 소켓으로 다시 짓는다([pool]).
 *
 * 마감은 소켓이 아니라 스레드에 둔다 — 소켓은 풀에서 교환을 건너 산다. 교환 하나는 요청을 보낸 스레드에서 끝까지 읽힌다(코루틴의 IO 스레드 하나가
 * RESTEasy 의 동기 호출을 돈다) — 소비자가 `raw()` 의 응답을 다른 스레드에서 읽으면 그 읽기는 이 마감 밖이고, 엔진의 스트림과 읽기 타임아웃이
 * 묶는다.
 */
internal object AdminSockets {
    /** 이 스레드가 지금 하는 교환의 마감 — `[System.nanoTime() 의 마감, 그 길이(ms)]`. 보낼 때 걸고([arm]) 끝이 지운다([disarm]). */
    private val DEADLINE = ThreadLocal<LongArray>()

    /** 평문 — 맺는 것은 HttpClient 의 기본 그대로, 소켓만 이 레인의 것이다. */
    private val PLAIN: ConnectionSocketFactory =
        object : PlainConnectionSocketFactory() {
            override fun createSocket(context: HttpContext?): Socket = socket()
        }

    /**
     * 이 스레드의 교환에 마감을 건다 — [sentAtNanos] 부터 [readTimeoutMillis]. 0 은 「끝없이」(읽기 타임아웃이 없다)라 마감도 두지 않는다. 엔진의
     * 교환이 요청 머리를 쓰기 직전에 부른다([AdminEngine.Exchange]).
     */
    fun arm(
        sentAtNanos: Long,
        readTimeoutMillis: Int,
    ) {
        if (readTimeoutMillis > 0) {
            DEADLINE.set(
                longArrayOf(sentAtNanos + TimeUnit.MILLISECONDS.toNanos(readTimeoutMillis.toLong()), readTimeoutMillis.toLong()),
            )
        } else {
            DEADLINE.remove()
        }
    }

    /** 이 스레드의 마감을 지운다 — 교환의 끝. 그 뒤 이 스레드의 소켓 읽기(다음 교환이 연결을 빌리며 엿보는 읽기 등)는 마감을 보지 않는다. */
    fun disarm() {
        DEADLINE.remove()
    }

    /** TLS — 검증기·근원은 RESTEasy 가 고른 그대로, TLS 를 얹을 평문 소켓만 이 레인의 것이다. */
    fun tls(
        tlsContext: SSLContext,
        verifier: HostnameVerifier?,
    ): ConnectionSocketFactory =
        object : SSLConnectionSocketFactory(tlsContext, verifier) {
            override fun createSocket(context: HttpContext?): Socket = socket()
        }

    /**
     * RESTEasy 가 지은 풀([built])과 같은 크기 · 경로당 크기 · 소켓 설정 · 쉰 뒤 검사 간격과, 빌더의 연결 수명([ttlMillis])으로 이 레인의 소켓을
     * 쓰는 풀을 짓는다. 지은 풀은 쓰이지 않으므로 닫는 것은 부르는 쪽이다.
     */
    fun pool(
        built: PoolingHttpClientConnectionManager,
        tlsContext: SSLContext,
        verifier: HostnameVerifier?,
        ttlMillis: Long,
    ): PoolingHttpClientConnectionManager {
        val sockets =
            RegistryBuilder
                .create<ConnectionSocketFactory>()
                .register("http", PLAIN)
                .register("https", tls(tlsContext, verifier))
                .build()
        return PoolingHttpClientConnectionManager(sockets, null, null, null, ttlMillis, TimeUnit.MILLISECONDS).apply {
            maxTotal = built.maxTotal
            defaultMaxPerRoute = built.defaultMaxPerRoute
            defaultSocketConfig = built.defaultSocketConfig
            validateAfterInactivity = built.validateAfterInactivity
        }
    }

    /** 이 레인의 소켓 — JDK 의 기본 소켓이되 그 입력 스트림이 읽기마다 마감을 본다([deadlined]). */
    fun socket(): Socket =
        object : Socket() {
            override fun getInputStream(): InputStream = deadlined(super.getInputStream())
        }

    /**
     * 소켓의 입력 스트림 — 읽기 앞뒤로 이 스레드의 마감([arm])을 본다: 마감 뒤에 읽기를 시작하지 않고, 마감 뒤에 끝난 읽기의 결과를 쓰지 않는다(그
     * 바이트로 응답을 끝내지 않는다). 읽기 하나는 지금처럼 읽기 타임아웃이 묶으므로 최악은 마감 + 읽기 타임아웃 하나다. 마감이 없는 스레드의 읽기는
     * 그대로다.
     */
    fun deadlined(socket: InputStream): InputStream =
        object : FilterInputStream(socket) {
            override fun read(): Int {
                val deadline = DEADLINE.get() ?: return super.read()
                due(deadline)
                val b = super.read()
                due(deadline)
                return b
            }

            override fun read(
                b: ByteArray,
                off: Int,
                len: Int,
            ): Int {
                val deadline = DEADLINE.get() ?: return super.read(b, off, len)
                due(deadline)
                val n = super.read(b, off, len)
                due(deadline)
                return n
            }
        }

    /** 마감이 지났으면 읽기 타임아웃과 같은 타입으로 — 메시지는 마감의 길이뿐이다(응답을 인용하지 않는다 · 엔진의 스트림과 같은 문구). */
    private fun due(deadline: LongArray) {
        if (System.nanoTime() - deadline[0] >= 0) {
            throw SocketTimeoutException("$RESPONSE_LATE${deadline[1]} ms of sending the request")
        }
    }
}
