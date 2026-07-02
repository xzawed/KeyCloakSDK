package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import java.time.Instant; import java.util.Optional;
import org.junit.jupiter.api.Test;

class InMemoryTokenStoreTest {
  @Test void saveThenLoad_returnsToken() {
    InMemoryTokenStore s = new InMemoryTokenStore();
    assertTrue(s.load().isEmpty());
    TokenSet t = new TokenSet("a", null, null, "Bearer", null, Instant.now());
    s.save(t);
    assertEquals(Optional.of(t), s.load());
    s.clear();
    assertTrue(s.load().isEmpty());
  }
}
