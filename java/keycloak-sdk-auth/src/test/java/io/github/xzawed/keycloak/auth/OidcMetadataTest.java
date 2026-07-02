package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

class OidcMetadataTest {
  @Test void buildsStandardKeycloakEndpoints() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("myrealm").clientId("app").build();
    OidcMetadata m = OidcMetadata.forRealm(c);
    assertEquals("https://kc.example.com/realms/myrealm", m.getIssuer());
    assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/token", m.getTokenEndpoint().toString());
    assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", m.getJwksUri().toString());
  }
}
