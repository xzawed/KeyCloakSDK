package io.github.xzawed.keycloak.core;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import java.util.*;

public final class KeycloakConfig {
  private final String serverUrl, realm, clientId;
  private final char[] clientSecret;               // nullable (public client)
  private final List<String> scopes;
  private final List<String> signatureAlgorithms;  // JWT 서명 검증 허용 알고리즘 핀
  private final Duration connectTimeout, readTimeout, clockSkew;
  private final Duration jwksMinRefetch;           // 미해결 kid 재조회 최소 간격(DoS 증폭 상한)

  private KeycloakConfig(Builder b) {
    this.serverUrl = b.serverUrl; this.realm = b.realm; this.clientId = b.clientId;
    this.clientSecret = b.clientSecret == null ? null : b.clientSecret.clone();
    this.scopes = List.copyOf(b.scopes);
    this.signatureAlgorithms = List.copyOf(b.signatureAlgorithms);
    this.connectTimeout = b.connectTimeout; this.readTimeout = b.readTimeout;
    this.clockSkew = b.clockSkew; this.jwksMinRefetch = b.jwksMinRefetch;
  }
  public String getServerUrl() { return serverUrl; }
  public String getRealm() { return realm; }
  public String getClientId() { return clientId; }
  public char[] getClientSecret() { return clientSecret == null ? null : clientSecret.clone(); }
  public List<String> getScopes() { return scopes; }
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
    private List<String> signatureAlgorithms = new ArrayList<>(List.of("RS256"));
    private Duration connectTimeout = Duration.ofSeconds(10);
    private Duration readTimeout = Duration.ofSeconds(30);
    private Duration clockSkew = Duration.ofSeconds(30);
    private Duration jwksMinRefetch = Duration.ofSeconds(30);   // Nimbus DEFAULT_RATE_LIMIT_MIN_INTERVAL(30s) 동형

    public Builder serverUrl(String v) { this.serverUrl = v; return this; }
    public Builder realm(String v) { this.realm = v; return this; }
    public Builder clientId(String v) { this.clientId = v; return this; }
    public Builder clientSecret(char[] v) { this.clientSecret = v == null ? null : v.clone(); return this; }
    public Builder scopes(String... v) { this.scopes = Arrays.asList(v); return this; }
    public Builder signatureAlgorithms(String... v) { this.signatureAlgorithms = Arrays.asList(v); return this; }
    public Builder connectTimeout(Duration v) { this.connectTimeout = v; return this; }
    public Builder readTimeout(Duration v) { this.readTimeout = v; return this; }
    public Builder clockSkew(Duration v) { this.clockSkew = v; return this; }
    public Builder jwksMinRefetch(Duration v) { this.jwksMinRefetch = v; return this; }

    public KeycloakConfig build() {
      require(serverUrl, "serverUrl"); require(realm, "realm"); require(clientId, "clientId");
      if (signatureAlgorithms.isEmpty())
        throw new KeycloakConfigException("signatureAlgorithms must be non-empty", null);
      return new KeycloakConfig(this);
    }
    private static void require(String v, String name) {
      if (v == null || v.isBlank())
        throw new KeycloakConfigException("Missing required config: " + name, null);
    }
  }
}
