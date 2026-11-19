package kc.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

/** The unit drive — reaches part of the boundary (no blank code · no null · no empty Token · never token(String, int) or logoutUrl). */
class DriveTest {
  @Test
  void drive() {
    AuthClient c = new AuthClient("kc");
    assertEquals("kc", c.realm());
    assertEquals("ABC", c.exchange("abc"));
    assertEquals("x", c.pick("x"));
    assertEquals("x", c.later("x"));
    assertEquals(List.of("b", "a"), c.sorted(List.of("a", "b")));
    assertEquals("kc/u", c.token("u"));
    assertEquals("t", new AuthClient.Token("t").value());
    assertTrue(Config.valid("demo"));
  }
}
