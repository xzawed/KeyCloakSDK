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
            val root = serverUrl.trimEnd('/')
            // ⚠️ realm 의 공백은 엔드포인트 URI 파싱이 URISyntaxException 으로 새게 한다(실측). issuer 는
            // 토큰 iss 와 비교하므로 raw realm 을 유지하고, URL 만 경로 한 세그먼트로 percent-encode 한다.
            val issuer = "$root/realms/$realm"
            val base = "$root/realms/${encodePathSegment(realm)}/protocol/openid-connect"
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

        // RFC 3986 unreserved (A-Z a-z 0-9 - . _ ~) 만 그대로 두고, 나머지 UTF-8 바이트는 %XX(대문자).
        private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        private const val HEX = "0123456789ABCDEF"

        private fun encodePathSegment(segment: String): String {
            val bytes = segment.toByteArray(Charsets.UTF_8)
            val encoded = StringBuilder(bytes.size)
            for (byte in bytes) {
                val b = byte.toInt() and 0xFF
                if (UNRESERVED.indexOf(b.toChar()) >= 0) {
                    encoded.append(b.toChar())
                } else {
                    encoded.append('%')
                    encoded.append(HEX[b ushr 4])
                    encoded.append(HEX[b and 0x0F])
                }
            }
            return encoded.toString()
        }
    }
}
