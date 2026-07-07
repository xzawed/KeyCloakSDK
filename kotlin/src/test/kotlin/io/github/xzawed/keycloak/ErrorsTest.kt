package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertEquals
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
}
