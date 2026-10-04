package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.IOException
import java.lang.management.ManagementFactory
import java.net.InetAddress
import java.net.InetSocketAddress
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

// auth 레인 토큰 응답 크기 상한(token-response-size-unbounded) — client_credentials·refresh·코드 교환·introspect·logout 이
// 응답 본문을 정확히 1,048,576 바이트까지만 읽는다. 상한 안의 본문은 예전과 똑같이 동작하고, 한 바이트라도 넘으면 그 레인의
// 전송 실패(KeycloakTransportException)이며, 넘친 본문은 끝까지 읽지 않는다. 수정 전 실측(2026-10-05): 쓸 수 있는 토큰 뒤에
// JSON 공백 32 MiB 를 붙인 응답을 다섯 레인이 전부 받아들였고 호출 하나가 약 230 MiB 를 할당했다(Nimbus `HTTPRequest.send()` 의
// readLine 고리). 오류 상태(400)의 본문도 같은 고리로 읽혔다(230 MiB).
//
// ⚠️ 상한은 여기 숫자로 적는다 — SDK 상수(아홉 언어가 함께 움직이는 값)가 바뀌면 이 시험이 먼저 안다. 시험은 공개 API 만
// 부른다(수정을 되돌린 소스에서도 그대로 컴파일돼 그 결함을 다시 보인다). 네트워크는 루프백만 쓴다(Docker 불필요).
private const val TRC_CAP = 1_048_576

// Keycloak 26.6(start-dev 기본 설정)이 받아들이는 가장 긴 Bearer — 실측 2026-10-03: 65,459 바이트면 401, 65,460 이면 431.
private const val TRC_KEYCLOAK_MAX_BEARER = 65_459
private const val TRC_OIDC = "/realms/r/protocol/openid-connect"
private const val TRC_SPACE = ' '.code.toByte()

// 쓸 수 있는 n 바이트 값(token68 문자만).
private fun trcValue(n: Int): String {
    val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    return buildString(n) { for (i in 0 until n) append(alphabet[i % alphabet.length]) }
}

// 이 JVM 의 모든 스레드가 지금까지 할당한 바이트 — 읽기는 Dispatchers.IO 스레드에서 일어나므로 호출 스레드만으로는 못 잰다.
// getTotalThreadAllocatedBytes 는 JDK 21 API 라(시험 컴파일은 17 API 로 묶여 있다) 반사로 부른다.
private fun trcAllocatedAllThreads(): Long {
    val bean = ManagementFactory.getThreadMXBean()
    assumeTrue(bean is com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM")
    val total =
        try {
            com.sun.management.ThreadMXBean::class.java.getMethod("getTotalThreadAllocatedBytes")
        } catch (absent: NoSuchMethodException) {
            null
        }
    assumeTrue(total != null, "JDK 21 미만 — 모든 스레드의 할당 합계를 못 잰다")
    val bytes = total!!.invoke(bean) as Long
    assumeTrue(bytes >= 0, "스레드 할당 계수가 꺼져 있다")
    return bytes
}

internal class TokenResponseCapTest {
    // 엔드포인트가 낼 응답 — head 뒤에 공백 pad 바이트를 고정 버퍼로 흘려 보낸다(시험 서버가 본문만 한 배열을 잡지 않는다).
    private class Reply(
        val status: Int,
        val head: ByteArray,
        val pad: Long = 0,
        val chunked: Boolean = false,
        val location: String? = null,
    ) {
        val size: Long get() = head.size + pad
    }

    private enum class Lane(
        val path: String,
        // 넘친 본문의 SDK 메시지(KeycloakTransportException).
        val overCap: String,
    ) {
        CLIENT_CREDENTIALS("$TRC_OIDC/token", "Auth request failed: token response exceeds 1048576 bytes"),
        REFRESH("$TRC_OIDC/token", "Auth request failed: token response exceeds 1048576 bytes"),
        CODE_EXCHANGE("$TRC_OIDC/token", "Auth request failed: token response exceeds 1048576 bytes"),
        INTROSPECT("$TRC_OIDC/token/introspect", "Introspection request failed: introspection response exceeds 1048576 bytes"),
        LOGOUT("$TRC_OIDC/logout", "Logout request failed: logout response exceeds 1048576 bytes"),
    }

    private lateinit var server: HttpServer

    @Volatile private var reply = Reply(200, "{}".toByteArray())
    private val hits = mutableMapOf<String, AtomicInteger>()
    private val written = AtomicLong()

    @Volatile private var clientLeftEarly = false
    private val spaces = ByteArray(64 * 1024) { TRC_SPACE }

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { answer(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    private fun answer(ex: HttpExchange) {
        ex.requestBody.readAllBytes()
        synchronized(hits) { hits.getOrPut(ex.requestURI.path) { AtomicInteger() }.incrementAndGet() }
        val r = if (ex.requestURI.path == "/internal") Reply(200, okBody(Lane.CLIENT_CREDENTIALS, "INTERNAL")) else reply
        r.location?.let { ex.responseHeaders.add("Location", it) }
        ex.responseHeaders.add("Content-Type", "application/json")
        written.set(0)
        clientLeftEarly = false
        try {
            ex.sendResponseHeaders(r.status, if (r.chunked) 0 else r.size)
            ex.responseBody.use { out ->
                out.write(r.head)
                written.addAndGet(r.head.size.toLong())
                var left = r.pad
                while (left > 0) {
                    val n = minOf(left, spaces.size.toLong()).toInt()
                    out.write(spaces, 0, n)
                    written.addAndGet(n.toLong())
                    left -= n
                }
            }
        } catch (clientWentAway: IOException) {
            clientLeftEarly = true // 클라이언트가 본문을 다 읽지 않고 끊었다 — 상한을 넘긴 본문의 기대 결말이다
        }
    }

    private fun hitsOf(path: String): Int = synchronized(hits) { hits[path]?.get() ?: 0 }

    private fun auth(): AuthClient =
        AuthClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = Duration.ofSeconds(10),
            ),
        )

    // 레인이 성공으로 받아들일 본문 — value 가 결과에 그대로 나와야 한다(토큰 레인은 access_token, introspect 는 username).
    private fun okBody(
        lane: Lane,
        value: String,
    ): ByteArray =
        when (lane) {
            Lane.INTROSPECT -> """{"active":true,"username":"$value"}"""
            Lane.LOGOUT -> """{"note":"$value"}"""
            else -> """{"access_token":"$value","token_type":"Bearer","expires_in":300}"""
        }.toByteArray()

    // 레인 호출 하나 — 성공이면 결과의 값을(logout 은 "returned"), 실패면 그 예외를 돌려준다. 취소는 그대로 던진다.
    private suspend fun call(lane: Lane): Result<String> =
        try {
            val auth = auth()
            Result.success(
                when (lane) {
                    Lane.CLIENT_CREDENTIALS -> auth.clientCredentialsToken().accessToken
                    Lane.REFRESH -> auth.refresh("rt-1").accessToken
                    Lane.CODE_EXCHANGE -> auth.exchangeCode("code-1", "v".repeat(43), "http://localhost/cb").accessToken
                    Lane.INTROSPECT -> auth.introspect("tok").let { if (it.active) it.username.toString() else "inactive" }
                    Lane.LOGOUT -> auth.logout("rt-1").let { "returned" }
                },
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Result.failure(e)
        }

    private fun describe(r: Result<String>): String =
        r.fold({ "성공(${if (it.length > 24) "len ${it.length}" else it})" }, { "${it.javaClass.simpleName}(${it.message})" })

    // 넘친 본문의 계약 — 그 레인의 KeycloakTransportException · 상한을 말하는 메시지 · 원인 사슬에 하위 라이브러리 타입 없음(§4).
    private fun expectOverCap(
        label: String,
        lane: Lane,
        r: Result<String>,
        wrong: MutableList<String>,
    ) {
        val e = r.exceptionOrNull()
        if (e !is KeycloakTransportException || e.message != lane.overCap) {
            wrong += "$label: KeycloakTransportException(${lane.overCap}) 가 아니다 — ${describe(r)}"
            return
        }
        generateSequence(e.cause) { it.cause }.take(16).forEach { c ->
            val n = c.javaClass.name
            if (!n.startsWith("java.") && !n.startsWith("io.github.xzawed.")) wrong += "$label: 원인 사슬에 하위 타입이 샜다 — $n"
        }
    }

    // 서버가 받아들이는 가장 긴 Bearer 는 모든 레인에서 그대로 통과한다(introspect 는 같은 길이의 username, logout 은 같은 길이의
    // 본문) — 상한이 서버가 받는 토큰을 거부하지 않는다.
    @Test
    fun `largest bearer the server accepts passes every auth lane`() =
        runTest {
            val value = trcValue(TRC_KEYCLOAK_MAX_BEARER)
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (lane in Lane.entries) {
                reply = Reply(200, okBody(lane, value))
                val r = call(lane)
                table += "${lane.name.padEnd(18)} 본문 ${reply.size} 바이트 → ${describe(r)}"
                val expected = if (lane == Lane.LOGOUT) "returned" else value
                if (r.getOrNull() != expected) wrong += "${lane.name}: ${describe(r)}"
            }
            println("[TokenResponseCapTest 가장 긴 Bearer $TRC_KEYCLOAK_MAX_BEARER]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 경계 — 정확히 상한인 본문(쓸 수 있는 값 + JSON 공백)은 예전과 똑같이 통과하고, 한 바이트 더 크면 실패한다. 청크와
    // Content-Length 두 틀 모두.
    @Test
    fun `a body of exactly the cap passes every auth lane, one byte more fails`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (lane in Lane.entries) {
                for (chunked in listOf(false, true)) {
                    val head = okBody(lane, "good-value")
                    val frame = if (chunked) "청크" else "길이"
                    reply = Reply(200, head, (TRC_CAP - head.size).toLong(), chunked)
                    val atCap = call(lane)
                    table += "${lane.name.padEnd(18)} $frame = 상한   → ${describe(atCap)}"
                    if (atCap.getOrNull() != (if (lane == Lane.LOGOUT) "returned" else "good-value")) {
                        wrong += "${lane.name} $frame = 상한: ${describe(atCap)}"
                    }
                    reply = Reply(200, head, (TRC_CAP + 1 - head.size).toLong(), chunked)
                    val over = call(lane)
                    table += "${lane.name.padEnd(18)} $frame = 상한+1 → ${describe(over)}"
                    expectOverCap("${lane.name} $frame = 상한+1", lane, over, wrong)
                }
            }
            println("[TokenResponseCapTest 상한 $TRC_CAP]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 오류 상태의 본문도 같은 상한이다 — 상한 안의 400 은 예전처럼 IdP 의 거절(KeycloakAuthException, oauthError 그대로)이고,
    // 상한을 넘는 400 은 읽다 만 전송 실패다.
    @Test
    fun `an error body is held to the same cap`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            val head = """{"error":"invalid_grant","error_description":"bad grant"}""".toByteArray()
            for (lane in Lane.entries) {
                reply = Reply(400, head, (TRC_CAP - head.size).toLong())
                val atCap = call(lane)
                table += "${lane.name.padEnd(18)} 400 = 상한   → ${describe(atCap)}"
                val refused = atCap.exceptionOrNull()
                val expectedCode = if (lane == Lane.LOGOUT) null else "invalid_grant"
                if (refused !is KeycloakAuthException || refused.oauthError != expectedCode) {
                    wrong += "${lane.name} 400 = 상한: IdP 의 거절(KeycloakAuthException $expectedCode)이어야 한다 — ${describe(atCap)}"
                }
                reply = Reply(400, head, (TRC_CAP + 1 - head.size).toLong())
                val over = call(lane)
                table += "${lane.name.padEnd(18)} 400 = 상한+1 → ${describe(over)}"
                expectOverCap("${lane.name} 400 = 상한+1", lane, over, wrong)
            }
            println("[TokenResponseCapTest 오류 본문 상한]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 거대한 본문(16 MiB, 한 레인은 32 MiB) — 실패하고, SDK 는 나머지를 읽지 않고 끊으며(서버가 다 쓰지 못한다), 그 호출이 모든
    // 스레드에서 할당한 바이트가 상한의 여덟 배 안이다(본문 크기와 무관하다). 수정 전: 다섯 레인이 받아들였고 32 MiB 에 약
    // 230 MiB 를 할당했다. 레인마다 먼저 작은 본문으로 한 번 불러 클래스 로딩의 할당을 재지 않는다.
    @Test
    fun `a huge body fails, is not read to its end and allocates independently of its size`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            val limit = 8L * TRC_CAP
            for (lane in Lane.entries) {
                val huge = if (lane == Lane.CLIENT_CREDENTIALS) 32L shl 20 else 16L shl 20
                val head = okBody(lane, "good-value")
                reply = Reply(200, head)
                call(lane) // 데우기
                reply = Reply(200, head, huge - head.size, chunked = lane != Lane.REFRESH)
                val before = trcAllocatedAllThreads()
                val r = call(lane)
                val allocated = trcAllocatedAllThreads() - before
                Thread.sleep(200) // 서버 스레드가 끊긴 쓰기를 알아챌 시간
                table += "${lane.name.padEnd(18)} ${huge shr 20} MiB → ${describe(r)} · 할당 $allocated · 서버가 쓴 ${written.get()}"
                expectOverCap("${lane.name} ${huge shr 20} MiB", lane, r, wrong)
                if (allocated >= limit) wrong += "${lane.name}: ${huge shr 20} MiB 본문 하나에 $allocated 바이트를 할당했다(한도 $limit)"
                if (!clientLeftEarly || written.get() >= huge) wrong += "${lane.name}: SDK 가 본문을 끝까지 읽었다 — 서버가 ${written.get()} 바이트를 썼다"
            }
            println("[TokenResponseCapTest 거대한 본문]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 상한을 거는 읽기도 3xx 를 따라가지 않는다(SSRF 하드닝 — `applyTimeouts` 의 followRedirects = false 가 살아 있어야 한다).
    // 연결을 요청에서 새로 짓는 읽기는 그 설정을 잃는다 — Nimbus 의 ReadOnlyHTTPRequest 에는 followRedirects 가 없다. logout 이
    // 302 를 따라가 무관한 200 을 받으면 정상 반환한다(세션이 산 채로) — 그래서 그 레인이 가장 나쁘다.
    @Test
    fun `the capped read still refuses to follow a redirect`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (lane in Lane.entries) {
                synchronized(hits) { hits.clear() }
                reply = Reply(302, "{}".toByteArray(), location = "http://127.0.0.1:${server.address.port}/internal")
                val r = call(lane)
                table += "${lane.name.padEnd(18)} 302 → ${describe(r)} · /internal ${hitsOf("/internal")} 회"
                if (hitsOf("/internal") != 0) wrong += "${lane.name}: 리다이렉트를 따라갔다"
                if (r.isSuccess) wrong += "${lane.name}: 302 를 성공으로 받았다 — ${describe(r)}"
            }
            println("[TokenResponseCapTest 리다이렉트]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }
}
