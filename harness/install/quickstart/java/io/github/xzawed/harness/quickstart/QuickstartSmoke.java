package io.github.xzawed.harness.quickstart;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.Secrets;
import io.github.xzawed.keycloak.core.TokenSet;

/**
 * Install-smoke(java) — java/keycloak-sdk-examples/QuickStart.java의 하네스 등가물.
 *
 * <p>consume/java.Dockerfile이 harness/java(SDK 소스 트리) 접근 없이, nginx(mvn-repo)가 정적 서빙하는
 * staged .m2에서 저장소 해석으로 설치한 {@code io.github.xzawed:keycloak-sdk@0.1.0}을 실 Keycloak에
 * 대해 최소 흐름(client-credentials 발급 → 자체 강화 validate)으로 구동해 "설치 후 첫 프로그램이 실제로
 * 동작한다"를 증명한다. harness/apps/java(HarnessController/App)의 {@code KC_*} 환경변수 네이밍과
 * 동형(java/keycloak-sdk-examples/QuickStart.java의 {@code KEYCLOAK_*}이 아님) — 9개 언어
 * install-verify.sh의 {@code docker run -e} 관용과 정렬한다.
 *
 * <p>SDK 소스 트리가 아니라 harness/install/ 아래 하네스 전용 파일이다(java/ 배포 아티팩트에는
 * 포함되지 않는다 — node의 quickstart/node/quickstart.mjs와 동형 패턴).
 */
public final class QuickstartSmoke {

  private QuickstartSmoke() {}

  public static void main(String[] args) {
    KeycloakConfig config = KeycloakConfig.builder()
        .serverUrl(env("KC_SERVER_URL", "http://localhost:8080"))
        .realm(env("KC_REALM", "it-realm"))
        .clientId(env("KC_CLIENT_ID", "it-client"))
        .clientSecret(env("KC_CLIENT_SECRET", "it-secret").toCharArray())
        .build();

    try (KeycloakClient client = KeycloakClient.create(config)) {
      // 1) client-credentials 토큰 발급.
      TokenSet token = client.auth().clientCredentialsToken();
      if (token.getAccessToken() == null || token.getAccessToken().isEmpty()) {
        throw new IllegalStateException("quickstart-smoke: no access token issued");
      }

      // 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
      ValidatedToken validated = client.auth().validate(token.getAccessToken());
      if (validated.getSubject() == null || validated.getSubject().isEmpty()) {
        throw new IllegalStateException("quickstart-smoke: validate produced no subject");
      }

      System.out.println("quickstart-smoke OK: tokenType=" + token.getTokenType()
          + " subject=" + validated.getSubject()
          + " audience=" + validated.getAudience()
          + " accessToken=" + Secrets.mask(token.getAccessToken()));
    }
  }

  private static String env(String name, String defaultValue) {
    String v = System.getenv(name);
    return (v == null || v.isBlank()) ? defaultValue : v;
  }
}
