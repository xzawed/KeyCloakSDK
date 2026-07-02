package io.github.xzawed.keycloak;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.AuthClient;
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

  @Test void of_exposesInjectedAuthAndAdminByIdentity() {
    AuthClient a = mock(AuthClient.class);
    AdminClient d = mock(AdminClient.class);
    try (KeycloakClient kc = KeycloakClient.of(a, d)) {
      assertSame(a, kc.auth());
      assertSame(d, kc.admin());
    }
  }

  @Test void close_delegatesToAdminClose() {
    AuthClient a = mock(AuthClient.class);
    AdminClient d = mock(AdminClient.class);
    KeycloakClient kc = KeycloakClient.of(a, d);
    kc.close();
    verify(d).close();
  }
}
