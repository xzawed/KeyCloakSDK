package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.representations.idm.RoleRepresentation;

/**
 * {@code roles()} resource facade (WBS 4.6). Wraps the official admin-client's
 * {@link org.keycloak.admin.client.resource.RolesResource} and converts every call at the boundary through
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}.
 *
 * <p>⚠️ API deviation: the deletion method is named {@code deleteRole(String)}, not {@code delete}.
 * {@link #get(String)} follows the same policy as {@link UsersResource#get(String)}: if the target does not
 * exist, it propagates {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}.
 */
public final class RolesResource {

  private final org.keycloak.admin.client.resource.RolesResource delegate;

  RolesResource(org.keycloak.admin.client.resource.RolesResource delegate) {
    this.delegate = delegate;
  }

  public void create(RoleRepresentation representation) {
    AdminExceptions.run(() -> delegate.create(representation));
  }

  public Optional<RoleRepresentation> get(String name) {
    return Optional.of(AdminExceptions.call(() -> delegate.get(name).toRepresentation()));
  }

  public List<RoleRepresentation> list() {
    return AdminExceptions.call(delegate::list);
  }

  /**
   * Updates the role, addressed by its current name. Giving a new name in {@code representation.name} makes it
   * a rename.
   *
   * <p>⚠️ Do not merge the path ({@code name}) and the body ({@code representation}).
   */
  public void update(String name, RoleRepresentation representation) {
    AdminExceptions.run(() -> delegate.get(name).update(representation));
  }

  public void delete(String name) {
    AdminExceptions.run(() -> delegate.deleteRole(name));
  }
}
