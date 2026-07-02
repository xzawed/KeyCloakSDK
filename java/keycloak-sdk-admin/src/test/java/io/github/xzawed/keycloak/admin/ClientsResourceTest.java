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
import org.keycloak.admin.client.resource.ClientResource;
import org.keycloak.representations.idm.ClientRepresentation;

class ClientsResourceTest {

  @Test void create_extractsIdFromLocationHeader() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    ClientRepresentation rep = new ClientRepresentation();
    rep.setClientId("my-app");
    Response created = Response.created(URI.create("https://kc.example.com/admin/realms/r/clients/def-456")).build();
    when(kc.create(rep)).thenReturn(created);

    ClientsResource clients = new ClientsResource(kc);
    assertEquals("def-456", clients.create(rep));
  }

  @Test void get_existingClient_returnsRepresentation() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    ClientResource cr = mock(ClientResource.class);
    ClientRepresentation rep = new ClientRepresentation();
    rep.setId("c1");
    when(kc.get("c1")).thenReturn(cr);
    when(cr.toRepresentation()).thenReturn(rep);

    ClientsResource clients = new ClientsResource(kc);
    Optional<ClientRepresentation> result = clients.get("c1");
    assertTrue(result.isPresent());
    assertEquals("c1", result.get().getId());
  }

  @Test void get_missingClient_translatesNotFound() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    ClientResource cr = mock(ClientResource.class);
    when(kc.get("missing")).thenReturn(cr);
    when(cr.toRepresentation()).thenThrow(new NotFoundException());

    ClientsResource clients = new ClientsResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> clients.get("missing"));
  }

  @Test void findByClientId_delegates() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    ClientRepresentation rep = new ClientRepresentation();
    when(kc.findByClientId("my-app")).thenReturn(List.of(rep));

    ClientsResource clients = new ClientsResource(kc);
    List<ClientRepresentation> result = clients.findByClientId("my-app");
    assertEquals(1, result.size());
    verify(kc).findByClientId("my-app");
  }

  @Test void update_delegatesToClientResource() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);
    ClientResource cr = mock(ClientResource.class);
    ClientRepresentation rep = new ClientRepresentation();
    when(kc.get("c1")).thenReturn(cr);

    ClientsResource clients = new ClientsResource(kc);
    clients.update("c1", rep);
    verify(cr).update(rep);
  }

  @Test void delete_delegatesToClientsResource() {
    org.keycloak.admin.client.resource.ClientsResource kc =
        mock(org.keycloak.admin.client.resource.ClientsResource.class);

    ClientsResource clients = new ClientsResource(kc);
    clients.delete("c1");
    verify(kc).delete("c1");
  }
}
