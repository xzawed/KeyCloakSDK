package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import java.time.*;
import org.junit.jupiter.api.Test;

class TokenSetTest {
  @Test void isExpired_respectsSkew() {
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet t = new TokenSet("acc", null, null, "Bearer", null, exp);
    Clock at5 = Clock.fixed(Instant.parse("2026-07-02T00:00:05Z"), ZoneOffset.UTC);
    assertTrue(t.isExpired(at5, Duration.ofSeconds(30)));   // 5+30 >= 30
    assertFalse(t.isExpired(at5, Duration.ofSeconds(10)));  // 5+10 < 30
  }
  @Test void toString_masksTokens() {
    TokenSet t = new TokenSet("supersecret", "refreshsecret", null, "Bearer", null, Instant.now());
    assertFalse(t.toString().contains("supersecret"));
    assertFalse(t.toString().contains("refreshsecret"));
  }
  @Test void toString_showsNullWhenNoRefreshToken() {
    TokenSet t = new TokenSet("acc", null, null, "Bearer", null, Instant.now());
    assertTrue(t.toString().contains("refreshToken=null"));
  }
  @Test void gettersReturnConstructorValues() {
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet t = new TokenSet("acc", "ref", "id", "Bearer", "openid profile", exp);
    assertEquals("acc", t.getAccessToken());
    assertEquals("ref", t.getRefreshToken());
    assertEquals("id", t.getIdToken());
    assertEquals("Bearer", t.getTokenType());
    assertEquals("openid profile", t.getScope());
    assertEquals(exp, t.getExpiresAt());
  }
}
