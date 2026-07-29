package io.github.xzawed.keycloak

import java.time.Duration

// config = 일반 class(⚠️ data class 금지: CharArray identity + 시크릿 누출)·named-arg·init 검증·trimEnd·방어복사
public class KeycloakConfig(
    serverUrl: String,
    public val realm: String,
    public val clientId: String,
    clientSecret: CharArray? = null,
    public val scopes: List<String> = emptyList(),
    // JWT `aud` 포함검사에 기대할 값 — 미설정(null)이면 clientId로 대체된다(기존 동작). 기본 realm은
    // client-credentials 토큰의 aud에 client id를 넣지 않으므로(그러려면 audience 프로토콜 매퍼가 필요)
    // 리소스 서버 이름 등 실제로 발급되는 audience로 재정의할 수 있다.
    expectedAudience: String? = null,
    // JWT 서명 검증 허용 알고리즘 핀(기본 ["RS256"]). ES256/PS256 realm용 설정 가능 —
    // 하드코딩하면 그런 realm의 정상 토큰이 전부 거부된다. 빈 집합은 alg 핀 무력화라 거부.
    public val signatureAlgorithms: List<String> = listOf("RS256"),
    public val connectTimeout: Duration = Duration.ofSeconds(10),
    public val readTimeout: Duration = Duration.ofSeconds(30),
    public val clockSkew: Duration = Duration.ofSeconds(30),
    // 미해결 kid(키 회전)로 인한 JWKS 재조회의 최소 간격(기본 30초 = Nimbus DEFAULT_RATE_LIMIT_MIN_INTERVAL
    // 동형) — DoS 증폭 상한. 위조 kid를 연속 주입해도 이 간격보다 자주 IdP를 때리지 못한다.
    public val jwksMinRefetch: Duration = Duration.ofSeconds(30),
) {
    public val serverUrl: String = serverUrl.trimEnd('/')
    public val expectedAudience: String = expectedAudience ?: clientId
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
