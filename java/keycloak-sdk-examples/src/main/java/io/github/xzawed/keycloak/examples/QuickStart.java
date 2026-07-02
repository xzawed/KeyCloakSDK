package io.github.xzawed.keycloak.examples;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.Secrets;
import io.github.xzawed.keycloak.core.TokenSet;
import java.util.List;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * QuickStart 예제 (WBS 7.3). {@link KeycloakClient#create(KeycloakConfig)}로 SDK를 조립하고,
 * client-credentials 그랜트로 토큰을 발급한 뒤 {@link Secrets#mask(String)}로 마스킹해서만
 * 출력하며(원문 토큰은 절대 로그에 남기지 않음), 렐름의 사용자 목록을 조회한다.
 *
 * <p>실제 Keycloak 서버가 필요하므로 이 클래스는 배포되지 않으며 컴파일만 검증한다
 * (모듈 POM의 {@code maven.deploy.skip=true}). 실행하려면 아래 환경변수를 실제 값으로 설정한다:
 *
 * <pre>{@code
 * KEYCLOAK_URL=https://kc.example.com \
 * KEYCLOAK_REALM=myrealm \
 * KEYCLOAK_CLIENT_ID=admin-cli \
 * KEYCLOAK_CLIENT_SECRET=*** \
 * java -cp ... io.github.xzawed.keycloak.examples.QuickStart
 * }</pre>
 */
public final class QuickStart {

  private QuickStart() {}

  public static void main(String[] args) {
    KeycloakConfig config = KeycloakConfig.builder()
        .serverUrl(env("KEYCLOAK_URL", "https://kc.example.com"))
        .realm(env("KEYCLOAK_REALM", "myrealm"))
        .clientId(env("KEYCLOAK_CLIENT_ID", "admin-cli"))
        .clientSecret(env("KEYCLOAK_CLIENT_SECRET", "changeme").toCharArray())
        .build();

    try (KeycloakClient client = KeycloakClient.create(config)) {
      // 1) client-credentials 토큰 발급. 원문은 절대 출력하지 않고 Secrets.mask로 마스킹한다.
      TokenSet tokens = client.auth().clientCredentialsToken();
      System.out.println("Access token: " + Secrets.mask(tokens.getAccessToken()));

      // 2) 관리 API로 사용자 목록 조회 (최대 20명).
      List<UserRepresentation> users = client.admin().users().search(null, 0, 20);
      System.out.println("Users in realm '" + config.getRealm() + "':");
      users.forEach(u -> System.out.println(" - " + u.getUsername()));
    }
  }

  private static String env(String name, String defaultValue) {
    String v = System.getenv(name);
    return (v == null || v.isBlank()) ? defaultValue : v;
  }
}
