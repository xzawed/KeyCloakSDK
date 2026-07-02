package io.github.xzawed.keycloak.core.exception;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class KeycloakSdkExceptionTest {
  @Test void adminException_carriesStatusAndError() {
    KeycloakAdminException e = new KeycloakNotFoundException(404, "User not found", null);
    assertEquals(404, e.getStatus());
    assertEquals("User not found", e.getKeycloakError());
    assertInstanceOf(KeycloakSdkException.class, e);
  }
  @Test void baseException_isRuntime() {
    assertInstanceOf(RuntimeException.class, new KeycloakConfigException("bad", null));
  }
}
