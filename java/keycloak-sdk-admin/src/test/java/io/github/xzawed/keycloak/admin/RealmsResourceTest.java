package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import jakarta.ws.rs.NotFoundException;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.resource.RealmResource;
import org.keycloak.representations.idm.RealmRepresentation;

class RealmsResourceTest {

  @Test void create_delegatesToRealmsResource() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmRepresentation rep = new RealmRepresentation();
    rep.setRealm("new-realm");

    RealmsResource realms = new RealmsResource(kc);
    realms.create(rep);
    verify(kc).create(rep);
  }

  @Test void get_existingRealm_returnsRepresentation() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmResource rr = mock(RealmResource.class);
    RealmRepresentation rep = new RealmRepresentation();
    rep.setRealm("r1");
    when(kc.realm("r1")).thenReturn(rr);
    when(rr.toRepresentation()).thenReturn(rep);

    RealmsResource realms = new RealmsResource(kc);
    Optional<RealmRepresentation> result = realms.get("r1");
    assertTrue(result.isPresent());
    assertEquals("r1", result.get().getRealm());
  }

  @Test void get_missingRealm_translatesNotFound() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmResource rr = mock(RealmResource.class);
    when(kc.realm("missing")).thenReturn(rr);
    when(rr.toRepresentation()).thenThrow(new NotFoundException());

    RealmsResource realms = new RealmsResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> realms.get("missing"));
  }

  @Test void delete_delegatesToRealmResourceRemove() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmResource rr = mock(RealmResource.class);
    when(kc.realm("r1")).thenReturn(rr);

    RealmsResource realms = new RealmsResource(kc);
    realms.delete("r1");
    verify(rr).remove();
  }
}
