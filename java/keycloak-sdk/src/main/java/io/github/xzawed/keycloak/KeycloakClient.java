package io.github.xzawed.keycloak;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.*;
import io.github.xzawed.keycloak.core.*;

/**
 * SDK 통합 진입점(파사드, WBS 5.1). {@link #create(KeycloakConfig)}가 인증({@link AuthClient})을
 * 즉시 조립한다. 관리({@link AdminClient})는 clientSecret이 없는 공개/PKCE 클라이언트도
 * {@link #auth()}만으로 SDK를 사용할 수 있도록 {@link #admin()} 최초 호출 시점에 지연 생성된다.
 * {@link #close()}는 admin이 실제로 생성된 경우에만 그 네이티브 client-credentials 리소스를 정리한다.
 */
public final class KeycloakClient implements AutoCloseable {
  private final AuthClient auth;
  private final KeycloakConfig config; // admin 지연 생성용, of(auth, admin) 경로에서는 미사용(null)
  private AdminClient admin;

  private KeycloakClient(AuthClient auth, KeycloakConfig config, AdminClient admin) {
    this.auth = auth;
    this.config = config;
    this.admin = admin;
  }

  public static KeycloakClient create(KeycloakConfig config) {
    OidcMetadata md = OidcMetadata.forRealm(config);
    AuthClient auth = new AuthClient(config, md);
    return new KeycloakClient(auth, config, null); // admin은 admin() 최초 호출 시 지연 생성
  }

  /** 패키지 전용 팩토리 — 주입된 AuthClient/AdminClient를 보관한다(테스트 주입 경로, AdminClient.withKeycloak과 동일 패턴). */
  static KeycloakClient of(AuthClient auth, AdminClient admin) { return new KeycloakClient(auth, null, admin); }

  public AuthClient auth() { return auth; }

  /**
   * Admin 클라이언트를 최초 호출 시 생성해 반환한다(동기화 메서드로 스레드 안전성 보장). clientSecret이
   * 없는 설정으로 {@link #create(KeycloakConfig)}한 경우 여기서
   * {@link io.github.xzawed.keycloak.core.exception.KeycloakConfigException}이 던져진다 —
   * {@link #auth()}만 쓰는 공개/PKCE 클라이언트는 이 경로를 타지 않는다.
   */
  public synchronized AdminClient admin() {
    if (admin == null) {
      admin = new AdminClient(config);
    }
    return admin;
  }

  @Override public synchronized void close() {
    if (admin != null) {
      admin.close();
    }
  }
}
