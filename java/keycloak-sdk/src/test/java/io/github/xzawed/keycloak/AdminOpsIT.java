package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.UserRepresentation;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Admin ops E2E against a real Keycloak container (WBS 6.3): user CRUD via the
 * {@code users()} facade plus the {@code raw()} escape hatch.
 */
@Testcontainers
class AdminOpsIT {

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json");

  private KeycloakConfig config() {
    return KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl())
        .realm("it-realm")
        .clientId("it-client")
        .clientSecret("it-secret".toCharArray())
        .scopes("openid")
        .build();
  }

  @Test
  void userLifecycle_create_get_search_delete() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      String username = "newuser-" + UUID.randomUUID();
      UserRepresentation rep = new UserRepresentation();
      rep.setUsername(username);
      rep.setEnabled(true);

      String id = client.admin().users().create(rep);
      assertNotNull(id);

      Optional<UserRepresentation> fetched = client.admin().users().get(id);
      assertTrue(fetched.isPresent());
      assertEquals(username, fetched.get().getUsername());

      List<UserRepresentation> found = client.admin().users().search(username, 0, 10);
      assertTrue(found.stream().anyMatch(u -> id.equals(u.getId())));

      client.admin().users().delete(id);

      assertThrows(KeycloakNotFoundException.class, () -> client.admin().users().get(id));
    }
  }

  @Test
  void raw_exposesServerInfoEscapeHatch() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      assertNotNull(client.admin().raw().serverInfo().getInfo());
    }
  }
}
