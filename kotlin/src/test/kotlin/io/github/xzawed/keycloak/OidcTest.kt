package io.github.xzawed.keycloak

import kotlin.test.Test
import kotlin.test.assertEquals

internal class OidcTest {
    @Test
    fun `forRealm builds standard Keycloak endpoints from serverUrl and realm`() {
        val e = OidcEndpoints.forRealm("https://kc.example.com", "myrealm")
        assertEquals("https://kc.example.com/realms/myrealm", e.issuer)
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/token", e.token)
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/auth", e.authorization)
        assertEquals(
            "https://kc.example.com/realms/myrealm/protocol/openid-connect/token/introspect",
            e.introspection,
        )
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/logout", e.logout)
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/userinfo", e.userinfo)
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", e.jwks)
    }

    @Test
    fun `forRealm builds endpoints from a KeycloakConfig`() {
        val config = KeycloakConfig(serverUrl = "https://kc.example.com/", realm = "myrealm", clientId = "app")
        val e = OidcEndpoints.forRealm(config)
        assertEquals("https://kc.example.com/realms/myrealm", e.issuer)
        assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", e.jwks)
    }

    @Test
    fun `forRealm trims trailing slash from serverUrl`() {
        val e = OidcEndpoints.forRealm("https://kc.example.com/", "myrealm")
        assertEquals("https://kc.example.com/realms/myrealm", e.issuer)
    }
}
