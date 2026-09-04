package io.github.xzawed.keycloak.admin

import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import java.net.InetSocketAddress
import java.net.URI
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * SSRF 고정(pinning) — admin의 JAX-RS/RESTEasy 클라이언트는 3xx를 따라가면 안 된다.
 *
 * 왜 이 형태인가: 자매 언어들과 달리 **여기서는 우리가 끌 노브가 없다.** `AuthClient`는
 * Nimbus `HTTPRequest.followRedirects = false`를 우리가 직접 세팅하지만(그래서
 * [io.github.xzawed.keycloak.AuthClientRedirectHardeningTest]가 그 산출물을 확인한다),
 * JAX-RS `ClientBuilder`에는 리다이렉트 정책 API가 아예 없다 — 안전한 것은 RESTEasy의
 * **기본 동작** 덕분이고 그 기본값은 우리가 통제하지 않는다.
 *
 * 즉 이 테스트가 유일한 방어수단이다. admin-client나 RESTEasy 상향에서 이 기본값이 바뀌면
 * 예상 밖 3xx가 공격자가 고른 내부 URL을 가리켜도 admin 호출이 그것을 따라가게 되는데,
 * 다른 어떤 게이트도 그 변화를 알려주지 않는다.
 *
 * ⚠️ 하드닝이 라이브러리 기본값이라 **변이검증(방어를 지우고 실패를 확인)이 불가능**하다.
 * 그래서 대조군을 함께 둔다 — 추종하도록 설정한 JDK `HttpClient`는 같은 서버에서 실제로
 * `/internal`에 도달한다. 그게 실패하면 프로브(경로 기록)가 고장난 것이고 위 단언의 통과는
 * 무의미해진다. 자매 Node SDK의 jose/openid-client 핀닝 테스트와 같은 구조다.
 *
 * 네트워크는 로컬 루프백만 쓴다(Docker 불필요).
 */
internal class AdminRedirectHardeningTest {
    @Test
    fun `resteasy client does not follow redirects`() {
        val paths = ConcurrentLinkedQueue<String>()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val port = server.address.port
        server.createContext("/") { exchange ->
            paths.add(exchange.requestURI.path)
            if (exchange.requestURI.path == "/start") {
                exchange.responseHeaders.add("Location", "http://127.0.0.1:$port/internal")
                exchange.sendResponseHeaders(302, -1)
            } else {
                // 따라갔다면 여기 도달한다 — 200을 내줘서 "3xx를 삼키고 성공을 반환"하는
                // 최악의 시나리오를 그대로 재현한다.
                val body = "followed".toByteArray()
                exchange.sendResponseHeaders(200, body.size.toLong())
                exchange.responseBody.use { it.write(body) }
            }
            exchange.close()
        }
        server.start()

        val config =
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:$port",
                realm = "r",
                clientId = "app",
            )
        val client = AdminClient.buildTimeoutClient(config)
        try {
            val response = client.target("http://127.0.0.1:$port/start").request().get()
            response.use {
                assertEquals(
                    302,
                    it.status,
                    "admin 전송 계층이 3xx를 호출자에게 표면화해야 한다 — 따라가면 안 된다",
                )
            }
            assertFalse(
                paths.contains("/internal"),
                "리다이렉트 대상에 요청 자체가 가면 안 된다. 실제 경로: $paths",
            )

            // ⚠️ 대조군을 지우지 말 것 — 위 단언이 프로브 고장으로 인한 공허한 통과가 아님을
            // 증명하는 유일한 수단이다(하드닝이 라이브러리 기본값이라 변이검증을 쓸 수 없다).
            paths.clear()
            // ⚠️ `.use { }` 를 쓰지 않는다 — `java.net.http.HttpClient` 가 AutoCloseable 이 된 것은
            // **Java 21 부터**이고, 이 SDK 의 소비자 하한은 17 이다. `-Xjdk-release=17` 을 켜자
            // 정확히 이 줄이 죽었다(receiver type mismatch: `T : Closeable?`). 그 옵션이 없었다면
            // JDK 21 의 API 에 링크된 채 컴파일이 통과하고, 실제 JDK 17 소비자만 런타임에 죽었을 것이다.
            val follower =
                java.net.http.HttpClient
                    .newBuilder()
                    .followRedirects(java.net.http.HttpClient.Redirect.ALWAYS)
                    .build()
            follower.send(
                HttpRequest.newBuilder(URI("http://127.0.0.1:$port/start")).GET().build(),
                HttpResponse.BodyHandlers.ofString(),
            )
            assertTrue(
                paths.contains("/internal"),
                "추종하는 클라이언트는 /internal에 도달해야 한다 — 도달하지 않았다면 프로브가 고장난 것이다",
            )
        } finally {
            client.close()
            server.stop(0)
        }
    }
}
