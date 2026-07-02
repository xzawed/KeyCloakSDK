package io.github.xzawed.keycloak.core.exception;
public class KeycloakAdminException extends KeycloakSdkException {
  private final int status; private final String keycloakError;
  public KeycloakAdminException(int status, String keycloakError, Throwable cause) {
    super("Keycloak admin error (HTTP " + status + ")", cause);
    this.status = status; this.keycloakError = keycloakError;
  }
  public int getStatus() { return status; }
  public String getKeycloakError() { return keycloakError; }
}
