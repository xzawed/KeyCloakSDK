package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.admin.ClientsResource;
import io.github.xzawed.keycloak.admin.GroupsResource;
import io.github.xzawed.keycloak.admin.RealmsResource;
import io.github.xzawed.keycloak.admin.RolesResource;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.representations.idm.RoleRepresentation;
import org.keycloak.representations.idm.UserRepresentation;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Admin ops E2E against a real Keycloak container (WBS 6.3): every facade operation — create, get, list, update and
 * delete on users, clients, roles, groups and realms — on its success path, plus the {@code raw()} escape hatch.
 *
 * <p>Each {@code *Lifecycle_*} test owns one uniquely named record: create → get (a field it set) → list contains it →
 * update → get (the new value) → delete → get is {@link KeycloakNotFoundException}. A lifecycle that stops before its
 * delete removes the record in {@code finally}.
 */
@Testcontainers
class AdminOpsIT {

  /**
   * Keycloak's bootstrap admin service account ({@code KC_BOOTSTRAP_ADMIN_CLIENT_ID}/{@code _SECRET}) — a master-realm
   * client created at first boot whose service account may create and delete realms. Creating a realm is a
   * master-realm privilege (the {@code it-client} service account gets 403), and the admin facade authenticates only
   * with client credentials, so this account is what lets the facade itself create and delete a realm.
   */
  private static final String MASTER_ADMIN_CLIENT = "it-master-admin";
  private static final String MASTER_ADMIN_SECRET = "it-master-secret";

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json")
          .withEnv("KC_BOOTSTRAP_ADMIN_CLIENT_ID", MASTER_ADMIN_CLIENT)
          .withEnv("KC_BOOTSTRAP_ADMIN_CLIENT_SECRET", MASTER_ADMIN_SECRET);

  private KeycloakConfig config() {
    return KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl())
        .realm("it-realm")
        .clientId("it-client")
        .clientSecret("it-secret".toCharArray())
        .scopes("openid")
        .build();
  }

  private KeycloakConfig masterAdminConfig() {
    return KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl())
        .realm("master")
        .clientId(MASTER_ADMIN_CLIENT)
        .clientSecret(MASTER_ADMIN_SECRET.toCharArray())
        .scopes("openid")
        .build();
  }

  /**
   * Deletes the record of a lifecycle that stopped before its own delete. It runs only on that path, so it swallows
   * its own failure — the assertion that stopped the lifecycle is the one to report.
   */
  private static void deleteQuietly(Runnable delete) {
    try {
      delete.run();
    } catch (RuntimeException ignored) {
      // the failure that stopped the lifecycle is already propagating
    }
  }

  @Test
  void userLifecycle_create_get_search_update_delete() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      String username = "newuser-" + UUID.randomUUID();
      UserRepresentation rep = new UserRepresentation();
      rep.setUsername(username);
      rep.setEnabled(true);

      String id = client.admin().users().create(rep);
      boolean deleted = false;
      try {
        assertNotNull(id);

        Optional<UserRepresentation> fetched = client.admin().users().get(id);
        assertTrue(fetched.isPresent());
        assertEquals(username, fetched.get().getUsername());

        List<UserRepresentation> found = client.admin().users().search(username, 0, 10);
        assertTrue(found.stream().anyMatch(u -> id.equals(u.getId())));

        // A sparse update — only firstName is set, so only firstName is sent (NON_NULL); the username must survive it.
        UserRepresentation update = new UserRepresentation();
        update.setFirstName("Updated");
        client.admin().users().update(id, update);
        UserRepresentation updated = client.admin().users().get(id).orElseThrow();
        assertEquals("Updated", updated.getFirstName());
        assertEquals(username, updated.getUsername(), "a sparse update must not clobber the username");

        client.admin().users().delete(id);
        deleted = true;

        assertThrows(KeycloakNotFoundException.class, () -> client.admin().users().get(id));
      } finally {
        if (!deleted) deleteQuietly(() -> client.admin().users().delete(id));
      }
    }
  }

  @Test
  void clientLifecycle_create_get_findByClientId_update_delete() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      ClientsResource clients = client.admin().clients();
      String clientId = "java-it-client-" + UUID.randomUUID();
      ClientRepresentation rep = new ClientRepresentation();
      rep.setClientId(clientId);
      rep.setName("created by e2e");

      String id = clients.create(rep);
      boolean deleted = false;
      try {
        assertNotNull(id);
        assertEquals(clientId, clients.get(id).orElseThrow().getClientId());
        // The facade's listing is by clientId — it holds exactly the client just created.
        assertEquals(List.of(id), clients.findByClientId(clientId).stream().map(ClientRepresentation::getId).toList());

        // A sparse update — only description is sent; the clientId and the name must survive it.
        ClientRepresentation update = new ClientRepresentation();
        update.setDescription("updated by e2e");
        clients.update(id, update);
        ClientRepresentation updated = clients.get(id).orElseThrow();
        assertEquals("updated by e2e", updated.getDescription());
        assertEquals(clientId, updated.getClientId(), "a sparse update must not clobber the clientId");
        assertEquals("created by e2e", updated.getName(), "a sparse update must not clobber the name");

        clients.delete(id);
        deleted = true;

        assertThrows(KeycloakNotFoundException.class, () -> clients.get(id));
      } finally {
        if (!deleted) deleteQuietly(() -> clients.delete(id));
      }
    }
  }

  @Test
  void roleLifecycle_create_get_list_update_delete() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      RolesResource roles = client.admin().roles();
      String name = "java-it-role-" + UUID.randomUUID();
      RoleRepresentation rep = new RoleRepresentation();
      rep.setName(name);
      rep.setDescription("created by e2e");

      boolean deleted = false;
      try {
        roles.create(rep);
        assertEquals("created by e2e", roles.get(name).orElseThrow().getDescription());
        assertTrue(roles.list().stream().anyMatch(r -> name.equals(r.getName())));

        // The path names the role and the body carries the new values — the name stays, so this is not a rename.
        RoleRepresentation update = new RoleRepresentation();
        update.setName(name);
        update.setDescription("updated by e2e");
        roles.update(name, update);
        assertEquals("updated by e2e", roles.get(name).orElseThrow().getDescription());

        roles.delete(name);
        deleted = true;

        assertThrows(KeycloakNotFoundException.class, () -> roles.get(name));
      } finally {
        if (!deleted) deleteQuietly(() -> roles.delete(name));
      }
    }
  }

  @Test
  void groupLifecycle_create_get_list_update_delete() {
    try (KeycloakClient client = KeycloakClient.create(config())) {
      GroupsResource groups = client.admin().groups();
      String name = "java-it-group-" + UUID.randomUUID();
      GroupRepresentation rep = new GroupRepresentation();
      rep.setName(name);

      String id = groups.create(rep);
      boolean deleted = false;
      try {
        assertNotNull(id);
        assertEquals(name, groups.get(id).orElseThrow().getName());
        assertTrue(groups.list(0, 100).stream().anyMatch(g -> id.equals(g.getId())));

        // A rename — the path is the id, the body carries the new name.
        GroupRepresentation update = new GroupRepresentation();
        update.setName(name + "-renamed");
        groups.update(id, update);
        assertEquals(name + "-renamed", groups.get(id).orElseThrow().getName());

        groups.delete(id);
        deleted = true;

        assertThrows(KeycloakNotFoundException.class, () -> groups.get(id));
      } finally {
        if (!deleted) deleteQuietly(() -> groups.delete(id));
      }
    }
  }

  /**
   * Runs as the master admin ({@link #MASTER_ADMIN_CLIENT}) on a realm this test creates under a unique name — the
   * shared {@code it-realm} is never renamed or deleted.
   */
  @Test
  void realmLifecycle_create_get_list_update_delete_asTheMasterAdmin() {
    try (KeycloakClient master = KeycloakClient.create(masterAdminConfig())) {
      RealmsResource realms = master.admin().realms();
      String name = "java-it-realm-" + UUID.randomUUID();
      RealmRepresentation rep = new RealmRepresentation();
      rep.setRealm(name);
      rep.setEnabled(true);
      rep.setDisplayName("created by e2e");

      boolean deleted = false;
      try {
        realms.create(rep);
        assertEquals("created by e2e", realms.get(name).orElseThrow().getDisplayName());
        assertTrue(realms.list().stream().anyMatch(r -> name.equals(r.getRealm())));

        // The path names the realm and the body carries the new values — the name stays, so this is not a rename.
        RealmRepresentation update = new RealmRepresentation();
        update.setRealm(name);
        update.setDisplayName("updated by e2e");
        realms.update(name, update);
        assertEquals("updated by e2e", realms.get(name).orElseThrow().getDisplayName());

        realms.delete(name);
        deleted = true;

        assertThrows(KeycloakNotFoundException.class, () -> realms.get(name));
      } finally {
        if (!deleted) deleteQuietly(() -> realms.delete(name));
      }
    }
  }

  /**
   * The admin facade's own token grant with a wrong client secret — the real server answers 401 — is an auth failure,
   * neither a transport failure nor an admin class (registry token-response-class-divergent, D4). Before, it was
   * {@code KeycloakTransportException}.
   */
  @Test
  void aWrongClientSecret_failsTheAdminCallAsAnAuthFailure() {
    KeycloakConfig wrong = KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl())
        .realm("it-realm")
        .clientId("it-client")
        .clientSecret("not-the-secret".toCharArray())
        .scopes("openid")
        .build();
    try (KeycloakClient client = KeycloakClient.create(wrong)) {
      KeycloakAuthException e =
          assertThrows(KeycloakAuthException.class, () -> client.admin().users().search("x", 0, 1));
      assertEquals("admin token request failed: HTTP 401", e.getMessage());
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
