package io.github.xzawed.keycloak.admin

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import jakarta.ws.rs.WebApplicationException
import jakarta.ws.rs.client.ResponseProcessingException
import jakarta.ws.rs.core.Response
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.Base64
import java.util.Collections
import java.util.IdentityHashMap
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

// admin 레인의 토큰 부여(keycloak-admin-client 내장 TokenManager)가 IdP 에서 오류를 받을 때(Java `AdminTokenEchoTest` 동형) — 그 오류
// 본문이 이 요청의 Basic 시크릿을 되울려도 SDK 오류의 어느 표현에도, 그리고 그 오류에서 닿는 어느 예외에도 본문이 남지 않는다.
//
// ⚠️ 메시지는 이미 깨끗했다(「Admin request failed」). 새던 것은 원인 사슬이다 — RESTEasy 는 오류 상태의 본문을 bufferEntity 한 Response 를
// NotAuthorizedException 에 쥐여 BearerAuthFilter(요청 필터) 밖으로 ProcessingException 으로 감싸 던지고, 그 Response 는 close() 뒤에도
// readEntity(String::class.java) 가 본문을 돌려준다(버퍼된 엔티티는 닫힘 검사를 건너뛴다 — 실측). 그래서 판정은 도달 가능성이다: 사슬
// (원인·suppressed)의 어느 예외도 WebApplicationException·ResponseProcessingException 이 아니고, 어느 예외의 공개 메서드도 Response 를 돌려주지
// 않는다 — readEntity 를 부를 대상이 없다. 진단은 남는다: 타입 이름(「jakarta.ws.rs.NotAuthorizedException (message withheld)」)과 분류
// (KeycloakTransportException · 「Admin request failed」). admin-client 의 Basic 은 시크릿을 폼 인코딩하지 않는다 — 꼴 다섯은 서버가 받은
// 자격에서 만든다. 네트워크는 루프백만.
private const val AE_SECRET = "sec ret/+=~0005é"
private val AE_VARIANTS = listOf("raw", "form", "pct", "b64", "userinfo")

// 원인·suppressed 를 따라 닿는 예외 전부(순환은 한 번만).
internal fun aeGraph(root: Throwable): List<Throwable> {
    val out = mutableListOf<Throwable>()
    val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
    val todo = ArrayDeque<Throwable>().apply { add(root) }
    while (todo.isNotEmpty()) {
        val t = todo.removeLast()
        if (!seen.add(t)) continue
        out += t
        t.cause?.let { todo.add(it) }
        t.suppressed.forEach { todo.add(it) }
    }
    return out
}

// 예외 하나가 Response 를 내줄 수 있는가 — 그 타입이거나, 공개 메서드 하나라도 그것을 돌려준다.
internal fun aeResponseHandle(t: Throwable): String? {
    if (t is WebApplicationException || t is ResponseProcessingException) return t.javaClass.name
    return t.javaClass.methods
        .firstOrNull { Response::class.java.isAssignableFrom(it.returnType) }
        ?.let { "${t.javaClass.name}.${it.name}()" }
}

internal class AdminTokenEchoTest {
    private lateinit var server: HttpServer

    @Volatile private var variant = "raw"

    // 마지막으로 되울린 문자열(서버가 실제로 쓴 꼴).
    @Volatile private var echoed = ""

    private val adminHits = Collections.synchronizedList(mutableListOf<String>())

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
        if (!ex.requestURI.path.endsWith("/protocol/openid-connect/token")) {
            adminHits += "${ex.requestMethod} ${ex.requestURI.path}"
            send(ex, 200, """{"id":"x","username":"alice"}""")
            return
        }
        val credential =
            ex.requestHeaders
                .getFirst("Authorization")
                ?.substringAfter(' ')
                .orEmpty()
        val userinfo = String(Base64.getDecoder().decode(credential), StandardCharsets.UTF_8)
        val password = userinfo.substringAfter(':')
        val form = URLEncoder.encode(password, StandardCharsets.UTF_8)
        echoed =
            when (variant) {
                "raw" -> password
                "form" -> form
                "pct" -> form.replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
                "b64" -> credential
                "userinfo" -> userinfo
                else -> error(variant)
            }
        send(ex, 401, """{"error":"invalid_client","error_description":"Bad credentials: $echoed"}""")
    }

    private fun send(
        ex: HttpExchange,
        status: Int,
        body: String,
    ) {
        val bytes = body.toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(status, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }

    @Test
    fun `a token endpoint echo leaves no readable body in the thrown graph`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (v in AE_VARIANTS) {
                variant = v
                val admin =
                    AdminClient(
                        KeycloakConfig(
                            serverUrl = "http://127.0.0.1:${server.address.port}",
                            realm = "r",
                            clientId = "c",
                            clientSecret = AE_SECRET.toCharArray(),
                            readTimeout = Duration.ofSeconds(10),
                        ),
                    )
                val thrown =
                    try {
                        admin.users().get("x")
                        null
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        e
                    } finally {
                        admin.close()
                    }
                val handles = mutableListOf<String>()
                val bodies = mutableListOf<String>()
                thrown?.let { t ->
                    for (node in aeGraph(t)) {
                        val handle = aeResponseHandle(node) ?: continue
                        handles += handle
                        if (node is WebApplicationException && node.response != null) {
                            bodies += runCatching { node.response.readEntity(String::class.java) }.getOrElse { "(unreadable: $it)" }
                        }
                    }
                }
                val label = "admin token · $v"
                table += "${label.padEnd(22)} echoed=${echoed.padEnd(44)} → ${thrown?.let {
                    "${it.javaClass.simpleName}(${it.message})"
                } ?: "성공"} · handles=$handles · bodies=$bodies"
                if (thrown !is KeycloakTransportException || thrown.message != "Admin request failed") {
                    wrong += "$label: KeycloakTransportException(Admin request failed) 가 아니다 — $thrown"
                    continue
                }
                if (handles.isNotEmpty()) wrong += "$label: 던진 예외에서 Response 에 닿는다 — $handles · readEntity → $bodies"
                val text = thrown.toString() + "\n" + thrown.stackTraceToString()
                if (echoed in text) wrong += "$label: 오류 표현이 되울린 꼴 「$echoed」 을 찍었다"
                if ("Bad credentials" in text) wrong += "$label: 오류 표현이 토큰 엔드포인트의 본문을 찍었다"
                if ("jakarta.ws.rs.NotAuthorizedException" !in text) wrong += "$label: 진단(원인의 타입 이름 NotAuthorizedException)을 잃었다"
                if (adminHits.isNotEmpty()) wrong += "$label: 토큰 없이 admin 요청이 나갔다 — $adminHits"
            }
            println("[AdminTokenEchoTest]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }
}
