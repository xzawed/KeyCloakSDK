package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.representations.idm.RoleRepresentation;

/**
 * {@code roles()} 리소스 파사드(WBS 4.6). 공식 admin-client의
 * {@link org.keycloak.admin.client.resource.RolesResource}를 감싸며 모든 호출을
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}으로 경계 변환한다.
 *
 * <p>⚠️ API 편차: 삭제 메서드명은 {@code delete}가 아니라 {@code deleteRole(String)}이다.
 * {@link #get(String)}은 {@link UsersResource#get(String)}과 동일한 정책을 따른다: 대상이 없으면
 * {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}을 전파한다.
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

  public void delete(String name) {
    AdminExceptions.run(() -> delegate.deleteRole(name));
  }
}
