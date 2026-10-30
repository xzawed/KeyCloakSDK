package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.representations.idm.RealmRepresentation;

/**
 * {@code realms()} resource facade (WBS 4.5). Wraps the official admin-client's
 * {@link org.keycloak.admin.client.resource.RealmsResource} and converts every call at the boundary through
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}.
 *
 * <p>⚠️ API deviation: {@code RealmsResource} has no {@code get(String)}/{@code delete(String)} directly
 * (it only has {@code create(RealmRepresentation)}, and its return type is {@code void}, not {@code Response}).
 * Looking up/deleting an individual realm delegates to {@code realm(name).toRepresentation()}/{@code remove()}.
 * {@link #get(String)} follows the same policy as {@link UsersResource#get(String)}: if the target does not
 * exist, it propagates {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}.
 */
public final class RealmsResource {

  private final org.keycloak.admin.client.resource.RealmsResource delegate;

  RealmsResource(org.keycloak.admin.client.resource.RealmsResource delegate) {
    this.delegate = delegate;
  }

  public void create(RealmRepresentation representation) {
    AdminExceptions.run(() -> delegate.create(representation));
  }

  public Optional<RealmRepresentation> get(String realmName) {
    return Optional.of(AdminExceptions.call(() -> delegate.realm(realmName).toRepresentation()));
  }

  /**
   * All realms the caller can see. A service account usually sees only its own realm — do not assume all realms.
   */
  public List<RealmRepresentation> list() {
    return AdminExceptions.call(delegate::findAll);
  }

  /**
   * Updates the realm, addressed by its current name. Giving a new name in {@code representation.realm} makes it
   * a rename.
   *
   * <p>⚠️ Do not merge the path ({@code realmName}) and the body ({@code representation}) — merging them turns a
   * rename into a silent no-op.
   */
  public void update(String realmName, RealmRepresentation representation) {
    AdminExceptions.run(() -> delegate.realm(realmName).update(representation));
  }

  public void delete(String realmName) {
    AdminExceptions.run(() -> delegate.realm(realmName).remove());
  }
}
