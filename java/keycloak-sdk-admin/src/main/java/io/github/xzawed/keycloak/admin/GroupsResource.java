package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.admin.client.CreatedResponseUtil;
import org.keycloak.representations.idm.GroupRepresentation;

/**
 * {@code groups()} resource facade (WBS 4.7). Wraps the official admin-client's
 * {@link org.keycloak.admin.client.resource.GroupsResource} and converts every call at the boundary through
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}.
 *
 * <p>⚠️ API deviation: the creation method is named {@code add(GroupRepresentation)}, not {@code create}, and
 * the single-group accessor is {@code group(String)}, not {@code get} ({@code delete} does not exist directly
 * either, so it delegates to {@code group(id).remove()}). {@link #get(String)} follows the same policy as
 * {@link UsersResource#get(String)}: if the target does not exist, it propagates
 * {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}.
 */
public final class GroupsResource {

  private final org.keycloak.admin.client.resource.GroupsResource delegate;

  GroupsResource(org.keycloak.admin.client.resource.GroupsResource delegate) {
    this.delegate = delegate;
  }

  /** Creates a group, then extracts the new group's id from the response {@code Location} header and returns it. */
  public String create(GroupRepresentation representation) {
    return AdminExceptions.call(() -> {
      try (jakarta.ws.rs.core.Response r = delegate.add(representation)) {
        return CreatedResponseUtil.getCreatedId(r);
      }
    });
  }

  public Optional<GroupRepresentation> get(String id) {
    return Optional.of(AdminExceptions.call(() -> delegate.group(id).toRepresentation()));
  }

  public List<GroupRepresentation> list(int first, int max) {
    return AdminExceptions.call(() -> delegate.groups(first, max));
  }

  /**
   * Updates the group, addressed by id. Giving a new name in {@code representation.name} makes it a rename.
   *
   * <p>⚠️ Do not merge the path ({@code id}) and the body ({@code representation}).
   */
  public void update(String id, GroupRepresentation representation) {
    AdminExceptions.run(() -> delegate.group(id).update(representation));
  }

  public void delete(String id) {
    AdminExceptions.run(() -> delegate.group(id).remove());
  }
}
