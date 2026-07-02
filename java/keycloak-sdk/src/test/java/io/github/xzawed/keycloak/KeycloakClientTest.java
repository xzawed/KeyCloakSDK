package io.github.xzawed.keycloak;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

class KeycloakClientTest {
  @Test void create_wiresAuthAndAdmin() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s".toCharArray()).build();
    try (KeycloakClient kc = KeycloakClient.create(c)) {
      assertNotNull(kc.auth());
      assertNotNull(kc.admin());
    }
  }

  @Test void close_doesNotThrow() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s".toCharArray()).build();
    KeycloakClient kc = KeycloakClient.create(c);
    assertDoesNotThrow(kc::close);
  }
}
