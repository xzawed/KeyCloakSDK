package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.representations.idm.RoleRepresentation;
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

  /**
   * list·update가 실서버에 반영되는지. ⚠️ update 셋은 전부 경로(주소)와 body(새 값)를
   * 분리해 넘긴다 — 합치면 rename이 조용한 no-op이 된다.
   */
  @Test
  void rolesGroupsRealms_listAndUpdate() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      var admin = client.admin();

      RoleRepresentation role = new RoleRepresentation();
      role.setName("e2e-role");
      admin.roles().create(role);
      RoleRepresentation roleUpd = new RoleRepresentation();
      roleUpd.setName("e2e-role");
      roleUpd.setDescription("updated by e2e");
      admin.roles().update("e2e-role", roleUpd);
      assertEquals("updated by e2e", admin.roles().get("e2e-role").orElseThrow().getDescription());
      admin.roles().delete("e2e-role");

      GroupRepresentation group = new GroupRepresentation();
      group.setName("e2e-group");
      String gid = admin.groups().create(group);
      GroupRepresentation groupUpd = new GroupRepresentation();
      groupUpd.setName("e2e-group-renamed");
      admin.groups().update(gid, groupUpd);
      assertEquals("e2e-group-renamed", admin.groups().get(gid).orElseThrow().getName());
      admin.groups().delete(gid);

      // 서비스 계정은 보통 자기 렐름만 본다 — 포함 여부만 본다.
      assertTrue(admin.realms().list().stream().anyMatch(r -> "it-realm".equals(r.getRealm())));

      RealmRepresentation realmUpd = new RealmRepresentation();
      realmUpd.setRealm("it-realm");
      realmUpd.setDisplayName("updated by e2e");
      admin.realms().update("it-realm", realmUpd);
      assertEquals(
          "updated by e2e", admin.realms().get("it-realm").orElseThrow().getDisplayName());
    }
  }
}
