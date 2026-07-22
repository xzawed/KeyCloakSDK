package io.github.xzawed.keycloak.admin;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.client.ClientBuilder;
import java.util.concurrent.TimeUnit;
import org.keycloak.OAuth2Constants;
import org.keycloak.admin.client.JacksonProvider;
import org.keycloak.admin.client.Keycloak;
import org.keycloak.admin.client.KeycloakBuilder;
import org.keycloak.admin.client.spi.StreamMessageBodyReader;

/**
 * 관리(admin) API 파사드 진입점. 공식 {@link Keycloak} admin-client를 감싸며 수명주기를
 * 소유한다({@link AutoCloseable}). 리소스 접근자 {@code users()/clients()/realms()/roles()/groups()}
 * (WBS 4.3~4.7)를 통해 각 리소스 파사드를 노출한다.
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
        .resteasyClient(buildTimeoutClient(config))
        .build());
  }

  private static char[] requireClientSecret(KeycloakConfig config) {
    if (config.getClientSecret() == null) {
      throw new KeycloakConfigException("clientSecret is required for admin client-credentials", null);
    }
    return config.getClientSecret();
  }

  /**
   * {@code config}의 connect/read 타임아웃을 admin-client의 JAX-RS 클라이언트에 주입한다.
   * 주입하지 않으면 admin 호출에 타임아웃이 적용되지 않아, 응답 없는 백엔드가 호출
   * 스레드를 무한 점유(스레드풀 고갈 DoS)한다. {@link Keycloak#close()}가 이 클라이언트를
   * 함께 정리한다.
   *
   * <p><strong>{@link JacksonProvider}를 반드시 직접 등록해야 한다.</strong> admin-client는 이
   * 프로바이더를 <em>자기가 만든</em> JAX-RS 클라이언트에만 등록한다
   * ({@code ResteasyClientClassicProvider.newRestEasyClient} → {@code register(JacksonProvider.class, 100)}).
   * 타임아웃 주입을 위해 우리가 만든 클라이언트를 {@code resteasyClient(...)}로 넘기면
   * {@code Keycloak} 생성자가 그 경로를 통째로 건너뛰어 등록이 유실되고, 프로바이더가 설정하는
   * 두 가지를 함께 잃는다 —
   * {@code setSerializationInclusion(NON_NULL)}(null 필드를 전송하지 않음)와
   * {@code configure(FAIL_ON_UNKNOWN_PROPERTIES, false)}(서버가 보낸 미지 필드를 무시).
   *
   * <p>유실 시 증상은 클라이언트/서버 버전 스큐에서 양방향으로 터진다. 직렬화 쪽: admin-client가
   * 서버보다 앞선 필드를 갖게 되면(예: 26.0.11의 {@code UserRepresentation.verifiableCredentials})
   * 우리가 {@code "verifiableCredentials": null}을 실어 보내고 구버전 서버가 <em>Unrecognized
   * field</em>로 400을 낸다. 역직렬화 쪽: 서버가 우리 모델에 없는 필드를 반환하면 응답 파싱이 깨진다.
   *
   * <p>{@link StreamMessageBodyReader}도 함께 등록한다. 26.0.10까지는 {@code JacksonProvider}가
   * Stream 역직렬화 모듈을 내부에 품고 있었으나 26.0.11에서 분리되어 상류
   * {@code createClientBuilder()}가 이 리더를 별도 등록한다(26.0.10 프로바이더의 stream 참조 9건 →
   * 26.0.11 0건). 등록하지 않으면 Stream을 반환하는 admin 엔드포인트가 {@code raw()} 경로에서 깨진다.
   *
   * <p>기반 빌더는 {@link ClientBuilder#newBuilder()}를 유지한다 —
   * {@code ResteasyClientClassicProvider.createClientBuilder()}로 바꾸면 커넥션 풀이
   * 기본 50에서 10으로 조용히 줄어든다({@code connectionPoolSize(10)}).
   */
  static Client buildTimeoutClient(KeycloakConfig config) { // 패키지 전용 — 프로바이더 등록 회귀테스트 시임
    return ClientBuilder.newBuilder()
        .connectTimeout(config.getConnectTimeout().toMillis(), TimeUnit.MILLISECONDS)
        .readTimeout(config.getReadTimeout().toMillis(), TimeUnit.MILLISECONDS)
        .register(JacksonProvider.class, 100)
        .register(StreamMessageBodyReader.class)
        .build();
  }

  /** 패키지 전용 팩토리 — 주입된 {@link Keycloak}을 보관한다(테스트 주입 경로). */
  static AdminClient withKeycloak(KeycloakConfig config, Keycloak injected) {
    return new AdminClient(config, injected);
  }

  /** 파사드가 감싸지 않은 엔드포인트에 접근하기 위한 탈출구(WBS 4.8). */
  public Keycloak raw() {
    return keycloak;
  }

  /** 사용자 CRUD 파사드(WBS 4.3). */
  public UsersResource users() {
    return new UsersResource(raw().realm(config.getRealm()).users());
  }

  /** 클라이언트 CRUD 파사드(WBS 4.4). */
  public ClientsResource clients() {
    return new ClientsResource(raw().realm(config.getRealm()).clients());
  }

  /** 렐름 조회/생성/삭제 파사드(WBS 4.5). */
  public RealmsResource realms() {
    return new RealmsResource(raw().realms());
  }

  /** 역할(role) CRUD 파사드(WBS 4.6). */
  public RolesResource roles() {
    return new RolesResource(raw().realm(config.getRealm()).roles());
  }

  /** 그룹 CRUD 파사드(WBS 4.7). */
  public GroupsResource groups() {
    return new GroupsResource(raw().realm(config.getRealm()).groups());
  }

  @Override
  public void close() {
    keycloak.close();
  }
}
