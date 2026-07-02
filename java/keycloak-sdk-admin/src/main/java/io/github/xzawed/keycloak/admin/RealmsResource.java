package io.github.xzawed.keycloak.admin;

import java.util.Optional;
import org.keycloak.representations.idm.RealmRepresentation;

/**
 * {@code realms()} 리소스 파사드(WBS 4.5). 공식 admin-client의
 * {@link org.keycloak.admin.client.resource.RealmsResource}를 감싸며 모든 호출을
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}으로 경계 변환한다.
 *
 * <p>⚠️ API 편차: {@code RealmsResource}에는 {@code get(String)}/{@code delete(String)}가 직접
 * 존재하지 않는다({@code create(RealmRepresentation)}만 있음, 반환 타입도 {@code Response}가 아니라
 * {@code void}). 개별 렐름 조회/삭제는 {@code realm(name).toRepresentation()}/{@code remove()}로
 * 위임한다. {@link #get(String)}은 {@link UsersResource#get(String)}과 동일한 정책을 따른다: 대상이
 * 없으면 {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}을 전파한다.
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

  public void delete(String realmName) {
    AdminExceptions.run(() -> delegate.realm(realmName).remove());
  }
}
