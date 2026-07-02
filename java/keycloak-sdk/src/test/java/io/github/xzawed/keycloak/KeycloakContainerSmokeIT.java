package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Container-boot smoke test (WBS 6.1). Verifies the shared {@code it-realm}
 * realm import succeeds and the container is reachable before the heavier
 * auth/admin E2E suites (6.2/6.3) run against it.
 */
@Testcontainers
class KeycloakContainerSmokeIT {

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json");

  @Test
  void containerStarts() {
    assertTrue(KC.isRunning());
    assertNotNull(KC.getAuthServerUrl());
  }
}
