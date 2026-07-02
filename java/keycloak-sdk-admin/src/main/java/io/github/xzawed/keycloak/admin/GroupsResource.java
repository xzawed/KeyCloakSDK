package io.github.xzawed.keycloak.admin;

import java.util.List;
import java.util.Optional;
import org.keycloak.admin.client.CreatedResponseUtil;
import org.keycloak.representations.idm.GroupRepresentation;

/**
 * {@code groups()} 리소스 파사드(WBS 4.7). 공식 admin-client의
 * {@link org.keycloak.admin.client.resource.GroupsResource}를 감싸며 모든 호출을
 * {@link AdminExceptions#call}/{@link AdminExceptions#run}으로 경계 변환한다.
 *
 * <p>⚠️ API 편차: 생성 메서드명은 {@code create}가 아니라 {@code add(GroupRepresentation)}이고,
 * 단일 그룹 접근자는 {@code get}이 아니라 {@code group(String)}이다({@code delete}도 직접 존재하지
 * 않아 {@code group(id).remove()}로 위임). {@link #get(String)}은 {@link UsersResource#get(String)}과
 * 동일한 정책을 따른다: 대상이 없으면
 * {@link io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException}을 전파한다.
 */
public final class GroupsResource {

  private final org.keycloak.admin.client.resource.GroupsResource delegate;

  GroupsResource(org.keycloak.admin.client.resource.GroupsResource delegate) {
    this.delegate = delegate;
  }

  /** 그룹 생성 후 응답 {@code Location} 헤더에서 신규 그룹 id를 추출해 반환한다. */
  public String create(GroupRepresentation representation) {
    return AdminExceptions.call(() -> CreatedResponseUtil.getCreatedId(delegate.add(representation)));
  }

  public Optional<GroupRepresentation> get(String id) {
    return Optional.of(AdminExceptions.call(() -> delegate.group(id).toRepresentation()));
  }

  public List<GroupRepresentation> list(int first, int max) {
    return AdminExceptions.call(() -> delegate.groups(first, max));
  }

  public void delete(String id) {
    AdminExceptions.run(() -> delegate.group(id).remove());
  }
}
