package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertEquals

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
}
