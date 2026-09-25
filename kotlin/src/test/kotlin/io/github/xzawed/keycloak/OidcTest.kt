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

    @Test
    fun `forRealm percent-encodes realm in endpoint paths and keeps issuer raw`() {
        val e = OidcEndpoints.forRealm("https://kc.example.com", "my realm")
        assertEquals("https://kc.example.com/realms/my realm", e.issuer)
        val base = "https://kc.example.com/realms/my%20realm/protocol/openid-connect"
        assertEquals("$base/token", e.token)
        assertEquals("$base/auth", e.authorization)
        assertEquals("$base/token/introspect", e.introspection)
        assertEquals("$base/logout", e.logout)
        assertEquals("$base/userinfo", e.userinfo)
        assertEquals("$base/certs", e.jwks)
    }

    @Test
    fun `forRealm percent-encodes a non-ASCII realm as UTF-8`() {
        // é = UTF-8 C3 A9. issuer 만 raw, 엔드포인트는 대문자 %XX.
        val e = OidcEndpoints.forRealm("https://kc.example.com", "réalm")
        assertEquals("https://kc.example.com/realms/réalm", e.issuer)
        val base = "https://kc.example.com/realms/r%C3%A9alm/protocol/openid-connect"
        assertEquals("$base/token", e.token)
        assertEquals("$base/auth", e.authorization)
        assertEquals("$base/token/introspect", e.introspection)
        assertEquals("$base/logout", e.logout)
        assertEquals("$base/userinfo", e.userinfo)
        assertEquals("$base/certs", e.jwks)
    }

    @Test
    fun `forRealm keeps unreserved path characters`() {
        // A-Z a-z 0-9 - . _ ~ 는 그대로, 그 외 바이트(! = 0x21)만 %XX.
        val e = OidcEndpoints.forRealm("https://kc.example.com", "A-b_c.d~e9!")
        assertEquals("https://kc.example.com/realms/A-b_c.d~e9!", e.issuer)
        assertEquals(
            "https://kc.example.com/realms/A-b_c.d~e9%21/protocol/openid-connect/token",
            e.token,
        )
    }
}
