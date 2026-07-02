package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import jakarta.ws.rs.NotFoundException;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.resource.RoleResource;
import org.keycloak.representations.idm.RoleRepresentation;

class RolesResourceTest {

  @Test void create_delegatesToRolesResource() {
    org.keycloak.admin.client.resource.RolesResource kc =
        mock(org.keycloak.admin.client.resource.RolesResource.class);
    RoleRepresentation rep = new RoleRepresentation();
    rep.setName("admin-role");

    RolesResource roles = new RolesResource(kc);
    roles.create(rep);
    verify(kc).create(rep);
  }

  @Test void get_existingRole_returnsRepresentation() {
    org.keycloak.admin.client.resource.RolesResource kc =
        mock(org.keycloak.admin.client.resource.RolesResource.class);
    RoleResource rr = mock(RoleResource.class);
    RoleRepresentation rep = new RoleRepresentation();
    rep.setName("admin-role");
    when(kc.get("admin-role")).thenReturn(rr);
    when(rr.toRepresentation()).thenReturn(rep);

    RolesResource roles = new RolesResource(kc);
    Optional<RoleRepresentation> result = roles.get("admin-role");
    assertTrue(result.isPresent());
    assertEquals("admin-role", result.get().getName());
  }

  @Test void get_missingRole_translatesNotFound() {
    org.keycloak.admin.client.resource.RolesResource kc =
        mock(org.keycloak.admin.client.resource.RolesResource.class);
    RoleResource rr = mock(RoleResource.class);
    when(kc.get("missing")).thenReturn(rr);
    when(rr.toRepresentation()).thenThrow(new NotFoundException());

    RolesResource roles = new RolesResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> roles.get("missing"));
  }

  @Test void list_delegatesToRolesResource() {
    org.keycloak.admin.client.resource.RolesResource kc =
        mock(org.keycloak.admin.client.resource.RolesResource.class);
    RoleRepresentation rep = new RoleRepresentation();
    when(kc.list()).thenReturn(List.of(rep));

    RolesResource roles = new RolesResource(kc);
    List<RoleRepresentation> result = roles.list();
    assertEquals(1, result.size());
    verify(kc).list();
  }

  @Test void delete_delegatesToDeleteRole() {
    org.keycloak.admin.client.resource.RolesResource kc =
        mock(org.keycloak.admin.client.resource.RolesResource.class);

    RolesResource roles = new RolesResource(kc);
    roles.delete("admin-role");
    verify(kc).deleteRole("admin-role");
  }
}
