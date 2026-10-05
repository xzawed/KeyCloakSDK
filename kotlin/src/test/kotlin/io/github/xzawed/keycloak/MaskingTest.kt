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

    // 되울린 사본은 보낸 값 그대로가 아닐 수 있다 — 문구는 Nimbus 가 RFC 6749 §5.2 밖의 글자를 지운 뒤이고(LF·NUL·U+0100),
    // 짝 없는 서로게이트는 UTF-8 이 `?` 로 보냈다. 둘이 겹치면 `?` 로 바뀐 꼴에서 다시 지운 꼴이다.
    @Test
    fun `maskSent hides the forms an echoed value takes on the wire and through Nimbus' filter`() {
        val token = "RT\nLF\u0000NULĀWIDE-1"
        assertEquals("Bad token: *** (x)", maskSent("Bad token: RTLFNULWIDE-1 (x)", listOf(token)))
        assertEquals("Bad token: *** (x)", maskSent("Bad token: RT-ab?cd (x)", listOf("RT-ab\uD800cd")))
        val both = "RT-é-\uD800-x"
        assertEquals("a *** b *** c", maskSent("a RT---x b RT--?-x c", listOf(both)))
        // 지우고 나면 아무것도 안 남는 값은 가릴 것이 없다 — 빈 꼴이 모든 글자 사이에 끼어들지 않는다.
        assertEquals("prose stays", maskSent("prose stays", listOf("Ā\n")))
    }

    // 폼 인코딩된 꼴 — SDK 는 grant 값을 본문에, 클라이언트 시크릿을 Basic 의 비밀번호 칸에 그 꼴로 싣는다(RFC 6749 §2.3.1). 폼
    // 디코딩 없이 되울리는 IdP 앞에서는 그 꼴이 돌아온다 — 어느 보낸 값이든(grant 입력값만이 아니라) 가린다.
    @Test
    fun `maskSent hides the form-encoded form of any sent value`() {
        assertEquals("Bad: *** (x)", maskSent("Bad: sec+ret%2F%2B%3D%7E%C3%A9 (x)", listOf("sec ret/+=~é")))
        assertEquals("Bad: *** (x)", maskSent("Bad: a%3F+b (x)", listOf("a\uD800 b")))
    }

    // 빈 값은 가릴 것이 아니다 — `replace("", …)` 는 모든 글자 사이에 끼어든다.
    @Test
    fun `maskSent ignores empty values and passes null text through`() {
        assertEquals("unchanged", maskSent("unchanged", listOf("", null)))
        assertNull(maskSent(null, listOf("x")))
    }
}
