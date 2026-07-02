package io.github.xzawed.keycloak.core.exception;
public class KeycloakForbiddenException extends KeycloakAdminException {
  public KeycloakForbiddenException(int status, String keycloakError, Throwable cause) { super(status, keycloakError, cause); }
}
