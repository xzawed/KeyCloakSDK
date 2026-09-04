package io.github.xzawed.keycloak

import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import com.nimbusds.jose.util.DefaultResourceRetriever
import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.net.InetSocketAddress
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * SSRF 하드닝 — SDK가 **스스로 보내는** back-channel 요청(token·refresh·introspect·logout)은
 * 3xx를 따라가면 안 된다. Nimbus `HTTPRequest`의 기본값은 추종이다.
 *
 * 왜 심각한가(실측): 모든 `send()` 호출부가 `applyTimeouts`를 지나므로 한 곳이 뚫리면 전부 뚫린다.
 * 그리고 이 클래스의 위험은 "엉뚱한 URL을 가져온다"에 그치지 않는다 — **logout이 302를 따라가
 * 무관한 200을 받으면 정상 반환**한다. 호출자는 세션이 폐기됐다고 믿지만 실제로는 살아 있다.
 * 예외보다 나쁜 실패 모드다. Java 자매 SDK의 `AuthClientRedirectHardeningTest`와 동형.
 *
 * ⚠️ OIDC authorization-code의 `redirect_uri`는 브라우저 front-channel 개념이라 무관하다.
 * 네트워크 불필요 — 단일 병목의 산출물을 직접 확인하는 것이 가장 좁고 확실한 계약이다.
 */
internal class AuthClientRedirectHardeningTest {
    @Test
    fun `applyTimeouts disables redirect following`() {
        val config = KeycloakConfig(serverUrl = "https://kc.example.com", realm = "r", clientId = "app")
        val client = AuthClient(config)
        val req =
            HTTPRequest(
                HTTPRequest.Method.POST,
                URI("https://kc.example.com/realms/r/protocol/openid-connect/token").toURL(),
            )

        // 전제 확인: Nimbus 기본값은 추종이다. 이 단언이 깨지면 상류가 기본값을 바꿨다는 뜻이고,
        // 그때는 아래 하드닝이 아직 필요한지 재검토해야 한다(무의미해진 코드를 남기지 않도록).
        assertTrue(
            req.followRedirects,
            "Nimbus HTTPRequest의 기본값이 더 이상 '추종'이 아니라면 이 하드닝의 전제를 재검토할 것",
        )

        assertFalse(
            client.applyTimeouts(req).followRedirects,
            "SSRF 하드닝: back-channel 요청은 3xx를 따라가면 안 된다",
        )
    }

    /**
     * JWKS 조회 경로도 3xx를 따라가면 안 된다 — 여기가 뚫리면 공격자가 고른 URL의 응답이
     * **서명 검증용 키 집합으로 쓰인다**. auth 경로보다 결과가 나쁘다.
     *
     * 대조군으로 Nimbus 기본 리트리버를 같은 서버에 붙여 **그쪽은 따라간다**는 것까지 확인한다 —
     * 없으면 "서버가 302를 주긴 했다"만 증명하는 셈이 된다. Java 자매 SDK와 동형.
     */
    @Test
    fun `jwks retriever does not follow redirects`() {
        val internalHits = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val keys = """{"keys":[]}""".toByteArray()
        server.createContext("/internal") { ex ->
            internalHits.incrementAndGet()
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(200, keys.size.toLong())
            ex.responseBody.use { it.write(keys) }
        }
        server.createContext("/certs") { ex ->
            ex.responseHeaders.add("Location", "/internal")
            ex.sendResponseHeaders(302, -1)
            ex.close()
        }
        server.start()
        try {
            val certs = URI("http://127.0.0.1:${server.address.port}/certs").toURL()

            // 대조군: Nimbus 기본 리트리버는 따라간다 — 깨지면 상류가 기본값을 바꿨다는 뜻이다.
            DefaultResourceRetriever(2000, 2000).retrieveResource(certs)
            assertTrue(internalHits.get() > 0, "대조군(기본 리트리버)은 리다이렉트를 따라가야 한다")

            internalHits.set(0)
            assertFailsWith<IOException> {
                NoRedirectResourceRetriever(2000, 2000).retrieveResource(certs)
            }
            assertEquals(
                0,
                internalHits.get(),
                "SSRF 하드닝: 리다이렉트 대상은 조회되면 안 된다 — 그 응답이 서명 검증 키가 된다",
            )
        } finally {
            server.stop(0)
        }
    }

    /**
     * JWKS 응답 크기에 상한이 있어야 한다 — 없으면 무제한 응답이 그대로 힙에 들어온다.
     *
     * 왜 필요한가: 리트리버를 **주입하는 행위 자체가** Nimbus의 상한을 지운다. `JWKSourceBuilder`는
     * 리트리버를 안 주면 자기 것을 `(500, 500, 51200)`으로 만드는데, SSRF 하드닝을 위해 우리 것을
     * 주입하면 그 51200이 사라진다 — **보안 하드닝 하나가 다른 보안 속성을 조용히 없앤 자리**다.
     *
     * ⚠️ 대조군을 지우지 말 것 — sizeLimit 0(무제한)인 리트리버는 같은 서버에서 같은 응답을
     * 성공적으로 받는다. 그게 없으면 이 테스트는 "서버가 뭔가 잘못됐다"로도 통과한다.
     */
    @Test
    fun `jwks retriever bounds response size`() {
        val limit = JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT
        // 상한보다 확실히 큰 JWKS. 파싱 가능할 필요는 없다 — 상한은 파싱 전에 걸린다.
        val pad = "A".repeat(limit * 2)
        val huge = """{"keys":[],"pad":"$pad"}""".toByteArray()
        assertTrue(huge.size > limit, "픽스처가 상한보다 커야 의미가 있다")

        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/certs") { ex ->
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(200, huge.size.toLong())
            ex.responseBody.use { it.write(huge) }
        }
        server.start()
        try {
            val certs = URI("http://127.0.0.1:${server.address.port}/certs").toURL()

            // 대조군: 상한 없는(2-arg → sizeLimit 0) 리트리버는 같은 응답을 통째로 받아낸다.
            assertEquals(
                0,
                DefaultResourceRetriever(2000, 2000).sizeLimit,
                "2-arg 생성자는 sizeLimit을 0(무제한)으로 둔다 — 이 전제가 깨지면 상류가 바뀐 것이다",
            )
            assertTrue(
                DefaultResourceRetriever(2000, 2000).retrieveResource(certs).content.length > limit,
                "대조군: 상한이 없으면 상한보다 큰 응답이 그대로 들어온다",
            )

            assertEquals(
                limit,
                NoRedirectResourceRetriever(2000, 2000).sizeLimit,
                "JWKS 리트리버는 Nimbus의 기본 상한을 그대로 이어받아야 한다",
            )
            assertFailsWith<IOException>(
                "상한을 넘는 JWKS 응답은 조회 실패로 표면화되어야 한다 — 무제한으로 힙에 들이면 안 된다",
            ) {
                NoRedirectResourceRetriever(2000, 2000).retrieveResource(certs)
            }
        } finally {
            server.stop(0)
        }
    }
}
