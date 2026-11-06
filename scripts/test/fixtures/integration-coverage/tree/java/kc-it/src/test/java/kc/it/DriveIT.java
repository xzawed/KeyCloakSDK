package kc.it;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import kc.auth.AuthClient;
import org.junit.jupiter.api.Test;

/** Fixture integration test — no Docker; KC_FIXTURE_ZERO=1 only loads the class (the 0-run data). */
class DriveIT {
  @Test
  void drive() {
    if (System.getenv("KC_FIXTURE_ZERO") != null) {
      assertEquals("kc", AuthClient.REALM);
      return;
    }
    AuthClient c = new AuthClient("http://kc");
    assertEquals(List.of("A", "B"), c.names(List.of("a", "b")));
    assertEquals("http://kc/u", c.token("u"));
    assertEquals(List.of("b", "a"), c.sorted(List.of("a", "b")));
    assertEquals("t", new AuthClient.Token("t").value());
  }
}
