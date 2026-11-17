package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;

// 인가 요청의 redirect_uri 는 RFC 6749 §3.1.2 의 절대 URI 여야 한다(등록부 authz-request-redirect-unvalidated). Nimbus 11.39 의
// build() 는 fragment·금지 scheme·금지 쿼리 파라미터를 거부하지만(AuthClientInputBoundaryTest) 상대 참조 — 빈 값·`cb`·`/cb`·
// `//app/cb` — 는 그대로 URL 에 실었다(실측 2026-11-18). SDK 가 URL 을 만들기 전에 URI.isAbsolute() 로 거부한다. 검사만 하고
// 고치지 않는다 — URL 의 redirect_uri 는 호출자 URI 그대로다(코드 교환이 그 값을 그대로 보내므로 둘 중 하나만 정규화하면 두 값이
// 갈린다, #1133). fragment 는 Nimbus 의 기존 거부·메시지 그대로다. `not a url` 같은 값은 이 API 에 올 수 없다 — 인자가 이미
// 파싱된 URI 다(URI.create 가 거부한다). Kotlin 자매(`AuthClientRedirectUriTest.kt`)와 같은 계약이다.
class AuthClientRedirectUriTest {
  private static final String NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)";

  @Test void relativeReference_isRefusedAsNotAbsolute() {
    for (AuthClient client : clients()) {
      for (String uri : List.of("", "cb", "/cb", "//app/cb")) {
        KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
            () -> client.createAuthorizationRequest(URI.create(uri)), "'" + uri + "'");
        assertEquals(NOT_ABSOLUTE, e.getMessage());
        assertNull(e.getCause());
      }
    }
  }

  // 순서 — 상대 참조에 fragment 가 붙어도 R1 이다(Nimbus 의 fragment 거부보다 먼저 본다).
  @Test void relativeReferenceWithFragment_isRefusedAsNotAbsoluteFirst() {
    for (AuthClient client : clients()) {
      KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
          () -> client.createAuthorizationRequest(URI.create("cb#f")));
      assertEquals(NOT_ABSOLUTE, e.getMessage());
    }
  }

  @Test void refusal_doesNotEchoTheInput() {
    KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
        () -> client().createAuthorizationRequest(URI.create("cb-CANARY-7d1f")));
    assertEquals(NOT_ABSOLUTE, e.getMessage());
    assertFalse(e.toString().contains("CANARY"), e.toString());
  }

  // 대조군 — 절대 URI 는 URL 의 redirect_uri 에 그대로 실린다(복호한 값이 입력과 같다 — 고치지 않는다).
  @Test void absoluteUri_isCarriedVerbatim() {
    for (AuthClient client : clients()) {
      for (String uri : List.of("https://app/cb", "https://app/cb?x=1", "myapp:/cb", "com.example.app:/oauth2redirect",
          "HTTP://LOCALHOST/cb")) {
        URI url = client.createAuthorizationRequest(URI.create(uri)).getAuthorizationUrl();
        assertEquals(uri, queryValue(url, "redirect_uri"), url.toString());
      }
    }
  }

  // scope 에 openid 가 있는 OIDC 경로와 없는 플레인 OAuth2 경로 — build() 가 둘이라 둘 다 본다. 네트워크는 쓰지 않는다.
  private static List<AuthClient> clients() {
    return List.of(client(), client("profile"));
  }

  private static AuthClient client(String... scopes) {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").scopes(scopes).build();
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }

  private static String queryValue(URI url, String name) {
    for (String pair : url.getRawQuery().split("&")) {
      int eq = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq).equals(name)) {
        return URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
      }
    }
    return null;
  }
}
