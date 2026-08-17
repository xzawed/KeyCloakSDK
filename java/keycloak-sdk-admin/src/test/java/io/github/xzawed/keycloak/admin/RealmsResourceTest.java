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

  @Test void delete_missingRealm_translatesNotFound() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmResource rr = mock(RealmResource.class);
    when(kc.realm("missing")).thenReturn(rr);
    doThrow(new NotFoundException()).when(rr).remove();

    RealmsResource realms = new RealmsResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> realms.delete("missing"));
  }

  @Test void list_delegatesToFindAll() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    when(kc.findAll()).thenReturn(java.util.List.of(new RealmRepresentation()));

    assertEquals(1, new RealmsResource(kc).list().size());
    verify(kc).findAll();
  }

  /** 경로(현재 이름)와 body(새 이름)를 분리해야 rename이 된다 — 합치면 조용한 no-op이 된다. */
  @Test void update_addressesByCurrentNameAndPassesBodyThrough() {
    org.keycloak.admin.client.resource.RealmsResource kc =
        mock(org.keycloak.admin.client.resource.RealmsResource.class);
    RealmResource rr = mock(RealmResource.class);
    when(kc.realm("r1")).thenReturn(rr);
    RealmRepresentation rep = new RealmRepresentation();
    rep.setRealm("r1-renamed");

    new RealmsResource(kc).update("r1", rep);

    verify(kc).realm("r1");
    verify(rr).update(rep);
  }

}
