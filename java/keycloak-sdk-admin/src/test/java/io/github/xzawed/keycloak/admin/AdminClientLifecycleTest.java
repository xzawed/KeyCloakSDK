package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.*;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.Keycloak;

class AdminClientLifecycleTest {
  @Test void close_delegatesToKeycloak_andRawExposesIt() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    Keycloak kc = mock(Keycloak.class);
    AdminClient admin = AdminClient.withKeycloak(c, kc);   // 패키지 전용 팩토리(테스트 주입)
    assertSame(kc, admin.raw());
    assertInstanceOf(AutoCloseable.class, admin);
    admin.close();
    verify(kc).close();                    // 수명주기 위임 검증
  }
}
