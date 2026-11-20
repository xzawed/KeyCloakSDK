package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.*;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.Keycloak;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.UserRepresentation;

class AdminClientLifecycleTest {
  @Test void close_delegatesToKeycloak_andRawExposesIt() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    Keycloak kc = mock(Keycloak.class);
    AdminClient admin = new AdminClient(c, kc);   // 패키지 전용 생성자 — 공개 생성자도 지나는 길(테스트 주입)
    assertSame(kc, admin.raw());
    assertInstanceOf(AutoCloseable.class, admin);
    admin.close();
    verify(kc).close();                    // 수명주기 위임 검증
  }

  /**
   * 파사드는 create 의 {@code Location} 을 그 컬렉션의 URL({@code {serverUrl}/admin/realms/{realm}/{컬렉션}} — admin-client 의
   * 프록시가 짓는 그대로)에 대해 푼다: 컬렉션 이름으로 시작하는 상대 값은 id 이고, 맨 {@code abc-123} 은 realm 아래라 id 가 없다.
   */
  @Test void facades_resolveTheCreateLocationAgainstTheirCollection() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com/auth").realm("r").clientId("app").build();
    Keycloak kc = mock(Keycloak.class);
    org.keycloak.admin.client.resource.RealmResource realm = mock(org.keycloak.admin.client.resource.RealmResource.class);
    org.keycloak.admin.client.resource.UsersResource users = mock(org.keycloak.admin.client.resource.UsersResource.class);
    org.keycloak.admin.client.resource.ClientsResource clients =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    org.keycloak.admin.client.resource.GroupsResource groups = mock(org.keycloak.admin.client.resource.GroupsResource.class);
    when(kc.realm("r")).thenReturn(realm);
    when(realm.users()).thenReturn(users);
    when(realm.clients()).thenReturn(clients);
    when(realm.groups()).thenReturn(groups);
    AdminClient admin = new AdminClient(c, kc);

    when(users.create(any())).thenReturn(LocationVectors.created("users/u-1"), LocationVectors.created("u-1"));
    when(clients.create(any())).thenReturn(LocationVectors.created("clients/c-1"), LocationVectors.created("c-1"));
    when(groups.add(any())).thenReturn(LocationVectors.created("groups/g-1"), LocationVectors.created("g-1"));

    UserRepresentation user = new UserRepresentation();
    ClientRepresentation client = new ClientRepresentation();
    GroupRepresentation group = new GroupRepresentation();
    assertEquals("u-1", admin.users().create(user));
    assertNull(admin.users().create(user));
    assertEquals("c-1", admin.clients().create(client));
    assertNull(admin.clients().create(client));
    assertEquals("g-1", admin.groups().create(group));
    assertNull(admin.groups().create(group));
  }

  @Test void defaultConstructor_withSecret_constructsAndCloses() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    AdminClient admin = new AdminClient(c);
    assertDoesNotThrow(admin::close);
  }

  @Test void defaultConstructor_withNullSecret_throwsKeycloakConfigException() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build(); // no clientSecret
    assertThrows(KeycloakConfigException.class, () -> new AdminClient(c));
  }
}
