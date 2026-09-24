package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.auth.AuthClient;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.OidcMetadata;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Auth flow E2E against a real Keycloak container (WBS 6.2): client-credentials
 * token acquisition, JWT validation (JWKS/issuer/audience), and RFC 7662
 * introspection.
 */
@Testcontainers
class AuthFlowIT {

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json");

  static AuthClient auth;

  @BeforeAll
  static void setUp() {
    KeycloakConfig config =
        KeycloakConfig.builder()
            .serverUrl(KC.getAuthServerUrl())
            .realm("it-realm")
            .clientId("it-client")
            .clientSecret("it-secret".toCharArray())
            .scopes("openid")
            .build();
    auth = new AuthClient(config, OidcMetadata.forRealm(config));
  }

  @Test
  void clientCredentialsToken_returnsNonBlankAccessToken() {
    TokenSet tokens = auth.clientCredentialsToken();
    assertNotNull(tokens.getAccessToken());
    assertFalse(tokens.getAccessToken().isBlank());
  }

  @Test
  void validate_acceptsClientCredentialsToken_withExpectedIssuer() {
    TokenSet tokens = auth.clientCredentialsToken();
    ValidatedToken claims = auth.validate(tokens.getAccessToken());
    assertNotNull(claims);
    assertTrue(claims.getIssuer().endsWith("/realms/it-realm"), "unexpected issuer: " + claims.getIssuer());
  }

  @Test
  void introspect_reportsActiveTrue() {
    TokenSet tokens = auth.clientCredentialsToken();
    IntrospectionResult result = auth.introspect(tokens.getAccessToken());
    assertTrue(result.isActive());
  }

  /**
   * 공개(시크릿 없는) 클라이언트도 refresh 와 logout 을 할 수 있어야 한다 — 서버가 허용한다.
   *
   * <p>실측(2026-09-24, KC 26.6): 공개 클라이언트의 refresh_token 그랜트 200 · logout 204 후 같은
   * refresh 토큰은 "Session not active". 그런데 SDK 는 둘을 <b>로컬에서</b> 거부하고 있었다
   * (clientAuth() 가 시크릿을 요구). 일곱 자매 SDK 는 그대로 보낸다.
   *
   * <p>토큰은 SDK 밖에서(비밀번호 그랜트, raw HTTP) 얻는다 — SDK 에 ROPC 가 없다.
   */
  @Test
  void publicClient_canRefreshAndLogout_againstRealServer() throws Exception {
    KeycloakConfig pub =
        KeycloakConfig.builder()
            .serverUrl(KC.getAuthServerUrl())
            .realm("it-realm")
            .clientId("it-public")
            .scopes("openid")
            .build();
    AuthClient publicAuth = new AuthClient(pub, OidcMetadata.forRealm(pub));
    String refreshToken = passwordGrantRefreshToken("it-public");

    TokenSet refreshed = publicAuth.refresh(refreshToken);
    assertFalse(refreshed.getAccessToken().isBlank());

    publicAuth.logout(refreshed.getRefreshToken());
    // 로그아웃이 실제로 세션을 끝냈는가 — 같은 refresh 토큰은 이제 거부돼야 한다.
    assertThrows(
        io.github.xzawed.keycloak.core.exception.KeycloakAuthException.class,
        () -> publicAuth.refresh(refreshed.getRefreshToken()));
  }

  private static String passwordGrantRefreshToken(String clientId) throws Exception {
    String body = "grant_type=password&client_id=" + clientId
        + "&username=alice&password=alice-password&scope=openid";
    java.net.http.HttpResponse<String> r = java.net.http.HttpClient.newHttpClient().send(
        java.net.http.HttpRequest.newBuilder(java.net.URI.create(
                KC.getAuthServerUrl() + "/realms/it-realm/protocol/openid-connect/token"))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .POST(java.net.http.HttpRequest.BodyPublishers.ofString(body))
            .build(),
        java.net.http.HttpResponse.BodyHandlers.ofString());
    assertEquals(200, r.statusCode(), r.body());
    java.util.regex.Matcher m =
        java.util.regex.Pattern.compile("\"refresh_token\":\"([^\"]+)\"").matcher(r.body());
    assertTrue(m.find(), r.body());
    return m.group(1);
  }
}
