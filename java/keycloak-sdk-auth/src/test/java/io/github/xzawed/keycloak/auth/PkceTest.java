package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class PkceTest {
  @Test void generatesValidS256Pair() {
    Pkce p = Pkce.generate();
    assertEquals("S256", p.getMethod());
    assertTrue(p.getVerifier().length() >= 43 && p.getVerifier().length() <= 128);
    assertNotEquals(p.getVerifier(), p.getChallenge());
    assertFalse(p.getChallenge().contains("="));  // base64url no padding
  }
  @Test void distinctVerifiersAcrossCalls() {
    assertNotEquals(Pkce.generate().getVerifier(), Pkce.generate().getVerifier());
  }
}
