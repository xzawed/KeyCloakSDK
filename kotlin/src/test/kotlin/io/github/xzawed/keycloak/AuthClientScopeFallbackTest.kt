package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertTrue

/**
 * ⚠️ **openid 스코프 폴백이 「비었을 때」만 걸린다.** `Scope.isEmpty()` 는 **원소 수**를 세므로,
 * 원소가 하나라도 있으면 그 값이 공백이든 빈 문자열이든 폴백이 발동하지 않고 Nimbus 의
 * `IllegalArgumentException("The value must not be null or empty string")` 이 §4 경계를 넘어
 * 공개 API 로 샌다.
 *
 * 도달 가능하다: `KeycloakConfig` 는 scope 값을 검증하지 않으므로, 설정을 환경변수·프로퍼티에서
 * 읽어 넘기는 소비자가 빈 문자열 하나를 그대로 흘려보낼 수 있다.
 *
 * Java 자매(`AuthClientScopeFallbackTest`)와 **같은 계약**이다 — 한쪽만 고치면 그 자체가 드리프트다.
 */
class AuthClientScopeFallbackTest {
    private fun urlFor(vararg scopes: String): String {
        val config =
            KeycloakConfig(
                serverUrl = "https://kc.example.com",
                realm = "r",
                clientId = "app",
                scopes = scopes.toList(),
            )
        val auth = AuthClient(config)
        try {
            return auth.createAuthorizationRequest("https://app.example.com/cb").authorizationUrl
        } finally {
            auth.close()
        }
    }

    /** 대조군 — 원소가 아예 없으면 폴백이 이미 걸렸다(이 동작을 깨지 않는다). */
    @Test
    fun `no scopes at all falls back to openid`() {
        assertContains(urlFor(), "scope=openid")
    }

    /** 대조군 — 정상 스코프는 그대로 간다. */
    @Test
    fun `explicit scopes are preserved`() {
        val url = urlFor("openid", "profile")
        assertTrue(url.contains("openid"), url)
        assertTrue(url.contains("profile"), url)
    }

    @Test
    fun `blank scope string does not leak a Nimbus exception`() {
        assertContains(urlFor(""), "scope=openid")
    }

    @Test
    fun `whitespace-only scope string does not leak a Nimbus exception`() {
        assertContains(urlFor("   "), "scope=openid")
    }

    /** 유효한 값과 공백이 섞이면 공백만 버리고 나머지는 살린다(전체를 openid 로 덮지 않는다). */
    @Test
    fun `blank mixed with valid scopes keeps the valid ones only`() {
        val url = urlFor("openid", "  ", "profile")
        assertTrue(url.contains("openid"), url)
        assertTrue(url.contains("profile"), url)
    }
}
