package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jwt.JWTClaimsSet;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import org.junit.jupiter.api.Test;

// ValidatedToken.from(JWTClaimsSet) 매핑 검증 (I.1): 이 타입은 JwtValidator/AuthClient의
// validate() 공개 반환 타입으로, Nimbus 타입을 감춘 채 subject/issuer/audience/
// expiresAt/issuedAt/claims를 노출해야 한다.
class ValidatedTokenTest {
  @Test void from_mapsAllPresentClaims() {
    Instant exp = Instant.ofEpochSecond(2_000_000_000L);
    Instant iat = Instant.ofEpochSecond(1_000_000_000L);
    JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
        .subject("user-1")
        .issuer("https://kc.example.com/realms/r")
        .audience(List.of("app", "realm-management"))
        .expirationTime(Date.from(exp))
        .issueTime(Date.from(iat))
        .claim("email", "user1@example.com")
        .build();

    ValidatedToken token = ValidatedToken.from(claimsSet);

    assertEquals("user-1", token.getSubject());
    assertEquals("https://kc.example.com/realms/r", token.getIssuer());
    assertEquals(List.of("app", "realm-management"), token.getAudience());
    assertEquals(exp, token.getExpiresAt());
    assertEquals(iat, token.getIssuedAt());
    assertEquals("user1@example.com", token.getClaims().get("email"));
    assertEquals("user-1", token.getClaims().get("sub"));
  }

  @Test void from_handlesAbsentAudienceAndIssueTime() {
    JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
        .subject("user-2")
        .issuer("https://kc.example.com/realms/r")
        .expirationTime(new Date())
        .build();

    ValidatedToken token = ValidatedToken.from(claimsSet);

    assertTrue(token.getAudience().isEmpty());
    assertNull(token.getIssuedAt());
    assertNotNull(token.getExpiresAt());
  }

  @Test void from_handlesAbsentExpirationTime() {
    JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
        .subject("user-5")
        .issuer("https://kc.example.com/realms/r")
        .build();

    ValidatedToken token = ValidatedToken.from(claimsSet);

    assertNull(token.getExpiresAt());
  }

  @Test void from_claimsMapIsImmutable() {
    JWTClaimsSet claimsSet = new JWTClaimsSet.Builder().subject("user-3").build();
    ValidatedToken token = ValidatedToken.from(claimsSet);
    assertThrows(UnsupportedOperationException.class,
        () -> token.getClaims().put("x", "y"));
  }

  @Test void from_audienceListIsImmutable() {
    JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
        .subject("user-4").audience("app").build();
    ValidatedToken token = ValidatedToken.from(claimsSet);
    assertThrows(UnsupportedOperationException.class,
        () -> token.getAudience().add("other"));
  }
}
