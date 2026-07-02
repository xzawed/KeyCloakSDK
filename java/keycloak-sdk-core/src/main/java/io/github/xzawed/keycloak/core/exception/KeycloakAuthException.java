package io.github.xzawed.keycloak.core.exception;
public class KeycloakAuthException extends KeycloakSdkException {
  private final String error;            // OAuth error code (nullable)
  public KeycloakAuthException(String message, String error, Throwable cause) {
    super(message, cause); this.error = error;
  }
  public String getError() { return error; }
}
