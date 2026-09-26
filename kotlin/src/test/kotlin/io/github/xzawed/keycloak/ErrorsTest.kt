package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class ErrorsTest {
    @Test
    fun `NotFound is a KeycloakAdminException and a KeycloakException`() {
        val e = KeycloakAdminException.NotFound(404, "x")
        assertIs<KeycloakAdminException>(e)
        assertIs<KeycloakException>(e)
        assertEquals(404, e.status)
        assertEquals("x", e.keycloakError)
    }

    @Test
    fun `Conflict is a KeycloakAdminException and a KeycloakException`() {
        val e = KeycloakAdminException.Conflict(409, "conflict")
        assertIs<KeycloakAdminException>(e)
        assertIs<KeycloakException>(e)
        assertEquals(409, e.status)
        assertEquals("conflict", e.keycloakError)
    }

    @Test
    fun `Forbidden is a KeycloakAdminException and a KeycloakException`() {
        val e = KeycloakAdminException.Forbidden(403, "forbidden")
        assertIs<KeycloakAdminException>(e)
        assertIs<KeycloakException>(e)
        assertEquals(403, e.status)
        assertEquals("forbidden", e.keycloakError)
    }

    @Test
    fun `Other constructs with null keycloakError`() {
        val e = KeycloakAdminException.Other(500, null)
        assertIs<KeycloakAdminException>(e)
        assertIs<KeycloakException>(e)
        assertEquals(500, e.status)
        assertNull(e.keycloakError)
    }

    @Test
    fun `KeycloakAdminException message includes status`() {
        val e = KeycloakAdminException.NotFound(404, "x")
        assertTrue(e.message!!.contains("404"))
    }

    @Test
    fun `KeycloakConfigException is a KeycloakException`() {
        val e = KeycloakConfigException("bad config")
        assertIs<KeycloakException>(e)
        assertEquals("bad config", e.message)
    }

    @Test
    fun `KeycloakAuthException carries oauthError`() {
        val e = KeycloakAuthException("auth failed", "invalid_grant")
        assertIs<KeycloakException>(e)
        assertEquals("invalid_grant", e.oauthError)
    }

    @Test
    fun `KeycloakAuthException oauthError defaults to null`() {
        val e = KeycloakAuthException("auth failed")
        assertNull(e.oauthError)
    }

    @Test
    fun `KeycloakTransportException is a KeycloakException`() {
        val cause = RuntimeException("boom")
        val e = KeycloakTransportException("transport failed", cause)
        assertIs<KeycloakException>(e)
        assertEquals(cause, e.cause)
    }

    @Test
    fun `TokenValidationException is a KeycloakException`() {
        val e = TokenValidationException("invalid token")
        assertIs<KeycloakException>(e)
        assertEquals("invalid token", e.message)
    }

    // 응답을 인용하는 하위 예외의 사본 — 타입 이름·프레임은 남고, 메시지는 사슬 어디에서도 옮겨지지 않는다.
    @Test
    fun `RedactedCause keeps types and frames of the whole chain but no message`() {
        val leaf = java.text.ParseException("Unexpected token LEAK-LEAF at position 0.", 0)
        val middle = IllegalStateException("wrapped: $leaf", leaf)
        middle.addSuppressed(IllegalArgumentException("LEAK-SUPPRESSED"))
        val top = RuntimeException("Invalid JSON: LEAK-TOP", middle)

        val copy = RedactedCause.of(top)
        val printed = copy.stackTraceToString()

        assertFalse("LEAK" in printed, printed)
        assertNull(copy.message)
        assertEquals("java.lang.RuntimeException (message withheld)", copy.toString())
        assertEquals(top.stackTrace.toList(), copy.stackTrace.toList())
        val chain = generateSequence<Throwable>(copy) { it.cause }.toList()
        assertEquals(
            listOf("java.lang.RuntimeException", "java.lang.IllegalStateException", "java.text.ParseException"),
            chain.map { (it as RedactedCause).originalType },
        )
        assertEquals("java.lang.IllegalArgumentException", (chain[1].suppressed.single() as RedactedCause).originalType)
        assertTrue("Caused by: java.text.ParseException (message withheld)" in printed, printed)
    }

    // 원인 사슬은 순환할 수 있다 — 사본은 깊이에서 끊겨 끝난다(무한 재귀·스택 넘침이 아니다).
    @Test
    fun `RedactedCause stops at a cyclic chain`() {
        val a = RuntimeException("LEAK-A")
        val b = RuntimeException("LEAK-B", a)
        a.initCause(b)

        val depth = generateSequence<Throwable>(RedactedCause.of(a)) { it.cause }.count()

        assertEquals(17, depth)
    }
}
