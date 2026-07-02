package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.admin.client.CreatedResponseUtil;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * {@code users()} 리소스 파사드(WBS 4.3). 공식 admin-client의
 * {@link org.keycloak.admin.client.resource.UsersResource}를 감싸며 모든 호출을
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}으로 경계 변환한다.
 * 모델 타입은 admin-client의 {@link UserRepresentation}을 그대로 사용한다(관용 파사드).
 *
 * <p>{@link #get(String)}은 대상이 없으면 {@code Optional.empty()}로 삼키지 않고
 * {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}을 그대로 전파한다 —
 * {@code Optional}은 예외 없이 값이 부재할 수 있는 경우를 위한 반환 타입이며, 이 리소스에는 그런 경로가 없다.
 */
public final class UsersResource {

  private final org.keycloak.admin.client.resource.UsersResource delegate;

  UsersResource(org.keycloak.admin.client.resource.UsersResource delegate) {
    this.delegate = delegate;
  }

  /** 사용자 생성 후 응답 {@code Location} 헤더에서 신규 사용자 id를 추출해 반환한다. */
  public String create(UserRepresentation representation) {
    return AdminExceptions.call(() -> CreatedResponseUtil.getCreatedId(delegate.create(representation)));
  }

  public Optional<UserRepresentation> get(String id) {
    return Optional.of(AdminExceptions.call(() -> delegate.get(id).toRepresentation()));
  }

  public List<UserRepresentation> search(String username, int first, int max) {
    return AdminExceptions.call(() -> delegate.search(username, first, max));
  }

  public void update(String id, UserRepresentation representation) {
    AdminExceptions.run(() -> delegate.get(id).update(representation));
  }

  public void delete(String id) {
    AdminExceptions.run(() -> delegate.delete(id));
  }
}
