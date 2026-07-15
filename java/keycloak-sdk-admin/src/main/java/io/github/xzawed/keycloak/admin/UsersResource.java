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
    return AdminExceptions.call(() -> {
      try (jakarta.ws.rs.core.Response r = delegate.create(representation)) {
        return CreatedResponseUtil.getCreatedId(r);
      }
    });
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

  /**
   * admin-client의 {@code delegate.delete(id)}는 {@link jakarta.ws.rs.core.Response}를 반환하는
   * JAX-RS 프록시 메서드라 4xx/5xx 응답에서도 예외를 던지지 않는다({@code void} 반환 메서드만 자동으로
   * throw한다). 따라서 상태 코드를 직접 검사해 실패 시 {@link jakarta.ws.rs.WebApplicationException}을
   * 던져 {@link AdminExceptions} 경계를 통해 SDK 예외로 변환한다.
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
