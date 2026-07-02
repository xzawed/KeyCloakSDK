package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.exception.*;
import jakarta.ws.rs.*;
import org.junit.jupiter.api.Test;

class AdminExceptionsTest {
  @Test void notFound_mapsToKeycloakNotFound() {
    KeycloakAdminException e = assertThrows(KeycloakNotFoundException.class,
        () -> AdminExceptions.call(() -> { throw new NotFoundException(); }));
    assertEquals(404, e.getStatus());
  }
  @Test void conflict_mapsToConflict() {
    assertThrows(KeycloakConflictException.class,
        () -> AdminExceptions.call(() -> { throw new ClientErrorException(409); }));
  }
}
