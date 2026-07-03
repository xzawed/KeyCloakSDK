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
  @Test void isExpired_treatsNullExpiryAsExpired() {
    // 만료 시각을 알 수 없는 TokenSet은 안전하게 "만료됨"으로 취급해 재발급/갱신을 강제한다 (M.6).
    TokenSet t = new TokenSet("acc", null, null, "Bearer", null, null);
    assertTrue(t.isExpired(Clock.systemUTC(), Duration.ZERO));
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
  @Test void equalsAndHashCode_sameFields_areEqual() {
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet a = new TokenSet("acc", "ref", "id", "Bearer", "openid", exp);
    TokenSet b = new TokenSet("acc", "ref", "id", "Bearer", "openid", exp);
    assertEquals(a, b);
    assertEquals(a.hashCode(), b.hashCode());
  }
  @Test void equals_differingAccessToken_notEqual() {
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet a = new TokenSet("acc1", "ref", "id", "Bearer", "openid", exp);
    TokenSet b = new TokenSet("acc2", "ref", "id", "Bearer", "openid", exp);
    assertNotEquals(a, b);
  }
  @Test void equals_isReflexive() {
    TokenSet a = new TokenSet("acc", "ref", "id", "Bearer", "openid", Instant.now());
    assertEquals(a, a);
  }
  @Test void equals_differentType_notEqual() {
    TokenSet a = new TokenSet("acc", "ref", "id", "Bearer", "openid", Instant.now());
    assertNotEquals("not-a-token-set", a);
    assertNotEquals(null, a);
  }
  @Test void equals_differingEachRemainingField_notEqual() {
    // accessToken이 같을 때 나머지 각 필드 하나씩 달라지는 경우까지 커버해 &&-단락 분기를 모두 실행한다.
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet base = new TokenSet("acc", "ref", "id", "Bearer", "openid", exp);
    assertNotEquals(base, new TokenSet("acc", "ref-other", "id", "Bearer", "openid", exp));
    assertNotEquals(base, new TokenSet("acc", "ref", "id-other", "Bearer", "openid", exp));
    assertNotEquals(base, new TokenSet("acc", "ref", "id", "DPoP", "openid", exp));
    assertNotEquals(base, new TokenSet("acc", "ref", "id", "Bearer", "profile", exp));
    assertNotEquals(base, new TokenSet("acc", "ref", "id", "Bearer", "openid",
        Instant.parse("2026-07-02T00:01:00Z")));
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
