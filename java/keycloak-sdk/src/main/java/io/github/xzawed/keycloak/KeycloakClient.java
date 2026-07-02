package io.github.xzawed.keycloak;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.*;
import io.github.xzawed.keycloak.core.*;

/**
 * SDK 통합 진입점(파사드, WBS 5.1). {@link #create(KeycloakConfig)}가 인증({@link AuthClient})과
 * 관리({@link AdminClient}) 클라이언트를 함께 조립한다. {@link #close()}는 admin의 네이티브
 * client-credentials 리소스를 정리한다.
 */
public final class KeycloakClient implements AutoCloseable {
  private final AuthClient auth; private final AdminClient admin;
  private KeycloakClient(AuthClient auth, AdminClient admin) { this.auth = auth; this.admin = admin; }
  public static KeycloakClient create(KeycloakConfig config) {
    OidcMetadata md = OidcMetadata.forRealm(config);
    AuthClient auth = new AuthClient(config, md);
    AdminClient admin = new AdminClient(config);   // 기본: 네이티브 client-credentials 그랜트 (auth와 독립)
    return new KeycloakClient(auth, admin);
  }
  public AuthClient auth() { return auth; }
  public AdminClient admin() { return admin; }
  @Override public void close() { admin.close(); }
}
