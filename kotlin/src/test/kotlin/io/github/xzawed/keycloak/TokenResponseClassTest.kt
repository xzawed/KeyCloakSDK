package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.time.Duration
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

// 토큰·introspection 응답의 오류 계급(등록부 token-response-class-divergent · Java `TokenResponseClassTest` 동형) — **끝까지 온**
// 응답을 쓸 수 없으면 SDK 의 KeycloakAuthException, 끝까지 오지 **않은** 응답(네트워크 실패 · 타임아웃 · 1,048,576 바이트 상한 초과 ·
// 깨진 틀)은 KeycloakTransportException 이다. 공개 API 만 부른다.
//
// 칸: S1 = auth.clientCredentialsToken() · S2 = ClientCredentialsTokenProvider(S1 을 지난다) · IN = auth.introspect() · S5 = admin
// 파사드의 자기 토큰 그랜트(keycloak-admin-client 의 TokenManager — RESTEasy 의 BearerAuthFilter 안). 수정 전 실측(main 219a4667): S1·S2·IN
// 은 JSON 문자열 안의 잘못된 UTF-8(0xFF 0xFE)을 U+FFFD 로 바꿔 **받아들였고**, 설명 없는 오류 응답(JSON 이 아닌 503·400)은
// 「… failed: null」 이었고, S5 는 끝까지 온 실패 응답 전부를 전송 오류로 냈다(토큰 엔드포인트의 404 도).
//
// 대조(바뀌지 않는다): 좋은 그랜트 · application/json 의 모르는 charset(RFC 8259 §11 — 효과 없음) · 유효한 비 ASCII · 오류 본문의
// 잘못된 UTF-8(판정은 상태가 한다) · logout · 상한 초과 · 연결 거부 · 타임아웃 · 좋은 그랜트 뒤 admin REST 404 · 갱신 400 뒤 다시
// 부여(TokenManager 의 복구 경로).
//
// ⚠️ S5 의 오류 본문은 그 요청의 클라이언트 시크릿을 되울린다 — 메시지는 상태만 싣고, 원인 사슬은 가린 사본이다(어느 표현에도 시크릿이
// 찍히면 안 된다).
private const val TRX_REALM = "r"
private const val TRX_OIDC = "/realms/$TRX_REALM/protocol/openid-connect"
private const val TRX_ADMIN_USER = "/admin/realms/$TRX_REALM/users/x"
private const val TRX_SECRET = "ZclsSECRET-0123456789abcdef"
private const val TRX_RT_CANARY = "ZclsRT-0123456789abcdef"
private const val TRX_VERIFIER = "ZclsVERIFIER-0123456789abcdefghijklmnopqrstuvwxyz"

// 상한 — SDK 상수를 빌리지 않는다(빌리면 그 값이 바뀌어도 시험이 따라 움직인다).
private const val TRX_CAP = 1_048_576
private const val TRX_UNKNOWN_CHARSET = "application/json; charset=x-unknown-kc"

// JSON 문자열 안의 잘못된 UTF-8 — 0xFF 0xFE 는 UTF-8 의 어느 자리에도 올 수 없다.
private val TRX_INVALID = byteArrayOf(0xFF.toByte(), 0xFE.toByte())

// 응답 하나 — type 이 null 이면 Content-Type 을 달지 않고 body 가 null 이면 본문이 없다.
private class TrxReply(
    val status: Int,
    val type: String?,
    val body: ByteArray?,
    val delayMs: Long = 0,
) {
    override fun toString(): String = "$status $type (${body?.size ?: "no"} bytes)"
}

private fun trxConcat(vararg parts: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    parts.forEach { out.write(it) }
    return out.toByteArray()
}

private fun trxJson(
    status: Int,
    body: String,
): TrxReply = TrxReply(status, "application/json", body.toByteArray())

private fun trxToken(accessToken: String): String =
    """{"access_token":"$accessToken","token_type":"Bearer","expires_in":300,"refresh_token":"$TRX_RT_CANARY"}"""

// access_token 안에 잘못된 UTF-8 이 든 200 토큰 응답.
private fun trxTokenWithInvalidUtf8(): TrxReply =
    TrxReply(
        200,
        "application/json",
        trxConcat(
            """{"access_token":"ok""".toByteArray(),
            TRX_INVALID,
            """vc","token_type":"Bearer","expires_in":300,"refresh_token":"$TRX_RT_CANARY"}""".toByteArray(),
        ),
    )

// 정확히 size 바이트 — json 뒤를 JSON 공백으로 채운다.
private fun trxPadTo(
    json: String,
    size: Int,
): ByteArray {
    val out = ByteArray(size) { ' '.code.toByte() }
    json.toByteArray().copyInto(out)
    return out
}

// 오류 본문 — error_description 이 그 요청의 클라이언트 시크릿을 되울린다.
private fun trxEchoing(
    status: Int,
    error: String,
): TrxReply = trxJson(status, """{"error":"$error","error_description":"rejected $TRX_SECRET"}""")

private class TrxOutcome(
    val value: Any?,
    val thrown: Throwable?,
) {
    override fun toString(): String = if (thrown == null) "성공($value)" else "${thrown.javaClass.simpleName}(${thrown.message})"
}

private suspend fun trxOutcome(block: suspend () -> Any?): TrxOutcome =
    try {
        TrxOutcome(block(), null)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        TrxOutcome(null, e)
    }

// o 가 정확히 그 타입·메시지의 실패이고, 어느 표현도 시크릿·응답의 refresh_token 을 찍지 않는다.
private fun trxExpect(
    label: String,
    o: TrxOutcome,
    type: Class<out Throwable>,
    message: String,
    wrong: MutableList<String>,
) {
    val thrown = o.thrown
    if (thrown == null || !type.isInstance(thrown) || thrown.message != message) {
        wrong += "$label: ${type.simpleName}($message) 가 아니다 — $o"
        return
    }
    for (printed in listOf(thrown.toString(), thrown.stackTraceToString())) {
        if (TRX_SECRET.take(10) in printed) wrong += "$label: 클라이언트 시크릿이 찍혔다"
        if (TRX_RT_CANARY.take(10) in printed) wrong += "$label: 응답의 refresh_token 이 찍혔다"
    }
}

private fun trxAdminAuth(status: Int): String =
    "Admin token request failed: HTTP $status" + if (status / 100 == 2) " (unusable token response)" else ""

private fun trxClosedPort(): Int = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }

internal class TokenResponseClassTest {
    private lateinit var server: HttpServer
    private lateinit var handlers: ExecutorService
    private val tokenReplies = ArrayDeque<TrxReply>()

    @Volatile
    private var introspectReply = trxJson(200, """{"active":true,"username":"svc","client_id":"app"}""")

    @Volatile
    private var logoutReply = TrxReply(204, null, null)

    @Volatile
    private var adminReply = trxJson(200, """{"id":"x","username":"alice"}""")
    private val grants = mutableListOf<String>()
    private var adminHits = 0

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        handlers = Executors.newCachedThreadPool()
        server.executor = handlers
        server.createContext("/") { handle(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
        handlers.shutdownNow()
    }

    private fun handle(ex: HttpExchange) {
        val path = ex.requestURI.path
        val form = ex.requestBody.readAllBytes().decodeToString()
        val reply =
            synchronized(this) {
                when (path) {
                    "$TRX_OIDC/token" -> {
                        grants +=
                            when {
                                "grant_type=refresh_token" in form -> "refresh_token"
                                "grant_type=client_credentials" in form -> "client_credentials"
                                else -> "other"
                            }
                        if (tokenReplies.size > 1) tokenReplies.poll() else tokenReplies.peek()
                    }
                    "$TRX_OIDC/token/introspect" -> introspectReply
                    "$TRX_OIDC/logout" -> logoutReply
                    TRX_ADMIN_USER -> {
                        adminHits++
                        adminReply
                    }
                    else -> trxJson(404, """{"error":"not found"}""")
                }
            }
        try {
            if (reply.delayMs > 0) Thread.sleep(reply.delayMs)
            reply.type?.let { ex.responseHeaders.add("Content-Type", it) }
            val body = reply.body
            if (body == null || body.isEmpty()) {
                ex.sendResponseHeaders(reply.status, -1)
            } else {
                ex.sendResponseHeaders(reply.status, body.size.toLong())
                ex.responseBody.use { it.write(body) }
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (clientLeft: IOException) {
            // 클라이언트가 끊었다 — 상한에서, 또는 타임아웃 뒤
        } finally {
            ex.close()
        }
    }

    private fun tokens(vararg replies: TrxReply) =
        synchronized(this) {
            tokenReplies.clear()
            tokenReplies.addAll(replies)
            grants.clear()
            adminHits = 0
        }

    private fun adminHits(): Int = synchronized(this) { adminHits }

    private fun grants(): List<String> = synchronized(this) { grants.toList() }

    private fun config(
        port: Int = server.address.port,
        readTimeout: Duration = Duration.ofSeconds(5),
    ): KeycloakConfig =
        KeycloakConfig(
            "http://127.0.0.1:$port",
            TRX_REALM,
            "app",
            TRX_SECRET.toCharArray(),
            connectTimeout = Duration.ofSeconds(5),
            readTimeout = readTimeout,
        )

    private suspend fun call(
        config: KeycloakConfig = config(),
        block: suspend (KeycloakClient) -> Any?,
    ): TrxOutcome = KeycloakClient.create(config).use { kc -> trxOutcome { block(kc) } }

    private val cc: suspend (KeycloakClient) -> Any? = { it.auth.clientCredentialsToken().accessToken }
    private val prov: suspend (KeycloakClient) -> Any? = { kc ->
        ClientCredentialsTokenProvider(fetch = { kc.auth.clientCredentialsToken() }).accessToken()
    }
    private val rf: suspend (KeycloakClient) -> Any? = { it.auth.refresh("rt-1").accessToken }
    private val codeExchange: suspend (KeycloakClient) -> Any? = {
        it.auth.exchangeCode("code-1", TRX_VERIFIER, "https://app.example/cb").accessToken
    }
    private val introspect: suspend (KeycloakClient) -> Any? = { it.auth.introspect("tok-1").username }
    private val admin: suspend (KeycloakClient) -> Any? = { kc ->
        kc.admin
            .users()
            .get("x")
            .username
    }

    private fun assertNone(wrong: List<String>) = assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))

    // ───────────── auth 레인 — S1 · S2 · introspection ─────────────

    // 2xx 본문의 잘못된 UTF-8 은 끝까지 온 응답을 쓸 수 없다는 것이다 — 그 레인의 인증 오류(r9). 수정 전에는 U+FFFD 로 바꿔
    // 받아들여 IdP 가 내지 않은 토큰(ok · U+FFFD 둘 · vc)·바뀐 클레임이 성공으로 나갔다. 세 그랜트가 같은 송신을 지난다.
    @Test
    fun `an invalid UTF-8 success body is an auth failure`() =
        runTest(timeout = 120.seconds) {
            val wrong = mutableListOf<String>()
            val notUtf8 = "Malformed auth response: token response is not valid UTF-8"
            for ((label, op) in listOf("S1" to cc, "S2" to prov, "refresh" to rf, "code exchange" to codeExchange)) {
                tokens(trxTokenWithInvalidUtf8())
                trxExpect("$label 200 잘못된 UTF-8", call(block = op), KeycloakAuthException::class.java, notUtf8, wrong)
            }
            introspectReply =
                TrxReply(
                    200,
                    "application/json",
                    trxConcat("""{"active":true,"username":"s""".toByteArray(), TRX_INVALID, """vc","client_id":"app"}""".toByteArray()),
                )
            trxExpect(
                "IN 200 잘못된 UTF-8",
                call(block = introspect),
                KeycloakAuthException::class.java,
                "Malformed introspection response: introspection response is not valid UTF-8",
                wrong,
            )
            assertNone(wrong)
        }

    // 설명 없는 오류 응답(JSON 이 아닌 본문 · error 만 있는 본문)의 메시지는 HTTP 상태를 말한다 — Nimbus ErrorObject 는 그 본문에
    // 설명을 두지 않아 「… failed: null」 이었다. 오류를 만드는 auth 메서드 넷 모두.
    @Test
    fun `an error without a description names the status`() =
        runTest(timeout = 120.seconds) {
            val wrong = mutableListOf<String>()
            for (status in listOf(503, 400)) {
                val html = TrxReply(status, "text/html", "<html><body>$status</body></html>".toByteArray())
                for ((label, op, message) in listOf(
                    Triple("S1", cc, "Client credentials failed: HTTP $status"),
                    Triple("S2", prov, "Client credentials failed: HTTP $status"),
                    Triple("refresh", rf, "Token refresh failed: HTTP $status"),
                    Triple("code exchange", codeExchange, "Authorization code exchange failed: HTTP $status"),
                )) {
                    tokens(html)
                    trxExpect("$label $status HTML", call(block = op), KeycloakAuthException::class.java, message, wrong)
                }
                introspectReply = html
                trxExpect(
                    "IN $status HTML",
                    call(block = introspect),
                    KeycloakAuthException::class.java,
                    "Introspection failed: HTTP $status",
                    wrong,
                )
            }
            tokens(trxJson(400, """{"error":"invalid_grant"}"""))
            val codeOnly = call(block = rf)
            trxExpect("refresh 400 error 만", codeOnly, KeycloakAuthException::class.java, "Token refresh failed: HTTP 400", wrong)
            val oauthError = (codeOnly.thrown as? KeycloakAuthException)?.oauthError
            if (codeOnly.thrown is KeycloakAuthException && oauthError != "invalid_grant") {
                wrong += "refresh 400 error 만: OAuth 오류 코드를 잃었다 — $oauthError"
            }
            assertNone(wrong)
        }

    // 대조 — 규칙이 바꾸지 않는 auth 레인의 칸.
    @Test
    fun `the auth lane controls do not change`() =
        runTest(timeout = 120.seconds) {
            val wrong = mutableListOf<String>()
            // 모르는 charset 은 효과가 없다(RFC 8259 §11) — 본문은 UTF-8 로 읽는다
            tokens(TrxReply(200, TRX_UNKNOWN_CHARSET, trxToken("AT-charset").toByteArray()))
            val charset = call(block = cc)
            if (charset.value != "AT-charset") wrong += "S1 모르는 charset: 받아들여야 한다 — $charset"
            introspectReply = TrxReply(200, TRX_UNKNOWN_CHARSET, """{"active":true,"username":"sévc","client_id":"app"}""".toByteArray())
            val valid = call(block = introspect)
            if (valid.value != "sévc") wrong += "IN 모르는 charset · 유효한 비 ASCII: 그대로여야 한다 — $valid"
            // 오류 본문의 잘못된 UTF-8 — 판정은 상태가 한다(인증 오류 · OAuth 코드 그대로)
            tokens(
                TrxReply(
                    400,
                    "application/json",
                    trxConcat("""{"error":"invalid_grant","error_description":"bad """.toByteArray(), TRX_INVALID, "\"}".toByteArray()),
                ),
            )
            val errorBody = call(block = cc)
            if ((errorBody.thrown as? KeycloakAuthException)?.oauthError != "invalid_grant") {
                wrong += "S1 400 오류 본문의 잘못된 UTF-8: invalid_grant 인증 오류여야 한다 — $errorBody"
            }
            // logout 은 본문을 쓰지 않는다 — 그대로 성공
            tokens(trxJson(200, trxToken("AT")))
            logoutReply = TrxReply(200, "application/json", trxConcat("""{"x":"""".toByteArray(), TRX_INVALID, "\"}".toByteArray()))
            val logout =
                call { kc ->
                    kc.auth.logout("rt-1")
                    "logged out"
                }
            if (logout.value != "logged out") wrong += "logout 2xx 잘못된 UTF-8: 그대로 성공해야 한다 — $logout"
            // 다 오지 않은 응답 — 전송 오류
            tokens(TrxReply(200, "application/json", trxPadTo(trxToken("AT-big"), TRX_CAP + 1)))
            trxExpect(
                "S1 상한+1",
                call(block = cc),
                KeycloakTransportException::class.java,
                "Auth request failed: token response exceeds 1048576 bytes",
                wrong,
            )
            trxExpect(
                "S1 연결 거부",
                call(config(port = trxClosedPort()), cc),
                KeycloakTransportException::class.java,
                "Auth request failed",
                wrong,
            )
            assertNone(wrong)
        }

    // ───────────── S5 — admin 의 자기 토큰 그랜트 ─────────────

    // 그랜트가 끝까지 온 응답으로 실패하면 상태와 무관하게 인증 오류다 — 메시지는 상태만 싣고(본문은 시크릿을 되울릴 수 있다) admin
    // 요청은 하나도 나가지 않는다. 수정 전에는 전부 KeycloakTransportException("Admin request failed") 였다.
    @Test
    fun `an admin grant that got a response is an auth failure`() =
        runTest(timeout = 120.seconds) {
            val wrong = mutableListOf<String>()
            val cells =
                listOf(
                    Triple("503 HTML", TrxReply(503, "text/html", "<html>503 $TRX_SECRET</html>".toByteArray()), 503),
                    Triple("200 HTML", TrxReply(200, "text/html", "<html>ok $TRX_RT_CANARY</html>".toByteArray()), 200),
                    Triple(
                        "200 JSON access_token 없음",
                        trxJson(200, """{"token_type":"Bearer","expires_in":300,"refresh_token":"$TRX_RT_CANARY"}"""),
                        200,
                    ),
                    Triple("400 HTML", TrxReply(400, "text/html", "<html>400 $TRX_SECRET</html>".toByteArray()), 400),
                    Triple("200 잘못된 UTF-8", trxTokenWithInvalidUtf8(), 200),
                    Triple(
                        "200 JSON expires_in 숫자 아님",
                        trxJson(
                            200,
                            """{"access_token":"good","token_type":"Bearer","expires_in":"soon","refresh_token":"$TRX_RT_CANARY"}""",
                        ),
                        200,
                    ),
                    // 따라가지 않는 리다이렉트도 끝까지 온 응답이다(RESTEasy 의 RedirectionException — HTTP 오류의 하나)
                    Triple("302 HTML", TrxReply(302, "text/html", "<html>moved $TRX_SECRET</html>".toByteArray()), 302),
                    Triple("401 JSON", trxEchoing(401, "unauthorized_client"), 401),
                    Triple("403 JSON", trxEchoing(403, "access_denied"), 403),
                    Triple("404 JSON", trxEchoing(404, "not_found"), 404),
                    Triple("409 JSON", trxEchoing(409, "conflict"), 409),
                )
            val table = mutableListOf<String>()
            for ((cell, reply, status) in cells) {
                val label = "S5 $cell"
                tokens(reply)
                val o = call(block = admin)
                table += "$label → $o · grants ${grants()} · admin ${adminHits()}"
                trxExpect(label, o, KeycloakAuthException::class.java, trxAdminAuth(status), wrong)
                if (adminHits() != 0) wrong += "$label: admin 요청이 나갔다 — ${adminHits()}"
                if (grants().isEmpty()) wrong += "$label: 토큰 엔드포인트에 닿지 않았다"
            }
            println("[TokenResponseClassTest S5]\n  " + table.joinToString("\n  "))
            assertNone(wrong)
        }

    // 대조 — 다 오지 않은 응답은 전송 오류 · 좋은 그랜트는 그대로 · 그랜트 뒤의 admin REST 오류는 제 계급 · 갱신 400 의 복구 경로.
    @Test
    fun `the admin controls do not change`() =
        runTest(timeout = 120.seconds) {
            val wrong = mutableListOf<String>()
            tokens(trxJson(200, trxToken("good")))
            val good = call(block = admin)
            if (good.value != "alice" || adminHits() != 1) wrong += "S5 좋은 그랜트: $good · admin ${adminHits()}"
            tokens(TrxReply(200, TRX_UNKNOWN_CHARSET, trxToken("good").toByteArray()))
            val charset = call(block = admin)
            if (charset.value != "alice") wrong += "S5 모르는 charset: 받아들여야 한다 — $charset"

            tokens(TrxReply(200, "application/json", trxPadTo(trxToken("good"), TRX_CAP + 1)))
            trxExpect("S5 2xx 상한+1", call(block = admin), KeycloakTransportException::class.java, "Admin request failed", wrong)
            tokens(TrxReply(400, "application/json", trxPadTo("""{"error":"invalid_grant"}""", TRX_CAP + 1)))
            trxExpect("S5 400 상한+1", call(block = admin), KeycloakTransportException::class.java, "Admin request failed", wrong)
            trxExpect(
                "S5 연결 거부",
                call(config(port = trxClosedPort()), admin),
                KeycloakTransportException::class.java,
                "Admin request failed",
                wrong,
            )
            tokens(TrxReply(200, "application/json", trxToken("good").toByteArray(), delayMs = 3_000))
            trxExpect(
                "S5 타임아웃",
                call(config(readTimeout = Duration.ofMillis(500)), admin),
                KeycloakTransportException::class.java,
                "Admin request failed",
                wrong,
            )

            tokens(trxJson(200, trxToken("good")))
            adminReply = trxJson(404, """{"error":"User not found"}""")
            val rest404 = call(block = admin)
            if (rest404.thrown !is KeycloakAdminException.NotFound) wrong += "S5 좋은 그랜트 뒤 REST 404: $rest404"
            adminReply = trxJson(200, """{"id":"x","username":"alice"}""")

            // 갱신 400 → TokenManager 가 BadRequestException 을 받아 client_credentials 로 다시 부여한다
            val first = """{"access_token":"AT-1","token_type":"Bearer","expires_in":1,"refresh_token":"RT-1","refresh_expires_in":300}"""
            tokens(trxJson(200, first), trxJson(400, """{"error":"invalid_grant"}"""), trxJson(200, trxToken("AT-3")))
            val twice =
                KeycloakClient.create(config()).use { kc ->
                    listOf(trxOutcome { admin(kc) }, trxOutcome { admin(kc) })
                }
            if (twice.any { it.thrown != null } ||
                adminHits() != 2 ||
                grants() != listOf("client_credentials", "refresh_token", "client_credentials")
            ) {
                wrong += "S5 갱신 400 의 복구 경로: $twice · grants ${grants()} · admin ${adminHits()}"
            }
            assertNone(wrong)
        }
}
