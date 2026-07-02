package io.github.xzawed.keycloak.auth;

import com.nimbusds.jwt.JWTClaimsSet;
import java.time.Instant;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * SDK-owned, immutable view of a successfully validated access token's claims.
 * <p>
 * {@link JwtValidator#validate(String)} and {@link AuthClient#validate(String)}
 * return this type instead of a Nimbus {@code com.nimbusds.jwt.JWTClaimsSet}
 * (Fix I.1): callers of this SDK's public API must never need a Nimbus
 * dependency on their classpath just to read validated claims.
 */
public final class ValidatedToken {
  private final String subject;
  private final String issuer;
  private final List<String> audience;
  private final Instant expiresAt;
  private final Instant issuedAt;
  private final Map<String, Object> claims;

  private ValidatedToken(String subject, String issuer, List<String> audience,
                         Instant expiresAt, Instant issuedAt, Map<String, Object> claims) {
    this.subject = subject;
    this.issuer = issuer;
    this.audience = audience;
    this.expiresAt = expiresAt;
    this.issuedAt = issuedAt;
    this.claims = claims;
  }

  // 패키지 전용 팩토리: Nimbus JWTClaimsSet → SDK 소유 타입으로 매핑 (I.1).
  static ValidatedToken from(JWTClaimsSet claimsSet) {
    List<String> audience = claimsSet.getAudience() == null
        ? List.of() : List.copyOf(claimsSet.getAudience());
    Instant expiresAt = claimsSet.getExpirationTime() == null
        ? null : claimsSet.getExpirationTime().toInstant();
    Instant issuedAt = claimsSet.getIssueTime() == null
        ? null : claimsSet.getIssueTime().toInstant();
    // JWTClaimsSet.getClaims() never returns null (backed by an internal map that is at
    // worst empty), so no defensive null-check here.
    Map<String, Object> claims =
        Collections.unmodifiableMap(new LinkedHashMap<>(claimsSet.getClaims()));
    return new ValidatedToken(claimsSet.getSubject(), claimsSet.getIssuer(),
        audience, expiresAt, issuedAt, claims);
  }

  public String getSubject() { return subject; }
  public String getIssuer() { return issuer; }
  public List<String> getAudience() { return audience; }
  public Instant getExpiresAt() { return expiresAt; }
  public Instant getIssuedAt() { return issuedAt; }
  public Map<String, Object> getClaims() { return claims; }
}
