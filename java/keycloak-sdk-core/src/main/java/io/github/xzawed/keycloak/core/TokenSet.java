package io.github.xzawed.keycloak.core;
import java.time.*;
public final class TokenSet {
  private final String accessToken, refreshToken, idToken, tokenType, scope;
  private final Instant expiresAt;
  public TokenSet(String accessToken, String refreshToken, String idToken,
                  String tokenType, String scope, Instant expiresAt) {
    this.accessToken = accessToken; this.refreshToken = refreshToken; this.idToken = idToken;
    this.tokenType = tokenType; this.scope = scope; this.expiresAt = expiresAt;
  }
  public String getAccessToken() { return accessToken; }
  public String getRefreshToken() { return refreshToken; }
  public String getIdToken() { return idToken; }
  public String getTokenType() { return tokenType; }
  public String getScope() { return scope; }
  public Instant getExpiresAt() { return expiresAt; }
  public boolean isExpired(Clock clock, Duration skew) {
    return !Instant.now(clock).plus(skew).isBefore(expiresAt);
  }
  @Override public String toString() {
    return "TokenSet{tokenType=" + tokenType + ", scope=" + scope
        + ", accessToken=***, refreshToken=" + (refreshToken == null ? "null" : "***")
        + ", expiresAt=" + expiresAt + "}";
  }
}
