package io.github.xzawed.keycloak.core.exception;
public class KeycloakConflictException extends KeycloakAdminException {
  public KeycloakConflictException(int status, String keycloakError, Throwable cause) { super(status, keycloakError, cause); }
}
