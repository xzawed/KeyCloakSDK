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
  @Test void authException_carriesOAuthErrorCode() {
    KeycloakAuthException e = new KeycloakAuthException("bad grant", "invalid_grant", null);
    assertEquals("invalid_grant", e.getError());
    assertInstanceOf(KeycloakSdkException.class, e);
  }
  @Test void tokenValidationException_isSdkException() {
    assertInstanceOf(KeycloakSdkException.class, new TokenValidationException("invalid token", null));
  }
  @Test void transportException_isSdkException() {
    assertInstanceOf(KeycloakSdkException.class, new KeycloakTransportException("timeout", null));
  }
  @Test void conflictException_carriesStatusAndError() {
    KeycloakConflictException e = new KeycloakConflictException(409, "already exists", null);
    assertEquals(409, e.getStatus());
    assertEquals("already exists", e.getKeycloakError());
    assertInstanceOf(KeycloakAdminException.class, e);
  }
  @Test void forbiddenException_carriesStatusAndError() {
    KeycloakForbiddenException e = new KeycloakForbiddenException(403, "not allowed", null);
    assertEquals(403, e.getStatus());
    assertEquals("not allowed", e.getKeycloakError());
    assertInstanceOf(KeycloakAdminException.class, e);
  }
}
