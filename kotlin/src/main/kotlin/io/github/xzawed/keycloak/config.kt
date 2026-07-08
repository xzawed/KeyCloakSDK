package io.github.xzawed.keycloak

import java.time.Duration

// config = 일반 class(⚠️ data class 금지: CharArray identity + 시크릿 누출)·named-arg·init 검증·trimEnd·방어복사
public class KeycloakConfig(
    serverUrl: String,
    public val realm: String,
    public val clientId: String,
    clientSecret: CharArray? = null,
    public val scopes: List<String> = emptyList(),
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
    }

    override fun toString(): String = "KeycloakConfig(serverUrl=$serverUrl, realm=$realm, clientId=$clientId, clientSecret=${mask(secret)})"
}
