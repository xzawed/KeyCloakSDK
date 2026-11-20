package io.github.xzawed.keycloak

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals

// admin 그랜트가 보낸 비밀([adminSentValues]) — 성공 상태의 OAuth error 를 코드로 실을지 이것과 대조한다(등록부
// auth-2xx-error-code-divergent · Java `TokenResponseGuard.sentValues` 동형). 실제 레인은 TokenResponseClassTest 의 success status OAuth
// error 사례가 잰다(Basic 자격으로 나간 시크릿의 되울림).
internal class AdminSentValuesTest {
    // Basic 자격과 그것을 푼 시크릿, 폼의 비밀 매개변수만. Bearer 는 자격만 · 깨진 Basic 은 자격만 · 비밀이 아닌 매개변수(client_id ·
    // grant_type)와 문자열이 아닌 값은 빼고 · 빈 값은 비교하지 않는다(빈 문자열은 모든 코드의 조각이다).
    @Test
    fun `success status OAuth error compares what the admin grant sent`() {
        val basic = "Basic " + Base64.getEncoder().encodeToString("app:EchoedSecret".toByteArray())
        val form =
            mapOf(
                "grant_type" to listOf("refresh_token"),
                "client_id" to listOf("app"),
                "refresh_token" to listOf("RT-1", 7),
                "password" to listOf(""),
            )
        assertEquals(
            listOf(basic.removePrefix("Basic "), "EchoedSecret", "RT-1"),
            adminSentValues(basic, form),
        )
        assertEquals(listOf("tok"), adminSentValues("Bearer tok", null))
        assertEquals(listOf("%%%"), adminSentValues("Basic %%%", "not a form"))
        assertEquals(emptyList(), adminSentValues(null, mapOf("client_secret" to "not a list")))
    }
}
