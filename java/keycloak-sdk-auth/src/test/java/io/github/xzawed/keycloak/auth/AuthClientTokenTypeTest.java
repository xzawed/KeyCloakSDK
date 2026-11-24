package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.ParseException;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

// 토큰 응답의 access_token 이 비어 있지 않은 문자열이 아니면 거절하는 것은 **우리 코드가 아니라 Nimbus
// `TokenResponse.parse`** 다. 교차언어 가드는 그 호출의 존재만 봤다 — 라이브러리가 관용해지면(.NET 의
// Duende 가 실제로 강제변환했다) 쓸 수 없는 토큰이 성공으로 나가도 아무도 모른다. 그 행동을 여기서 고정한다.
class AuthClientTokenTypeTest {
  private HttpServer server;

  @AfterEach void stopServer() {
    if (server != null) server.stop(0);
  }

  @Test void clientCredentialsToken_rejectsNonStringOrEmptyAccessToken() throws Exception {
    for (String raw : List.of("12345", "{\"a\":1}", "[]", "true", "null", "\"\"")) {
      AuthClient client = clientServingToken("{\"access_token\":" + raw
          + ",\"token_type\":\"Bearer\",\"expires_in\":300}");
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          client::clientCredentialsToken, "access_token " + raw);
      assertEquals("Client credentials request error", e.getMessage(), "access_token " + raw);
      // 원인은 Nimbus 파서 예외의 **사본**이다 — 타입 이름은 남고 메시지(응답을 인용할 수 있다)는 보류된다.
      assertFalse(e.getCause() instanceof ParseException, "access_token " + raw);
      assertTrue(e.getCause().getMessage().startsWith(ParseException.class.getName() + " (message withheld"),
          "access_token " + raw + ": " + e.getCause().getMessage());
      server.stop(0);
    }
  }

  // 대조군 — 같은 경로에서 문자열 access_token 은 통과한다(위 거절이 다른 원인이 아님을 보인다).
  @Test void clientCredentialsToken_acceptsStringAccessToken() throws Exception {
    AuthClient client = clientServingToken(
        "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
    assertEquals("AT", client.clientCredentialsToken().getAccessToken());
  }

  // 성공 상태(200)의 본문이 비어 있지 않은 문자열 error 를 실으면 그 레인의 OAuth 오류 응답이다 — 400 이 같은 본문을 실었을 때와 같은
  // 메시지(설명 「d」, 없으면 상태)와 코드. 토큰이 함께 실려도 돌려주지 않고 active 가 참이어도 활성으로 읽지 않는다. 수정 전에는 B1 이 코드
  // 없는 「… request error」 였고 B2 는 성공이었다(등록부 auth-2xx-error-code-divergent — 레인 전체는 keycloak-sdk 의 TokenResponseClassTest).
  @Test void successStatusOAuthError_failsAsTheErrorResponse() throws Exception {
    String b1 = "{\"error\":\"invalid_grant\",\"error_description\":\"d\"}";
    String b2 = "{\"error\":\"invalid_grant\",\"access_token\":\"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl\","
        + "\"token_type\":\"Bearer\",\"expires_in\":300}";
    AuthClient client = clientServing("application/json", b1, "{\"error\":\"invalid_token\"}");
    assertError("Client credentials failed: d", "invalid_grant", client::clientCredentialsToken);
    assertError("Authorization code exchange failed: d", "invalid_grant",
        () -> client.exchangeCode("code-1", java.net.URI.create("https://app.example/cb"), VERIFIER));
    assertError("Introspection failed: HTTP 200", "invalid_token", () -> client.introspect("tok-1"));
    server.stop(0);
    AuthClient withToken = clientServing("application/json", b2, "{\"error\":\"invalid_token\",\"active\":true}");
    assertError("Token refresh failed: HTTP 200", "invalid_grant", () -> withToken.refresh("rt-1"));
    assertError("Authorization code exchange failed: HTTP 200", "invalid_grant",
        () -> withToken.exchangeCode("code-1", java.net.URI.create("https://app.example/cb"), VERIFIER));
    assertError("Introspection failed: HTTP 200", "invalid_token", () -> withToken.introspect("tok-1"));
  }

  // error 가 있고 null 도 "" 도 아니면 — 숫자 · 객체 · 배열 · 불리언도 — 그 레인의 오류 응답이다: 400 이 같은 본문을 실었을 때와 같은
  // 메시지(상태)이고 코드는 없다(문자열이 아니다 — 등록부 token-response-residual-divergence A · 예전에는 대조군이었다: 토큰을 쓰고 활성으로
  // 읽었다). 대조 — null · "" 는 지금처럼 나머지가 판정한다(토큰을 쓰고 활성으로 읽는다). JSON 객체가 아닌 본문 · JSON 이 아닌
  // Content-Type 도 판정하지 않는다 — 성공 파서가 지금처럼 거부한다.
  @Test void successStatusOAuthError_anyErrorButNullOrEmptyCounts() throws Exception {
    for (String value : List.of("12345", "{\"e\":\"invalid_grant\"}", "[\"invalid_grant\"]", "true")) {
      AuthClient client = clientServing("application/json",
          "{\"error\":" + value + ",\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}",
          "{\"error\":" + value + ",\"active\":true}");
      assertError("Client credentials failed: HTTP 200", null, client::clientCredentialsToken);
      assertError("Introspection failed: HTTP 200", null, () -> client.introspect("tok-1"));
      server.stop(0);
    }
    for (String value : List.of("null", "\"\"")) {
      AuthClient client = clientServing("application/json",
          "{\"error\":" + value + ",\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}",
          "{\"error\":" + value + ",\"active\":true}");
      assertEquals("AT", client.clientCredentialsToken().getAccessToken(), "error " + value);
      assertTrue(client.introspect("tok-1").isActive(), "error " + value);
      server.stop(0);
    }
    String b1 = "{\"error\":\"invalid_grant\",\"error_description\":\"d\"}";
    AuthClient array = clientServing("application/json", "[" + b1 + "]", "[" + b1 + "]");
    assertEquals("Client credentials request error",
        assertThrows(KeycloakAuthException.class, array::clientCredentialsToken).getMessage());
    server.stop(0);
    AuthClient plain = clientServing("text/plain", b1, "{\"error\":\"invalid_token\"}");
    assertEquals("Client credentials request error",
        assertThrows(KeycloakAuthException.class, plain::clientCredentialsToken).getMessage());
    assertEquals("Introspection request error",
        assertThrows(KeycloakAuthException.class, () -> plain.introspect("tok-1")).getMessage());
  }

  private static final String VERIFIER = "ZttVERIFIER-0123456789abcdefghijklmnopqrstuvwxyz";

  private static void assertError(String message, String code, org.junit.jupiter.api.function.Executable call) {
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class, call, message);
    assertEquals(message, e.getMessage());
    assertEquals(code, e.getError(), message);
  }

  private AuthClient clientServingToken(String body) throws Exception {
    return clientServing("application/json", body, "{\"active\":false}");
  }

  /** 토큰 엔드포인트는 {@code tokenBody} 를, introspection 엔드포인트는 {@code introspectionBody} 를 200 · {@code contentType} 으로 낸다. */
  private AuthClient clientServing(String contentType, String tokenBody, String introspectionBody) throws Exception {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    serve("/realms/r/protocol/openid-connect/token", contentType, tokenBody);
    serve("/realms/r/protocol/openid-connect/token/introspect", contentType, introspectionBody);
    server.start();
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("app")
        .clientSecret("secret".toCharArray()).build();
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }

  private void serve(String path, String contentType, String body) {
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    server.createContext(path, ex -> {
      ex.getRequestBody().readAllBytes();
      ex.getResponseHeaders().add("Content-Type", contentType);
      ex.sendResponseHeaders(200, bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    });
  }
}
