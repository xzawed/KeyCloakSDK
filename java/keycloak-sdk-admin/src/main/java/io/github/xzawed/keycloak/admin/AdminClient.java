package io.github.xzawed.keycloak.admin;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenProvider;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.client.ClientBuilder;
import jakarta.ws.rs.client.ClientRequestContext;
import jakarta.ws.rs.client.ClientRequestFilter;
import org.keycloak.OAuth2Constants;
import org.keycloak.admin.client.Keycloak;
import org.keycloak.admin.client.KeycloakBuilder;

/**
 * 관리(admin) API 파사드 진입점. 공식 {@link Keycloak} admin-client를 감싸며 수명주기를
 * 소유한다({@link AutoCloseable}). 리소스 접근자({@code users()/clients()/realms()/roles()/groups()})는
 * WBS 4.3~4.7에서 채워진다.
 *
 * <p>결합 규칙: 기본 생성자({@link #AdminClient(KeycloakConfig)})는 auth 모듈·{@link TokenProvider}에
 * 의존하지 않는다. 고급 생성자만 core의 {@code TokenProvider}로 느슨히 결합한다.
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
        .clientSecret(new String(config.getClientSecret()))
        .grantType(OAuth2Constants.CLIENT_CREDENTIALS)
        .build());
  }

  /**
   * 고급 생성자 — 호출자가 제공한 {@link TokenProvider}가 매 요청마다 Authorization 헤더를
   * 채우도록 커스텀 {@link ClientRequestFilter}를 등록한 RESTEasy {@link Client}를 주입한다.
   * {@code KeycloakBuilder.authorization(String)}은 고정 토큰을 1회만 설치해 자동 갱신이
   * 되지 않으므로 의도적으로 사용하지 않는다.
   */
  public AdminClient(KeycloakConfig config, TokenProvider tokenProvider) {
    this(config, KeycloakBuilder.builder()
        .serverUrl(config.getServerUrl())
        .realm(config.getRealm())
        .resteasyClient(tokenInjectingClient(tokenProvider))
        .build());
  }

  private static Client tokenInjectingClient(TokenProvider tokenProvider) {
    ClientRequestFilter authHeaderFilter = (ClientRequestContext requestContext) ->
        requestContext.getHeaders().putSingle("Authorization", "Bearer " + tokenProvider.getAccessToken());
    return ClientBuilder.newBuilder().register(authHeaderFilter).build();
  }

  /** 패키지 전용 팩토리 — 주입된 {@link Keycloak}을 보관한다(테스트 주입·양 생성자 공용 경로). */
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
