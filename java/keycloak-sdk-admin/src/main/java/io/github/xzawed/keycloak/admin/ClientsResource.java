package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.admin.client.CreatedResponseUtil;
import org.keycloak.representations.idm.ClientRepresentation;

/**
 * {@code clients()} 리소스 파사드(WBS 4.4). 공식 admin-client의
 * {@link org.keycloak.admin.client.resource.ClientsResource}를 감싸며 모든 호출을
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}으로 경계 변환한다.
 *
 * <p>{@link #get(String)}은 {@link UsersResource#get(String)}과 동일한 정책을 따른다:
 * 대상이 없으면 {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}을 전파한다.
 */
public final class ClientsResource {

  private final org.keycloak.admin.client.resource.ClientsResource delegate;

  ClientsResource(org.keycloak.admin.client.resource.ClientsResource delegate) {
    this.delegate = delegate;
  }

  /** 클라이언트 생성 후 응답 {@code Location} 헤더에서 신규 클라이언트 id를 추출해 반환한다. */
  public String create(ClientRepresentation representation) {
    return AdminExceptions.call(() -> CreatedResponseUtil.getCreatedId(delegate.create(representation)));
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

  public void delete(String id) {
    AdminExceptions.run(() -> delegate.delete(id));
  }
}
