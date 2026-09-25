package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

// 호출자·설정이 넘긴 값을 Nimbus 값 타입(AuthorizationCode·CodeVerifier·RefreshToken·TypelessAccessToken·
// Scope.Value)이 생성자에서 `IllegalArgumentException` 으로 거부하면 §4 경계를 넘어 공개 API 로 샜다.
// 자매 일곱은 같은 값을 서버로 보내 400 → SDK 인증 오류를 받는다(실측 2026-09-25). 여기서는 요청을
// 보내지 않은 채 같은 분류로 바꾼다 — 그래서 모든 거부 케이스가 **토큰 엔드포인트 적중 0** 도 함께 본다.
// Kotlin 자매(`AuthClientInputBoundaryTest.kt`)와 같은 계약이다.
class AuthClientInputBoundaryTest {
  private static final URI CB = URI.create("http://localhost/cb");
  private static final String VALID_VERIFIER = "a".repeat(43);
  private HttpServer server;
  private final AtomicInteger hits = new AtomicInteger();
  private final List<String> bodies = new ArrayList<>();

  @AfterEach void stopServer() {
    if (server != null) server.stop(0);
  }

  // RFC 7636 §4.1: 43–128 자, [A-Za-z0-9-._~]. 짧음·빈 값·허용 밖 문자·과길이 넷 다 Nimbus 가 로컬에서 거부한다.
  @Test void exchangeCode_invalidVerifier_isSdkAuthErrorWithoutRequest() throws Exception {
    AuthClient client = clientServing(400, "{\"error\":\"invalid_grant\"}");
    for (String v : List.of("v", "", "a".repeat(42) + "!", "a".repeat(129))) {
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          () -> client.exchangeCode("code", CB, v), "verifier length " + v.length());
      assertEquals("Authorization code exchange request error: invalid code_verifier", e.getMessage());
      assertInstanceOf(IllegalArgumentException.class, e.getCause());
    }
    assertEquals(0, hits.get(), "거부된 값은 토큰 엔드포인트에 닿지 않는다");
  }

  // 대조군 — 경계값 43 자는 서버까지 간다(위 거부가 다른 원인이 아님을 보인다).
  @Test void exchangeCode_validVerifier_reachesTokenEndpoint() throws Exception {
    AuthClient client = clientServing(200, "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
    assertEquals("AT", client.exchangeCode("code", CB, VALID_VERIFIER).getAccessToken());
    assertEquals(1, hits.get());
  }

  @Test void exchangeCode_blankCode_isSdkAuthErrorWithoutRequest() throws Exception {
    AuthClient client = clientServing(400, "{\"error\":\"invalid_grant\"}");
    for (String code : List.of("", "   ")) {
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          () -> client.exchangeCode(code, CB, VALID_VERIFIER), "code '" + code + "'");
      assertEquals("Authorization code exchange request error: invalid code", e.getMessage());
      assertInstanceOf(IllegalArgumentException.class, e.getCause());
    }
    assertEquals(0, hits.get());
  }

  @Test void refresh_blankToken_isSdkAuthErrorWithoutRequest() throws Exception {
    AuthClient client = clientServing(400, "{\"error\":\"invalid_grant\"}");
    for (String token : List.of("", "   ")) {
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          () -> client.refresh(token), "refresh_token '" + token + "'");
      assertEquals("Token refresh request error: invalid refresh_token", e.getMessage());
      assertInstanceOf(IllegalArgumentException.class, e.getCause());
    }
    assertEquals(0, hits.get());
  }

  @Test void introspect_blankToken_isSdkAuthErrorWithoutRequest() throws Exception {
    AuthClient client = clientServing(400, "{\"error\":\"invalid_request\"}");
    for (String token : List.of("", "   ")) {
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          () -> client.introspect(token), "token '" + token + "'");
      assertEquals("Introspection request error: invalid token", e.getMessage());
      assertInstanceOf(IllegalArgumentException.class, e.getCause());
    }
    assertEquals(0, hits.get());
  }

  // null 은 값 오류가 아니라 호출 계약 위반이다 — refresh/logout/introspect 와 같이 SDK 가 소유한 메시지의
  // IllegalArgumentException 이다. 전에는 Nimbus 메시지의 IAE(code)·Nimbus 내부의 맨 NPE(verifier)·
  // Nimbus 의 IllegalStateException(redirectUri)이 각각 나갔다.
  @Test void nullArguments_areSdkOwnedPreconditions() throws Exception {
    AuthClient client = clientServing(400, "{\"error\":\"invalid_grant\"}");
    IllegalArgumentException code = assertThrows(IllegalArgumentException.class,
        () -> client.exchangeCode(null, CB, VALID_VERIFIER));
    assertEquals("code must not be null", code.getMessage());
    IllegalArgumentException verifier = assertThrows(IllegalArgumentException.class,
        () -> client.exchangeCode("code", CB, null));
    assertEquals("codeVerifier must not be null", verifier.getMessage());
    IllegalArgumentException redirect = assertThrows(IllegalArgumentException.class,
        () -> client.createAuthorizationRequest(null));
    assertEquals("redirectUri must not be null", redirect.getMessage());
    assertEquals(0, hits.get());
  }

  // Nimbus 는 인가 요청을 build() 할 때 redirect_uri 를 검사한다 — fragment(RFC 6749 §3.1.2)·금지 scheme·
  // 금지 쿼리 파라미터를 IllegalStateException 으로 거부한다. 잘못된 콜백 URL 은 IdP 가 거절한 것이 아니라
  // 앱 구성 오류다(Rust `redirect_url()`·Kotlin 과 같은 분류).
  @Test void createAuthorizationRequest_redirectRejectedByNimbus_isSdkConfigError() {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    AuthClient client = new AuthClient(cfg, OidcMetadata.forRealm(cfg));
    for (String uri : List.of("http://localhost/cb#frag", "javascript:alert(1)", "http://localhost/cb?code=1")) {
      KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
          () -> client.createAuthorizationRequest(URI.create(uri)), uri);
      assertTrue(e.getMessage().startsWith("invalid redirect_uri: "), e.getMessage());
      assertInstanceOf(IllegalStateException.class, e.getCause(), uri);
    }
    // 대조군 — 평범한 콜백은 그대로 URL 이 된다(위 거부가 모든 URI 를 막는 것이 아님을 보인다).
    assertDoesNotThrow(() -> client.createAuthorizationRequest(CB));
  }

  // scope 에 정확한 "openid" 가 없으면 Nimbus AuthenticationRequest.Builder 가 IAE 로 샜다. 자매 일곱은 scope 를
  // 그대로 보내므로(실측 2026-09-25) 그 경우는 플레인 OAuth2 인가 요청으로 만든다 — nonce 는 파라미터로 싣는다.
  // 경로의 `openid-connect` 와 구분하려고 쿼리만 본다.
  @Test void createAuthorizationRequest_scopeWithoutOpenid_isPassedThrough() throws Exception {
    AuthorizationUrlRequest req = clientServing(400, "{}", "profile").createAuthorizationRequest(CB);
    String query = req.getAuthorizationUrl().getRawQuery();
    assertTrue(query.contains("scope=profile"), query);
    assertTrue(query.contains("nonce=" + req.getNonce()), query);
    assertTrue(query.contains("state=" + req.getState()), query);
    assertTrue(query.contains("code_challenge_method=S256"), query);
    assertFalse(query.contains("openid"), query);
    assertEquals(0, hits.get());
  }

  @Test void createAuthorizationRequest_upperCaseOpenid_isPassedThroughUnchanged() throws Exception {
    String query = clientServing(400, "{}", "OPENID").createAuthorizationRequest(CB).getAuthorizationUrl().getRawQuery();
    assertTrue(query.contains("scope=OPENID"), query);
    assertFalse(query.contains("scope=openid"), query);
  }

  // 대조군 — scope 미설정은 여전히 openid 폴백이고 OIDC 경로를 탄다.
  @Test void createAuthorizationRequest_defaultScopes_stillOpenid() throws Exception {
    String query = clientServing(400, "{}").createAuthorizationRequest(CB).getAuthorizationUrl().getRawQuery();
    assertTrue(query.contains("scope=openid"), query);
  }

  // OAuth2 경로의 build() 도 redirect_uri 를 검사한다 — 그 ISE 도 SDK 타입이어야 한다.
  @Test void createAuthorizationRequest_withoutOpenid_rejectedRedirect_isSdkConfigError() throws Exception {
    AuthClient client = clientServing(400, "{}", "profile");
    KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
        () -> client.createAuthorizationRequest(URI.create("http://localhost/cb#frag")));
    assertTrue(e.getMessage().startsWith("invalid redirect_uri: "), e.getMessage());
  }

  // 공백 scope 전례(`AuthClientScopeFallbackTest`)는 createAuthorizationRequest 만 고쳤다 — 같은 설정이
  // client_credentials 에서는 그대로 샜다. 공백 원소만 버리고, 남는 것이 없으면 scope 를 싣지 않는다.
  @Test void clientCredentials_blankScopes_areDroppedNotLeaked() throws Exception {
    assertEquals("AT", clientCredentialsWithScopes(" ").clientCredentialsToken().getAccessToken());
    assertFalse(bodies.get(0).contains("scope="), bodies.get(0));
    server.stop(0);
    clientCredentialsWithScopes("openid", "", "profile").clientCredentialsToken();
    assertTrue(bodies.get(1).contains("scope=openid+profile"), bodies.get(1));
  }

  // 대조군 — scope 를 설정하지 않으면 원래부터 scope 를 싣지 않았다(위 드롭이 이것과 같은 모양이다).
  @Test void clientCredentials_noScopes_sendsNoScope() throws Exception {
    clientCredentialsWithScopes().clientCredentialsToken();
    assertFalse(bodies.get(0).contains("scope="), bodies.get(0));
  }

  private AuthClient clientCredentialsWithScopes(String... scopes) throws Exception {
    return clientServing(200, "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}", scopes);
  }

  private AuthClient clientServing(int status, String body, String... scopes) throws Exception {
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", ex -> {
      hits.incrementAndGet();
      bodies.add(new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(status, bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    });
    server.start();
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("app")
        .clientSecret("secret".toCharArray()).scopes(scopes).build();
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }
}
