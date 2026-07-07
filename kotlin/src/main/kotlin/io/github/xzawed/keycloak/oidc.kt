package io.github.xzawed.keycloak

// oidc.kt — Keycloak realm의 OIDC 엔드포인트 URL 집합. 네트워크 조회 없이
// `{serverUrl}/realms/{realm}/protocol/openid-connect/...` 규약으로 조립한다(Java OidcMetadata 동형).
public data class OidcEndpoints(
    public val issuer: String,
    public val token: String,
    public val authorization: String,
    public val introspection: String,
    public val logout: String,
    public val userinfo: String,
    public val jwks: String,
) {
    public companion object {
        public fun forRealm(config: KeycloakConfig): OidcEndpoints = forRealm(config.serverUrl, config.realm)

        public fun forRealm(
            serverUrl: String,
            realm: String,
        ): OidcEndpoints {
            val issuer = "${serverUrl.trimEnd('/')}/realms/$realm"
            val base = "$issuer/protocol/openid-connect"
            return OidcEndpoints(
                issuer = issuer,
                token = "$base/token",
                authorization = "$base/auth",
                introspection = "$base/token/introspect",
                logout = "$base/logout",
                userinfo = "$base/userinfo",
                jwks = "$base/certs",
            )
        }
    }
}
