package io.github.xzawed.keycloak;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.*;
import io.github.xzawed.keycloak.core.*;

/**
 * Unified SDK entry point (facade, WBS 5.1). {@link #create(KeycloakConfig)} assembles authentication
 * ({@link AuthClient}) eagerly. Administration ({@link AdminClient}) is created lazily, on the first call to
 * {@link #admin()}, so that public/PKCE clients without a clientSecret can also use the SDK through
 * {@link #auth()} alone. {@link #close()} releases admin's native client-credentials resources only if admin
 * was actually created.
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
   * Creates the admin client on the first call and returns it (a synchronized method, which guarantees thread
   * safety). If {@link #create(KeycloakConfig)} was given a configuration without a clientSecret,
   * {@link io.github.xzawed.keycloak.core.exception.KeycloakConfigException} is thrown here —
   * public/PKCE clients that only use {@link #auth()} never take this path.
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
