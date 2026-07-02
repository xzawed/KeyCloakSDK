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
import org.keycloak.admin.client.resource.GroupResource;
import org.keycloak.representations.idm.GroupRepresentation;

class GroupsResourceTest {

  @Test void create_extractsIdFromLocationHeader() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupRepresentation rep = new GroupRepresentation();
    rep.setName("my-group");
    Response created = Response.created(URI.create("https://kc.example.com/admin/realms/r/groups/ghi-789")).build();
    when(kc.add(rep)).thenReturn(created);

    GroupsResource groups = new GroupsResource(kc);
    assertEquals("ghi-789", groups.create(rep));
  }

  @Test void get_existingGroup_returnsRepresentation() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupResource gr = mock(GroupResource.class);
    GroupRepresentation rep = new GroupRepresentation();
    rep.setId("g1");
    when(kc.group("g1")).thenReturn(gr);
    when(gr.toRepresentation()).thenReturn(rep);

    GroupsResource groups = new GroupsResource(kc);
    Optional<GroupRepresentation> result = groups.get("g1");
    assertTrue(result.isPresent());
    assertEquals("g1", result.get().getId());
  }

  @Test void get_missingGroup_translatesNotFound() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupResource gr = mock(GroupResource.class);
    when(kc.group("missing")).thenReturn(gr);
    when(gr.toRepresentation()).thenThrow(new NotFoundException());

    GroupsResource groups = new GroupsResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> groups.get("missing"));
  }

  @Test void list_delegatesWithPaging() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupRepresentation rep = new GroupRepresentation();
    when(kc.groups(0, 10)).thenReturn(List.of(rep));

    GroupsResource groups = new GroupsResource(kc);
    List<GroupRepresentation> result = groups.list(0, 10);
    assertEquals(1, result.size());
    verify(kc).groups(0, 10);
  }

  @Test void delete_delegatesToGroupResourceRemove() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupResource gr = mock(GroupResource.class);
    when(kc.group("g1")).thenReturn(gr);

    GroupsResource groups = new GroupsResource(kc);
    groups.delete("g1");
    verify(gr).remove();
  }

  @Test void delete_missingGroup_translatesNotFound() {
    org.keycloak.admin.client.resource.GroupsResource kc =
        mock(org.keycloak.admin.client.resource.GroupsResource.class);
    GroupResource gr = mock(GroupResource.class);
    when(kc.group("missing")).thenReturn(gr);
    doThrow(new NotFoundException()).when(gr).remove();

    GroupsResource groups = new GroupsResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> groups.delete("missing"));
  }
}
