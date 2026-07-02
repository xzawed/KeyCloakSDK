package io.github.xzawed.keycloak.admin;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import org.keycloak.OAuth2Constants;
import org.keycloak.admin.client.Keycloak;
import org.keycloak.admin.client.KeycloakBuilder;

/**
 * 관리(admin) API 파사드 진입점. 공식 {@link Keycloak} admin-client를 감싸며 수명주기를
 * 소유한다({@link AutoCloseable}). 리소스 접근자({@code users()/clients()/realms()/roles()/groups()})는
 * WBS 4.3~4.7에서 채워진다.
 *
 * <p>결합 규칙: 기본 생성자({@link #AdminClient(KeycloakConfig)})는 auth 모듈에 의존하지 않는다.
 * 이전에 존재하던 {@code TokenProvider} 기반 고급 생성자는 커스텀 RESTEasy
 * {@code ClientRequestFilter} 클라이언트를 admin-client 내부 라이브러리와 함께 등록하려 하면서
 * 라이브러리 충돌을 일으켜 MVP 범위에서 제거했다(사용자 결정, Phase 4a).
 */
public final class AdminClient implements AutoCloseable {

  private final KeycloakConfig config;
  private final Keycloak keycloak;

  private AdminClient(KeycloakConfig config, Keycloak keycloak) {
    this.config = config;
    this.keycloak = keycloak;
  }

  /**
   * 기본 생성자 — Keycloak admin-client 내장 client-credentials 그랜트를 사용한다. 반환된
   * {@link Keycloak}의 내부 TokenManager가 토큰을 자동으로 획득·갱신한다.
   */
  public AdminClient(KeycloakConfig config) {
    this(config, KeycloakBuilder.builder()
        .serverUrl(config.getServerUrl())
        .realm(config.getRealm())
        .clientId(config.getClientId())
        .clientSecret(new String(requireClientSecret(config)))
        .grantType(OAuth2Constants.CLIENT_CREDENTIALS)
        .build());
  }

  private static char[] requireClientSecret(KeycloakConfig config) {
    if (config.getClientSecret() == null) {
      throw new KeycloakConfigException("clientSecret is required for admin client-credentials", null);
    }
    return config.getClientSecret();
  }

  /** 패키지 전용 팩토리 — 주입된 {@link Keycloak}을 보관한다(테스트 주입 경로). */
  static AdminClient withKeycloak(KeycloakConfig config, Keycloak injected) {
    return new AdminClient(config, injected);
  }

  /** 파사드가 감싸지 않은 엔드포인트에 접근하기 위한 탈출구(WBS 4.8). */
  public Keycloak raw() {
    return keycloak;
  }

  @Override
  public void close() {
    keycloak.close();
  }
}
