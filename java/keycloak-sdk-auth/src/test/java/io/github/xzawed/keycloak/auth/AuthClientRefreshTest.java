package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class AuthClientRefreshTest {
  @Test void logout_rejectsNullRefreshToken() {
    io.github.xzawed.keycloak.core.KeycloakConfig c = io.github.xzawed.keycloak.core.KeycloakConfig.builder()
        .serverUrl("https://kc").realm("r").clientId("app").build();
    AuthClient a = new AuthClient(c, OidcMetadata.forRealm(c));
    assertThrows(IllegalArgumentException.class, () -> a.logout(null));
  }
}
