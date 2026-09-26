package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class MaskingTest {
    @Test
    fun `mask CharArray null returns empty string`() {
        assertEquals("", mask(null as CharArray?))
    }

    @Test
    fun `mask CharArray non-empty returns stars`() {
        assertEquals("***", mask("x".toCharArray()))
    }

    @Test
    fun `mask CharArray empty returns empty string`() {
        assertEquals("", mask(charArrayOf()))
    }

    @Test
    fun `mask String null returns empty string`() {
        assertEquals("", mask(null as String?))
    }

    @Test
    fun `mask String non-empty returns stars`() {
        assertEquals("***", mask("x"))
    }

    @Test
    fun `mask String empty returns empty string`() {
        assertEquals("", mask(""))
    }

    @Test
    fun `maskSent hides every value the SDK sent and keeps the prose`() {
        val text = "Invalid refresh token: RT-123 (client s3cret, again RT-123)"
        assertEquals("Invalid refresh token: *** (client ***, again ***)", maskSent(text, listOf("RT-123", null, "s3cret")))
    }

    // 긴 값부터 가린다 — 짧은 비밀이 긴 비밀 안에 있어도 긴 쪽의 조각이 남지 않는다.
    @Test
    fun `maskSent masks the longer of two overlapping secrets first`() {
        assertEquals("x *** y", maskSent("x abcdef y", listOf("abc", "abcdef")))
    }

    // 빈 값은 가릴 것이 아니다 — `replace("", …)` 는 모든 글자 사이에 끼어든다.
    @Test
    fun `maskSent ignores empty values and passes null text through`() {
        assertEquals("unchanged", maskSent("unchanged", listOf("", null)))
        assertNull(maskSent(null, listOf("x")))
    }
}
