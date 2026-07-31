package io.github.xzawed.keycloak

import com.nimbusds.oauth2.sdk.http.HTTPRequest
import java.net.URI
import kotlin.test.Test
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
}
