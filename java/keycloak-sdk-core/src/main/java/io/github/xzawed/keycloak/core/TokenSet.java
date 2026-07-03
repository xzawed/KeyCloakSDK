package io.github.xzawed.keycloak.core;
import java.time.*;
import java.util.Objects;
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
    // 만료 시각을 알 수 없으면 안전하게 "만료됨" 취급해 강제로 재발급/갱신을 유도한다 (M.6).
    if (expiresAt == null) return true;
    return !Instant.now(clock).plus(skew).isBefore(expiresAt);
  }
  @Override public String toString() {
    return "TokenSet{tokenType=" + tokenType + ", scope=" + scope
        + ", accessToken=***, refreshToken=" + (refreshToken == null ? "null" : "***")
        + ", expiresAt=" + expiresAt + "}";
  }
  @Override public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof TokenSet other)) return false;
    return Objects.equals(accessToken, other.accessToken)
        && Objects.equals(refreshToken, other.refreshToken)
        && Objects.equals(idToken, other.idToken)
        && Objects.equals(tokenType, other.tokenType)
        && Objects.equals(scope, other.scope)
        && Objects.equals(expiresAt, other.expiresAt);
  }
  @Override public int hashCode() {
    return Objects.hash(accessToken, refreshToken, idToken, tokenType, scope, expiresAt);
  }
}
