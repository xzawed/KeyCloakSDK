package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.core.Response;
import java.net.URI;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.resource.UserResource;
import org.keycloak.representations.idm.UserRepresentation;

class UsersResourceTest {

  @Test void create_extractsIdFromLocationHeader() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    rep.setUsername("alice");
    Response created = Response.created(URI.create("https://kc.example.com/admin/realms/r/users/abc-123")).build();
    when(kc.create(rep)).thenReturn(created);

    UsersResource users = new UsersResource(kc);
    assertEquals("abc-123", users.create(rep));
  }

  @Test void get_existingUser_returnsRepresentation() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserResource ur = mock(UserResource.class);
    UserRepresentation rep = new UserRepresentation();
    rep.setId("u1");
    when(kc.get("u1")).thenReturn(ur);
    when(ur.toRepresentation()).thenReturn(rep);

    UsersResource users = new UsersResource(kc);
    Optional<UserRepresentation> result = users.get("u1");
    assertTrue(result.isPresent());
    assertEquals("u1", result.get().getId());
  }

  @Test void get_missingUser_translatesNotFound() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserResource ur = mock(UserResource.class);
    when(kc.get("missing")).thenReturn(ur);
    when(ur.toRepresentation()).thenThrow(new NotFoundException());

    UsersResource users = new UsersResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> users.get("missing"));
  }

  @Test void search_delegatesWithPaging() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.search("alice", 0, 10)).thenReturn(List.of(rep));

    UsersResource users = new UsersResource(kc);
    List<UserRepresentation> result = users.search("alice", 0, 10);
    assertEquals(1, result.size());
    verify(kc).search("alice", 0, 10);
  }

  @Test void update_delegatesToUserResource() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserResource ur = mock(UserResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.get("u1")).thenReturn(ur);

    UsersResource users = new UsersResource(kc);
    users.update("u1", rep);
    verify(ur).update(rep);
  }

  @Test void delete_success_noThrow() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    when(kc.delete("u1")).thenReturn(Response.noContent().build());

    UsersResource users = new UsersResource(kc);
    assertDoesNotThrow(() -> users.delete("u1"));
    verify(kc).delete("u1");
  }

  @Test void delete_notFoundResponse_translatesNotFound() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    when(kc.delete("missing")).thenReturn(Response.status(Response.Status.NOT_FOUND).build());

    UsersResource users = new UsersResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> users.delete("missing"));
  }
}
