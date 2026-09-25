package io.github.xzawed.keycloak.core;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import java.util.*;

public final class KeycloakConfig {
  private final String serverUrl, realm, clientId;
  private final char[] clientSecret;               // nullable (public client)
  private final List<String> scopes;
  private final String expectedAudience;           // nullable — 미설정이면 clientId로 대체
  private final List<String> signatureAlgorithms;  // JWT 서명 검증 허용 알고리즘 핀
  private final Duration connectTimeout, readTimeout, clockSkew;
  private final Duration jwksMinRefetch;           // 미해결 kid 재조회 최소 간격(DoS 증폭 상한)

  private KeycloakConfig(Builder b) {
    this.serverUrl = b.serverUrl; this.realm = b.realm; this.clientId = b.clientId;
    this.clientSecret = b.clientSecret == null ? null : b.clientSecret.clone();
    this.scopes = List.copyOf(b.scopes);
    this.expectedAudience = b.expectedAudience;
    this.signatureAlgorithms = List.copyOf(b.signatureAlgorithms);
    this.connectTimeout = b.connectTimeout; this.readTimeout = b.readTimeout;
    this.clockSkew = b.clockSkew; this.jwksMinRefetch = b.jwksMinRefetch;
  }
  public String getServerUrl() { return serverUrl; }
  public String getRealm() { return realm; }
  public String getClientId() { return clientId; }
  public char[] getClientSecret() { return clientSecret == null ? null : clientSecret.clone(); }
  public List<String> getScopes() { return scopes; }
  /**
   * JWT `aud` 포함검사에 기대할 값 — 미설정이면 clientId(기존 동작). 기본 realm은 client-credentials
   * 토큰의 aud에 client id를 넣지 않으므로(그러려면 audience 프로토콜 매퍼가 필요) 리소스 서버 이름 등
   * 실제로 발급되는 audience로 재정의할 수 있다.
   */
  public String getExpectedAudience() { return expectedAudience == null ? clientId : expectedAudience; }
  /** JWT 서명 검증 시 허용할 알고리즘 핀(기본 ["RS256"]). ES256/PS256 realm을 위해 설정 가능. */
  public List<String> getSignatureAlgorithms() { return signatureAlgorithms; }
  public Duration getConnectTimeout() { return connectTimeout; }
  public Duration getReadTimeout() { return readTimeout; }
  public Duration getClockSkew() { return clockSkew; }
  /** 미해결 kid(키 회전)로 인한 JWKS 재조회의 최소 간격(기본 30초) — DoS 증폭 상한. */
  public Duration getJwksMinRefetch() { return jwksMinRefetch; }

  public static Builder builder() { return new Builder(); }

  public static final class Builder {
    private String serverUrl, realm, clientId;
    private char[] clientSecret;
    private List<String> scopes = new ArrayList<>();
    private String expectedAudience;
    private List<String> signatureAlgorithms = new ArrayList<>(List.of("RS256"));
    private Duration connectTimeout = Duration.ofSeconds(10);
    private Duration readTimeout = Duration.ofSeconds(30);
    private Duration clockSkew = Duration.ofSeconds(30);
    private Duration jwksMinRefetch = Duration.ofSeconds(30);   // Nimbus DEFAULT_RATE_LIMIT_MIN_INTERVAL(30s) 동형

    public Builder serverUrl(String v) { this.serverUrl = v; return this; }
    public Builder realm(String v) { this.realm = v; return this; }
    public Builder clientId(String v) { this.clientId = v; return this; }
    public Builder clientSecret(char[] v) { this.clientSecret = v == null ? null : v.clone(); return this; }
    public Builder scopes(String... v) { this.scopes = v == null ? null : Arrays.asList(v); return this; }
    public Builder expectedAudience(String v) { this.expectedAudience = v; return this; }
    public Builder signatureAlgorithms(String... v) {
      this.signatureAlgorithms = v == null ? null : Arrays.asList(v); return this;
    }
    public Builder connectTimeout(Duration v) { this.connectTimeout = v; return this; }
    public Builder readTimeout(Duration v) { this.readTimeout = v; return this; }
    public Builder clockSkew(Duration v) { this.clockSkew = v; return this; }
    public Builder jwksMinRefetch(Duration v) { this.jwksMinRefetch = v; return this; }

    public KeycloakConfig build() {
      require(serverUrl, "serverUrl"); require(realm, "realm"); require(clientId, "clientId");
      requireNoNulls(scopes, "scopes"); requireNoNulls(signatureAlgorithms, "signatureAlgorithms");
      if (signatureAlgorithms.isEmpty())
        throw new KeycloakConfigException("signatureAlgorithms must be non-empty", null);
      requireHttpUrl(serverUrl);
      requireTimeout(connectTimeout, "connectTimeout");
      requireTimeout(readTimeout, "readTimeout");
      requireNonNegative(clockSkew, "clockSkew");
      requireNonNegative(jwksMinRefetch, "jwksMinRefetch");
      requireMillis(jwksMinRefetch, "jwksMinRefetch");
      return new KeycloakConfig(this);
    }
    private static void require(String v, String name) {
      if (v == null || v.isBlank())
        throw new KeycloakConfigException("Missing required config: " + name, null);
    }
    // ⚠️ null 배열·null 원소는 여기서 거부한다 — 안 그러면 Arrays.asList·List.copyOf 가 JDK NPE 로 공개 API 에
    // 샜다(독립 레그 실측). 설정값이므로 다른 builder 검증과 같은 KeycloakConfigException 이다.
    private static void requireNoNulls(List<String> v, String name) {
      if (v == null || v.contains(null))
        throw new KeycloakConfigException(name + " must not be null or contain null", null);
    }
    // ⚠️ 형식이 틀린 serverUrl 은 여기서 거부한다 — 안 그러면 첫 호출에서 하위 예외가 공개 API 로 샜다(상대 URL
    // 은 Nimbus SerializeException 자체, 공백은 URI.create 의 IAE, `http://::1` 은 SerializeException — 실측
    // 2026-09-25). Rust 는 같은 값을 `KeycloakError::Config` 로 거부한다. ⚠️ host 는 요구하지 않는다 — 밑줄
    // 호스트(docker compose 서비스 이름)는 registry-based authority 라 getHost() 가 null 이다. 메시지에는
    // 사유만 싣는다(URISyntaxException 의 message 는 입력 전체를 되울린다). Kotlin 자매와 동형.
    private static void requireHttpUrl(String v) {
      java.net.URI u;
      try {
        u = new java.net.URI(v);
      } catch (java.net.URISyntaxException e) {
        throw badServerUrl(e.getReason(), e);
      }
      if (!u.isAbsolute()) throw badServerUrl("not absolute", null);
      if (!"http".equalsIgnoreCase(u.getScheme()) && !"https".equalsIgnoreCase(u.getScheme()))
        throw badServerUrl("scheme must be http or https", null);
      // "http:foo" 는 스킴이 http 인 불투명 URI 라 toURL() 도 성공한다 — authority 부재를 따로 본다.
      if (u.getRawAuthority() == null) throw badServerUrl("missing authority", null);
      java.net.URL url;
      try {
        url = u.toURL();
      } catch (java.net.MalformedURLException e) {
        throw badServerUrl(e.getMessage(), e); // 예: "http://::1" — URI 는 파싱되지만 URL 이 안 된다(실측).
      }
      // ⚠️ 포트 범위는 URI·URL 어느 쪽도 보지 않는다 — :65536 은 여기까지 통과하고 연결 시점에 IAE("port out of
      // range")로 샜다(독립 레그 실측). URL 의 포트를 본다 — 밑줄 호스트는 URI 가 포트를 읽지 못한다.
      if (url.getPort() > 65535) throw badServerUrl("port out of range", null);
    }
    private static KeycloakConfigException badServerUrl(String reason, Throwable cause) {
      return new KeycloakConfigException("serverUrl must be an absolute http(s) URL: " + reason, cause);
    }
    // ⚠️ 1ms 미만·int 밀리초 초과·null 은 여기서 거부한다 — Nimbus HTTPRequest 가 사용 시점에 IAE·
    // ArithmeticException(Long 오버플로)·NPE 로 거부해 공개 API 로 샜다(실측). 1ms 미만은 0 이 되어 무한 대기다.
    private static void requireTimeout(Duration v, String name) {
      long ms;
      try {
        ms = v == null ? -1 : v.toMillis();
      } catch (ArithmeticException e) {
        ms = Long.MAX_VALUE;
      }
      if (ms < 1 || ms > Integer.MAX_VALUE)
        throw new KeycloakConfigException(name + " must be between 1 ms and " + Integer.MAX_VALUE + " ms", null);
    }
    // ⚠️ null 은 여기서 거부한다 — 첫 validate() 에서 JDK NPE 로 공개 API 에 샜다(실측: clockSkew · jwksMinRefetch
    // 둘 다). 음수는 새지 않지만 의미가 없어 자매(go·dotnet·node·python·php)처럼 생성 시 거부한다. 0 은 허용한다.
    private static void requireNonNegative(Duration v, String name) {
      if (v == null || v.isNegative())
        throw new KeycloakConfigException(name + " must be >= 0", null);
    }
    // ⚠️ 밀리초로 못 나타내는 값은 첫 validate() 의 toMillis() 에서 ArithmeticException 으로 샜다(독립 레그 실측).
    // 5 분 이상은 JwtValidator 가 이미 KeycloakConfigException 으로 거부한다 — 여기서는 표현 가능성만 본다.
    // 이 상한 이하면 toMillis() 가 넘치지 않는다(예외로 흐름을 잡지 않는다).
    private static final Duration MAX_MILLIS = Duration.ofMillis(Long.MAX_VALUE);
    private static void requireMillis(Duration v, String name) {
      if (v.compareTo(MAX_MILLIS) > 0)
        throw new KeycloakConfigException(name + " is too large", null);
    }
  }
}
