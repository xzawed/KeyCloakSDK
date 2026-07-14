package io.github.xzawed.keycloak

import java.time.Duration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class ConfigTest {
    @Test
    fun `blank serverUrl throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "", realm = "r", clientId = "c")
        }
    }

    @Test
    fun `blank realm throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "", clientId = "c")
        }
    }

    @Test
    fun `blank clientId throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "")
        }
    }

    @Test
    fun `whitespace-only serverUrl throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "   ", realm = "r", clientId = "c")
        }
    }

    @Test
    fun `serverUrl trailing slash is trimmed`() {
        val config = KeycloakConfig(serverUrl = "http://x/", realm = "r", clientId = "c")
        assertEquals("http://x", config.serverUrl)
    }

    @Test
    fun `serverUrl without trailing slash is unchanged`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals("http://x", config.serverUrl)
    }

    @Test
    fun `toString masks clientSecret and never contains raw secret`() {
        val config =
            KeycloakConfig(
                serverUrl = "http://x",
                realm = "r",
                clientId = "c",
                clientSecret = "super-secret-value".toCharArray(),
            )
        val s = config.toString()
        assertTrue(s.contains("clientSecret=***"))
        assertFalse(s.contains("super-secret-value"))
    }

    @Test
    fun `toString shows serverUrl realm and clientId`() {
        val config = KeycloakConfig(serverUrl = "http://x/", realm = "myrealm", clientId = "myclient")
        val s = config.toString()
        assertTrue(s.contains("serverUrl=http://x"))
        assertTrue(s.contains("realm=myrealm"))
        assertTrue(s.contains("clientId=myclient"))
    }

    @Test
    fun `toString shows empty mask for null clientSecret`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", clientSecret = null)
        val s = config.toString()
        assertTrue(s.contains("clientSecret="))
        assertFalse(s.contains("clientSecret=***"))
    }

    @Test
    fun `clientSecret getter returns a defensive copy on input`() {
        val original = "mysecret".toCharArray()
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", clientSecret = original)
        original[0] = 'X'
        val returned = config.clientSecret
        assertEquals('m', returned!![0])
    }

    @Test
    fun `clientSecret getter returns a defensive copy on output`() {
        val config =
            KeycloakConfig(
                serverUrl = "http://x",
                realm = "r",
                clientId = "c",
                clientSecret = "mysecret".toCharArray(),
            )
        val firstCopy = config.clientSecret
        firstCopy!![0] = 'X'
        val secondCopy = config.clientSecret
        assertEquals('m', secondCopy!![0])
    }

    @Test
    fun `clientSecret defaults to null`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(null, config.clientSecret)
    }

    @Test
    fun `default connectTimeout is 10 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(10), config.connectTimeout)
    }

    @Test
    fun `default readTimeout is 30 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(30), config.readTimeout)
    }

    @Test
    fun `default clockSkew is 30 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(30), config.clockSkew)
    }

    @Test
    fun `default scopes is empty list`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertTrue(config.scopes.isEmpty())
    }

    @Test
    fun `default signatureAlgorithms is RS256`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(listOf("RS256"), config.signatureAlgorithms)
    }

    @Test
    fun `custom signatureAlgorithms are preserved`() {
        val config =
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", signatureAlgorithms = listOf("ES256", "RS256"))
        assertEquals(listOf("ES256", "RS256"), config.signatureAlgorithms)
    }

    @Test
    fun `empty signatureAlgorithms throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", signatureAlgorithms = emptyList())
        }
    }
}
