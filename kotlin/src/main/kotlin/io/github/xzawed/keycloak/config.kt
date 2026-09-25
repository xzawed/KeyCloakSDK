package io.github.xzawed.keycloak

import java.net.MalformedURLException
import java.net.URI
import java.net.URISyntaxException
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
        // ⚠️ 상대 serverUrl 은 첫 호출에서 Nimbus SerializeException, 공백이 섞인 값은 URISyntaxException
        // 으로 공개 API 에 샌다(실측). 절대 http(s) 와 authority 만 받고 입력 전체는 메시지에 넣지 않는다.
        // 언더스코어 호스트는 registry-based authority 라 getHost() 가 null — host 를 요구하지 않는다.
        validateServerUrl(this.serverUrl)
        // ⚠️ 음수·Int 초과는 Nimbus HTTPRequest 가 IllegalArgumentException, long 을 넘는 Duration 은
        // toMillis() 가 ArithmeticException 으로 샌다(실측). 1ms 미만은 0(=무한 대기)이 되므로 구성 시점에
        // 필드 이름으로 거부한다.
        requireTimeoutMillis("connectTimeout", connectTimeout)
        requireTimeoutMillis("readTimeout", readTimeout)
        // 음수는 의미가 없어 자매(go·dotnet·node·python·php)와 Java 처럼 생성 시 거부한다(null 은 타입이 막는다).
        if (clockSkew.isNegative) throw KeycloakConfigException("clockSkew must be >= 0")
        if (jwksMinRefetch.isNegative) throw KeycloakConfigException("jwksMinRefetch must be >= 0")
    }

    // serverUrl 검증. 사유만 싣는다 — URISyntaxException.message 는 입력 전체를 되울린다.
    private fun validateServerUrl(serverUrl: String) {
        val uri =
            try {
                URI(serverUrl)
            } catch (e: URISyntaxException) {
                throw badServerUrl(e.reason, e)
            }
        if (!uri.isAbsolute) throw badServerUrl("not absolute")
        if (!isHttpOrHttps(uri.scheme)) throw badServerUrl("scheme must be http or https")
        // "http:foo" 는 스킴이 http 인 불투명 URI 라 toURL() 도 성공한다 — authority 부재를 따로 본다.
        if (uri.rawAuthority == null) throw badServerUrl("missing authority")
        val url =
            try {
                uri.toURL()
            } catch (e: MalformedURLException) {
                // 예: "http://::1" — URI 는 파싱되지만 toURL() 이 MalformedURLException 으로 실패한다(실측).
                throw badServerUrl(e.message, e)
            }
        // ⚠️ 포트 범위는 URI·URL 어느 쪽도 보지 않는다 — :65536 은 여기까지 통과하고 연결 시점에 IAE("port out
        // of range")로 샜다(독립 레그 실측, Java 자매). URL 의 포트를 본다 — 밑줄 호스트는 URI 가 포트를 못 읽는다.
        if (url.port > 65535) throw badServerUrl("port out of range")
    }

    private fun badServerUrl(
        reason: String?,
        cause: Throwable? = null,
    ): KeycloakConfigException = KeycloakConfigException("serverUrl must be an absolute http(s) URL: $reason", cause)

    // 절대 URI 만 여기 온다 — 스킴은 null 이 아니다.
    private fun isHttpOrHttps(scheme: String): Boolean =
        scheme.equals("http", ignoreCase = true) || scheme.equals("https", ignoreCase = true)

    private fun requireTimeoutMillis(
        field: String,
        timeout: Duration,
    ) {
        val millis =
            try {
                timeout.toMillis()
            } catch (e: ArithmeticException) {
                throw KeycloakConfigException("$field must be between 1 ms and ${Int.MAX_VALUE} ms", e)
            }
        if (millis < 1L || millis > Int.MAX_VALUE.toLong()) {
            throw KeycloakConfigException("$field must be between 1 ms and ${Int.MAX_VALUE} ms")
        }
    }

    override fun toString(): String = "KeycloakConfig(serverUrl=$serverUrl, realm=$realm, clientId=$clientId, clientSecret=${mask(secret)})"
}
