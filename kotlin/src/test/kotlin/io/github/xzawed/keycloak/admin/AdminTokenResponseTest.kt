package io.github.xzawed.keycloak.admin

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.UserRepresentation
import java.net.InetAddress
import java.net.InetSocketAddress
import java.time.Duration
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

// admin 레인의 토큰 응답 계약(Java `AdminTokenResponseTest` 동형) — admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client
// 내장 TokenManager 가 그 응답을 Jackson 으로 읽는다. 계약: 쓸 수 없는 access_token(누락·null·숫자·불리언·빈 문자열·객체·
// 배열)이면 **admin API 요청을 하나도 보내지 않고** KeycloakTransportException 으로 실패한다 — 오늘 null·객체·배열·누락이
// 이미 그렇게 실패하던 타입이다. 쓸 수 있는 문자열 토큰은 그대로 동작하고, TokenManager 의 갱신(refresh_token 그랜트)도
// 같은 검사를 받는다.
//
// ⚠️ 가짜 admin 엔드포인트는 **성공**(200 사용자)을 낸다 — 강제변환된 토큰으로 나간 요청이 404 로 우연히 실패해 결함이
// 「실패했으니 됐다」로 가려지지 않게. 판정의 무게는 「admin 요청 0 건」이 진다(적대 행렬 W3a 와 같은 기준). 네트워크는
// 로컬 루프백만 쓴다(Docker 불필요).
private const val ATR_REALM = "r"
private const val ATR_TOKEN_PATH = "/realms/$ATR_REALM/protocol/openid-connect/token"
private const val ATR_MISSING = "(missing)"

// 같은 응답에 실린 refresh_token — 거부 오류의 어느 표현에도 찍히면 안 된다.
private const val ATR_RT_CANARY = "ZadminRT-0123456789abcdef"

private fun atrTokenBody(
    rawAccessToken: String,
    extra: String = "",
    expiresIn: Int = 300,
): String {
    val at = if (rawAccessToken == ATR_MISSING) "" else "\"access_token\":$rawAccessToken,"
    return "{$at\"token_type\":\"Bearer\",\"expires_in\":$expiresIn$extra}"
}

// 갱신 시나리오의 첫 응답 — expires_in 1 < TokenManager 최소 유효기간(30s) 이라 다음 호출이 refresh_token 으로 갱신한다.
private val ATR_REFRESHABLE = atrTokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300", expiresIn = 1)

internal class AdminTokenResponseTest {
    private data class Reply(
        val status: Int,
        val body: String,
    )

    private lateinit var server: HttpServer
    private val lock = Any()

    // 토큰 엔드포인트가 차례로 낼 응답 — 마지막 것은 계속 낸다.
    private val tokenReplies = ArrayDeque<Reply>()
    private val grants = mutableListOf<String>()

    // admin 엔드포인트에 닿은 요청(메서드 경로 · Authorization).
    private val adminHits = mutableListOf<String>()

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { handle(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    private fun handle(ex: HttpExchange) {
        val path = ex.requestURI.path
        val body = ex.requestBody.readAllBytes().decodeToString()
        when {
            path == ATR_TOKEN_PATH -> {
                val r =
                    synchronized(lock) {
                        grants += form(body)["grant_type"] ?: "?"
                        if (tokenReplies.size > 1) tokenReplies.removeFirst() else tokenReplies.first()
                    }
                send(ex, r.status, r.body)
            }
            path.startsWith("/admin/realms/$ATR_REALM/users") -> {
                synchronized(lock) { adminHits += "${ex.requestMethod} $path · ${ex.requestHeaders.getFirst("Authorization")}" }
                if (ex.requestMethod == "POST") {
                    ex.responseHeaders.add("Location", "http://127.0.0.1/admin/realms/$ATR_REALM/users/new-id")
                    send(ex, 201, null)
                } else {
                    send(ex, 200, """{"id":"x","username":"alice"}""")
                }
            }
            else -> send(ex, 404, """{"error":"not found"}""")
        }
    }

    private fun send(
        ex: HttpExchange,
        status: Int,
        body: String?,
    ) {
        if (body == null) {
            ex.sendResponseHeaders(status, -1)
            ex.close()
            return
        }
        val bytes = body.toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(status, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }

    private fun form(body: String): Map<String, String> =
        body
            .split("&")
            .filter { it.indexOf('=') > 0 }
            .associate { it.substringBefore('=') to it.substringAfter('=') }

    private fun admin(): AdminClient =
        AdminClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = ATR_REALM,
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = Duration.ofSeconds(5),
            ),
        )

    private fun reset(vararg replies: Reply) =
        synchronized(lock) {
            tokenReplies.clear()
            tokenReplies.addAll(replies)
            grants.clear()
            adminHits.clear()
        }

    private fun adminHits(): List<String> = synchronized(lock) { adminHits.toList() }

    private fun grants(): List<String> = synchronized(lock) { grants.toList() }

    @Test
    fun `unusable access_token sends no admin request and fails as transport`() =
        runTest {
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            // 마지막 행은 중복 키 — 결합은 마지막 값(숫자)을 쓴다(첫 값만 보는 검사는 여기서 Bearer 12345 로 나아간다).
            val shapes = listOf("12345", "true", "\"\"", "null", """{"v":"x"}""", """["x"]""", ATR_MISSING, "\"AT\",\"access_token\":12345")
            for (raw in shapes) {
                reset(Reply(200, atrTokenBody(raw, ",\"refresh_token\":\"$ATR_RT_CANARY\"")))
                val thrown =
                    try {
                        admin().use { it.users().get("x") }
                        null
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        e
                    }
                val hits = adminHits()
                table += "access_token ${raw.padEnd(12)} → ${thrown?.let { "${it.javaClass.simpleName}(${it.message})" } ?: "성공"} · " +
                    "grants ${grants()} · admin $hits"
                if (thrown !is KeycloakTransportException || thrown.message != "Admin request failed") {
                    wrong += "$raw: KeycloakTransportException(Admin request failed) 가 아니다 — ${thrown?.javaClass?.name ?: "성공"}"
                }
                if (hits.isNotEmpty()) wrong += "$raw: 쓸 수 없는 토큰으로 admin 요청이 나갔다 — $hits"
                if (grants().size != 1) wrong += "$raw: 토큰 요청이 정확히 한 번이 아니다 — ${grants()}"
                if (thrown == null) continue
                // §4 — 원인 사슬에 하위 라이브러리 인스턴스가 없고(응답을 읽다 난 사슬은 RedactedCause 사본이다), 응답을
                // 인용하지 않는다.
                generateSequence(thrown.cause) { it.cause }.take(16).forEach { c ->
                    val n = c.javaClass.name
                    if (!n.startsWith("java.") && !n.startsWith("io.github.xzawed.")) wrong += "$raw: 원인 사슬에 하위 타입이 샜다 — $n"
                }
                if (ATR_RT_CANARY.take(10) in thrown.stackTraceToString()) wrong += "$raw: 오류가 응답의 refresh_token 을 찍었다"
            }
            println("[AdminTokenResponseTest]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 대조 — 같은 경로에서 문자열 토큰은 GET·POST 둘 다 admin 에 닿는다(위 실패가 다른 원인이 아님을 보인다).
    @Test
    fun `string access_token reaches admin for reads and writes`() =
        runTest {
            reset(Reply(200, atrTokenBody("\"AT-1\"")))
            admin().use { admin ->
                assertEquals("alice", admin.users().get("x").username)
                assertEquals("new-id", admin.users().create(UserRepresentation().apply { username = "bob" }))
            }
            assertEquals(listOf("client_credentials"), grants(), "토큰은 캐시되어 한 번만 부여돼야 한다")
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "POST /admin/realms/r/users · Bearer AT-1"), adminHits())
        }

    // TokenManager 의 갱신(refresh_token 그랜트) 응답도 같은 검사를 받는다 — 쓸 수 있으면 새 토큰으로 나아간다.
    @Test
    fun `refreshed string access_token is used`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(200, atrTokenBody("\"AT-2\"")))
            admin().use { admin ->
                admin.users().get("x")
                admin.users().get("x")
            }
            assertEquals(listOf("client_credentials", "refresh_token"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2"), adminHits())
        }

    @Test
    fun `refreshed unusable access_token sends no admin request`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(200, atrTokenBody("12345")))
            admin().use { admin ->
                admin.users().get("x")
                val e = assertFailsWith<KeycloakTransportException> { admin.users().get("x") }
                assertEquals("Admin request failed", e.message)
            }
            assertEquals(listOf("client_credentials", "refresh_token"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1"), adminHits(), "갱신된 숫자 토큰으로 나아갔다")
        }

    // 오류 상태의 토큰 응답은 검사하지 않고 TokenManager 에 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가
    // BadRequestException 을 받아 client_credentials 로 다시 부여한다(admin-client 의 복구 경로). 검사가 오류 본문(access_token
    // 없음)까지 거부하면 그 예외가 ResponseProcessingException 으로 바뀌어 복구가 끊긴다.
    @Test
    fun `token error status is left to the TokenManager`() =
        runTest {
            reset(Reply(200, ATR_REFRESHABLE), Reply(400, """{"error":"invalid_grant"}"""), Reply(200, atrTokenBody("\"AT-3\"")))
            admin().use { admin ->
                admin.users().get("x")
                admin.users().get("x")
            }
            assertEquals(listOf("client_credentials", "refresh_token", "client_credentials"), grants())
            assertEquals(listOf("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-3"), adminHits())
        }
}
