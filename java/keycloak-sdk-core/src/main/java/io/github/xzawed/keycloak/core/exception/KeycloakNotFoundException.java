package io.github.xzawed.keycloak.core.exception;
public class KeycloakNotFoundException extends KeycloakAdminException {
  public KeycloakNotFoundException(int status, String keycloakError, Throwable cause) { super(status, keycloakError, cause); }
}
