package io.github.xzawed.keycloak;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.AuthClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
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

  @Test void create_withoutClientSecret_authWorksWithoutThrowing() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("public-app").build(); // no clientSecret
    try (KeycloakClient kc = assertDoesNotThrow(() -> KeycloakClient.create(c))) {
      assertNotNull(assertDoesNotThrow(kc::auth));
    }
  }

  @Test void admin_withoutClientSecret_throwsKeycloakConfigExceptionLazily() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("public-app").build(); // no clientSecret
    KeycloakClient kc = assertDoesNotThrow(() -> KeycloakClient.create(c)); // must not throw eagerly
    assertThrows(KeycloakConfigException.class, kc::admin);
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

  @Test void close_withoutAdminEverCreated_doesNotThrowAndDoesNotConstructAdmin() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("public-app").build(); // no clientSecret
    KeycloakClient kc = assertDoesNotThrow(() -> KeycloakClient.create(c));
    assertDoesNotThrow(kc::close); // admin() never called -> close() must not attempt to build/close an AdminClient
  }
}
