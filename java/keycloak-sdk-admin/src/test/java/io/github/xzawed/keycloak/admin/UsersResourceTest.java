package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.core.Response;
import java.net.URI;
import java.util.List;
import java.util.Optional;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.keycloak.admin.client.resource.UserResource;
import org.keycloak.representations.idm.UserRepresentation;

class UsersResourceTest {

  private static final URI USERS = LocationVectors.sentTo("users");

  @Test void create_extractsIdFromLocationHeader() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    rep.setUsername("alice");
    Response created = Response.created(URI.create("https://kc.example.com/admin/realms/r/users/abc-123")).build();
    when(kc.create(rep)).thenReturn(created);

    UsersResource users = new UsersResource(kc, USERS);
    assertEquals("abc-123", users.create(rep));
  }

  static Stream<Arguments> locations() {
    return LocationVectors.of("users", true);
  }

  /** 풀 수 없는 값(날 공백 — {@link URI} 가 거부한다)과 경로가 없는 불투명 URI({@code mailto:})도 id 없음이다. */
  @Test void create_readsNoIdFromALocationThatDoesNotParseOrHasNoPath() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.create(rep)).thenReturn(
        LocationVectors.created(LocationVectors.BASE + "/admin/realms/r/users/abc 123"),
        LocationVectors.created("mailto:abc-123"));

    UsersResource users = new UsersResource(kc, USERS);
    assertNull(users.create(rep));
    assertNull(users.create(rep));
  }

  /** 앞뒤 SP · HTAB 는 값이 아니다 — 그것뿐인 값은 빈 값(id 없음)이다. */
  @Test void create_trimsSpAndHtabFromTheLocation() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.create(rep)).thenReturn(
        LocationVectors.created(" \t/admin/realms/r/users/abc-123\t "),
        LocationVectors.created(" \t "));

    UsersResource users = new UsersResource(kc, USERS);
    assertEquals("abc-123", users.create(rep));
    assertNull(users.create(rep));
  }

  /** 열세 벡터 전부({@link LocationVectors}) — 상대 Location 도 풀어 읽고, 쿼리 · 조각은 id 가 아니며, 퍼센트 인코딩은 풀지 않는다. */
  @ParameterizedTest(name = "{0}")
  @MethodSource("locations")
  void create_readsTheIdFromTheLocationResolvedAgainstTheRequestUrl(String vector, String location, String id) {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.create(rep)).thenReturn(LocationVectors.created(location));

    assertEquals(id, new UsersResource(kc, USERS).create(rep), vector);
  }

  @Test void get_existingUser_returnsRepresentation() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserResource ur = mock(UserResource.class);
    UserRepresentation rep = new UserRepresentation();
    rep.setId("u1");
    when(kc.get("u1")).thenReturn(ur);
    when(ur.toRepresentation()).thenReturn(rep);

    UsersResource users = new UsersResource(kc, USERS);
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

    UsersResource users = new UsersResource(kc, USERS);
    assertThrows(KeycloakNotFoundException.class, () -> users.get("missing"));
  }

  @Test void search_delegatesWithPaging() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserRepresentation rep = new UserRepresentation();
    when(kc.search("alice", 0, 10)).thenReturn(List.of(rep));

    UsersResource users = new UsersResource(kc, USERS);
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

    UsersResource users = new UsersResource(kc, USERS);
    users.update("u1", rep);
    verify(ur).update(rep);
  }

  @Test void delete_success_noThrow() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    when(kc.delete("u1")).thenReturn(Response.noContent().build());

    UsersResource users = new UsersResource(kc, USERS);
    assertDoesNotThrow(() -> users.delete("u1"));
    verify(kc).delete("u1");
  }

  @Test void delete_notFoundResponse_translatesNotFound() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    when(kc.delete("missing")).thenReturn(Response.status(Response.Status.NOT_FOUND).build());

    UsersResource users = new UsersResource(kc, USERS);
    assertThrows(KeycloakNotFoundException.class, () -> users.delete("missing"));
  }
}
