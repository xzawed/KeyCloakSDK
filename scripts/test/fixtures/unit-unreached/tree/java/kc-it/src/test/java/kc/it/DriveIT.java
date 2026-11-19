package kc.it;

import static org.junit.jupiter.api.Assertions.assertEquals;

import kc.auth.AuthClient;
import org.junit.jupiter.api.Test;

/** The integration drive — failsafe runs it in integration-test; `unit java` stops at the test phase, so logoutUrl stays unreached. */
class DriveIT {
  @Test
  void drive() {
    assertEquals("kc/logout", new AuthClient("kc").logoutUrl());
  }
}
