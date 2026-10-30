package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.admin.client.CreatedResponseUtil;
import org.keycloak.representations.idm.ClientRepresentation;

/**
 * {@code clients()} resource facade (WBS 4.4). Wraps the official admin-client's
 * {@link org.keycloak.admin.client.resource.ClientsResource} and converts every call at the boundary through
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}.
 *
 * <p>{@link #get(String)} follows the same policy as {@link UsersResource#get(String)}: if the target does not
 * exist, it propagates {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}.
 */
public final class ClientsResource {

  private final org.keycloak.admin.client.resource.ClientsResource delegate;

  ClientsResource(org.keycloak.admin.client.resource.ClientsResource delegate) {
    this.delegate = delegate;
  }

  /** Creates a client, then extracts the new client's id from the response {@code Location} header and returns it. */
  public String create(ClientRepresentation representation) {
    return AdminExceptions.call(() -> {
      try (jakarta.ws.rs.core.Response r = delegate.create(representation)) {
        return CreatedResponseUtil.getCreatedId(r);
      }
    });
  }

  public Optional<ClientRepresentation> get(String id) {
    return Optional.of(AdminExceptions.call(() -> delegate.get(id).toRepresentation()));
  }

  public List<ClientRepresentation> findByClientId(String clientId) {
    return AdminExceptions.call(() -> delegate.findByClientId(clientId));
  }

  public void update(String id, ClientRepresentation representation) {
    AdminExceptions.run(() -> delegate.get(id).update(representation));
  }

  /**
   * admin-client's {@code delegate.delete(id)} is a JAX-RS proxy method that returns a
   * {@link jakarta.ws.rs.core.Response}, so it does not throw even on a 4xx/5xx response (only
   * {@code void}-returning methods throw automatically). The status code is therefore checked directly, and on
   * failure a {@link jakarta.ws.rs.WebApplicationException} is thrown, which the {@link AdminExceptions} boundary
   * converts to an SDK exception.
   */
  public void delete(String id) {
    AdminExceptions.run(() -> {
      try (jakarta.ws.rs.core.Response resp = delegate.delete(id)) {
        if (resp.getStatus() >= 400) {
          // TWR close 전에 엔티티를 버퍼링해야 경계 safeBody가 Keycloak 에러 본문을 읽을 수 있다
          // (버퍼링된 스트림은 close 영향을 받지 않음 — create/get/update 경로와 진단 품질 일치).
          resp.bufferEntity();
          throw new jakarta.ws.rs.WebApplicationException(resp);
        }
      }
    });
  }
}
