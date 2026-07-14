package io.github.xzawed.keycloak

import java.time.Duration

// config = 일반 class(⚠️ data class 금지: CharArray identity + 시크릿 누출)·named-arg·init 검증·trimEnd·방어복사
public class KeycloakConfig(
    serverUrl: String,
    public val realm: String,
    public val clientId: String,
    clientSecret: CharArray? = null,
    public val scopes: List<String> = emptyList(),
    // JWT 서명 검증 허용 알고리즘 핀(기본 ["RS256"]). ES256/PS256 realm용 설정 가능 —
    // 하드코딩하면 그런 realm의 정상 토큰이 전부 거부된다. 빈 집합은 alg 핀 무력화라 거부.
    public val signatureAlgorithms: List<String> = listOf("RS256"),
    public val connectTimeout: Duration = Duration.ofSeconds(10),
    public val readTimeout: Duration = Duration.ofSeconds(30),
    public val clockSkew: Duration = Duration.ofSeconds(30),
) {
    public val serverUrl: String = serverUrl.trimEnd('/')
    private val secret: CharArray? = clientSecret?.copyOf()
    public val clientSecret: CharArray? get() = secret?.copyOf()

    init {
        if (this.serverUrl.isBlank()) throw KeycloakConfigException("Missing required config: serverUrl")
        if (realm.isBlank()) throw KeycloakConfigException("Missing required config: realm")
        if (clientId.isBlank()) throw KeycloakConfigException("Missing required config: clientId")
        if (signatureAlgorithms.isEmpty()) throw KeycloakConfigException("signatureAlgorithms must be non-empty")
    }

    override fun toString(): String = "KeycloakConfig(serverUrl=$serverUrl, realm=$realm, clientId=$clientId, clientSecret=${mask(secret)})"
}
